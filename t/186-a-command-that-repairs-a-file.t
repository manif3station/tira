#!/usr/bin/env perl
# A damaged file can be cleaned, by somebody who asked.
#
# His request, and his name for it: "a new command like tira.doctor that will
# remove special characters". Two boards carry history files holding a byte that
# is not valid UTF-8 - a multiplication sign written as latin-1 - which silenced
# twenty-seven rules until 1.78 and is read past since 1.80.
#
# One correction to what he described, because it changes what the command does.
# U+FFFD is not in his files. It is what a lenient decode PRODUCES when it meets
# a byte it cannot read, so it is what he sees in output rather than what is on
# disk. A doctor searching his files for U+FFFD would find nothing and report
# them all clean, which is the worst possible answer from a repair tool.
#
# So it looks for BYTES that are not valid UTF-8. And it repairs them by reading
# each as latin-1 and writing it back as UTF-8, which recovers the character
# somebody meant: 0xD7 becomes a multiplication sign rather than a replacement
# mark. Substituting U+FFFD would turn damage into data permanently - the thing
# the lenient read is careful never to write back.
#
# Nothing is repaired without being asked. History is the permanent record of a
# board, and a program that edits it unattended is a worse problem than the one
# it solves: a record somebody's tooling quietly rewrites is not evidence any
# more. So the command reports by default and writes only when told to.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Damaged', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'DRS', epic_prefix => 'DRE', ticket_prefix => 'DRT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with a damaged journal' )->{ref};

my $journal = File::Spec->catfile( $root, '.tira', 'history', "$card.jsonl" );

# His byte, in his words: "Workflow finder x2 + 3 independent refuters", with
# the multiplication sign written as latin-1.
open my $damage, '>>:raw', $journal or die $!;
print {$damage} qq({"after":"Workflow finder \xd72 + 3 refuters","at":"2026-08-15T09:00:00Z",)
  . qq("author":null,"before":null,"field":"title","op":"update","ref":"$card"}\n);
close $damage;

sub bytes_of {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    my $all = <$fh>;
    close $fh;
    return $all;
}

my $before = bytes_of($journal);
like( $before, qr/\xd7/, 'the journal really does hold the byte this is about' );

# --- it finds the damage -------------------------------------------------------------

my $found = $tira->doctor( project => $root );
is( scalar @{ $found->{damaged} }, 1, 'the doctor finds the one damaged file' );

my ($report) = @{ $found->{damaged} };
like( $report->{path}, qr/\Q$card\E/, 'naming the file it is in' );
is( $report->{bytes}, 1, 'and how many bytes it could not read' );
like( $report->{detail}, qr/0xD7|\\xd7/i, 'saying which byte, so the reader can check it themselves' );

# --- and changes nothing until it is asked --------------------------------------------
#
# The whole reason this is a command rather than something police does. A record
# a program rewrites unattended is not evidence any more.

is( bytes_of($journal), $before, 'and has not touched the file' );
# An empty arrayref is true in Perl, so ok(!...) here would have passed
# whatever the doctor did. Counted instead.
is( scalar @{ $found->{repaired} }, 0, 'reporting is not repairing' );

# --- when asked, it repairs ------------------------------------------------------------

my $fixed = $tira->doctor( project => $root, repair => 1 );
is( scalar @{ $fixed->{repaired} }, 1, 'asked to repair, it repairs the file' );

my $after = bytes_of($journal);
isnt( $after, $before, 'the file changed' );
unlike( $after, qr/\xd7(?![\x80-\xbf])/, 'the lone byte is gone' );

# --- into the character somebody meant --------------------------------------------------
#
# Not a replacement mark. 0xD7 is a multiplication sign in latin-1, which is
# what it was: recovering it keeps the sentence readable, and substituting
# U+FFFD would write the damage permanently into the record.

like( $after, qr/\xc3\x97/, 'the byte became a multiplication sign in UTF-8' );
unlike( $after, qr/\xef\xbf\xbd/, 'and not a replacement character, which would be damage made permanent' );

# --- and the file reads strictly afterwards ----------------------------------------------

{
    my $ok = eval { $tira->history_list( project => $root, ref => $card ); 1 };
    ok( $ok, 'the journal can be read' ) or diag($@);

    open my $fh, '<:raw', $journal or die $!;
    my $clean = 1;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        $clean = 0 if !eval { Tira::json_decode($line); 1 };
    }
    close $fh;
    ok( $clean, 'and every line of it decodes strictly, which it did not before' );
}

# --- while every other byte is where it was ------------------------------------------------
#
# A repair nobody can audit is indistinguishable from corruption, so the only
# difference between the two files must be the bytes it said it changed.

