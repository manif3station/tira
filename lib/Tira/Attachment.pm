package Tira::Attachment;

# Attachments: storing a file, knowing what it is, and hanging it off a record.
#
# LIFTED OUT OF lib/Tira.pm BY TKT-746 (EPC-007). The engine held every command,
# rule and renderer in one file, so reading it to change one command meant
# reading all of it. Three concerns were lifted before this one - Tira::Toon,
# Tira::Tasklist, Tira::Render - and Tira::Job was written into its own module
# from the start for the same reason.
#
# MEASURED AT THE LIFT, commit 51a22aa: lib/Tira.pm was 14,584 lines and this
# concern was 12 subs and 405 of them. The number is stated with the commit it
# was taken at, because four other places in the tree state this file's size and
# every one of them is wrong (TKT-876) - which is what happens to a count copied
# forward instead of measured.
#
# WHY THIS CONCERN STANDS ALONE. It is a complete subsystem: store a file, sniff
# its type, read its head, attach it to a record, list, fetch, detach, discard.
# Its private helpers are already named for it, and nothing outside reaches into
# them.
#
# IT TAKES $self AND CALLS BACK THROUGH IT, which is the shape Tira::Job already
# uses. The engine keeps its own shared furniture - _atomic_write,
# _canonical_path, _load_yaml, _replace_record, _require_person,
# _safe_path_input, _with_project_lock, _write_yaml - and this module reaches it
# through the object it is handed. Only the concern moved.
#
# THREE HELPERS KEEP A NAME IN THE ENGINE. _store_attachment_file and
# _attachment_path are called by question_attach, question_voice and
# _backfill_added_at, because questions attach files through this store.
# _attachment_content_type is called by Tira::CLI and t/423 by its full package
# name, from another file - which is why two caller searches inside lib/Tira.pm
# both said it was free to leave, and the suite caught it instead. They live
# here and Tira forwards to all three: a lift that breaks its callers is not a
# lift.
#
# THE VOICE-TYPE LIST CAME TOO. %QUESTION_VOICE_TYPES was declared `our` in the
# engine, but a search across lib/ and t/ found its only reader was
# _store_attachment_file itself - so the `our` was vestigial and it is `my` here.
#
# THE IMPORTS ARE NOT DECORATION. This module calls sha256_hex and basename with
# no package prefix. Tira.pm imports both, and a lifted module that assumed it
# inherited them is exactly the third failure t/431 was written for: it
# compiles, and dies when reached.

use strict;
use warnings;

use Cpanel::JSON::XS ();
use Encode qw(encode_utf8);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Spec;

my %QUESTION_VOICE_TYPES = ( mp3 => 1, wav => 1, m4a => 1, ogg => 1, oga => 1, opus => 1, flac => 1 );

# One place that takes a path and returns a stored reference, shared by
# voice notes and by the evidence hung on a question or its answer. Content
# addressed like every other attachment, so the same file in three places is one
# file and the route that already serves attachments serves these.
sub _store_attachment_file {
    my ( $self, $root, $path, %opt ) = @_;
    die "A file is required\n" if !defined $path || $path !~ /\S/;
    my $extension = $path =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : '';
    if ( $opt{audio_only} ) {
        die "A voice note must be audio: " . join( ', ', sort keys %QUESTION_VOICE_TYPES ) . "\n"
          if !$QUESTION_VOICE_TYPES{$extension};
    }
    $extension = 'bin' if $extension eq '';
    my $safe = $self->_safe_path_input( $path, 'attachment' );
    open my $fh, '<:raw', $safe or die "Cannot read '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "That file is empty\n" if !length $content;
    die "That file is too large (16 MB maximum)\n" if length($content) > 16 * 1024 * 1024;
    my $sha = sha256_hex($content);
    $sha =~ /\A([0-9a-f]{64})\z/ or die "Cannot validate attachment\n";
    $sha = $1;
    my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
    $self->_atomic_write( $stored, $content ) if !-f $stored;
    return {
        sha => $sha, extension => $extension,

        # The browser hands over bytes in a temporary file, so the name it was
        # dropped under has to travel separately or the card records a
        # meaningless one.
        original_filename => $opt{filename} // basename($safe),
        added_at => $self->{clock}->(),
    };
}

