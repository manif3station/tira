package Tira::Tasklist;

# The tasklist commands, lifted out of Tira.pm so that reading the engine to
# change one command no longer means reading these too. TKT-746's second lift
# (TKT-832), after TKT-830 moved the TOON overrides into Tira::Toon.
#
# LOADED LAZILY. Tira.pm's entry points (tasklist_add, tasklist_list, and the
# rest) are thin forwarders that require this module only when one of them is
# actually called - a command that never touches the tasklist never compiles
# it. t/484 asserts both halves of that: this module compiles and works
# standalone, without Tira.pm having been loaded first, and a command that
# never touches the tasklist leaves it out of %INC.
#
# ENTRY POINTS KEEP THEIR OLD NAMES. Every sub here is called as
# $tira->tasklist_add(...) etc. by Tira::CLI::Browser and by the test suite,
# so Tira.pm keeps a same-named forwarding sub for each one - the same shape
# Tira::CLI::Browser already uses for browser_providers. A lift is a move,
# not a rename.
#
# NO CALL SITE OUTSIDE THIS CONCERN NEEDED TO CHANGE. Every sub below that
# takes $self as its first argument is called the same way it always was,
# regardless of which package's code is executing, because $self is still a
# blessed Tira object - no cycle, nothing here needs `use Tira`. The one
# sub called as a bareword (not a method) from outside this block,
# _tasklist_session (Tira::search's own use of it), still resolves too:
# Tira.pm keeps a same-named plain-function forwarder for it, the same as
# every method-style entry point below gets one.

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Spec;

# A parallel system to the ticket/epic/sow one, on purpose - TKT-504, his
# design: free text, three fixed states, no gates or checklists. Kept beside
# the project file for the same reason warnings are: every command must be
# able to read it and none of them should need SQLite to do so.
sub _tasklist_path {
    my ( $self, $root ) = @_;
    return File::Spec->catfile( $root, '.tira', 'tasklist.json' );
}

my %TASKLIST_STATUS_CODE = ( pending => 0, working => 1, done => 2 );

# Accepts either the word or the code, his screenshot showed both ("0:
# pending" etc) - normalizes to the canonical int, or dies naming the three
# words, the same refusal shape the old string-only version used.
sub _tasklist_status_code {
    my ($value) = @_;
    return undef if !defined $value;
    return $TASKLIST_STATUS_CODE{$value} if exists $TASKLIST_STATUS_CODE{$value};

    # A CLI-supplied "0" is a string, and JSON::XS encodes a string that was
    # never used in numeric context as "0" (quoted), not 0 - found
    # adversarially: tasklist.update --status 0 stored a status unlike every
    # other write path's real int. +0 forces the numeric context once, here.
    return $value + 0 if $value =~ /\A[0-2]\z/;
    die "Status must be one of pending, working, done\n";
}

sub _tasklist_read {
    my ( $self, $root ) = @_;
    my $path = _tasklist_path( $self, $root);
    return [] if !-f $path;
    open my $fh, '<:raw', $path or die "Cannot read tasklist '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close tasklist '$path': $!\n";
    my $items = Tira::json_object()->utf8->decode($content);

    # TKT-508: status became a stored int (his design: "tasklist status is
    # enum, 0: pending 1: working 2: done"). A file written before this
    # shipped still has the old word - read transparently here, in memory
    # only; the next real write of that item is what actually upgrades the
    # file, so a project that is never touched again keeps working exactly
    # as it was, just read correctly either way.
    for my $item ( @{$items} ) {
        $item->{status} = $TASKLIST_STATUS_CODE{ $item->{status} }
          if defined $item->{status} && exists $TASKLIST_STATUS_CODE{ $item->{status} };
    }
    return $items;
}

# His follow-up, TKT-505: typing --session on every call is unnecessarily
# long once genuinely multi-agent, so an explicit --session is asked for
# first and the environment is the fallback - the same precedence every
# other explicit-flag-over-environment seam in this file already uses.
sub _tasklist_session {
    my (%args) = @_;
    return $args{session} if defined $args{session};
    return $ENV{TIRA_AGENT_SESSION} // '';
}

