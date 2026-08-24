#!/usr/bin/env perl
# TKT-424. priority-skipped fires on a parent (sow/epic) sitting in a
# working column with a lower priority than something waiting elsewhere -
# including a parent that is open only because it has an unfinished child,
# not because anyone chose to work on the parent itself. Measured live: 10
# manual rule.suspend calls for EPC-003 alone in one afternoon, all for the
# identical bookkeeping reason.
#
# Q-074, answered by the owner 2026-08-24: option B. A parent is exempt only
# when it has no assignee AND has at least one open (non-settled) child AND
# its own last_updated is no later than that child's own last_updated/
# created_at - guarding against an unassigned parent someone actively edited
# (priority, description, ...) without formally claiming it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-24T10:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Waiting', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'WAS', epic_prefix => 'WAE', ticket_prefix => 'WAT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'priority-skipped', action => 'bridge-reminder' );

sub skipped_on {
    my ($ref) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'priority-skipped' && $_->{ref} eq $ref } @{ $pass->{violations} } ];
}

# A higher-priority EPIC waiting in the backlog - priority-skipped only
# compares cards of the same type, so the card that outranks an epic being
# worked has to be an epic too.
my $waiting = $tira->create_record( project => $root, type => 'epic',
    title => 'Waiting, higher priority', priority => 5 );

# --- a parent reopened only because a child is open is not "skipped" -------
my $epic = $tira->create_record( project => $root, type => 'epic',
    title => 'Reopened for its child', priority => 1 );
$tira->record_move( author => 'claude', project => $root, ref => $epic->{ref}, column => 'implement' );

my $child = $tira->create_record( project => $root, type => 'ticket',
    title => 'The open child', priority => 1 );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $child->{ref} );
$tira->record_move( author => 'claude', project => $root, ref => $child->{ref}, column => 'implement' );

is( scalar @{ skipped_on( $epic->{ref} ) }, 0,
    'a parent with no assignee, open only because of its own child, does not trigger priority-skipped' );

# --- assigned and worked directly - the exemption does not apply -----------
$tira->record_update( author => 'claude', project => $root, ref => $epic->{ref}, assignee => 'claude' );

is( scalar @{ skipped_on( $epic->{ref} ) }, 1,
    'the same parent, once assigned, triggers priority-skipped normally - genuine work is not exempt' );

# --- unassigned but actively edited after the child - still not exempt -----
my $epic2 = $tira->create_record( project => $root, type => 'epic',
    title => 'Reopened, then quietly worked without claiming it', priority => 1 );
$tira->record_move( author => 'claude', project => $root, ref => $epic2->{ref}, column => 'implement' );

my $child2 = $tira->create_record( project => $root, type => 'ticket',
    title => 'Its own open child', priority => 1 );
$tira->hierarchy_link( project => $root, parent => $epic2->{ref}, child => $child2->{ref} );
$tira->record_move( author => 'claude', project => $root, ref => $child2->{ref}, column => 'implement' );

is( scalar @{ skipped_on( $epic2->{ref} ) }, 0,
    'sanity: this second parent starts exempt too, same as the first' );

$now = '2026-08-24T11:00:00Z';
$tira->record_update( author => 'claude', project => $root, ref => $epic2->{ref},
    description => 'edited directly, without ever being assigned' );

is( scalar @{ skipped_on( $epic2->{ref} ) }, 1,
    'edited after its child, with no assignee - still fires, the exemption is narrow' );

done_testing;

__END__

=head1 NAME

389-a-parent-waiting-on-its-own-child.t - priority-skipped exempts a parent reopened only for its child

=head1 DESCRIPTION

TKT-424: priority-skipped could not tell a parent (sow/epic) that is open
only because a child is open under it from one genuinely being worked out
of turn, and fired identically on both - 10 manual C<rule.suspend> calls in
one afternoon for the same bookkeeping reason. Q-074 settled the design:
option B. The rule now exempts a parent with no assignee AND at least one
open child AND whose own C<last_updated> is no later than that child's own
activity - an assigned parent, or one edited after its child, still fires
exactly as before.

=cut
