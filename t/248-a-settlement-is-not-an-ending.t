#!/usr/bin/env perl
# A settlement is not an ending, and the line has to say so.
#
# His observation, and it is about how the channel is read rather than what is
# in it: "Most agents think the last settle statement as end and all done and
# forget everything."
#
# A settlement is written in the same shape as a violation and arrives last, so
# it reads as a closing statement. An agent that has just been told something is
# over stops looking. This board had 84 violations outstanding while
# settlements were landing on the same channel, and the agent reading it - me -
# moved on for hours.
#
# So every pass that writes anything ends with what is still open: how many, and
# which. Nothing when the board is clear, because silence has to go on meaning
# silence.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-16T23:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Reading', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RDS', epic_prefix => 'RDE', ticket_prefix => 'RDT',
);
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

my $first  = $tira->create_record( project => $root, type => 'ticket', title => 'One' );
my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Two' );

# Only what this pass wrote. The log is cumulative and reading all of it would
# hand an assertion a line from an earlier pass - which is how the first version
# of this test reported a failure that was its own.
my $read_to = 0;

sub bridge {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations}, settled => $pass->{settled} );
    open my $fh, '<:raw', $tira->bridge_log_path( store => $store ) or return ();
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    my @fresh = @lines[ $read_to .. $#lines ];
    $read_to = scalar @lines;
    return @fresh;
}

# --- two open violations, and the line says how many ---------------------------

{
    my @lines = bridge();

    # non-empty is the whole claim: everything below is about what the lines
    # say, and no lines would satisfy any of it.
    cmp_ok( scalar @lines, '>', 0, 'the bridge has something in it' );

    my ($tail) = grep { /STILL OPEN/ } @lines;
    ok( $tail, 'a pass that reports violations ends by saying what is open' );
    like( $tail // '', qr/2 violation\(s\) outstanding/,
        'counting them, so the reader knows the size of it' );
    like( $tail // '', qr/\Q$first->{ref}\E/, 'and naming them' );
    like( $tail // '', qr/tira\.police\.outstanding/, 'and where to see them all' );
}

# --- one settles, and the settlement does not read as an ending ----------------
#
# The whole of his point. The last line an agent reads decides what it thinks is
# left, and a settlement arriving alone says "done".

{
    $tira->record_update( author => 'claude', project => $root, ref => $first->{ref}, labels => ['standalone'] );
    $now = '2026-08-16T23:05:00Z';

    my @lines = bridge();
    my ($settled) = grep { /SETTLED/ } @lines;
    ok( $settled, 'the settlement is written' );

    my @tails = grep { /STILL OPEN/ } @lines;
    my $last  = $tails[-1] // '';
    like( $last, qr/1 violation\(s\) outstanding/,
        'and is followed by the one that is still open' );
    like( $last, qr/\Q$second->{ref}\E/, 'named, so it cannot be read as finished' );
}

# --- and only what the policy asked to reach the bridge -------------------------
#
# The tail is a bridge line like any other, so it obeys the same rule: a policy
# set to log-only is being tuned and stays out of the way. Without this the tail
# counted every outstanding violation whatever its action, and a board whose
# rules were all log-only started getting bridge lines about them - which t/150
# caught the moment it was written.

{
    my $quiet = File::Spec->catdir( $tmp, 'quiet' );
    my $other = Tira->new( clock => sub {$now} );
    my $bench = File::Spec->catdir( $tmp, 'bench' );
    $other->project_new(
        name => 'Tuning', dir => $bench, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'TNS', epic_prefix => 'TNE', ticket_prefix => 'TNT',
    );
    $other->policy_add( project => $bench, rule => 'orphan-card', action => 'log-only' );
    $other->create_record( project => $bench, type => 'ticket', title => 'Parentless' );

    my $pass = $other->police_pass( project => $bench, store => $quiet, world => {} );
    cmp_ok( scalar @{ $pass->{violations} }, '>', 0,
        'the rule being tuned does report something' );

    my $wrote = $other->bridge_write( store => $quiet, project => $bench,
        violations => $pass->{violations}, settled => $pass->{settled} );
    is( $wrote, 0,
        'and nothing of it reaches the bridge, tail included, because it is log-only' );
}

# --- and when the board is clear, nothing extra --------------------------------
#
# Silence has to go on meaning silence, or the tail becomes the noise it was
# written to prevent.

{
    $tira->record_update( author => 'claude', project => $root, ref => $second->{ref}, labels => ['standalone'] );
    $now = '2026-08-16T23:10:00Z';

    my @written = bridge();
    ok( scalar( grep { /SETTLED/ } @written ),
        'the last violation settles' );
    is( scalar( grep { /STILL OPEN/ } @written ), 0,
        'and nothing is added about what is open, because nothing is' );

    my $wrote = $tira->bridge_write( store => $store, project => $root,
        violations => [], settled => [] );
    is( $wrote, 0, 'a pass with nothing to say writes nothing at all' );
}

done_testing;

__END__

=head1 NAME

248-a-settlement-is-not-an-ending.t - what is still open, said after the news

=head1 DESCRIPTION

A settlement is written in the shape of a violation and arrives last, so it
reads as a closing statement - and this board had 84 violations outstanding
while settlements landed on the same channel.

Every pass that writes anything now ends with how many violations are still
open and which. A pass with nothing to say still writes nothing.

=cut
