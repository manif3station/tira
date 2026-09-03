#!/usr/bin/env perl
# The queue shifting out from under the count, and lines nobody ever heard.
#
# TKT-893's ninth member, found by the hourly bug hunt at 19:00 on 2026-09-03
# and reproduced in a container before it was written down.
#
# HOW IT GOES WRONG. Police reads a monitor's output during a pass, writes it to
# the bridge, and then drains what it announced - by COUNT, off the front:
#
#     my $count = defined $args{count} ? $args{count} : scalar @held;
#     my @lines = splice @held, 0, $count;
#
# on the stated reasoning that "Lines are added at the BACK, so removing the
# first N removes exactly the N that were read." True, until the buffer
# overflows in between: job_feed keeps the NEWEST $MONITOR_OUTPUT_HELD lines and
# trims from the FRONT. So a chatty monitor between the read and the drain
# shifts the queue out from under the count, and the first N are now lines
# nobody has seen.
#
# MEASURED, before this file existed:
#
#   police READS   : 200 lines, first=OLD-1 last=OLD-200
#   monitor FLOODS : buffer now 200 lines, first=NEW-1 last=NEW-200, dropped=200
#   police DRAINS  : took 200, first=NEW-1 last=NEW-200
#   buffer AFTER   : 0 lines, dropped counter=200
#   LINES REMOVED THAT POLICE NEVER ANNOUNCED: 200
#   and the dropped counter accounts for 0 of them
#
# THE CODE GUARDED THE WRONG HALF OF ITS OWN HAZARD, which is the interesting
# part. Its comment says taking everything "would discard lines nobody
# announced - losing a monitor's output silently, which is the single failure
# this rule exists to prevent, arriving through the fix for it." Exactly right.
# The count it introduced prevents the case where the buffer GREW; it does
# nothing about the case where the buffer also SHRANK from the front.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::Job;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Drained', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'DRS', epic_prefix => 'DRE', ticket_prefix => 'DRT',
    );
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'sleep 600' );
    return ( $tira, $root, $job->{id} );
}

# THE BUFFER SIZE, not the per-pass batch. The first draft of this file used
# monitor_output_per_pass(), which is 20 - the number of lines police announces
# in one go - where the buffer holds 200. Feeding 20 and then 20 never
# overflowed, so the very assertion this file exists for PASSED against the
# unfixed code. A red test that is green is not a fixed bug; it is a fixture
# that never reached the fault.
my $held = $Tira::Job::MONITOR_OUTPUT_HELD;

# --- the ordinary pass is untouched -------------------------------------------
#
# Read some, drain what was read, and the rest waits. This is what happens every
# time and it must go on happening.

{
    my ( $tira, $root, $id ) = board();
    $tira->job_feed( project => $root, id => $id, lines => [ map { "L$_" } 1 .. 5 ] );

    my ( $taken, $dropped ) = $tira->job_output_drain(
        project => $root, id => $id, count => 3, dropped => 0 );

    is_deeply( $taken, [ 'L1', 'L2', 'L3' ],
        'a drain takes the lines that were announced, oldest first' );

    my ($job) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    is_deeply( $job->{output}, [ 'L4', 'L5' ],
        'and leaves the ones that arrived after the read' );
}

# --- AND A DRAIN AFTER AN OVERFLOW TAKES NOTHING NOBODY HEARD -----------------
#
# The whole card. Police reads the buffer full, the monitor floods it so every
# announced line is trimmed away, and then police drains the count it announced.

{
    my ( $tira, $root, $id ) = board();

    $tira->job_feed( project => $root, id => $id,
        lines => [ map { "OLD-$_" } 1 .. $held ] );

    my ($read) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    my @announced = @{ $read->{output} };
    is( scalar @announced, $held, 'police reads a full buffer' );

    # The monitor speaks again, hard, while the bridge write is happening.
    $tira->job_feed( project => $root, id => $id,
        lines => [ map { "NEW-$_" } 1 .. $held ] );

    my ( $taken, $dropped ) = $tira->job_output_drain(
        project => $root, id => $id,
        count => scalar @announced, dropped => 0 );

    my %was_announced = map { $_ => 1 } @announced;
    my @never_said = grep { !$was_announced{$_} } @{ $taken || [] };

    is( scalar @never_said, 0,
        'THE DRAIN REMOVES NOTHING THE BRIDGE DID NOT ANNOUNCE. The buffer '
          . 'shifted out from under the count, so taking N off the front takes '
          . 'N lines nobody has heard - which is the silent loss this whole '
          . 'epic exists to end, arriving through the fix for it' );

    my ($after) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    my %still = map { $_ => 1 } @{ $after->{output} || [] };

    ok( $still{"NEW-1"},
        'and the newest lines are still there to be announced next pass' );
    ok( $still{"NEW-$held"}, 'including the last thing it said' );
}

# --- and what genuinely was lost is counted ----------------------------------
#
# The overflow itself is a real loss and somebody has to be told. What must not
# happen is losing lines to the DRAIN on top of it, uncounted.

{
    my ( $tira, $root, $id ) = board();

    $tira->job_feed( project => $root, id => $id,
        lines => [ map { "OLD-$_" } 1 .. $held ] );
    $tira->job_feed( project => $root, id => $id,
        lines => [ map { "NEW-$_" } 1 .. $held ] );

    my ($mid) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    is( $mid->{output_dropped}, $held,
        'the overflow is counted, because a buffer that drops quietly is the '
          . 'silence this feature was built to remove' );

    my ( $taken, $dropped ) = $tira->job_output_drain(
        project => $root, id => $id, count => $held, dropped => 0 );

    my ($after) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    is( $after->{output_dropped}, $held,
        'and it survives a drain that did not claim it, so the next pass can '
          . 'still say how much was lost' );
}

done_testing();

__END__

=head1 NAME

514-a-drain-that-took-what-nobody-said.t - the count, and the queue beneath it

=head1 WHY

TKT-893, ninth member. C<job_output_drain> removes the announced COUNT off the
front of the buffer, which is correct only while nothing trims the front in
between - and C<job_feed> trims exactly there when the buffer overflows. A
chatty monitor between a read and its drain therefore loses lines that were
never announced, and the dropped counter says nothing about them.

=head1 WHAT IS ASSERTED

That an ordinary read-then-drain is unchanged; that after an overflow the drain
removes nothing the bridge did not announce and the newest lines survive to be
announced next pass; and that the overflow's own loss is still counted.

=cut
