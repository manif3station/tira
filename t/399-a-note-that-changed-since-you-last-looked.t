#!/usr/bin/env perl
# TKT-548. card-changed-by-owner already announces when the owner edits a
# ticket the agent might otherwise not notice - tasklist items have no
# equivalent. If a tasklist item's text is updated, an attachment is added,
# or a ref is linked, nothing tells the reading agent this happened via the
# bridge; the only way to find out is to re-list the tasklist and diff it
# against memory, which does not happen on any reliable cadence.
#
# Michael's exact words: "if task updated text or new attachment or linked
# to new ticket, the police will announce it on the bridge too." Asked
# whether that should be owner-only (matching card-changed-by-owner) or for
# any actor, since the agent's own routine tasklist_add/update calls happen
# many times an hour and an owner-only filter avoids the bridge drowning in
# them - his answer, live: "Announce every change regardless of actor."

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub { '2026-08-26T09:00:00Z' } );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police-store' );
$tira->project_new(
    name => 'Changed', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'CTS', epic_prefix => 'CTE', ticket_prefix => 'CTT',
);

sub changed_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'task-changed' } @{ $pass->{violations} } ];
}

# --- the rule exists, and needs no age - a change is a change the moment it
# happens, the same reasoning conversation-not-folded already gives -------
{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'task-changed'}, 'the catalogue offers a rule for a changed task' );
}

$tira->policy_add( project => $root, rule => 'task-changed', action => 'bridge-reminder' );

# --- a brand new item is not reported - there is nothing to compare it against
my $item = $tira->tasklist_add( project => $root, text => 'Original wording' );
is( scalar @{ changed_findings() }, 0, 'a freshly-added item is not reported - no prior state to differ from' );

# --- and a second, unchanged pass stays quiet -------------------------------
is( scalar @{ changed_findings() }, 0, 'an unchanged item stays quiet on a second look' );

# --- text changing is reported, any actor, per Michael's answer ------------
$tira->tasklist_update( project => $root, id => $item->{id}, text => 'Revised wording' );
my @found = @{ changed_findings() };
is( scalar @found, 1, 'a text change is reported' );
is( $found[0]{ref}, $item->{id}, 'naming the tasklist item' );
like( $found[0]{detail}, qr/text/i, 'saying what changed' );

# --- and settles once seen - the same item does not repeat next pass -------
is( scalar @{ changed_findings() }, 0, 'the same unchanged text does not report again' );

# --- an attachment being added is reported ----------------------------------
$tira->tasklist_task_attach_add_content( project => $root, id => $item->{id},
    filename => 'notes.txt', content => 'hello' );
@found = @{ changed_findings() };
is( scalar @found, 1, 'adding an attachment is reported' );
like( $found[0]{detail}, qr/attachment/i, 'saying an attachment changed' );
is( scalar @{ changed_findings() }, 0, 'and settles once seen' );

# --- linking a ref is reported ----------------------------------------------
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Now tracked' );
$tira->tasklist_task_ref_link( project => $root, id => $item->{id}, refs => [ $card->{ref} ] );
@found = @{ changed_findings() };
is( scalar @found, 1, 'linking a ref is reported' );
like( $found[0]{detail}, qr/ref/i, 'saying a ref changed' );
is( scalar @{ changed_findings() }, 0, 'and settles once seen' );

# --- any actor, not just the owner - the agent's own routine call reports too,
# per Michael's explicit answer overriding card-changed-by-owner's precedent
$tira->tasklist_update( project => $root, id => $item->{id}, text => 'Changed by the agent itself' );
is( scalar @{ changed_findings() }, 1,
    'the agent\'s own edit is reported too - no owner-only filter, per Q-082\'s answer' );
changed_findings();    # settle it before the next assertion

# --- a done item is not swept - the same restraint task-unlinked shows ------
my $finished = $tira->tasklist_add( project => $root, text => 'Wrapping up' );
changed_findings();    # establish its baseline
$tira->tasklist_update( project => $root, id => $finished->{id}, status => 'done' );
is( scalar @{ changed_findings() }, 0, 'marking an item done is not itself reported as a text/attachment/ref change' );

done_testing;

__END__

=head1 NAME

399-a-note-that-changed-since-you-last-looked.t - task-changed announces a tasklist edit

=head1 DESCRIPTION

TKT-548: whenever a tasklist item's text, attachments, or linked refs change
since the last police pass saw it, task-changed announces it via the bridge,
naming the item and what changed - for any actor, per Michael's explicit
answer to Q-082, not filtered to the owner the way card-changed-by-owner is.
No age (a change is a change the moment it happens); settles the instant it
has been seen once.

=cut