{
    ( my $expected = $before ) =~ s/\xd7/\xc3\x97/;
    is( $after, $expected, 'and nothing else in the file moved' );
}

# --- two damaged files are reported in a settled order ------------------------------------
#
# A board with one bad byte is the case that was reported; a board with several
# is the case somebody actually runs the command on - his has two. The order has
# to be the same every run, or a reader diffing two reports sees churn that
# means nothing.
#
# Added because a coverage run found both sort comparators had never executed: a
# sort block only runs when there is something to compare, and every case here
# had a single file.

{
    my $several = File::Spec->catdir( $tmp, 'several' );
    my $many = Tira->new;
    $many->project_new(
        name => 'Several', dir => $several, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'SVS', epic_prefix => 'SVE', ticket_prefix => 'SVT',
    );

    my @refs = map {
        $many->create_record( project => $several, type => 'ticket',
            title => "damaged $_" )->{ref}
    } ( 1, 2, 3 );

    for my $ref (@refs) {
        my $file = File::Spec->catfile( $several, '.tira', 'history', "$ref.jsonl" );
        open my $fh, '>>:raw', $file or die $!;
        print {$fh} qq({"after":"LOW\xd72","at":"2026-08-15T09:00:00Z","author":null,)
          . qq("before":null,"field":"title","op":"update","ref":"$ref"}\n);
        close $fh;
    }

    my $seen = $many->doctor( project => $several );
    is( scalar @{ $seen->{damaged} }, 3, 'every damaged file is found, not just the first' );
    is_deeply( [ map { $_->{path} } @{ $seen->{damaged} } ],
        [ sort map { $_->{path} } @{ $seen->{damaged} } ],
        'and they are reported in a settled order, so two runs can be compared' );

    my $mended = $many->doctor( project => $several, repair => 1 );
    is( scalar @{ $mended->{repaired} }, 3, 'and all three are repaired' );
    is_deeply( [ map { $_->{path} } @{ $mended->{repaired} } ],
        [ sort map { $_->{path} } @{ $mended->{repaired} } ],
        'in the same settled order' );

    is_deeply( $many->doctor( project => $several )->{damaged}, [],
        'and afterwards there is nothing left to repair' );
}

# --- a board with nothing wrong is left alone -----------------------------------------------

{
    my $well = File::Spec->catdir( $tmp, 'well' );
    my $healthy = Tira->new;
    $healthy->project_new(
        name => 'Healthy', dir => $well, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'HLS', epic_prefix => 'HLE', ticket_prefix => 'HLT',
    );
    $healthy->create_record( project => $well, type => 'ticket', title => 'Nothing wrong' );

    my $checked = $healthy->doctor( project => $well );
    is_deeply( $checked->{damaged}, [], 'a board with nothing wrong reports nothing' );

    my $touched = $healthy->doctor( project => $well, repair => 1 );
    is_deeply( $touched->{repaired}, [], 'and repairing it changes nothing' );
}

# --- attachments are not text and are not touched --------------------------------------------
#
# A recording is bytes that were never meant to decode. Repairing one would
# corrupt the very thing it was trying to protect.

{
    my $store = File::Spec->catdir( $root, '.tira', 'attachments' );
    mkdir $store;
    my $recording = File::Spec->catfile( $store, 'deadbeef.mp3' );
    open my $mp3, '>:raw', $recording or die $!;
    print {$mp3} "\xff\xf3\x84\xc4\x00\x00";
    close $mp3;
    my $sound = bytes_of($recording);

    my $again = $tira->doctor( project => $root, repair => 1 );
    is( bytes_of($recording), $sound, 'an attachment is left exactly as it was' );
    is_deeply( [ grep { $_->{path} =~ /deadbeef/ } @{ $again->{damaged} } ], [],
        'and is not reported as damaged, because it was never text' );
}

done_testing;

__END__

=head1 NAME

186-a-command-that-repairs-a-file.t - a damaged file can be cleaned, when asked

=head1 DESCRIPTION

C<tira.doctor> finds board files holding bytes that are not valid UTF-8, says
which file and which byte, and repairs them only when asked. It searches for
bytes rather than for U+FFFD: the replacement character is what a lenient decode
produces, not what is on disk, so a doctor looking for it would report every
damaged file clean.

A bad byte is repaired by reading it as latin-1 and writing it back as UTF-8, so
C<0xD7> becomes the multiplication sign somebody meant rather than a replacement
mark - which would make the damage permanent. Nothing else in the file moves,
and attachments are never touched, being bytes that were never meant to decode.

=cut