sub attachment_add {
    my ( $self, %args ) = @_;
    die "An attachment is a file, given by --file\n" if !defined $args{file} || $args{file} eq '';
    my $file = $self->_canonical_path( $args{file}, "attachment '$args{file}'" );
    open my $fh, '<:raw', $file or die "Cannot read attachment '$file': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $self->attachment_add_content( %args, filename => basename($file), content => $content );
}

# Content-based twin of attachment_add for browser uploads: same sha dedup
# and reference bookkeeping, no temporary file, and a hard size cap so a
# dialog upload cannot balloon the store.
sub attachment_add_content {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $content = $args{content};
        die "Attachment upload requires filename and content\n"
          if !defined $args{filename} || $args{filename} eq '' || !defined $content;
        die "Attachment upload is too large (16 MB maximum)\n" if length($content) > 16 * 1024 * 1024;

        # A long proof quoting the dashboard's own emoji, an em dash, or an
        # accented name arrives as a character string, and Digest::SHA dies
        # on one containing code points above 255 - "Wide character in
        # subroutine entry" naming a hashing routine the caller has never
        # heard of. Encoded to bytes first, the same pattern DashboardWeb's
        # and OnboardWeb's own _response_bytes already use, hashing and
        # writing see exactly what was sent - and a byte string (the common
        # case: a file already read with :raw, or pure ASCII) passes through
        # unchanged, so an existing attachment keeps the hash it always had.
        # TKT-687.
        $content = encode_utf8($content) if utf8::is_utf8($content);
        my $sha = sha256_hex($content);
        $sha =~ /\A([0-9a-f]{64})\z/ or die "Cannot validate attachment SHA\n";
        $sha = $1;
        my $name = $args{filename};
        my $extension = $name =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : 'bin';
        my $root = $self->discover_project(%args);
        my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
        $self->_atomic_write( $stored, $content ) if !-f $stored;
        my $reference = { sha => $sha, extension => $extension, original_filename => $name, added_at => $self->{clock}->() };
        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $attachments;
        if ( defined $args{comment} ) {
            my ($comment) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$comment;
            $attachments = $comment->{attachments};
        }
        else {
            $attachments = $record->{attachments};
        }
        my ($retained) = grep { $_->{sha} eq $sha && $_->{extension} eq $extension } @{$attachments};

        # A write that cannot take does not report success. These bytes are set
        # aside on this card, so deduplication would answer with the discarded
        # record - original timestamp, discarded_at still on it, deduped true,
        # exit zero - and create nothing. A project lost ten screenshots to
        # that: their script counted exit codes and reported ten fresh
        # attachments having made none, and the only repair left was to change
        # the bytes until the hash moved.
        #
        # Refused rather than revived. Reviving is friendlier, and discard is
        # described as setting aside rather than deleting, so being unable to
        # put it back is the surprise - but a refusal cannot lose anything, and
        # a revive can be added on top of one. It could not be added on top of
        # silence.
        die "These bytes were discarded on '$args{ref}' and adding them again "
          . "will not bring them back. Attach different content, or say so "
          . "explicitly on the card.\n"
          if $retained && $retained->{discarded_at};

        my $deduped = defined $retained;
        if ( !$deduped ) {
            push @{$attachments}, $reference;
            $retained = $reference;
        }
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
        return {
            %{$retained}, supplied_filename => $name,
            deduped => $deduped ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
        };
    } );
}

# Removes one attachment reference from a record (or one of its comments).
# Storage is deduplicated by content hash, so the stored file is physically
# removed - through the logged attachment_remove workflow - only when no
# record or comment anywhere in the project still references it.
sub attachment_detach {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $root = $self->discover_project(%args);
        my $sha = $args{sha} // '';
        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $owner;
        if ( defined $args{comment} ) {
            ($owner) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$owner;
        }
        else {
            $owner = $record;
        }
        my @keep = grep {
            !( $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} ) )
        } @{ $owner->{attachments} };
        my ($reference) = grep {
            $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} )
        } @{ $owner->{attachments} };
        die "Attachment '$sha' is not attached there\n" if !$reference;
        $owner->{attachments} = \@keep;
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );

        my $extension = $reference->{extension};
        my $still_referenced = 0;
        for my $candidate ( @{ $self->record_list( project => $root ) } ) {
            my @pools = ( $candidate->{attachments}, map { $_->{attachments} } @{ $candidate->{comments} // [] } );
            for my $pool (@pools) {
                $still_referenced ||= grep { $_->{sha} eq $sha && $_->{extension} eq $extension } @{ $pool // [] };
            }
        }
        my $removed = 0;
        if ( !$still_referenced ) {
            $self->attachment_remove( project => $root, sha => $sha, extension => $extension );
            $removed = 1;
        }
        return {
            detached => Cpanel::JSON::XS::true, sha => $sha, extension => $extension,
            removed_from_store => $removed ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
        };
    } );
}

