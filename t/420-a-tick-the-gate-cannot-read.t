#!/usr/bin/env perl

# An item ticked as 'Done' is finished to the card and unfinished to the gate.
#
# TKT-671, and it stopped a real release rather than being found by looking.
# The push of 4.57, 4.58 and 4.59 was refused:
#
#   TKT-625 is in push with 1 checklist item(s) unfinished: Document which
#     commands honour --dry-run in SKILLS.md
#   TKT-626 is in push with 4 checklist item(s) unfinished: ...
#   2 card(s) incomplete. Fill them in before pushing.
#
# Every one of those items was marked done. They were stored as 'Done', which
# is the natural capitalisation and matches the 'To Do' the column templates
# themselves use. The engine lowercases before comparing; the gate does not.
#
# THE TWO SITES FAIL IN OPPOSITE DIRECTIONS, and only the loud one was noticed.
# incomplete() counts a 'Done' item as waiting and refuses a good push.
# stalled() takes a 'Done' item as proof the checklist is unfinished and
# returns early - so the detector that exists because Michael caught TKT-005
# fully ticked and still sitting in implement is, against 'Done', permanently
# blind. A fix that lowercases the first and not the second trades a false
# alarm for a silence.
#
# The fourth instance of one fault: the dashboard had it (TKT-601), the
# move-in reminder still has it (TKT-657), and this file has it twice. So the
# last assertion here is a ledger rather than a fix - it fails on a NEW
# case-sensitive comparison against 'done' anywhere in tools/, which is the
# only thing that stops a fifth.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# --- the engine is the side that is right -----------------------------------
#
# Asserted first and on purpose. Everything below asks the gate to agree with
# the engine, so a run where the engine itself were wrong would be reading the
# wrong answer off the wrong side.

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-08-28T18:00:00+0100' } );
$tira->project_new(
    name => 'Ticks', dir => $root, members => ['claude'],
    columns => ['backlog, implement, push, done'],
    sow_prefix => 'TSW', epic_prefix => 'TEP', ticket_prefix => 'TTK',
);

sub card_with {
    my (@statuses) = @_;
    my $card = $tira->create_record(
        project => $root, author => 'claude', type => 'ticket',
        title => 'a card with ticked items' );
    my $i = 0;
    for my $status (@statuses) {
        $i++;
        my $entry = $tira->checklist_add(
            project => $root, ref => $card->{ref}, author => 'claude',
            item => "item number $i", status => 'To Do' );
        $tira->checklist_update(
            project => $root, ref => $card->{ref}, author => 'claude',
            id => $entry->{id}, status => $status,
            command => ["prove item $i"], proof => ["item $i is done"] )
          if lc $status eq 'done';
    }
    return $tira->record_show( project => $root, ref => $card->{ref} );
}

for my $spelling (qw(done Done DONE)) {
    my $card = card_with( $spelling, $spelling );
    is( $card->{checklist_done}, 2,
        "the engine counts an item stored '$spelling' as done - it lowercases before comparing" );
}

my $mixed = card_with( 'Done', 'To Do' );
is( $mixed->{checklist_done}, 1,
    'and a genuinely unfinished item is still unfinished, whatever case its neighbour used' );

# --- the gate must not keep its own opinion ---------------------------------
#
# Read rather than run, which is how this suite already asserts things about
# the gate (t/224, t/416): it is a separate program in another language, and
# what matters is that it has no second opinion to drift.

open my $tool, '<', 'tools/card-holes' or die "card-holes: $!";
my $gate = do { local $/; <$tool> };
close $tool;

unlike( $gate, qr/\Qstatus'\E\s*\)\s*!=\s*'done'/,
    'the push gate does not decide for itself whether an item is done by comparing its status text' );

like( $gate, qr/checklist_done/,
    'it reads the engine\'s own count instead, the way it already asks the engine what a complete card is' );

# The count and the list must agree, or the message is honest about the number
# and quietly wrong about the evidence - which is what "4 checklist item(s)
# unfinished: ..." followed by three names already does.
# Asserted as what the message SAYS, not as the absence of a slice. The first
# version forbade waiting[:3] outright, which the fix still does and should -
# naming three of nine is right, and the fault was never the slice. It was the
# silence beside it.
like( $gate, qr/\Qand {len(waiting) - 3} more\E/,
    'and when it lists three of four unfinished items it says how many it did not name' );

# --- the counts and the card must agree before anything is called finished --
#
# Raised by a code review of the finished fix, and the two cases point in
# opposite directions. On a record from record_list they cannot arise at all -
# checklist_done and checklist_total are computed by _checklist_progress over
# the same array in the same call - so this asserts a rule rather than a repair:
# a checklist is finished only when the engine's count says so AND no item on
# the card contradicts it.
#
# The dangerous direction is the counts saying complete over an array that is
# not. Under a count-only shortcut, stalled() announced 'every checklist item
# is done but the card is still in implement' beside an item visibly marked
# To Do. A gate that contradicts what it prints is worse than one that is
# merely wrong, because the reader cannot tell which half to believe.

like( $gate, qr/\Qand not waiting\E/,
    'the count shortcut only confirms what the card already shows - it cannot declare a checklist finished over an item that says otherwise' );

# --- the ledger, which is the only part that stops a fifth ------------------
#
# Not a fix and not about this bug: a guard. Four instances of one fault is a
# class, and a class needs something that fails when it recurs somewhere new.

# Aimed at STATUS comparisons, not at the string. The first version of this
# grepped for "!= 'done'" and matched tools/card-holes:368,
# "if row.get('column') != 'done'", which is a column name and entirely
# correct - so the ledger would have stayed red after the real fix and taught
# whoever met it that the assertion was the thing to loosen.
my @sites;
open my $dir, '-|', 'grep', '-rn', "get('status') != 'done'", 'tools/' or die $!;
while ( my $line = <$dir> ) { chomp $line; push @sites, $line }
close $dir;
is_deeply( \@sites, [],
    'no tool compares an item\'s status to \'done\' case-sensitively - the fault that has now been fixed four times cannot come back unnoticed' );

done_testing();

__END__

=head1 NAME

t/420-a-tick-the-gate-cannot-read.t - a checklist item ticked as 'Done' must be
finished to the push gate as well as to the card

=head1 DESCRIPTION

The engine lowercases a checklist item's status before comparing it;
C<tools/card-holes> did not. An item ticked as C<Done> - the natural
capitalisation, and the one the column templates themselves use for C<To Do> -
was therefore finished to the card and unfinished to the gate, which refused
the push of 4.57, 4.58 and 4.59 over items every one of which was marked done.

The two places that compared statuses failed in B<opposite> directions, and
only the loud one had been noticed. C<premature()> counted a C<Done> item as
outstanding and refused a good push. C<stalled()> - which exists because a card
was found fully ticked and still sitting in implement - took a C<Done> item as
proof the checklist was unfinished and returned early, so against C<Done> it
never fired at all. Lowercasing the reported site alone would have traded a
false alarm for a silence.

So the gate stops holding an opinion. C<record_list> already attaches
C<checklist_done> and C<checklist_total> to every row, and the gate reads
those, working out only which items to name. Two readers, one definition - the
arrangement C<t/224> already established for what makes a card complete.

The first four assertions are anchors rather than achievements: they cover the
engine, which was always right, so that the gate-side results read as "the gate
now agrees with the engine" rather than "both sides moved together".

The last is a ledger, not a fix. This is the fourth instance of one fault - the
dashboard had it, this file had it twice, and the move-in reminder still does
under its own card - and nothing failed when a new one appeared.

=cut
