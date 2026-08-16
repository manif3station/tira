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

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Crowded', dir => $root, members => [ 'ada', 'grace' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CRS', epic_prefix => 'CRE', ticket_prefix => 'CRT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );

# One agent per ticket, named for the ticket - so a violation belongs to
# whoever is carrying that card, and a bridge that hands every agent every
# violation is noise by construction.
my %card;
for my $who (qw(ada grace)) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "\u${who}'s work" );
    $tira->record_update( project => $root, ref => $card->{ref}, assignee => $who );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
    $card{$who} = $card->{ref};
}
my $nobodys = $tira->create_record( project => $root, type => 'ticket', title => 'Nobody is carrying this' );
$tira->record_move( project => $root, ref => $nobodys->{ref}, column => 'implement' );

my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
$tira->bridge_write( store => $store, violations => $pass->{violations} );

sub heard_by {
    my ($agent) = @_;
    return join "\n", @{ $tira->bridge_backlog( store => $store, lines => 200, agent => $agent ) };
}

# --- each agent hears its own ---------------------------------------------

my $ada = heard_by('ada');
like( $ada, qr/\Q$card{ada}\E/, 'an agent hears about the card it is carrying' );
unlike( $ada, qr/\Q$card{grace}\E/, 'and not about somebody else\'s' );

my $grace = heard_by('grace');
like( $grace, qr/\Q$card{grace}\E/, 'and the same the other way round' );
unlike( $grace, qr/\Q$card{ada}\E/, 'with neither reading the other\'s work' );

# --- and the card nobody is carrying --------------------------------------

# Filtering that loses the unowned card trades noise for silence, which is the
# worse of the two: nobody is watching it by definition.
like( $ada, qr/\Q$nobodys->{ref}\E/, 'a card assigned to nobody reaches everybody' );
like( $grace, qr/\Q$nobodys->{ref}\E/, 'so it cannot fall between two agents' );

# --- asking for everything still works ------------------------------------

# The owner reads the whole bridge; only an agent narrows it.
my $everything = join "\n", @{ $tira->bridge_backlog( store => $store, lines => 200 ) };
like( $everything, qr/\Q$card{ada}\E/, 'naming no agent still hears everything' );
like( $everything, qr/\Q$card{grace}\E/, 'both halves of it' );

# --- what is not about a card ---------------------------------------------

# An unresolved policy is nobody's card and everybody's problem.
$tira->policy_add( project => $root, rule => 'card-stalled',
    before => 'nowhere-at-all', action => 'bridge-reminder' );
my $unresolved = $tira->policy_unresolved( project => $root );
$tira->bridge_write( store => $store, violations => [], notices => $unresolved );

like( heard_by('ada'), qr/UNRESOLVED/, 'a policy that resolves to nothing reaches an agent' );
like( heard_by('grace'), qr/UNRESOLVED/, 'every agent, because it is not about a card' );

# --- the way an agent actually reads it ------------------------------------

# The command an agent runs and keeps running. It narrows to whoever says who
# they are, by --author or by TIRA_AUTHOR said once in the environment.
{
    require Tira::CLI;

    sub bridge_cli {
        my (@argv) = @_;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        {
            local *STDOUT = $so;
            local *STDERR = $se;
            do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'policy.bridge', tira => $tira,
                argv => [ '--store', $store, '--once', @argv ] ) };
        }
        return $out;
    }

    my $named = bridge_cli( '--author', 'ada' );
    like( $named, qr/\Q$card{ada}\E/, 'the bridge command shows an agent its own cards' );
    unlike( $named, qr/\Q$card{grace}\E/, 'and not the other agent\'s' );

    my $from_environment = do {
        local $ENV{TIRA_AUTHOR} = 'grace';
        bridge_cli();
    };
    like( $from_environment, qr/\Q$card{grace}\E/,
        'and it takes who you are from the environment, said once rather than every time' );
    unlike( $from_environment, qr/\Q$card{ada}\E/, 'narrowing just the same' );

    my $everything = bridge_cli();
    like( $everything, qr/\Q$card{ada}\E/, 'while nobody named still reads the whole board' );
    like( $everything, qr/\Q$card{grace}\E/, 'which is how the owner watches it' );
}

done_testing;

__END__

=head1 NAME

102-bridge-per-agent.t - the bridge speaks to whoever is carrying the card

=head1 DESCRIPTION

AT99 in the kanban-management skill is one agent per ticket, named for the
ticket. So an agent's concern is exactly one card, and a bridge that hands
every agent every violation is noise by construction - and a channel that
becomes noise is one everybody learns to read past, which is the single failure
a warning system cannot survive.

A card nobody is carrying goes to everybody, because filtering that loses it
trades noise for silence and nobody is watching it by definition. Anything that
is not about a card at all - a policy that resolves to nothing - reaches
everybody for the same reason.

Reading the bridge without naming an agent still shows all of it. The owner
watches the whole board; it is only an agent that narrows.

=cut
