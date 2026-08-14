#!/usr/bin/env perl
# The card outlives the agent working it.
#
# Michael's design, 2026-08-12: a card agent lives as long as its turn and then
# closes. Waking it must be a resume rather than a fresh agent - in his words,
# you get the previous context and the conversation back, otherwise it redoes
# everything, wastes tokens and becomes inconsistent. And who may wake it is
# its parent: the chain is strictly one-to-many downward, one at the top and
# many below, never the other way.
#
# Neither survived an agent closing, because neither was written anywhere. An
# agent that finished its turn took with it the only knowledge of how to
# continue it, and anything the user had said to it directly.
#
# So the card carries both: the handle to resume, and what passed. Tira spawns
# nothing and resumes nothing - it records what the thing that does needs to
# find, which is the same boundary that keeps it invoking no shell.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A chain', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ACS', epic_prefix => 'ACE', ticket_prefix => 'ACT',
);

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A part of the work' );
my $one = $tira->create_record( project => $root, type => 'ticket', title => 'First card' );
my $two = $tira->create_record( project => $root, type => 'ticket', title => 'Second card' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $one->{ref} );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $two->{ref} );

# --- the handle -----------------------------------------------------------

is( $tira->record_show( project => $root, ref => $one->{ref} )->{agent_session}, undef,
    'a card nobody has spawned an agent for carries no handle, rather than an empty one' );

$tira->record_update( project => $root, ref => $one->{ref}, agent_session => 'sess-7f3a' );
is( $tira->record_show( project => $root, ref => $one->{ref} )->{agent_session}, 'sess-7f3a',
    'the handle its parent needs to resume it is written on the card' );

$tira->record_update( project => $root, ref => $one->{ref}, agent_session => '' );
is( $tira->record_show( project => $root, ref => $one->{ref} )->{agent_session}, undef,
    'and can be cleared, for an agent that will not be woken again' );
$tira->record_update( project => $root, ref => $one->{ref}, agent_session => 'sess-7f3a' );

# --- a parent finds its children's, from the board alone ------------------
#
# From the board rather than from whatever spawned them, because the thing that
# spawned them is the thing that closes.

$tira->record_update( project => $root, ref => $two->{ref}, agent_session => 'sess-91bd' );

my $children = $tira->agent_sessions( project => $root, ref => $epic->{ref} );
is_deeply( $children,
    [ { ref => $one->{ref}, agent_session => 'sess-7f3a' },
      { ref => $two->{ref}, agent_session => 'sess-91bd' } ],
    'a parent can find every child it may wake, and what to resume' );

my $none = $tira->agent_sessions( project => $root, ref => $one->{ref} );
is_deeply( $none, [], 'a card with no children below it has nobody to wake' );

# A child with no agent yet is still a child. Leaving it out would make the
# list read as "these are all your children" when it is not.
my $three = $tira->create_record( project => $root, type => 'ticket', title => 'Not started' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $three->{ref} );
my $all = $tira->agent_sessions( project => $root, ref => $epic->{ref} );
is( scalar @{$all}, 3, 'a child with no agent yet is still listed' );
is( $all->[2]{agent_session}, undef, 'with nothing to resume, said plainly' );

# --- what passed ----------------------------------------------------------
#
# His words: the conversation is reflected onto the card, and the agent who
# owns the card is responsible for updating it. One command, so it is a thing
# that happens rather than a convention somebody remembers.

my $reflected = $tira->conversation_add(
    project => $root, ref => $one->{ref}, author => 'michael',
    said => 'Use the second approach, not the first',
    heard => 'ada',
);
like( $reflected->{id}, qr/\ACNV-\d{3}\z/, 'what passed is recorded with a number of its own' );

my $card = $tira->record_show( project => $root, ref => $one->{ref} );
is( scalar @{ $card->{conversation} }, 1, 'and lands on the card' );
is( $card->{conversation}[0]{author}, 'michael', 'saying who said it' );
is( $card->{conversation}[0]{heard}, 'ada', 'and who it was said to' );
like( $card->{conversation}[0]{said}, qr/second approach/, 'and what was said' );
ok( $card->{conversation}[0]{created_at}, 'and when' );

# --- and the chain can read it --------------------------------------------
#
# The reason it is on the card at all: a manager that cannot see what passed at
# the bottom of the chain is managing something it cannot see.

my $seen = $tira->conversation_list( project => $root, ref => $one->{ref} );
is( scalar @{$seen}, 1, 'anybody reading the card reads what passed' );

# More than one exchange, numbered in order. A conversation of one is the case
# that proves nothing about numbering, and a chain that only ever recorded the
# first thing said would be worse than recording none - it would read complete.
my $second = $tira->conversation_add(
    project => $root, ref => $one->{ref}, author => 'ada',
    said => 'Understood - the second approach it is', heard => 'michael' );
is( $second->{id}, 'CNV-002', 'the next exchange follows the last, rather than overwriting it' );
is( scalar @{ $tira->conversation_list( project => $root, ref => $one->{ref} ) }, 2,
    'and both are on the card, in the order they happened' );

my $refused = !eval {
    $tira->conversation_add( project => $root, ref => $one->{ref}, author => 'nobody-here',
        said => 'something' );
    1;
};
ok( $refused, 'and it has to be somebody the board knows, like every other authored thing' );

# --- the boundary ---------------------------------------------------------
#
# Tira records what the thing that spawns agents needs to find, and spawns
# nothing itself. The same boundary that keeps it invoking no shell.

my $engine = do { local $/; open my $fh, '<', 'lib/Tira.pm' or die $!; <$fh> };
$engine =~ s/^=\w.*?^=cut//gmsx;
$engine =~ s/^\s*#.*$//gm;
like( $engine, qr/package Tira/,
    'the engine source really was read, so the denial below is about code' );
unlike( $engine,
    qr/(?: qx[\{\(\/] | (?<![.\w]) system \s* \( | (?<![.\w]) exec \s* \( )/x,
    'nothing here spawns or resumes anything - Tira still invokes nothing' );

done_testing();

__END__

=head1 NAME

114-card-survives-its-agent.t - the card outlives the agent working it

=head1 DESCRIPTION

A card agent closes when its turn ends, and waking it must be a resume rather
than a fresh agent, or it works everything out again. Who may wake it is its
parent, because the chain is strictly one-to-many downward.

Neither survived an agent closing, because neither was written down. The card
carries both now: the handle to resume, and what passed between the user and
whoever was working it - so a manager can see what happened at the bottom of
its own chain.

Tira spawns nothing and resumes nothing. It records what the thing that does
needs to find.

=cut
