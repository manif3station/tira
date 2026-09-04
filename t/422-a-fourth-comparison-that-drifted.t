#!/usr/bin/env perl

# Four places ask whether a required item is done. Three lowercase first.
#
# TKT-657. lib/Tira/CLI.pm compares a required item's status against 'done' in
# four places - the entry gate, _outstanding_here, the exit gate, and
# _remind_one_at_a_time. The first three read lc($_->{status}); the fourth
# reads $_->{status}. So an item marked --status Done, with the capital the CLI
# accepts and TKT-434 deliberately made the gates tolerate, is DONE to every
# gate and OUTSTANDING to the move-in reminder: move such a card in and it
# prints "This column brought N required action(s) with it. Read them first..."
# for items that are already finished.
#
# THIS IS THE THIRD INSTANCE OF ONE FAULT IN A DAY, and the count is what turns
# the card's second question from tidying into work. TKT-601: the dashboard JS
# compared against the literal 'done' while the engine lowercased, so an item
# marked Done was finished to the gate and an empty box to whoever was looking.
# TKT-671: tools/card-holes did it twice, in OPPOSITE directions - one refusing
# a good push, one silently blind - and it refused the release of 4.57, 4.58
# and 4.59. Now four comparisons in one file with one disagreeing.
#
# So this file asserts two things, and the second is the one that lasts. That
# the four agree, which is the bug. And that there is ONE named predicate to
# agree with, because four inline comparisons cannot be guarded - TKT-671's
# ledger greps tools/ for exactly this and cannot help here, and a predicate is
# greppable in a way a repeated expression is not.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 't/lib';
use Suite ();
use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub { '2026-08-28T21:00:00+0100' } );
$tira->project_new(
    name => 'A fourth comparison', dir => $root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'FSW', epic_prefix => 'FEP', ticket_prefix => 'FTK',
);
$tira->column_update(
    project => $root, type => 'ticket', name => 'implement',
    required_action => ['Prove the thing'],
);

sub run_cli {
    my ( $command, @argv ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    # any failure is what this means: these calls are expected to succeed and a
    # death from any cause fails the claim being made about them.
    my $died = !eval {
        Tira::CLI->run( command => $command, tira => $tira,
            argv => [ '--type', 'ticket', @argv, '-o', 'toon' ] );
        1;
    };
    select $old;
    return { out => $stdout // '', err => $said // '', died => $died };
}

# --- the engine already tolerates the capital -------------------------------
#
# An anchor. TKT-434 made this deliberate, so the failures below read as one
# reader disagreeing with the rest rather than 'Done' being a mistake.

my $card = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'a card with a capital D' );
run_cli( 'record.move', '--ref', $card->{ref}, '--column', 'implement', '--author', 'ada' );

my ($item) = @{ $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} )
      ->{required_items} // [] };
ok( $item, 'the column put its required action on the card' ) or BAIL_OUT('nothing to mark');

$tira->required_item_update(
    project => $root, ref => $card->{ref}, author => 'ada', id => $item->{id},
    status => 'Done', command => ['prove it'], proof => ['proved'] );

my $after = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( $after->{required_items}[0]{status}, 'Done',
    'stored with the capital, not normalised away - the board keeps what was written' );

# --- and the gate agrees it is done -----------------------------------------
#
# STILL AN ANCHOR, and labelled here rather than only in the POD. A review
# pointed out that this assertion passes against the reverted fix - which is
# true, and is the point: the exit gate already lowercased, so it is one of the
# three readers that were RIGHT. It is here so the reminder's failure below
# reads as one reader disagreeing with the others rather than as 'Done' being
# an invalid status - and without it the obvious repair is to normalise on
# write, which would undo TKT-434.
#
# The heading above it said none of that, so the label was in the POD and not
# where somebody meets the assertion. That was worth fixing even though the
# assertion was not.

my $out = run_cli( 'record.move', '--ref', $card->{ref}, '--column', 'done', '--author', 'ada' );

# The subject is established before it is denied, rather than declared empty.
# Empty is NOT what passes here: a move that printed nothing would mean it
# never happened, and the denial below would be true about nothing. t/147
# exists for exactly that, and caught this line.
# Written with the subject as the first argument, which is the form t/147
# recognises - my first attempt wrapped it in length() and did not count, and
# the guard was right to keep refusing: a reader checking whether the subject
# was established would have had to unwrap the call to see it.
ok( $out->{out} . $out->{err},
    'the move said something, so the denial below is about a move that happened' );
