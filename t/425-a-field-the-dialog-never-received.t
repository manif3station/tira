#!/usr/bin/env perl
# What the card dialog is told about an attachment.
#
# TKT-645 gave the browser viewer one way to decide whether a file can be shown
# as text: the content_type the engine computes. The viewer's own extension
# list was deleted in the same change, which is the point - two lists drift,
# and this board has spent a day finding pairs of them.
#
# But record_show does not carry content_type, and the dialog is filled from
# record_show. So the viewer asked every attachment a question the payload had
# no answer to, read undefined as "not text", and offered the download message
# for every source file on every real card. The Perl suite passed throughout:
# nothing in it opens the dialog. A browser test unrelated to this card caught
# it, and only because it drives the live page rather than a fixture.
#
# The fix is not to teach record_show the field. Computing it stats the stored
# file and sometimes reads its first bytes, and a record is read on every gate,
# every police pass and every board render. attachment_list already computes
# it, from the one implementation, when asked - so the detail provider asks and
# stamps the answer on.
#
# This file pins the payload the dialog actually receives, which is the thing
# that was wrong. A fixture cannot: the browser test that passed while this was
# broken passed because its fixture supplied a field the server did not.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-28T07:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'A field the dialog never received',
    dir           => $root,
    members       => ['michael'],
    columns       => ['backlog, implement, done'],
    sow_prefix    => 'AFS',
    epic_prefix   => 'AFE',
    ticket_prefix => 'AFT',
);
my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with a program on it' );

my $program = File::Spec->catfile( $tmp, 'hello.pl' );
open my $fh, '>', $program or die "cannot write $program: $!";
print {$fh} "#!/usr/bin/perl\nmy \$x = 1;  # a comment\n";
close $fh;
$tira->attachment_add( project => $root, ref => $card->{ref}, file => $program );

# A NUL byte is what makes this one binary, not its name - the extension is
# unknown to both named lists, so the engine has to look.
my $blob = File::Spec->catfile( $tmp, 'thing.dat' );
open my $bin, '>', $blob or die "cannot write $blob: $!";
binmode $bin;
print {$bin} "\0\1\2\3binary\0";
close $bin;
$tira->attachment_add( project => $root, ref => $card->{ref}, file => $blob );

my $comment = $tira->comment_add(
    project => $root, ref => $card->{ref}, author => 'michael',
    text => 'A comment carrying its own file' );
my $note = File::Spec->catfile( $tmp, 'note.md' );
open my $md, '>', $note or die "cannot write $note: $!";
print {$md} "# a note\n";
close $md;
$tira->attachment_add(
    project => $root, ref => $card->{ref}, file => $note,
    comment => $comment->{id} );

# A question carries attachments in three more places - its own, its voice
# note, and its answer's - and the viewer opens all of them from the same
# strip, so all of them have to be stamped. Without a question here the three
# lines that reach them are never run, and "it works" would mean "it works for
# the two shapes I happened to fixture".
my $asked = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'claude',
    text => 'Which of these should the viewer show inline?' );

my $evidence = File::Spec->catfile( $tmp, 'evidence.py' );
open my $py, '>', $evidence or die "cannot write $evidence: $!";
print {$py} "def main():\n    return 1\n";
close $py;
$tira->question_attach(
    project => $root, ref => $card->{ref}, id => $asked->{id}, file => $evidence );

my $spoken = File::Spec->catfile( $tmp, 'asked.wav' );
open my $wav, '>', $spoken or die "cannot write $spoken: $!";
binmode $wav;
print {$wav} "RIFF\0\0\0\0WAVEfmt ";
close $wav;
$tira->question_voice(
    project => $root, ref => $card->{ref}, id => $asked->{id}, file => $spoken );

$tira->question_answer(
    project => $root, ref => $card->{ref}, id => $asked->{id},
    author => 'michael', text => 'Show the source, not the recording.' );
my $reply = File::Spec->catfile( $tmp, 'reply.sql' );
open my $sql, '>', $reply or die "cannot write $reply: $!";
print {$sql} "select 1;\n";
close $sql;
$tira->question_attach(
    project => $root, ref => $card->{ref}, id => $asked->{id},
    to => 'answer', file => $reply );

