#!/usr/bin/env perl
# TKT-666. card-duration measured a sow/epic's own dwell from its own
# arrival in a column - and a sow/epic lives in "in-progress" (or whatever
# a board calls its working column) for its ENTIRE life by design, the same
# way wip-limit already had to stop counting them per TKT-333. Live on this
# board: EPC-007 and SOW-004 fired CRITICAL over 250 times each, every one
# correctly answered by doing nothing, because no action short of finishing
# every child settles a duration measured from the parent's own arrival.
#
# THE FIX: a sow/epic's dwell is measured from the LATER of its own arrival
# or its most recent child's own last move - so a parent whose children are
# still moving is not stale, and one whose children stopped weeks ago while
# comments continued on the parent itself is still caught. A ticket's own
# dwell is unaffected; tickets have no children to look at.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-09-01T00:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'store' );
$tira->project_new(
    name => 'Parented', dir => $root, members => ['claude'],
    columns => ['backlog, in-progress, done'],
    sow_prefix => 'PTS', epic_prefix => 'PTE', ticket_prefix => 'PTT',
);
sub at { $now = $_[0]; return $now; }

$tira->policy_add( project => $root, rule => 'card-duration',
    action => 'bridge-reminder', column => 'in-progress', age => '2h' );

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A long epic' );
$tira->record_move( author => 'claude', project => $root, ref => $epic->{ref}, column => 'in-progress' );
my $child = $tira->create_record( project => $root, type => 'ticket', title => 'child one',
    parent => $epic->{ref} );

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'an ordinary ticket' );
$tira->record_move( author => 'claude', project => $root, ref => $ticket->{ref}, column => 'in-progress' );

sub card_duration_refs {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ sort map { $_->{ref} } grep { ( $_->{rule} // '' ) eq 'card-duration' } @{ $pass->{violations} } ];
}

# --- past the age, children still moving: the parent is not reported -------

at('2026-09-01T03:00:00Z');    # +3h on the epic's own arrival
$tira->record_move( author => 'claude', project => $root, ref => $child->{ref}, column => 'in-progress' );
$tira->record_move( author => 'claude', project => $root, ref => $child->{ref}, column => 'done' );

is_deeply( card_duration_refs(), [ $ticket->{ref} ],
    "the epic is not reported while its own child just moved - only the ordinary ticket is, exactly as today" );

# --- children stop moving for longer than the age: the parent IS reported --

at('2026-09-01T06:00:00Z');    # +3h since the child's own last move
is_deeply( card_duration_refs(), [ $epic->{ref}, $ticket->{ref} ],
    'once the child has also been quiet past the age, the epic is caught too - an abandoned epic is still found' );

done_testing();

__END__

=head1 NAME

666-a-parent-measured-by-its-children.t - card-duration measures a parent's
dwell from its children, not only its own arrival

=head1 DESCRIPTION

TKT-666. C<card-duration> used to measure a sow/epic's dwell from its own
arrival in a watched column - and a sow/epic lives there for its entire
life, so nothing short of finishing every child could ever settle the
violation (measured live: EPC-007 and SOW-004 fired 250+ times each). It
now takes the LATER of the parent's own arrival and its most recent child's
own last move, so a parent whose children are still active is not
reported, while one whose children have genuinely gone quiet still is - the
same "children moving means the parent is not stalled" reasoning TKT-333
already gave C<wip-limit>. A ticket's own dwell, having no children, is
unaffected.

=cut
