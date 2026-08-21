#!/usr/bin/env perl
# Two rules that speak about columns where work has ended.
#
# Reported from another project on 2.07, with counts: their bridge holds 737
# distinct violations and the largest group by far is conversation-not-folded
# on cards that are finished - ten epics and three SOWs, every one of them in a
# column marked terminal. The message asks to fold the conversation into the
# details. On a card whose work has shipped there is nothing to fold it into
# that anybody will read, and no decision left to lose, which is the thing the
# rule exists to protect.
#
# column-unwatched came with it and is sharper still: it describes itself as
# "a column work happens in that no column-scoped policy names", and it was
# naming three columns marked terminal. Work does not happen there. The rule's
# own words exclude them, so this is the rule not doing what it says rather
# than a judgement about what it should do.
#
# The board already says which columns these are, and the engine already asks:
# checklist-unmoved reads _resting_columns, which takes protected and terminal
# from the board and falls back to done when nothing is marked. The decision
# exists. These two did not ask it.

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
    name => 'Ended', dir => $root, members => ['claude'],
    columns => ['backlog, implement, shipped, done'],
    sow_prefix => 'ENS', epic_prefix => 'ENE', ticket_prefix => 'ENT',
);

# A second ending, marked as one. A board with more than one finished column
# marks each of them, which is what these rules should be reading.
$tira->column_update( project => $root, type => 'ticket', name => 'shipped', terminal => 1 );

$tira->policy_add( project => $root, rule => 'conversation-not-folded',
    action => 'bridge-reminder' );

# A card with a comment newer than anything written on it - the shape the rule
# is about - so what follows is about where the card sits and nothing else.
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Talked about after it was written down' );

# Moved first and talked about afterwards, in that order. A move writes the
# card, so a comment made before it is not later than anything written - which
# is the rule being right, and made the first version of this test measure
# nothing.
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
$now = '2026-08-16T10:00:00Z';
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude',
    text => 'Something said after the card was last written' );

sub findings {
    my ($rule) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq $rule } @{ $pass->{violations} } ];
}

# --- while the card is still being worked ----------------------------------
#
# Asserted first, so what follows is a difference between two columns rather
# than a rule that had nothing to say about this card at all.

ok( scalar @{ findings('conversation-not-folded') },
    'a card still being worked is asked to fold the conversation in' );

# --- and once it has ended --------------------------------------------------

# Moved, then talked about again, so the card is in the same state it was in
# above and only the column has changed. Without the second comment the move
# itself writes the card, nothing is unfolded, and the rule is silent for a
# reason that has nothing to do with the column - which is what the first
# version of this test measured.
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'shipped' );
$now = '2026-08-16T11:00:00Z';
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude',
    text => 'Something said after it had shipped' );
is( scalar @{ findings('conversation-not-folded') }, 0,
    'and a card in a column the board marks terminal is not, because there is nothing left to fold it into' );

done_testing;

__END__

=head1 NAME

221-a-conversation-on-a-finished-card.t - folding into details nobody will read

=head1 DESCRIPTION

C<conversation-not-folded> asked cards in terminal columns to fold a
conversation into details nobody will read, and was the largest group of
violations on the board that reported it. C<column-unwatched> named terminal
columns as columns work happens in, which its own description excludes.

The board says which columns these are and the engine already asks through
C<_resting_columns>. These two did not.

=cut
