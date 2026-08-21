#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $now = '2026-08-12T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0] }

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Busy', dir => $root, members => [ 'ada', 'grace', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BSS', epic_prefix => 'BSE', ticket_prefix => 'BST',
);
my $store = File::Spec->catdir( $tmp, 'police' );
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );

my %card;
for my $who (qw(ada grace)) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "For $who" );
    $tira->record_update( project => $root, ref => $card->{ref}, assignee => $who );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $card{$who} = $card->{ref};
}

sub sweep {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, violations => $pass->{violations} );
    return $pass;
}

sub heard_by {
    my ($agent) = @_;
    return join "\n", @{ $tira->bridge_backlog( store => $store, lines => 500, agent => $agent ) };
}

sweep();
like( heard_by('ada'), qr/\Q$card{ada}\E/, 'both agents are being told about their cards' );
like( heard_by('grace'), qr/\Q$card{grace}\E/, 'to begin with' );

# --- one agent asks for quiet ---------------------------------------------

# One agent per ticket means quiet has to belong to the agent. A switch that
# silences the board lets one agent stop the others being told about their own
# work, which is the opposite of what an escape hatch is for.
at('2026-08-12T09:05:00Z');
my $quiet = $tira->police_suspend(
    project => $root, store => $store, seconds => 300,
    reason => 'chasing one failing test to the bottom', author => 'ada' );
ok( $quiet, 'an agent can ask for quiet' );

at('2026-08-12T09:06:00Z');
sweep();

my $ada_after = $tira->bridge_backlog( store => $store, lines => 500, agent => 'ada' );
my $grace_after = $tira->bridge_backlog( store => $store, lines => 500, agent => 'grace' );

is( scalar( grep { /\Q$card{ada}\E/ && /09:06/ } @{$ada_after} ), 0,
    'the agent that asked hears nothing more while it is quiet' );
isnt( scalar( grep { /\Q$card{grace}\E/ && /09:06/ } @{$grace_after} ), 0,
    'and the other agent carries on hearing about its own cards' );

# --- the owner still sees everything --------------------------------------

# Police runs in his terminal. An agent asking for quiet is not entitled to
# silence the person watching the board.
at('2026-08-12T09:07:00Z');
my $pass = sweep();
ok( scalar @{ $pass->{violations} },
    'police still finds and reports violations to the owner while an agent is quiet' );

# --- and it comes back on its own -----------------------------------------

at('2026-08-12T09:11:00Z');
sweep();
isnt( scalar( grep { /\Q$card{ada}\E/ && /09:11/ }
        @{ $tira->bridge_backlog( store => $store, lines => 500, agent => 'ada' ) } ), 0,
    'when the time runs out the agent hears again, with nothing to undo' );

# --- the log is unchanged in shape ----------------------------------------

my $log = $tira->enforcement_log( project => $root, store => $store );
my ($entry) = grep { ( $_->{kind} // '' ) eq 'suspension' } @{$log};
ok( $entry, 'the suspension is in the enforcement log as it always was' );
like( $entry->{detail}, qr/chasing one failing test/, 'with the reason that was given' );

done_testing;

__END__

=head1 NAME

103-suspension-per-agent.t - quiet belongs to the agent that asked for it

=head1 DESCRIPTION

Suspension was one switch for the whole board: an agent asked police for quiet
so it could concentrate, and every agent stopped hearing. With one agent per
ticket that is one agent silencing everybody else's work.

So quiet is per agent. The others carry on being told about their own cards,
the owner watching police in his own terminal still sees everything - an agent
is not entitled to silence the person watching the board - and the enforcement
log records the suspension exactly as it did before. What changed is who stops
hearing, not what is written down.

=cut