unlike( $out->{out} . $out->{err}, qr/required action/i,
    'the exit gate lets the card leave - it lowercases before comparing' );

# --- the reminder is the one that disagrees ---------------------------------
#
# A FORWARD move into a column whose item is already Done, which is the only
# way to reach this. My first attempt moved the card out and back, and the
# reminder fired correctly there: a BACKWARD move resets that column's done
# items to pending on the way through (TKT-434's own reset, a few lines below
# the reminder), so by the time it ran there was genuinely nothing done. The
# test was reproducing the reset, not the bug.
#
# Reachable because an item can carry a column the card is not in yet - it is
# seeded on creation into that column since TKT-681, or added directly - so it
# can be finished before the card ever arrives.

my $ahead = $tira->create_record(
    project => $root, author => 'ada', type => 'ticket', title => 'a card that did the work early' );
my $early = $tira->required_item_add(
    project => $root, ref => $ahead->{ref}, author => 'ada',
    column => 'implement', item => 'Prove the thing', status => 'pending' );
$tira->required_item_update(
    project => $root, ref => $ahead->{ref}, author => 'ada', id => $early->{id},
    status => 'Done', command => ['prove it early'], proof => ['proved early'] );

my $forward = run_cli( 'record.move', '--ref', $ahead->{ref}, '--column', 'implement', '--author', 'ada' );

is( $tira->record_show( project => $root, type => 'ticket', ref => $ahead->{ref} )
      ->{required_items}[0]{status}, 'Done',
    'a forward move does not reset it - the reset is for moving BACK, so Done survives the arrival' );
# empty is what passes: the claim IS that the reminder said nothing, so an
# empty stderr is the finding rather than this denial slipping through. The
# assertion directly above establishes the card state it depends on - the item
# is still Done at the moment of the move - so a change that stopped seeding,
# or reset the item, would fail there rather than pass quietly here.
unlike( $forward->{err}, qr/brought \d+ required action/,
    'and the move-in reminder does not announce an item marked Done as outstanding' );

# --- one predicate, so a fourth cannot drift again --------------------------
#
# Not a fix and not about this bug: the guard. Three instances in one day is a
# class, and TKT-671's ledger greps tools/ so it cannot see this file. Read
# rather than run, the way t/224 and t/416 already assert things about code
# they cannot execute.

my $cli = Suite::cli_source();

# Everything OUTSIDE the predicate. The first version scanned the whole file
# and flagged the predicate's own line - lc( ... $item->{status} ... ) eq
# 'done' - because the lc sits before the status reference rather than inside
# the captured span. The predicate is the one place this comparison belongs, so
# it is cut out and the rest is what must be clean.
my $outside = $cli;
$outside =~ s/sub _item_is_done \{.*?\n\}\n//s;
my @inline = $outside =~ /(\$\w+->\{status\}[^;]{0,60}?(?:ne|eq)\s*'done')/g;
is_deeply( \@inline, [],
    'no comparison of an item status against \'done\' is written out by hand any more' );

like( $cli, qr/sub _item_is_done\b/,
    'and there is one named predicate to ask instead, so a fourth site cannot quietly disagree' );

done_testing();

__END__

=head1 NAME

t/422-a-fourth-comparison-that-drifted.t - every reader of a required item's
status must agree that C<Done> means done

=head1 DESCRIPTION

C<lib/Tira/CLI.pm> compares a required item's status against C<done> in four
places. Three lowercase first; C<_remind_one_at_a_time> does not. So an item
marked C<Done> - the capital the CLI accepts, and which TKT-434 deliberately
made the gates tolerate - is finished to every gate and outstanding to the
move-in reminder, which then tells an agent to work items that are already
done.

This is the third instance of one fault in a single day. The dashboard had it
(TKT-601), C<tools/card-holes> had it twice in opposite directions and refused
a real release (TKT-671), and these four comparisons are the third. That count
is what turns the card's second question - whether four hand-written
comparisons should be one named predicate - from tidying into work.

So the file asserts both halves. That the four agree, which is the bug; and
that there is a single named predicate to agree with, which is what stops a
fourth site drifting. TKT-671's ledger greps C<tools/> for this exact fault and
cannot help here, and a predicate is greppable in a way a repeated expression
is not.

The first assertions are anchors: the engine stores the capital rather than
normalising it away, and the exit gate lets the card leave. Without them the
reminder's failure would read as C<Done> being an invalid status.

=cut