# Scoped by agent_session, his design: two sessions never see each other's
# items, and calling with none declared is single-agent mode, one shared
# list. Not a per-card field - a session id names who is asking, not
# something stored against a ticket. Sorted by the explicit order field
# rather than storage position, so shift/pop/unshift/slice can reorder
# without needing to rewrite every other item's created_at. TKT-507.
my %TASKLIST_NUMERIC_FIELD = map { $_ => 1 } qw(status order);

# What a tasklist item can be sorted BY. Named rather than inferred from
# whatever the first item happens to carry: an empty list would then accept
# every field, and a list whose first item lacks an optional one would refuse a
# field that is perfectly real. TKT-888.
my @TASKLIST_SORT_FIELD = qw(created_at id last_updated order session status text);
my %TASKLIST_SORT_FIELD = map { $_ => 1 } @TASKLIST_SORT_FIELD;

# His screenshot: "tira.tasklist.list --sort last_updated:desc,status:asc by
# default." A display sort, independent of the order field next/shift/pop
# use for queue position - this is what a person reading the list sees, not
# what FIFO/LIFO operate on.
sub _tasklist_sort_items {
    my ( $items, $sort_spec ) = @_;
    my @specs = map {
        my ( $field, $dir ) = split /:/, $_, 2;

        # DESC IS ACCEPTED, and the decision is recorded rather than left to be
        # inferred from the code. SQL writes DESC, every spreadsheet writes
        # DESC, and somebody typing it means desc unambiguously - refusing it
        # would be pedantry. What was never defensible is what this did before:
        # reading it as ASCENDING and handing back the opposite of the ask,
        # which looks exactly like an answer. TKT-888.
        $dir = defined $dir && $dir =~ /\S/ ? lc $dir : 'asc';

        # ANYTHING ELSE IS REFUSED rather than accepted and ignored - the fault
        # this file's own neighbours name by name: a flag that parses and does
        # nothing reads as confirmation. A sort is worse than a flag, because it
        # returns a list in an order nobody asked for and gives the caller no
        # reason to doubt it.
        die "A sort direction of '$dir' is not one this board understands - "
          . "use asc or desc (DESC and Desc are read as desc)\n"
          if $dir ne 'asc' && $dir ne 'desc';

        die "There is no '$field' to sort a tasklist by. The fields are: "
          . join( ', ', @TASKLIST_SORT_FIELD ) . "\n"
          if !defined $field || !$TASKLIST_SORT_FIELD{$field};

        [ $field, ( $dir eq 'desc' ? -1 : 1 ) ];
    } split /,/, $sort_spec;
    return [ sort {
        my $cmp = 0;
        for my $spec (@specs) {
            my ( $field, $mult ) = @{$spec};
            $cmp = $TASKLIST_NUMERIC_FIELD{$field}
              ? ( ( $a->{$field} // 0 ) <=> ( $b->{$field} // 0 ) ) * $mult
              : ( ( $a->{$field} // '' ) cmp ( $b->{$field} // '' ) ) * $mult;
            last if $cmp;
        }
        $cmp;
    } @{$items} ];
}

sub tasklist_list {
    my ( $self, %args ) = @_;
    my $root  = $self->discover_project(%args);
    my $items = _tasklist_read( $self, $root);

    # TKT-539: a deliberate, explicit opt-in for the one legitimate need
    # TKT-537/538 otherwise closed off - a supervising agent checking on
    # several subagents' tasklists without already knowing each one's
    # session id. Every other tasklist read/write stays single-session.
    my @mine = $args{all_sessions}
      ? @{$items}
      : grep { ( $_->{session} // '' ) eq _tasklist_session(%args) } @{$items};

    # TKT-545: the aggregation a list command is for. next/shift/pop already
    # filter to pending internally for their own single-item use, and update
    # already accepts pending|working|done or 0|1|2 - so the vocabulary
    # existed and only list could not be asked, leaving "what is still on my
    # plate" to be answered by pulling every item as JSON and filtering the
    # status field by hand.
    #
    # Through the same parser update uses, deliberately: it settles both
    # spellings in one place, and it DIES on a value it does not know rather
    # than matching nothing - an unknown status returning an empty list would
    # read as "no such work" when it means "no such status".
    if ( defined $args{status} ) {
        my $wanted = _tasklist_status_code( $args{status} );
        @mine = grep { ( $_->{status} // 0 ) == $wanted } @mine;
    }

    # TKT-552: the same shape again, for linkage instead of status. TKT-547's
    # task-unlinked rule watches for pending or working items with an empty
    # refs array, but only reports one once it has aged past its grace - so an
    # agent wanting to find them BEFORE the police does had to fetch every
    # item and filter refs itself.
    #
    # Linkage only, deliberately: the rule it serves watches pending and
    # working, but an audit that silently dropped done items would answer a
    # narrower question than the one asked. It composes with status rather
    # than replacing it, since the two read different fields.
    @mine = grep { !@{ $_->{refs} // [] } } @mine if $args{unlinked};

    # The same gap TKT-552 closed for --unlinked, open on the opposite
    # question - not "which items have no card at all" but "which items
    # belong to THIS card". --ref was a normal option name on many other
    # commands, so the generic CLI parser accepted it without complaint and
    # tasklist_list silently ignored it, returning the whole list instead of
    # refusing or filtering - a caller checking one card's own items got
    # every session's every item back, wrongly, with nothing saying so.
    # Composes with status/unlinked rather than replacing them, the same way
    # those two already compose with each other. TKT-802.
    if ( defined $args{ref} && $args{ref} ne '' ) {
        my $wanted_ref = $args{ref};
        @mine = grep { grep { $_ eq $wanted_ref } @{ $_->{refs} // [] } } @mine;
    }

    # Filter before sort, so an explicit --sort orders what survived rather
    # than being applied to a set the caller never asked for.
    return _tasklist_sort_items( \@mine, $args{sort} // 'last_updated:desc,status:asc' );
}

# TKT-541: closes the gap --all-sessions left open - a supervisor still had
# to hand-dedupe the session field out of a flat dump to find out which
# sessions even exist. No session-scoping args of its own: seeing every
# session is the whole point, the same way --all-sessions already treats it.
my @TASKLIST_STATUS_NAME = ( 'pending', 'working', 'done' );

sub tasklist_sessions {
    my ( $self, %args ) = @_;
    my $root  = $self->discover_project(%args);
    my $items = _tasklist_read( $self, $root);
    my %by_session;
    for my $item ( @{$items} ) {
        my $session = $item->{session} // '';
        my $row = $by_session{$session} //=
          { session => $session, count => 0, status => { pending => 0, working => 0, done => 0 } };
        $row->{count}++;
        $row->{status}{ $TASKLIST_STATUS_NAME[ $item->{status} // 0 ] // 'pending' }++;
    }
    return [ sort { $b->{count} <=> $a->{count} || $a->{session} cmp $b->{session} } values %by_session ];
}

sub _tasklist_counter_path {
    my ($root) = @_;
    return File::Spec->catfile( $root, '.tira', 'tasklist-counter' );
}

# Found adversarially: minting an id from the current items alone reused a
# ended item's id the moment the list emptied (shift/pop/remove genuinely
# delete, unlike every other record type's ids, which are never freed up
# because nothing is ever truly removed). A small counter file that only
# ever goes up, next to the list itself, survives every item being deleted.
sub _tasklist_next_id {
    my ( $root, $items ) = @_;
    my $counter_path = _tasklist_counter_path($root);
    my $max = 0;
    if ( open my $in, '<', $counter_path ) {
        my $line = <$in>;
        close $in;
        $max = $1 if defined $line && $line =~ /\A(\d+)/;
    }
    for my $item ( @{$items} ) {
        my ($number) = ( $item->{id} // '' ) =~ /(\d+)\z/;
        $max = $number if defined $number && $number > $max;
    }
    $max++;
    open my $out, '>', $counter_path or die "Cannot write '$counter_path': $!\n";
    print {$out} "$max\n";
    close $out or die "Cannot close '$counter_path': $!\n";
    return sprintf( 'TSK-%03d', $max );
}

# Content-addressed, the same store record attachments already use
# (.tira/attachments/<sha>.<ext>) - a screenshot attached to a task and one
# attached to a ticket share the blob if they are the same bytes.
sub _tasklist_store_attachment {
    my ( $self, $root, $file ) = @_;
    my $path = $self->_canonical_path( $file, "attachment '$file'" );
    open my $fh, '<:raw', $path or die "Cannot read attachment '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    return _tasklist_store_attachment_bytes( $self,  $root, basename($path), $content );
}

# Content-based twin, for a browser upload that has bytes but no server-side
# path - the same split attachment_add/attachment_add_content already draws
# for record attachments.
sub _tasklist_store_attachment_bytes {
    my ( $self, $root, $name, $content ) = @_;
    my $sha = sha256_hex($content);
    my $extension = $name =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : 'bin';
    my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
    $self->_atomic_write( $stored, $content ) if !-f $stored;
    return { sha => $sha, extension => $extension, original_filename => $name, added_at => $self->{clock}->() };
}

sub tasklist_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task text is required\n" if !defined $args{text} || $args{text} eq '';
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $max_order = 0;
        for my $item ( @{$items} ) {
            next if ( $item->{session} // '' ) ne $session;
            $max_order = $item->{order} if ( $item->{order} // 0 ) > $max_order;
        }
        my $now = $self->{clock}->();
        my $refs = $args{refs} // [];
        my $entry = {
            id => _tasklist_next_id( $root, $items ), text => $args{text}, status => 0,
            session => $session, refs => $refs, order => $max_order + 1,
            attachments => [ map { _tasklist_store_attachment( $self,  $root, $_ ) } @{ $args{attach} // [] } ],
            created_at => $now, last_updated => $now,
        };

        push @{$items}, $entry;
        $self->_write_json( _tasklist_path( $self, $root), $items );

        # A soft signal, not a hard refusal - tasklist's own "sticky-note,
        # no gates" design (Q-075). Hit three times in one real session
        # (TKT-675, TKT-788, TKT-793): each card already had a pending or
        # working item from an earlier pickup, and adding a fresh "pick
        # this up" item for the same card created a second,
        # indistinguishable entry, found only by manually cross-checking
        # the shared list by hand. A caller may still legitimately want
        # two distinct tasks on one card, so the new item is created
        # regardless - it just now names what it may be duplicating. A
        # done item is not "still owed" and does not count; an item with
        # no refs at all has nothing to compare against. Computed on the
        # response only, not written to the store - a stored value would
        # go stale the moment the item it names is later marked done or
        # removed, and this call has no reason to ever be re-read the way
        # a written field would be. TKT-806, Codex review.
        if (@{$refs}) {
            my %wanted = map { $_ => 1 } @{$refs};
            my ($existing) = grep {
                $_->{id} ne $entry->{id}
                  && ( $_->{session} // '' ) eq $session
                  && ( $_->{status} // 0 ) != 2
                  && grep { $wanted{$_} } @{ $_->{refs} // [] }
            } @{$items};
            return { %{$entry}, possible_duplicate => { id => $existing->{id}, text => $existing->{text} } } if $existing;
        }
        return $entry;
    } );
}

# Read-only - "the top of the queue", asked without disturbing it.
sub tasklist_next {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $session = _tasklist_session(%args);
    my %wanted_ref = map { $_ => 1 } @{ $args{refs} // [] };
    my @pending = sort { $a->{order} <=> $b->{order} }
      grep { !%wanted_ref || grep { $wanted_ref{$_} } @{ $_->{refs} // [] } }
      grep { ( $_->{session} // '' ) eq $session && ( ( $_->{status} // -1 ) == 0 ) }
      @{ _tasklist_read( $self, $root) };
    return $pending[0];
}

# Read AND remove, his own words - array shift, not a status change.
sub tasklist_shift {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my @pending = sort { $a->{order} <=> $b->{order} }
          grep { ( $_->{session} // '' ) eq $session && ( ( $_->{status} // -1 ) == 0 ) } @{$items};
        return undef if !@pending;
        my $chosen = $pending[0];
        $self->_write_json( _tasklist_path( $self, $root),
            [ grep { $_->{id} ne $chosen->{id} } @{$items} ] );
        return $chosen;
    } );
}

# The back of the queue, LIFO - the most recently pushed pending item.
sub tasklist_pop {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my @pending = sort { $b->{order} <=> $a->{order} }
          grep { ( $_->{session} // '' ) eq $session && ( ( $_->{status} // -1 ) == 0 ) } @{$items};
        return undef if !@pending;
        my $chosen = $pending[0];
        $self->_write_json( _tasklist_path( $self, $root),
            [ grep { $_->{id} ne $chosen->{id} } @{$items} ] );
        return $chosen;
    } );
}

# Jumps the queue - an order lower than anything else this session has,
# rather than an insertion that has to renumber the rest.
sub tasklist_unshift {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task text is required\n" if !defined $args{text} || $args{text} eq '';
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $min_order;
        for my $item ( @{$items} ) {
            next if ( $item->{session} // '' ) ne $session;
            $min_order = $item->{order}
              if !defined $min_order || ( $item->{order} // 0 ) < $min_order;
        }
        $min_order //= 1;
        my $now = $self->{clock}->();
        my $entry = {
            id => _tasklist_next_id( $root, $items ), text => $args{text}, status => 0,
            session => $session, refs => $args{refs} // [], order => $min_order - 1,
            created_at => $now, last_updated => $now,
        };
        push @{$items}, $entry;
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

# Insert at an arbitrary position - the only operation that renumbers,
# because "between two items" has no single order value to reuse safely
# forever without drifting into fractions.
sub tasklist_slice {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task text is required\n" if !defined $args{text} || $args{text} eq '';
    die "A position is required\n" if !defined $args{position};
    die "Position must not be negative\n" if $args{position} < 0;
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my @mine = sort { $a->{order} <=> $b->{order} }
          grep { ( $_->{session} // '' ) eq $session } @{$items};
        my @others = grep { ( $_->{session} // '' ) ne $session } @{$items};
        my $now = $self->{clock}->();
        my $entry = {
            id => _tasklist_next_id( $root, $items ), text => $args{text}, status => 0,
            session => $session, refs => $args{refs} // [],
            created_at => $now, last_updated => $now,
        };
        my $position = $args{position};
        $position = scalar @mine if $position > @mine;
        splice @mine, $position, 0, $entry;
        my $order = 1;
        $_->{order} = $order++ for @mine;
        $self->_write_json( _tasklist_path( $self, $root), [ @others, @mine ] );
        return $entry;
    } );
}

# Deletes the item outright - distinct from tasklist_update's --status done,
# which keeps it as a record of having been finished.
sub tasklist_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        $self->_write_json( _tasklist_path( $self, $root),
            [ grep { $_->{id} ne $args{id} } @{$items} ] );
        return $entry;
    } );
}

# His follow-up: "you can add the required actions items or checklist items
# to the tasklist, so you can focus on a task at a time." Copies a card's own
# still-pending required-actions/checklist entries into linked tasklist
# items. Idempotent via imported_from, so calling it again after new
# required-actions appear only adds the new ones.
sub tasklist_import {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "A card ref is required\n" if !defined $args{ref} || $args{ref} eq '';
    my $session = _tasklist_session(%args);
    my $record = $self->record_show(%args);
    my @source = (
        ( grep { ( $_->{status} // '' ) eq 'pending' } @{ $record->{required_items} // [] } ),
        ( grep { ( $_->{status} // '' ) eq 'pending' } @{ $record->{checklist} // [] } ),
    );
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my %already = map { ( $_->{imported_from} // '' ) => 1 }
          grep { ( $_->{session} // '' ) eq $session } @{$items};
        my @created;
        for my $entry_source (@source) {
            my $tag = "$args{ref}#$entry_source->{id}";
            next if $already{$tag};
            my $max_order = 0;
            for my $item ( @{$items} ) {
                next if ( $item->{session} // '' ) ne $session;
                $max_order = $item->{order} if ( $item->{order} // 0 ) > $max_order;
            }
            my $now = $self->{clock}->();
            my $entry = {
                id => _tasklist_next_id( $root, $items ), text => $entry_source->{item}, status => 0,
                session => $session, refs => [ $args{ref} ], order => $max_order + 1,
                imported_from => $tag, created_at => $now, last_updated => $now,
            };
            push @{$items}, $entry;
            push @created, $entry;
            $already{$tag} = 1;
        }
        $self->_write_json( _tasklist_path( $self, $root), $items ) if @created;
        return \@created;
    } );
}

sub tasklist_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my $status_code = _tasklist_status_code( $args{status} );
    die "Status or text is required\n"
      if !defined $status_code && ( !defined $args{text} || $args{text} eq '' );
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        $entry->{status} = $status_code if defined $status_code;
        $entry->{text} = $args{text} if defined $args{text} && $args{text} ne '';
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

# His screenshot: "tira.tasklist.prune to remove all done items." Session-
# scoped like list/add - a shared (no-session) call prunes the shared list.
sub tasklist_prune {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my @pruned = grep { ( $_->{session} // '' ) eq $session && ( $_->{status} // -1 ) == 2 } @{$items};
        return \@pruned if !@pruned;
        my %pruned_id = map { $_->{id} => 1 } @pruned;
        $self->_write_json( _tasklist_path( $self, $root),
            [ grep { !$pruned_id{ $_->{id} } } @{$items} ] );
        return \@pruned;
    } );
}

sub _tasklist_find_item {
    my ( $items, $id, $session ) = @_;
    my ($entry) = grep { $_->{id} eq ( $id // '' ) } @{$items};
    die "No task '$id'\n" if !$entry;

    # A different session's item does not exist as far as this caller is
    # concerned - the same die a truly-missing id gets, so a probe cannot
    # tell "wrong session" from "no such task" apart. TKT-538: this check
    # was missing entirely, so any session could mutate or delete any
    # other session's item just by knowing its (sequential) id.
    die "No task '$id'\n"
      if defined $session && ( $entry->{session} // '' ) ne $session;
    return $entry;
}

# The four sub-verbs, operating on an existing item by --id rather than
# creating one: attach/discard files, link/unlink refs. Mirrors the shape
# tasklist.add already has (attachments content-addressed the same way,
# refs a plain deduplicated list), just applied after the item exists.
sub tasklist_task_attach_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my @files = @{ $args{files} // [] };
    die "At least one file is required\n" if !@files;
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        $entry->{attachments} //= [];
        for my $file (@files) {
            my $reference = _tasklist_store_attachment( $self,  $root, $file );
            my ($existing) = grep {
                $_->{sha} eq $reference->{sha} && $_->{extension} eq $reference->{extension}
            } @{ $entry->{attachments} };
            push @{ $entry->{attachments} }, $reference if !$existing;
        }
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

# Content-based twin for a browser upload, which has bytes rather than a
# server-side path - the dashboard's Task List section is the only caller.
sub tasklist_task_attach_add_content {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    die "Attachment upload requires filename and content\n"
      if !defined $args{filename} || $args{filename} eq '' || !defined $args{content};
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        $entry->{attachments} //= [];
        my $reference = _tasklist_store_attachment_bytes( $self,  $root, $args{filename}, $args{content} );
        my ($existing) = grep {
            $_->{sha} eq $reference->{sha} && $_->{extension} eq $reference->{extension}
        } @{ $entry->{attachments} };
        push @{ $entry->{attachments} }, $reference if !$existing;
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

sub tasklist_task_attach_discard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my @files = @{ $args{files} // [] };
    die "At least one file is required\n" if !@files;
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        my %discard = map { basename($_) => 1 } @files;
        $entry->{attachments} =
          [ grep { !$discard{ $_->{original_filename} // '' } } @{ $entry->{attachments} // [] } ];
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

sub tasklist_task_ref_link {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my @refs = @{ $args{refs} // [] };
    die "At least one ref is required\n" if !@refs;

    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );

        # Checked only once the item is confirmed to exist AND belong to
        # this session - t/397 (TKT-538) expects a cross-session attempt
        # to be told "No task", the same as every other tasklist.task.*
        # command, even when the ref it carries is also bogus; naming the
        # wrong problem first would leak a made-up ref's non-existence to
        # a caller who was never entitled to touch this item at all.
        #
        # A ref that names nothing real looked exactly like a real link
        # once stored - task-unlinked falls silent the moment any ref is
        # present, whether or not it means anything, so a typo here is
        # worse than no ref at all: it reads as solved and is not.
        # link_add already refuses this the same way, via the same
        # lookup. Checked before any ref is written, so one bad ref among
        # several good ones refuses the whole call rather than applying
        # the rest.
        #
        # Deliberately NOT extended to tasklist_add/unshift/slice, though
        # a Codex review on this card found the identical-looking gap
        # there: a ref naming no card is an accepted, tested state at
        # CREATION time elsewhere on this board (t/419's own QTK-404
        # fixture exists specifically to prove task-card-mismatch's
        # duplicate walk stays silent about a card nobody can open) -
        # linking is a considered claim an agent makes about existing
        # work; a fresh, still-unlinked task naming a not-yet-real card
        # is the ordinary, expected case this whole ticket exists to let
        # get linked LATER. TKT-682.
        $self->_record_data( project => $root, ref => $_ ) for @refs;

        $entry->{refs} //= [];
        my %have = map { $_ => 1 } @{ $entry->{refs} };
        for my $ref (@refs) {
            push @{ $entry->{refs} }, $ref if !$have{$ref}++;
        }
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

sub tasklist_task_ref_unlink {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Task id is required\n" if !defined $args{id} || $args{id} eq '';
    my @refs = @{ $args{refs} // [] };
    die "At least one ref is required\n" if !@refs;
    my $session = _tasklist_session(%args);
    return $self->_with_project_lock( $root, sub {
        my $items = _tasklist_read( $self, $root);
        my $entry = _tasklist_find_item( $items, $args{id}, $session );
        my %remove = map { $_ => 1 } @refs;
        $entry->{refs} = [ grep { !$remove{$_} } @{ $entry->{refs} // [] } ];
        $entry->{last_updated} = $self->{clock}->();
        $self->_write_json( _tasklist_path( $self, $root), $items );
        return $entry;
    } );
}

1;

__END__

=head1 NAME

Tira::Tasklist - the shared to-do queue, one concern lifted out of Tira.pm

=head1 DESCRIPTION

The tasklist commands (C<tasklist_add>, C<tasklist_list>, C<tasklist_next>,
and the rest) and their private C<_tasklist_*> helpers - a parallel system to
the ticket/epic/sow one, on purpose (TKT-504): free text, three fixed
states, no gates or checklists.

Loaded with C<require> from each forwarding entry point in F<lib/Tira.pm>,
not C<use>d at the top of the engine, so a command that never touches the
tasklist never compiles it. Every sub here still runs as if it were still a
C<Tira> method: C<$self> is a blessed C<Tira> object throughout, so calls
like C<$self-E<gt>_with_project_lock(...)> resolve exactly as they did
before the lift, with nothing here needing C<use Tira>.

=head1 CALL IT THROUGH TIRA, NOT DIRECTLY

C<Tira> is the public entry point and this module is an implementation
detail of it. Call C<$tira-E<gt>tasklist_add(...)> and its siblings, which
is what F<lib/Tira/CLI/Browser.pm> and the whole test suite do; the
same-named subs here take C<$self> as their first argument and exist to be
reached that way.

=head1 IF YOU EDIT THIS MODULE

Two properties are load-bearing and easy to undo by accident:

=over 4

=item * B<Do not add C<use Tira::Tasklist> to F<lib/Tira.pm>.> The
per-entry-point C<require> is the whole point of the lift - a top-level
C<use> would restore the cost it removed while leaving every test passing
on behaviour. This one is guarded rather than merely asked for: F<t/484>
runs a command that does not touch the task list and asserts
C<Tira/Tasklist.pm> is absent from C<%INC>, so collapsing the forwarders
into a top-level C<use> turns that assertion red.

=item * B<Do not call the private helpers as methods from in here.>
C<$self> is a blessed C<Tira>, and C<Tira> no longer defines
C<_tasklist_path> and friends, so C<$self-E<gt>_tasklist_path($root)>
compiles clean under C<perl -c> and dies at runtime with "Can't locate
object method". They are called as plain functions with C<$self> passed
explicitly for that reason. Methods that still live on C<Tira> -
C<_with_project_lock>, C<_write_json>, C<discover_project>,
C<_atomic_write>, C<_record_data>, C<record_show>, C<_canonical_path> -
are called as methods, as normal.

=back

Two helpers keep forwarders on C<Tira> because callers outside this concern
use them: C<_tasklist_read>, which C<search> and the police pass both read
the list with, and C<_tasklist_session>, which C<search> calls as a plain
function rather than a method.

=cut
