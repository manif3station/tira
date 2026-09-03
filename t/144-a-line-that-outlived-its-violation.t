#!/usr/bin/env perl
# The bridge says when a violation stops being true.
#
# zen-framework reported that a rule was firing on discarded cards: their bridge
# said "ZSD-140 is Done with no completion date" about a card that was in
# discard at the time. Their explanation was that entering a column means
# at-or-past it and discard is stored last, so every discarded card satisfies
# every --enter requirement.
#
# That mechanism does not exist. Entering a column is an exact match and has
# been since the police subsystem was first written, and the one place that does
# compare positions - _policy_before_column - opens by excluding discard. Built
# on their own column shape, police reports the card in done and says nothing
# about the card in discard.
#
# What does happen is this. Police notices perfectly well when a violation stops
# being true: the ledger moves it out of open, records a closed_at, and the live
# count drops to zero. The bridge is never told. The original line stays in the
# log with nothing marking it settled, so an agent tailing the bridge - or
# replaying the backlog after a restart - reads a demand about a card that dealt
# with it hours ago.
#
# Their whole backlog arrived at once because the bridge was buffered, which is
# the defect fixed as TKT-132 in 1.50. A pile of old lines about cards that had
# moved on, arriving together, reads exactly like a rule firing across discard.
# So 1.50 makes this worse rather than better: now that the bridge flushes,
# agents will read backlogs, and every stale line in one is an instruction to do
# work that is already done.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T01:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Settled', dir => $root, members => [ 'michael', 'ada', 'claude' ],
    columns => ['backlog, doing, done, discard'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->policy_add( project => $root, rule => 'card-metrics',
    enter => 'done', require => 'due_date', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Finished without a date', assignee => 'ada' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );

# Exactly what the police command does: a pass, then the bridge written from
# what the pass found. Settled violations travel the same way, because a
# settlement an agent has to ask for is one it will not ask for.
sub round {
    my $result = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $result->{violations}, settled => $result->{settled} );
    return $result;
}

sub bridge {
    my $path = $tira->bridge_log_path( store => $store );
    return () if !-f $path;
    open my $fh, '<:raw', $path or die $!;
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

# --- the violation is raised ------------------------------------------------

my $raised = round();
is( scalar @{ $raised->{violations} }, 1, 'the card in done with no date is reported' );
my ($said) = grep { /\Q$card->{ref}\E/ } bridge();
ok( $said, 'and the bridge carries it' );
my ($number) = $said =~ /(VIO-\d+)/;
ok( $number, 'with a violation number' );

# --- and then the card is set aside -------------------------------------------
#
# The exact move zen-framework made. Police stops reporting it at once, which it
# always did correctly; the question is what the bridge says.

$now = '2026-08-14T01:01:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'discard' );
my $after = round();
is( scalar @{ $after->{violations} }, 0, 'police stops reporting it the moment it stops being true' );

# The tone field, not the word anywhere in the line.
#
# This board is called 'Settled', and since 2.00 every line ends with the board
# it belongs to - so a grep for the bare word matches every line on this board.
# That is a real cost of naming the board rather than a quirk of this test: any
# board called Settled, Done or Urgent poisons a substring match, including one
# an agent writes while tailing the bridge. Matching the field is what the line
# was always shaped for.
my @settled = grep { /\Q$number\E/ && / \| SETTLED \| / } bridge();
is( scalar @settled, 1, 'and the bridge says that violation is settled' );
like( $settled[0], qr/\Q$card->{ref}\E/, 'naming the card it was about' );
# It reaches the same reader as the original, which is what this always meant -
# but no line names anybody now (TKT-308), so it is asserted by reading it as
# that agent rather than by looking for a name in the text. Whose a line is
# comes from the store via the reference it carries, which is the field this
# line was always shaped around.
like( join( "\n", @{ $tira->bridge_backlog( store => $store, lines => 500, agent => 'ada' ) } ),
    qr/\Q$number\E/,
    'and reaches whoever the original did, so it settles for the same reader' );
unlike( $settled[0], qr/ \| for /,
    'while naming nobody, because that guess is what taught readers to skip lines' );

# --- said once, not on every pass afterwards ----------------------------------
#
# A settlement repeated every thirty seconds is the noise the whole channel
# exists to rise above, and it would be worse than the stale line it replaces.

for my $minute ( 2 .. 4 ) {
    $now = sprintf '2026-08-14T01:%02d:00Z', $minute;
    round();
}
is( scalar( grep { /\Q$number\E/ && / \| SETTLED \| / } bridge() ), 1,
    'and it is said once, however many passes follow' );

# --- a violation that is still true says nothing new ---------------------------

$now = '2026-08-14T01:10:00Z';
my $second = $tira->create_record( project => $root, type => 'ticket',
    title => 'Also finished without a date' );
$tira->record_move(author => 'claude',  project => $root, ref => $second->{ref}, column => 'done' );
round();
$now = '2026-08-14T01:11:00Z';
round();
is( scalar( grep { /\Q$second->{ref}\E/ && / \| SETTLED \| / } bridge() ), 0,
    'a violation that is still true is never announced as settled' );

# --- and it comes back if it comes back ----------------------------------------
#
# Numbers are never reused, so a violation that returns carries the number it
# had. The settlement must not stop the return being said.

$now = '2026-08-14T01:20:00Z';
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref}, due_date => '2026-08-20T00:00:00Z' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );
round();
$now = '2026-08-14T01:21:00Z';
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref}, due_date => '' );
my $returned = round();
is( scalar( grep { $_->{ref} eq $card->{ref} } @{ $returned->{violations} } ), 1,
    'a violation that becomes true again is reported again' );

