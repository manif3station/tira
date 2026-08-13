#!/usr/bin/env perl
# A card being worked says who is working on it.
#
# He sent a screenshot of a card reading "TKT-104 . ticket . implement" with the
# assignee showing a dash: "implementing but no assignee? a ghost working on
# it?" It was true of every card moved into a gate that day. The board said work
# was in progress and could not say by whom, for hours, and nothing on it
# objected - twenty-three rules watching, and none of them asking who is doing
# the work.
#
# Then: "that is another new policy the agent to set to preview unassigned
# ticket being work at. Add this policy option for agent to set and police will
# catch it."
#
# card-metrics could already express it per column - --enter implement --require
# assignee reports exactly this, and that was checked before writing a line of
# code. What it cannot do is stay true when somebody adds a column: the policy
# names one, and the next column arrives uncovered and silent, which is the
# shape of every check this project has found not firing.
#
# So the rule asks the board rather than a policy. Every board is created with
# backlog and discard marked protected - the two columns Tira owns - and
# everything else is somewhere work happens. A column added tomorrow is covered
# the day it exists.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T16:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Who holds it', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'WHS', epic_prefix => 'WHE', ticket_prefix => 'WHT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

sub unassigned {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'card-unassigned' } @{ $pass->{violations} } ];
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Somebody must hold this' );

# --- a board that has not asked hears nothing ---------------------------------
#
# Before the rule is declared at all. Every rule here is a setting an agent
# turns on, and a board that never asked must be untouched.

$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
is( scalar @{ unassigned() }, 0, 'a board that has not declared the rule hears nothing about it' );

$tira->policy_add( project => $root, rule => 'card-unassigned', action => 'bridge-reminder' );

# --- work in progress with nobody on it ----------------------------------------

my $found = unassigned();
is( scalar @{$found}, 1, 'a card being worked with nobody on it is reported' );
is( $found->[0]{ref}, $card->{ref}, 'naming the card' );
like( $found->[0]{detail}, qr/implement/, 'and where it is, because that is what makes it work in progress' );
like( $found->[0]{detail}, qr/nobody|no one|assignee/i, 'saying what is missing' );

# --- and it stops the moment somebody takes it ---------------------------------

$tira->assignment_set( project => $root, ref => $card->{ref}, people => ['ada'] );
is( scalar @{ unassigned() }, 0, 'once somebody holds it, nothing more is said' );

# --- waiting is not working -----------------------------------------------------
#
# The backlog is where cards wait, and a card nobody has picked up is the normal
# state of a backlog rather than a fault. Reporting those would make the rule
# noise on the first day of any board.

my $waiting = $tira->create_record( project => $root, type => 'ticket', title => 'Not started' );
is( scalar @{ unassigned() }, 0, 'a card sitting in the backlog with nobody on it is not reported' );

# --- and neither is work that is over -------------------------------------------

$tira->record_move( project => $root, ref => $waiting->{ref}, column => 'discard' );
is( scalar @{ unassigned() }, 0, 'nor one that was set aside' );

# --- every other column counts, including ones added later -----------------------
#
# The reason this is a rule rather than card-metrics --require assignee, which
# already worked per column. A policy naming a column stops covering the board
# the moment somebody adds one, and says nothing about it.

$tira->column_add( project => $root, type => 'ticket', name => 'review' );
my $later = $tira->create_record( project => $root, type => 'ticket', title => 'In a column nobody declared' );
$tira->record_move( project => $root, ref => $later->{ref}, column => 'review' );
my $covered = unassigned();
is( scalar @{$covered}, 1, 'a column added after the policy was declared is covered' );
is( $covered->[0]{ref}, $later->{ref}, 'and it is the card in it' );

# --- done is work that is over too ----------------------------------------------
#
# Not protected, so it has to be reasoned about rather than assumed. A finished
# card with nobody on it is history, not work in progress - and chasing it would
# mean chasing every card the board has ever finished, for ever.

$tira->record_move( project => $root, ref => $later->{ref}, column => 'done' );
is( scalar @{ unassigned() }, 0, 'a finished card is not work in progress, whoever finished it' );

# --- the rule takes nothing it cannot honour -------------------------------------
#
# It asks the board which columns are work, so a column on the policy would be a
# second answer to a question already answered - and a setting accepted and
# ignored is worse than one refused.

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'card-unassigned',
        column => 'implement', action => 'bridge-reminder' );
    1;
};
ok( $refused, 'a column on this rule is refused, because the board already says which are work' );

# And the other way a column can be named. Both are declared as refused and only
# one was tried, which the check in t/79 found on its first run - the rule
# refused correctly either way, and nothing would have noticed if it stopped.
my $entering = !eval {
    $tira->policy_add( project => $root, rule => 'card-unassigned',
        enter => 'implement', action => 'bridge-reminder' );
    1;
};
ok( $entering, 'and so is naming a column to enter, for the same reason' );

done_testing;

__END__

=head1 NAME

133-work-with-nobody-on-it.t - a card being worked says who is working on it

=head1 DESCRIPTION

A card sat in C<implement> with no assignee for hours and nothing on the board
objected: twenty-three rules watching, none asking who is doing the work.

C<card-unassigned> reports a card that is neither waiting nor finished and has
nobody on it. It asks the board which columns those are - every board marks its
backlog and discard columns protected - rather than naming one on the policy,
so a column added tomorrow is covered the day it exists. C<card-metrics
--require assignee> could already do it for one named column; that is what it
stops doing the moment the board grows.

=cut