# The subject has to exist before anything is asserted about it. record_show
# not carrying the field is the fault this file exists for, so it is stated
# rather than assumed - if it ever starts carrying it, this test should be
# reconsidered, not silently kept.
my $bare = $tira->record_show( project => $root, ref => $card->{ref} );
my @bare_attachments = @{ $bare->{attachments} // [] };
is( scalar @bare_attachments, 2, 'the card holds both of its own attachments' );
ok( !exists $bare_attachments[0]{content_type},
    'record_show does not compute a content type - that is why the dialog '
      . 'has to be given one' );

my %providers =
  Tira::CLI::browser_providers( tira => $tira, project => $root );
ok( ref $providers{detail} eq 'CODE', 'the browser is given a detail provider' );

my $payload = $providers{detail}->( { ref => $card->{ref} } );
ok( length $payload, 'the detail provider answered with a payload' );

my $seen = Cpanel::JSON::XS->new->decode($payload);
my @attachments = @{ $seen->{attachments} // [] };
is( scalar @attachments, 2, 'and the payload carries both attachments' );

my %type_of = map { ( $_->{original_filename} // '' ) => $_->{content_type} }
  @attachments;

is( $type_of{'hello.pl'}, 'text/plain; charset=UTF-8',
    'a Perl file reaches the dialog as text, which is the only thing that '
      . 'makes the viewer show it' );
is( $type_of{'thing.dat'}, 'application/octet-stream',
    'and a file whose bytes are binary reaches it as binary, so the viewer '
      . 'still refuses rather than rendering mojibake' );

my ($comment_seen) = @{ $seen->{comments} // [] };
my ($carried) = @{ ( $comment_seen || {} )->{attachments} // [] };
ok( $carried, 'the comment still carries its own attachment' );
is( ( $carried || {} )->{content_type}, 'text/plain; charset=UTF-8',
    'a comment attachment is stamped too - the viewer opens it from the same '
      . 'strip and cannot tell where it came from' );

my ($question_seen) = @{ $seen->{questions} // [] };
ok( $question_seen, 'the payload carries the question' );

my ($on_question) = @{ ( $question_seen || {} )->{attachments} // [] };
is( ( $on_question || {} )->{content_type}, 'text/plain; charset=UTF-8',
    'a file hung on a question is stamped - it opens from the same strip as '
      . 'the card\'s own' );

is( ( ( $question_seen || {} )->{voice} || {} )->{content_type},
    'audio/wav',
    'a voice note is stamped as well, and as the audio it is - the engine '
      . 'answers wav before it ever looks at the bytes, which a RIFF header '
      . 'full of NULs would otherwise have called binary' );

my ($on_answer) =
  @{ ( ( $question_seen || {} )->{answer} || {} )->{attachments} // [] };
is( ( $on_answer || {} )->{content_type}, 'text/plain; charset=UTF-8',
    'and a file hung on the answer is stamped, which is the third place a '
      . 'question can carry one' );

# Attachments are content-addressed, so a sha does not identify an attachment -
# the same bytes under two names are two entries sharing one sha, and the type
# follows the name as well as the content. This is the case where that matters:
# a valid SVG is also valid text, so the two answers differ.
my $shared = "<svg xmlns='http://www.w3.org/2000/svg'><text>hi</text></svg>\n";
for my $name ( 'twin.svg', 'twin.txt' ) {
    my $path = File::Spec->catfile( $tmp, $name );
    open my $out, '>', $path or die "cannot write $path: $!";
    print {$out} $shared;
    close $out;
    $tira->attachment_add( project => $root, ref => $card->{ref}, file => $path );
}

my $twinned = Cpanel::JSON::XS->new->decode(
    $providers{detail}->( { ref => $card->{ref} } ) );
my %twin_type =
  map { ( $_->{original_filename} // '' ) => $_->{content_type} }
  @{ $twinned->{attachments} // [] };

is( $twin_type{'twin.svg'}, 'image/svg+xml',
    'the .svg copy is stamped as an image' );
is( $twin_type{'twin.txt'}, 'text/plain; charset=UTF-8',
    'and the .txt copy holding the identical bytes is stamped as text - '
      . 'keying the lookup on the sha alone gave both whichever came last, '
      . 'and the SVG opened in the text pane' );

# The stamp must not invent entries or lose them, since the strip is rendered
# straight from this list.
my @named = sort map { $_->{original_filename} // '' } @attachments;
is_deeply( \@named, [ 'hello.pl', 'thing.dat' ],
    'stamping changed no filename and added no attachment' );

# An attachment store that cannot be read costs the preview, not the card:
# without this the dialog would fail to open at all, which is a far worse
# failure than a file offered as a download.
my $store = File::Spec->catdir( $root, '.tira', 'attachments' );
my $moved = File::Spec->catdir( $root, '.tira', 'attachments-elsewhere' );
rename $store, $moved or die "cannot move the attachment store: $!";
my $without = eval { $providers{detail}->( { ref => $card->{ref} } ) };
my $died = $@;
ok( defined $without && !$died,
    'the card still opens when its attachment store has gone - the detail '
      . 'provider answered rather than dying with: '
      . ( $died || 'no error' ) );
rename $moved, $store or die "cannot restore the attachment store: $!";

done_testing();

__END__

=head1 NAME

t/425-a-field-the-dialog-never-received.t - the card dialog must be told what
its attachments are

=head1 DESCRIPTION

TKT-645 gave the browser viewer one way to decide whether a file can be shown
as text: the C<content_type> the engine computes. The viewer's own extension
list was deleted in the same change, which is the point - two lists drift, and
this board spent a day finding pairs of them.

But C<record_show> does not carry C<content_type>, and the dialog is filled
from C<record_show>. So the viewer asked every attachment a question the
payload could not answer, read undefined as "not text", and offered the
download message for every source file on every real card. The Perl suite
passed throughout, because nothing in it opens the dialog.

The fix is not to teach C<record_show> the field. Computing it stats the stored
file and sometimes reads its first bytes, and a record is read on every gate,
every police pass and every board render. C<attachment_list> already computes
it, from the one implementation, when asked - so the detail provider asks and
stamps the answer on by C<sha>.

This file pins the payload the dialog actually receives, which is the thing
that was wrong. A fixture cannot: the browser test that passed while this was
broken passed because its fixture supplied a field the server did not.

=cut