# --- and the running watcher carries it too -------------------------------------
#
# There are two places that write the bridge from a pass: the single run and the
# follow loop that is left going for days. The loop is the one that matters
# here, and fixing only the one a test happens to exercise is how two copies of
# one decision come apart.

# Read out of every module under lib/, not out of Tira/CLI.pm by name. The two
# writers were in one file until 4.74, when the follow loop moved to
# Tira::CLI::Police (TKT-607) and this assertion started counting one of two -
# green code, red test, and the test was the thing that was wrong. Naming the
# file made this test a claim about where the code lives, which was never what
# it was for. Same lesson TKT-594 taught the coverage gate a few hours earlier:
# a list of file paths is maintained by somebody remembering, and eventually
# nobody does.
{
    my @sources;
    File::Find::find(
        {   no_chdir => 1,
            wanted   => sub {
                return if !/\.pm\z/;
                open my $handle, '<', $File::Find::name or die "$File::Find::name: $!";
                push @sources, do { local $/; <$handle> };
                close $handle;
            },
        },
        'lib'
    );
    ok( scalar @sources >= 4, 'lib/ was read - ' . scalar(@sources) . ' modules' );
    # THREE, not two, and the number was wrong here rather than in the code.
    # There have been three writers since the --fresh path was added: the watch
    # loop, --fresh, and the police command itself. This assertion saw two,
    # because --fresh ended its call with a statement-modifier `if` -
    #
    #     $tira->bridge_write( ... )
    #       if $result->{watching};
    #
    # so the terminating `;` sat after the condition and the pattern below,
    # which stops at the first `;`, never matched it. TKT-851 turned that line
    # into a block for an unrelated reason and the hidden writer appeared.
    #
    # Counting three is the more accurate claim, and the assertion that MATTERS
    # is the second one - that every writer carries what has been settled. All
    # three do, and did before this change; the guard simply could not see one
    # of them saying so.
    my @writes = map { /bridge_write\(([^;]*?)\);/gs } @sources;
    is( scalar @writes, 3, 'the bridge is written from a pass in three places' );
    is( scalar( grep { /settled\s*=>/ } @writes ), 3,
        'and every one of them carries what has been settled, not just the one under test' );
}

done_testing;

__END__

=head1 NAME

144-a-line-that-outlived-its-violation.t - the bridge says when a violation stops being true

=head1 DESCRIPTION

Police has always noticed when a violation clears - the ledger moves it out of
open and records the moment - and never told the bridge. The original line
stayed in the log with nothing marking it settled, so an agent tailing the
bridge, or replaying the backlog after a restart, read a demand about a card
that had dealt with it hours ago.

It was reported as C<--enter> requirements being inherited by discarded cards.
That mechanism does not exist; what the reporter saw was a buffered bridge
replaying old lines about cards that had moved on. Fixing the buffering made
this one matter more, not less.

A settlement is said once, carries the number of the line it settles, and goes
to the reader the original was addressed to.

=cut
