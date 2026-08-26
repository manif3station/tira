#!/usr/bin/env perl
# TKT-547. This session's own standing practice already treats a tasklist
# item as real, trackable work whenever it represents something worth
# remembering - every bug/improvement/doc-gap hunt finding got both a full
# ticket AND a tasklist entry linked to it via --ref. Nothing in the policy
# engine ever checked whether a tasklist item actually got that link, so a
# task written down and never turned into a card can sit informally tracked
# but invisible to every card-based policy (card-duration, checklist-idle,
# priority-skipped, gate-missing - none of them apply to tasklist items at
# all). Michael's own words, given live: "if task list empty; do nothing /
# if task list > 0 && if tasks has no ticket linked > 0 then / if related
# ticket <= 0 then create a new ticket from the task endif / link the task
# to the ticket endif" - and, when a police-engine rule was proposed for
# this, "the police would send instruction to the bridge instead of doing
# that itself" - it reports and instructs, it does not create or link
# anything on its own.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-26T14:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Noted', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'NTS', epic_prefix => 'NTE', ticket_prefix => 'NTT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

# --- the rule exists and needs an age, the same grace board-still/agent-still
# already use, so a task jotted down seconds ago is not immediately flagged
{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'task-unlinked'}, 'the catalogue offers a rule for an unlinked task' );

    my $bare = eval {
        $tira->policy_add( project => $root, rule => 'task-unlinked', action => 'bridge-reminder' );
        1;
    };
    ok( !$bare, 'declaring it without an age is refused' );
    like( $@ // '', qr/--age/, 'and the refusal names the option' );
}

# --- and it is a whole-board rule, not narrowable to one card --------------
{
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Anchor' );
    my $scoped = eval {
        $tira->policy_add( project => $root, rule => 'task-unlinked', age => '30m',
            action => 'bridge-reminder', ref => $card->{ref} );
        1;
    };
    ok( !$scoped, 'a --ref scope is refused' );
    like( $@ // '', qr/whole board/, 'naming why' );
}

$tira->policy_add( project => $root, rule => 'task-unlinked', age => '30m', action => 'bridge-reminder' );

sub unlinked_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'task-unlinked' } @{ $pass->{violations} } ];
}

# --- a fresh unlinked item is not flagged - it has not had a grace period yet
my $fresh = $tira->tasklist_add( project => $root, text => 'Just jotted down' );
is( scalar @{ unlinked_findings() }, 0, 'a task younger than the age is not flagged' );

# --- once it has aged past the grace period, it is reported ----------------
$now = '2026-08-26T14:45:00Z';
my @found = @{ unlinked_findings() };
is( scalar @found, 1, 'an aged, unlinked task is reported' );
is( $found[0]{ref}, $fresh->{id}, 'naming the tasklist item, by its own id' );
like( $found[0]{detail}, qr/no linked ticket/i, 'saying what is missing' );
like( $found[0]{detail}, qr/link it to one that already/i, 'instructing linking to an existing ticket' );
like( $found[0]{detail}, qr/file a full ticket/i, 'or filing a new one, linking the two' );

# --- linking it to a ticket settles the finding -----------------------------
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Now tracked' );
$tira->tasklist_task_ref_link( project => $root, id => $fresh->{id}, refs => [ $card->{ref} ] );
is( scalar @{ unlinked_findings() }, 0, 'linking it to a ticket settles the finding' );

# --- a done item is not reported, linked or not -----------------------------
my $finished = $tira->tasklist_add( project => $root, text => 'Already wrapped up' );
$tira->tasklist_update( project => $root, id => $finished->{id}, status => 'done' );
$now = '2026-08-26T15:30:00Z';
is( scalar @{ unlinked_findings() }, 0, 'a done item is not reported even unlinked and aged' );

# --- every session is swept, not just the shared one ------------------------
my $subagent = $tira->tasklist_add( project => $root, text => 'From a subagent', session => 'agent-a' );
$now = '2026-08-26T16:15:00Z';
@found = @{ unlinked_findings() };
is( scalar @found, 1, 'a different session\'s unlinked task is swept too' );
is( $found[0]{ref}, $subagent->{id}, 'naming it' );

done_testing;

__END__

=head1 NAME

398-a-note-nobody-turned-into-a-card.t - task-unlinked names a task nobody tied to a ticket

=head1 DESCRIPTION

TKT-547: a pending or working tasklist item with an empty C<refs> array,
older than the policy's C<--age>, is reported via the bridge naming the item
and instructing the reading agent to link it to an existing ticket or file a
new one - the police engine detects and instructs, it never creates or links
a ticket on its own. Whole-board (a C<--ref> scope is refused, the same way
C<board-still>/C<agent-still> refuse one), swept across every session, and
silent for a fresh, already-linked, or already-done item.

=cut
