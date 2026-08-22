#!/usr/bin/env perl
# A card moved backwards has not claimed anything.
#
# checklist-unmoved catches a card advancing while nothing was done: moved on
# with nothing ticked since it entered the column before. Reported from another
# project on a rule one day old, measured on their own card: it went
# in-progress to in-review, then in-review back to in-progress, and the rule
# reported the backwards move.
#
# Moving a card back is what happens when review sends it back. The checklist
# has not advanced precisely because the work is not done, which is the correct
# state and not a fault - and the report is the inverse of the rule's own
# purpose, which is why they called it that.
#
# The board knows its own column order, so which way a move went is answerable
# without inventing anything. It is the same question TKT-223 made the push
# gate ask a few hours earlier.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-08-16T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Sent back', dir => $root, members => ['claude'],
    columns => ['backlog, implement, review, done'],
    sow_prefix => 'SBS', epic_prefix => 'SBE', ticket_prefix => 'SBT',
);
$tira->policy_add( project => $root, rule => 'checklist-unmoved',
    action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Sent back for more work' );
$tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
    item => 'The work itself', status => 'todo' );

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'checklist-unmoved' } @{ $pass->{violations} } ];
}

# --- moved on with nothing ticked ------------------------------------------
#
# Asserted first, because what follows is a difference between two directions
# and not a rule that had nothing to say about this card at all.

$now = '2026-08-16T10:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
$now = '2026-08-16T11:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'review' );

ok( scalar @{ findings() },
    'a card moved on with nothing ticked since it entered the last column is reported' );

# --- and sent back with nothing ticked -------------------------------------

$now = '2026-08-16T12:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

is( scalar @{ findings() }, 0,
    'and a card sent back is not, because moving back claims nothing and the work not being done is why it went back' );

# --- then on again, which is a claim -----------------------------------------
#
# The rule has to come back. A card that could be silenced for ever by one
# backwards move would be worse than the report it replaced.

$now = '2026-08-16T13:00:00Z';
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'review' );

ok( scalar @{ findings() },
    'and moving on again with still nothing ticked is reported as before' );

done_testing;

__END__

=head1 NAME

223-a-card-sent-back.t - a backwards move claims nothing

=head1 DESCRIPTION

C<checklist-unmoved> reports a card that advanced with nothing ticked. It
reported backwards moves too, which is the inverse of its purpose: a card sent
back has an unfinished checklist because the work is not finished, and that is
the correct state.

The board knows its column order, so the direction of a move is answerable. The
rule comes back the moment the card advances again.

=cut
