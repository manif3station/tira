#!/usr/bin/env perl
# TKT-332. "Four epic agents were spawned... All four cards had
# agent_session: null... ALL FOUR failed with 'No agent named ... is
# reachable'." Our rules require RESUMING an agent rather than forking a
# second one for the same card, because a resumed agent keeps every
# measurement, dead end and correction it has already made - so an
# unrecorded spawn handle does not merely lose a field, it converts every
# future resume into a silent re-fork that discards everything the first
# agent learned. "The failure is invisible in the worst direction": forking
# a replacement looks like diligence and reports success.
#
# None of the 35 existing policy rules asked whether a card being worked
# had an agent_session recorded, even though record_update updates 'sandbox
# agent_session' in the same qw() list, one word apart, and card-sandbox-
# missing exists for the first.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T14:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Reachable', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'RCS', epic_prefix => 'RCE', ticket_prefix => 'RCT',
);
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->policy_add( project => $root, rule => 'card-agentless',
    enter => 'implement', action => 'bridge-reminder' );

sub agentless_findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'card-agentless' } @{ $pass->{violations} } ];
}

# --- a card being worked with no agent_session is reported ------------------
my $working = $tira->create_record( project => $root, type => 'ticket', title => 'Spawned, handle not written down' );
$tira->record_move( author => 'claude', project => $root, ref => $working->{ref}, column => 'implement' );

my @found = @{ agentless_findings() };
is( scalar @found, 1, 'a card in the working column with no agent_session is reported' );
is( $found[0]{ref}, $working->{ref}, 'naming the card' );
like( $found[0]{detail}, qr/agent_session/, 'and saying what is missing' );

# --- recording the handle settles it -----------------------------------------
$tira->record_update( project => $root, ref => $working->{ref}, author => 'claude',
    agent_session => 'sess-abc123' );
is( scalar @{ agentless_findings() }, 0, 'recording the handle settles the finding' );

# --- a card not in the working column is not reported ------------------------
my $waiting = $tira->create_record( project => $root, type => 'ticket', title => 'Not started yet' );
is( scalar @{ agentless_findings() }, 0, 'a card sitting in backlog, not being worked, is not reported' );

# --- a correctly assigned card with no session STILL reports - this is a
# different question from card-unassigned, not the same one -----------------
my $assigned = $tira->create_record( project => $root, type => 'ticket', title => 'Assigned but unreachable',
    assignee => 'claude' );
$tira->record_move( author => 'claude', project => $root, ref => $assigned->{ref}, column => 'implement' );
my @assigned_found = grep { $_->{ref} eq $assigned->{ref} } @{ agentless_findings() };
is( scalar @assigned_found, 1,
    'a card correctly assigned to somebody still reports missing agent_session - assignee is a different question from reachability' );

done_testing;

__END__

=head1 NAME

383-a-handle-nobody-wrote-down.t - card-agentless catches a working card with no recorded spawn handle

=head1 DESCRIPTION

TKT-332: none of the 35 existing policy rules asked whether a card being
worked had an agent_session recorded, even though record_update writes
'sandbox agent_session' one word apart in the same list, and
card-sandbox-missing already exists for the first. card-agentless reports
a card in the declared working column (--enter) with no agent_session,
settles the moment it is written, does not fire on a card not being
worked, and is a genuinely different question from card-unassigned - a
correctly assigned card with an unreachable agent still reports.
