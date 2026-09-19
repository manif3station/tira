#!/usr/bin/env perl
# TKT-1126, Q-175 (Michael's own answer): a static snapshot - extend
# TKT-1028's own indicator to always show running/not-running, whenever
# the board is served, rather than saying nothing when a companion is
# not running. Before this, with_police=>0 (a served board that was
# genuinely asked NOT to run police beside it, or whose spawn failed -
# TKT-1028's own with_police=>$police_child?1:0 fix) rendered no
# indicator at all - indistinguishable from a bare table export that
# never had a server behind it and never set the key at all.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'served' );
my $tira = Tira->new( clock => sub {'2026-09-19T00:00:00Z'} );
$tira->project_new(
    name => 'Served', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);
my $data = $tira->dashboard( project => $root, summary => 1 );

# --- a served board that never even asked (no with_police key at all) ------
# stays exactly as it was: a bare export, no claim either way.

my $unserved = $tira->format_output( $data, output => 'table', project => $root );
like( $unserved, qr/\A<!doctype html>/i, 'the baseline page is a real rendered board, not an empty string' );
unlike( $unserved, qr/Police running beside this board/,
    'a bare export with no with_police key at all says nothing about police' );
unlike( $unserved, qr/Police not running beside this board/,
    'nor does it say "not running" - it was never asked' );
unlike( $unserved, qr/Policy bridge (?:not )?running beside this board/,
    'same for the policy bridge' );

# --- a served board that WAS asked, and the answer was no ------------------

my $neither_running = $tira->format_output(
    $data, output => 'table', project => $root,
    with_police => 0, with_policy_bridge => 0 );
like( $neither_running, qr/dashboard-indicator--police/,
    'a served board that answered "not running" still carries the indicator element' );
like( $neither_running, qr/Police not running beside this board/,
    'and says so in plain words, rather than nothing at all' );
like( $neither_running, qr/dashboard-indicator--policy-bridge/,
    'same for the policy-bridge indicator element' );
like( $neither_running, qr/Policy bridge not running beside this board/,
    'and its plain-words message' );

# --- the existing "running" case is unaffected ------------------------------

my $both_running = $tira->format_output(
    $data, output => 'table', project => $root,
    with_police => 1, with_policy_bridge => 1 );
like( $both_running, qr/Police running beside this board/,
    'the existing "running" message is unaffected' );
like( $both_running, qr/Policy bridge running beside this board/,
    'and the policy-bridge one' );

# --- one running, one not - the two messages are independent ---------------

my $mixed = $tira->format_output(
    $data, output => 'table', project => $root,
    with_police => 1, with_policy_bridge => 0 );
like( $mixed, qr/Police running beside this board/, 'police running is reported' );
like( $mixed, qr/Policy bridge not running beside this board/,
    'and the policy bridge not running is reported independently, not overwritten' );

done_testing();

__END__

=head1 NAME

1126-a-silence-that-was-not-off.t - the dashboard says when police/the policy
bridge is NOT running too

=head1 DESCRIPTION

TKT-1028 gave the served dashboard an indicator for when police or the
policy bridge IS running beside it, but said nothing at all when either
was explicitly not - indistinguishable, in the rendered page, from a
context that never asked. TKT-1126 (Q-175, Michael's own answer: a static
snapshot) extends the same indicator to always render, in either
direction, whenever the caller answered the question at all - C<with_police>/
C<with_policy_bridge> passed as C<0> now renders "not running", the same
way C<1> already rendered "running". A caller that never passes the key at
all - a bare, unserved table export - still renders neither, since no
question was ever asked of it.

=cut