sub attachment_discard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $sha = $args{sha} // '';
        die "An attachment reference is required\n" if $sha eq '';
        $self->_require_person( %args, person => $args{author} ) if defined $args{author};

        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $owner = $record;
        if ( defined $args{comment} ) {
            ($owner) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$owner;
        }

        my ($reference) = grep {
            $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} )
        } @{ $owner->{attachments} };
        die "Attachment '$sha' is not attached there\n" if !$reference;

        # Stamping one twice would rewrite who discarded it and when, which is
        # the record somebody would be relying on.
        die "Attachment '$sha' is already discarded\n" if $reference->{discarded_at};

        # The stamp is the record of it. The work log reads it off the card
        # rather than being told separately, so the entry cannot be forgotten
        # and cannot be written by hand either.
        $reference->{discarded_at} = $self->{clock}->();
        $reference->{discarded_by} = $args{author};
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
        return $reference;
    } );
}

sub attachment_get {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    if ( defined $path && -f $path ) {
        open my $fh, '<:raw', $path or die "Cannot read attachment: $!\n";
        my $content = do { local $/; <$fh> };
        close $fh;
        return { content => $content, deleted => 0 };
    }
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    if ( -f $log_path ) {
        my $entries = $self->_load_yaml($log_path) || [];
        my ($entry) = reverse grep { $_->{sha} eq ( $args{sha} // '' ) && ( !defined $args{extension} || $_->{extension} eq $args{extension} ) } @{$entries};
        return { content => "Deleted at $entry->{deleted_at}\n", deleted => 1, deleted_at => $entry->{deleted_at} } if $entry;
    }
    die "Attachment '$args{sha}' not found\n";
}

sub attachment_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    die "Attachment '$args{sha}' not found\n" if !defined $path || !-f $path;
    my $extension = $args{extension} // ( basename($path) =~ /\.([^.]+)\z/ ? $1 : 'bin' );
    unlink $path or die "Cannot remove attachment: $!\n";
    my $entry = { sha => $args{sha}, extension => $extension, deleted_at => $self->{clock}->() };
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    my $entries = -f $log_path ? ( $self->_load_yaml($log_path) || [] ) : [];
    push @{$entries}, $entry;
    $self->_write_yaml( $log_path, $entries );
    return $entry;
}

my @ATTACHMENT_FIELDS = qw(sha extension original_filename added_at filename size content_type);
my %ATTACHMENT_FIELD = map { $_ => 1 } @ATTACHMENT_FIELDS;

sub _attachment_content_type {
    my ( $extension, $path ) = @_;
    my %image = map { $_ => 1 } qw(png jpg jpeg gif webp svg);
    return 'image/' . ( $extension eq 'jpg' ? 'jpeg' : $extension eq 'svg' ? 'svg+xml' : $extension )
      if $image{$extension};
    return 'image/tiff' if $extension eq 'tif' || $extension eq 'tiff';
    my %video = ( mp4 => 'video/mp4', m4v => 'video/mp4', mov => 'video/quicktime', webm => 'video/webm' );
    return $video{$extension} if $video{$extension};
    my %audio = ( mp3 => 'audio/mpeg', wav => 'audio/wav', m4a => 'audio/mp4', ogg => 'audio/ogg', flac => 'audio/flac' );
    return $audio{$extension} if $audio{$extension};
    return 'application/pdf' if $extension eq 'pdf';

    # TKT-645. This list held nine extensions and everything else was served
    # as a binary stream, so a program attached to a card was called binary by
    # the engine and refused by the viewer - which the owner hit on a shell
    # script he had asked to be attached to another card.
    #
    # The twelve languages the card names, plus the shell script that started
    # it and the handful of neighbours it would be perverse to exclude once
    # their siblings are in. Named rather than sniffed because these are known
    # answers: a .pl file is Perl whatever its first bytes look like, and an
    # empty one is still text.
    my %text = map { $_ => 1 } qw(
      txt md log csv json yml yaml xml html
      pl pm py rb java go rs php js jsx ts tsx css scss c h cpp hpp cc sh bash
      sql ini toml conf cfg diff patch tsv rst
    );
    return 'text/plain; charset=UTF-8' if $text{$extension};

    # And a list of things that are definitely NOT text, so the sniff below
    # never has to guess about them - a zip whose first bytes happen to look
    # printable must not be served as text, which is the card's fourth
    # acceptance criterion and the one thing "show everything" would break.
    my %binary = map { $_ => 1 } qw(
      zip tar gz bz2 xz 7z rar bin exe dll o so dylib a wasm class jar
      pyc pdf doc docx xls xlsx ppt pptx odt ods sqlite db
    );
    return 'application/octet-stream' if $binary{$extension};

    # Anything else is decided by looking, when there is something to look at.
    # That is what makes this a default rather than a longer list: a file with
    # an extension nobody anticipated is shown if it reads as text, and the
    # list above only exists to answer the cases where guessing would be worse
    # than knowing.
    return _looks_like_text( _attachment_head($path) )
      ? 'text/plain; charset=UTF-8' : 'application/octet-stream';
}

# The first few kilobytes of a stored attachment, or undef when there is
# nothing to read. Only reached for an extension in neither list, so the cost
# is paid on the unusual file rather than on every listing.
sub _attachment_head {
    my ($path) = @_;
    return undef if !defined $path || !-f $path;
    open my $fh, '<:raw', $path or return undef;
    read $fh, my $head, 8192;
    close $fh;
    return $head;
}

# a file on a card can live in three places - on the card, on a comment,
# or as a voice note on a question. Counting only the first meant a card whose
# files all hung off comments reported zero, and an agent read that zero as
# failure and went looking for a bug that was not there. A count that says zero
# when files exist is a lie by omission, so this looks everywhere and says where
# each one was found.
sub _record_attachments {
    my ($record) = @_;
    my @found = map { { %{$_}, attached_to => 'card' } } @{ $record->{attachments} // [] };
    for my $comment ( @{ $record->{comments} // [] } ) {
        push @found, map { { %{$_}, attached_to => "comment $comment->{id}" } }
          @{ $comment->{attachments} // [] };
    }
    for my $question ( @{ $record->{questions} // [] } ) {
        push @found, { %{ $question->{voice} }, attached_to => "question $question->{id}" }
          if $question->{voice};
        push @found, map { { %{$_}, attached_to => "question $question->{id}" } }
          @{ $question->{attachments} // [] };
        push @found, map { { %{$_}, attached_to => "answer $question->{id}" } }
          @{ $question->{answer}{attachments} // [] } if $question->{answer};
    }
    return \@found;
}

sub attachment_list {
    my ( $self, %args ) = @_;
    my $meta_only = delete $args{meta_only};
    my $count_mode = delete $args{count};
    my $since = delete $args{since};
    my $fields = delete $args{fields};
    if ( !defined $args{ref} ) {
        die "Attachment read options require --ref\n"
          if $meta_only || $count_mode || defined $since || defined $fields;
    }
    if ( defined $args{ref} && ( $meta_only || $count_mode || defined $since || defined $fields ) ) {
        my $keep;
        if ( defined $fields ) {
            my @names = map { split /,/, $_, -1 } @{$fields};
            for my $name (@names) {
                die "Empty field name in field selection\n" if !length $name;
                die "Unknown attachment field '$name'\n" if !$ATTACHMENT_FIELD{$name};
            }
            $keep = { map { $_ => 1 } @names };
        }
        my $references = _record_attachments( $self->record_show(%args) );
        if ( my @only = @{ $args{questions} // [] } ) {

            # Naming a question narrows to it, exactly as the owner asked. Naming
            # none shows everything, so a count can still be trusted.
            my %wanted = map { ( "question $_" => 1, "answer $_" => 1 ) } @only;
            $references = [ grep { $wanted{ $_->{attached_to} // '' } } @{$references} ];
        }
        if ( defined $since ) {
            my $threshold = Tira::_epoch_of_datetime( $since, 'Since' );
            $references = [ grep {
                my $stamp = eval { Tira::_epoch_of_datetime( $_->{added_at}, 'Added at' ) };
                !defined $stamp || $stamp >= $threshold;
            } @{$references} ];
        }
        return { count => scalar @{$references} } if $count_mode;
        my $root = $self->discover_project(%args);
        my @entries = map {
            my $reference = $_;
            my $stored = eval { $self->_attachment_path( $root, sha => $reference->{sha}, extension => $reference->{extension} ) };
            +{
                %{$reference},
                filename => $reference->{original_filename}
                  // ( ( $reference->{sha} // 'attachment' ) . '.' . ( $reference->{extension} // 'bin' ) ),
                size => ( defined $stored && -f $stored ) ? -s $stored : undef,
                content_type => _attachment_content_type( $reference->{extension} // '', $stored ),
            };
        } @{$references};
        if ($keep) {
            return [ map {
                my $entry = $_;
                +{ map { exists $entry->{$_} ? ( $_ => $entry->{$_} ) : () } ( 'sha', keys %{$keep} ) };
            } @entries ];
        }
        # CA12: newest evidence first, documented.
        @entries = sort {
            ( $b->{added_at} // '' ) cmp( $a->{added_at} // '' )
        } @entries;
        my $total_size = 0;
        $total_size += $_->{size} // 0 for @entries;
        return { attachments => \@entries, count => scalar @entries, total_size => $total_size };
    }
    return _record_attachments( $self->record_show(%args) ) if defined $args{ref};
    my $root = $self->discover_project(%args);
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @items = map { my ( $sha, $ext ) = /\A([0-9a-f]{64})\.([^.]+)\z/; { sha => $sha, extension => $ext } }
      grep { /\A[0-9a-f]{64}\.[^.]+\z/ } readdir $dh;
    closedir $dh;
    if ( $args{include_deleted} ) {
        my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
        if ( -f $log_path ) {
            push @items, map { { %{$_}, deleted => Cpanel::JSON::XS::true } } @{ $self->_load_yaml($log_path) || [] };
        }
    }
    return \@items;
}

sub _attachment_path {
    my ( $self, $root, %args ) = @_;
    my $sha = $args{sha} // '';
    die "Invalid attachment SHA\n" if $sha !~ /\A([0-9a-f]{64})\z/;
    $sha = $1;
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    if ( defined $args{extension} ) {
        die "Invalid attachment extension\n" if $args{extension} !~ /\A([A-Za-z0-9]+)\z/;
        my $extension = $1;
        return File::Spec->catfile( $dir, "$sha.$extension" );
    }
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @matches = map { /\A(\Q$sha\E)\.([A-Za-z0-9]+)\z/ ? File::Spec->catfile( $dir, "$1.$2" ) : () } readdir $dh;
    closedir $dh;
    die "Attachment SHA '$sha' has multiple extensions\n" if @matches > 1;
    return $matches[0];
}

# CAME WITH THE CONCERN. Its only caller was _attachment_content_type, so
# leaving it in the engine would have split one question - "is this file
# text?" - across two files.
# Whether bytes read as text, asked the way file(1) has always asked it: a NUL
# byte means binary, and so does a high proportion of bytes outside the
# printable and common-whitespace range. Deliberately conservative - undef or
# empty content is NOT text, because an unknown extension with nothing to
# examine is exactly the case where refusing and offering the download is the
# honest answer.
sub _looks_like_text {
    my ($content) = @_;
    return 0 if !defined $content || $content eq '';
    my $sample = substr $content, 0, 8192;
    return 0 if index( $sample, "\0" ) >= 0;
    my $odd = () = $sample =~ /[^\t\n\r\x20-\x7e\x80-\xff]/g;
    return ( $odd / length $sample ) < 0.1 ? 1 : 0;
}

1;

__END__

=head1 NAME

Tira::Attachment - storing files and hanging them off records

=head1 DESCRIPTION

The attachment concern, lifted out of L<Tira> by TKT-746: store a file, know
what it is, attach it to a record, and list, fetch, detach or discard it.

Every sub takes C<$self> - a blessed L<Tira> - and reaches the engine's shared
helpers through it. L<Tira> keeps a forwarder for each public verb, requiring
this module at the call site, so a command that never touches an attachment
never compiles it.

=head1 THREE PRIVATE HELPERS KEEP A NAME IN THE ENGINE

C<_store_attachment_file> and C<_attachment_path> are called by
C<question_attach>, C<question_voice> and C<_backfill_added_at> - questions
attach files through this store.

C<_attachment_content_type> is called by L<Tira::CLI> and by F<t/423> as
C<Tira::_attachment_content_type>, fully qualified across a file boundary.
Nothing inside F<lib/Tira.pm> calls it at all, which is why two caller searches
in a row said it could move outright: a leading underscore marks a name private
to a PACKAGE, not to a file.

All three live here; L<Tira> forwards to them.

=cut
