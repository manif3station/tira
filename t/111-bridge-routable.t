#!/usr/bin/env perl
# In a chain, one reader has to be able to route what it is told.
#
# Michael's design, 2026-08-12: police tells the core agent, and the core agent
# walks the message down the chain - core to SOW agent, SOW to epic agent, epic
# to ticket agent - with the answer coming back the same way. He was explicit
# that the card agent does not read the bridge; the core does.
#
# The bridge already says whose card it is, which is what a single agent needs
# to hear only about its own. A core agent needs something else: the path down
# to the card, because it does not hand a message to a ticket agent directly -
# it hands it to that agent's manager, who hands it on.
#
# Without the path the core agent has to go back to the board to work out who
# to tell, and going back to the board is exactly what the bridge exists to
# avoid: a card reparented after the line was written would rewrite what was
# already said.
#
# Nothing here changes what a single agent sees. That behaviour shipped in
# 1.14, it is right, and Q-018 and Q-021 are answers to different questions -
# one is how an agent hears about its own cards, the other is who reads the
# bridge in a chain.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-12T21:30:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Chained', dir => $root, members => [ 'michael', 'ada', 'grace' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CHS', epic_prefix => 'CHE', ticket_prefix => 'CHT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'The work' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A part of it' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'A card' );
$tira->hierarchy_link( project => $root, parent => $sow->{ref}, child => $epic->{ref} );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $ticket->{ref} );
$tira->record_update( project => $root, ref => $ticket->{ref}, assignee => 'ada' );

# --- the path down to the card --------------------------------------------

my $path = $tira->card_path( project => $root, ref => $ticket->{ref} );
is_deeply( $path, [ $sow->{ref}, $epic->{ref}, $ticket->{ref} ],
    'a card knows the whole path down to it, top first' );

is_deeply( $tira->card_path( project => $root, ref => $sow->{ref} ), [ $sow->{ref} ],
    'a card with nothing above it is its own path, rather than an error' );

my $loose = $tira->create_record( project => $root, type => 'ticket', title => 'On its own' );
is_deeply( $tira->card_path( project => $root, ref => $loose->{ref} ), [ $loose->{ref} ],
    'and so is a card raised on its own, which is how found work arrives' );

# --- written into the line ------------------------------------------------

$tira->bridge_write(
    store => $store,
    violations => [ {
        id => 'VIO-0001', ref => $ticket->{ref}, rule => 'card-full-details',
        detail => 'missing description', assignee => 'ada', tone => 'note',
        action => 'bridge-reminder', project => $root,
    } ],
);

# The first line introduces the replay; the violation is the one after it.
my ($line) = grep { /VIO-/ } @{ $tira->bridge_backlog( store => $store, lines => 5 ) };
like( $line, qr/\Qvia $sow->{ref} > $epic->{ref}\E/,
    'the line says the path down to the card, so the core agent knows who to tell' );
# Whose the card is used to be written into the line as well, inferred from
# the assignee. TKT-308 took it out: it was a guess, and a wrong one gave every
# other reader a reason to skip the line. The line still carries the reference
# and the command that shows the card, so whose it is comes from the card -
# exactly, where the guess was only usually right.
unlike( $line, qr/ \| for /, 'and names nobody, because that part was a guess' );
like( $line, qr/\Q$ticket->{ref}\E/,
    'while carrying the card, which is what whose-is-it is looked up from' );

# --- a card with nobody above it ------------------------------------------
#
# Said plainly rather than left out. A missing field reads as an oversight; a
# card that is genuinely nobody's child is a fact worth stating, and in a chain
# it means the core agent handles it itself.

$tira->bridge_write(
    store => $store,
    violations => [ {
        id => 'VIO-0002', ref => $loose->{ref}, rule => 'card-full-details',
        detail => 'missing description', tone => 'note',
        action => 'bridge-reminder', project => $root,
    } ],
);

my @lines = @{ $tira->bridge_backlog( store => $store, lines => 5 ) };
like( $lines[-1], qr/via nobody/,
    'a card with nothing above it says so, rather than leaving the reader to wonder' );

# --- a line about no card at all ------------------------------------------

$tira->bridge_write(
    store => $store,
    violations => [ {
        id => 'VIO-0003', rule => 'board-unbacked', detail => 'the board has never been backed up',
        tone => 'note', action => 'bridge-reminder', project => $root,
    } ],
);

@lines = @{ $tira->bridge_backlog( store => $store, lines => 5 ) };
unlike( $lines[-1], qr/via/,
    'a violation about no card carries no path, because there is nothing to walk down' );

# --- and one agent still hears only its own -------------------------------
#
# The behaviour that shipped in 1.14, unchanged. A chain reads the bridge
# without naming an agent; a single agent names itself and hears its own cards.

my $hers = $tira->bridge_backlog( store => $store, agent => 'ada', lines => 10 );
is( scalar( grep { /VIO-/ } @{$hers} ), 3,
    'ada hears her own card, the unassigned one, and the one about no card at all' );
ok( ( grep { /\Q$ticket->{ref}\E/ } @{$hers} ),
    'including hers, which she is given by the routing rather than by a name in the text' );

my $everything = $tira->bridge_backlog( store => $store, lines => 10 );
is( scalar( grep { /VIO-/ } @{$everything} ), 3,
    'and the core agent, naming nobody, hears all of it' );

done_testing();

__END__

=head1 NAME

111-bridge-routable.t - in a chain, one reader has to be able to route what it hears

=head1 DESCRIPTION

Police tells the core agent, and the core agent walks the message down the
chain rather than handing it to a ticket agent directly. That needs the path
down to the card written into the line, because going back to the board to work
it out is what the bridge exists to avoid - a card reparented afterwards would
rewrite what was already said.

What a single agent sees is unchanged. Hearing only about your own cards and
being the only reader of the bridge are answers to different questions.

=cut
