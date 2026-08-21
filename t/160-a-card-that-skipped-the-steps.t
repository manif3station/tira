#!/usr/bin/env perl
# A card cannot quietly skip the steps the board defines.
#
# He sent a photo of his own board - TESTS-RED, IMPLEMENT, VERIFY, DOCUMENT and
# PUSH, every one of them empty - and asked what was being worked. Nothing was
# wrong with the tool. The board defines eight columns and this agent had been
# using two of them: implement, then done. Every card in a long session made that
# move in one step, so the columns that exist to say what is happening were empty
# the whole time, and the only report he has said nothing.
#
# His answer, in his words: another policy option the agent sets, so that when a
# card moves from one column to another and misses the required columns, police
# shouts and calls it back.
#
# The evidence is already written down. Every move is journalled with its before
# and after by the engine rather than by whoever moved the card, so a card's own
# history says which columns it has been in.
#
# Which columns are required is the agent's to declare rather than inferred from
# the order they sit in. A documentation-only card has no red test to write, and
# a rule that inferred the whole sequence would report every legitimate shortcut
# - which is the noise that kills a channel.
#
# Police reports and moves nothing. Calling a card back is the agent's to do,
# like every other violation.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T13:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Steps', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, verify, document, push, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

sub walk {
    my ( $title, @columns ) = @_;
    my $card = $tira->create_record( project => $root, type => 'ticket', title => $title );
    for my $column (@columns) {
        $now =~ s/T(\d\d):(\d\d)/sprintf 'T%02d:%02d', $1, $2 + 1/e;
        $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => $column );
    }
    return $card->{ref};
}

sub skipped {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'column-skipped' } @{ $pass->{violations} } ];
}

my $short = walk( 'Worked the way this agent has been working', 'implement', 'done' );
my $long  = walk( 'Worked the way the board says',
    'tests-red', 'implement', 'verify', 'document', 'push', 'done' );

# --- a board that has not asked hears nothing ---------------------------------------

is( scalar @{ skipped() }, 0, 'a board that has not declared the rule hears nothing about it' );

$tira->policy_add( project => $root, rule => 'column-skipped', enter => 'done',
    require => 'tests-red, implement, verify, document, push', action => 'bridge-reminder' );

# --- the card that took the short way -------------------------------------------------

my $found = skipped();
is( scalar @{$found}, 1, 'a card that arrived without passing through the steps is reported' );
is( $found->[0]{ref}, $short, 'and it is the one that took the short way' );

# --- and it says which steps, not merely that some were missed -------------------------
#
# "This card skipped something" sends the reader back to the history to work out
# what. The rule already knows, and a violation that makes somebody look it up
# is one they will stop looking up.

like( $found->[0]{detail}, qr/tests-red/, 'the violation names the red test it never had' );
like( $found->[0]{detail}, qr/verify/,    'and the verification' );
like( $found->[0]{detail}, qr/document/,  'and the documentation' );
like( $found->[0]{detail}, qr/push/,      'and the release it never sat in' );
unlike( $found->[0]{detail}, qr/implement/,
    'and does not name the one it did pass through, because that is the half a reader acts on' );

# --- the card that did the work is silent ------------------------------------------------

is( scalar( grep { $_->{ref} eq $long } @{ skipped() } ), 0,
    'a card that passed through every required column is not reported' );

# --- a card that has not arrived yet is nobody's business ---------------------------------
#
# The rule is about arriving somewhere without having done the work, not about
# work in progress. A card still in implement has not skipped verify; it has not
# reached it.

my $working = walk( 'Still being worked', 'implement' );
is( scalar( grep { $_->{ref} eq $working } @{ skipped() } ), 0,
    'a card still on its way is not accused of skipping what it has not reached' );

# --- and the rule needs to be told what to require ------------------------------------------
#
# Without it the rule would have to infer the sequence from the order the
# columns sit in, and a documentation-only card with no red test would be
# reported for a step it never needed.

my $vague = !eval {
    $tira->policy_add( project => $root, rule => 'column-skipped', enter => 'done',
        action => 'bridge-reminder' );
    1;
};
ok( $vague, 'a policy that does not say which columns are required is refused' );
like( $@, qr/--require/, 'and names the option that says so' );

my $nowhere = !eval {
    $tira->policy_add( project => $root, rule => 'column-skipped',
        require => 'verify', action => 'bridge-reminder' );
    1;
};
ok( $nowhere, 'and so is one that does not say which column arriving means' );
like( $@, qr/--enter/, 'naming that one too' );

# --- police still writes no board --------------------------------------------------------
#
# Calling the card back is the agent's. A rule that moved cards would be the one
# piece of this that acts on its own, and the boundary is worth more than the
# convenience.

my ($still) = grep { $_->{ref} eq $short }
  @{ $tira->record_list( project => $root, type => 'ticket' ) };
is( $tira->record_show( project => $root, ref => $short )->{column}, 'done',
    'the card police complained about has not been moved by police' );

done_testing;

__END__

=head1 NAME

160-a-card-that-skipped-the-steps.t - a card cannot quietly skip the steps the board defines

=head1 DESCRIPTION

A card could arrive in a column without having been in the ones before it and
nothing said so - which is how a whole session of cards went from implement to
done in one move while the columns that show what is happening stayed empty.

C<column-skipped> reports a card that arrived in a named column without passing
through the columns the agent declared as required, and names which ones were
missed. The required set is declared rather than inferred, because a card that
legitimately skips a step would otherwise be reported for it. Police reports and
moves nothing: calling the card back is the agent's.

=cut
