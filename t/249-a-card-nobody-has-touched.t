#!/usr/bin/env perl
# A card nothing has happened to, wherever it is sitting.
#
# His question: "is there any policy to remind the agent a card has been sitting
# on the same column without any changes for too long?"
#
# Partly, and the gap is the second half. card-duration measures how long a card
# has been in one named column and says nothing about whether anybody is working
# it - a card being actively worked for five hours fires it exactly as an
# abandoned one does. checklist-idle watches the checklist alone, so a card
# edited constantly with no ticks fires and a card ticked once and then dropped
# does not. board-still asks the right question, has anything happened, and asks
# it of the whole board; the catalogue calls it the only rule here that is not
# about a card.
#
# So dwell is answered and silence is not. A card moved into verify twenty
# minutes ago and abandoned is indistinguishable from one moved in twenty
# minutes ago and being verified right now.
#
# This reads what board-still reads, one level down: last_updated, which every
# kind of activity stamps - a field written, a comment, an answer, a checklist
# tick, a column move. And it skips the columns work does not happen in, because
# a card resting in backlog or finished in done is not stalled, and reporting
# those would put every board permanently in violation of its own history.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Untouched', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
);

# --- the rule exists, and needs an age ----------------------------------------

{
    my %rules = map { $_ => 1 } @{ Tira::policy_rules() };
    ok( $rules{'card-still'}, 'the catalogue offers a rule for a card nothing happens to' );

    my $refused = !eval {
        $tira->policy_add( project => $root, rule => 'card-still',
            action => 'bridge-reminder' );
        1;
    };
    ok( $refused, 'and it cannot be declared without an age, because silence has a length' );
    like( $@ // '', qr/--age/, 'saying which option supplies it' );
}

$tira->policy_add( project => $root, rule => 'card-still', action => 'bridge-reminder',
    age => '2h' );

my $worked    = $tira->create_record( project => $root, type => 'ticket', title => 'Being worked' );
my $abandoned = $tira->create_record( project => $root, type => 'ticket', title => 'Left alone' );
my $waiting   = $tira->create_record( project => $root, type => 'ticket', title => 'Not started' );
my $finished  = $tira->create_record( project => $root, type => 'ticket', title => 'Over' );

$tira->record_move(author => 'claude',  project => $root, ref => $_->{ref}, column => 'implement' )
  for ( $worked, $abandoned );
$tira->record_move(author => 'claude',  project => $root, ref => $finished->{ref}, column => 'done' );

sub still {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return { map { $_->{ref} => $_ }
          grep { ( $_->{rule} // '' ) eq 'card-still' } @{ $pass->{violations} } };
}

# --- nothing is stale yet -----------------------------------------------------
#
# Asserted first, so what follows is time passing rather than a rule that
# reports everything.

is_deeply( still(), {}, 'a board where everything was just touched is quiet' );

# --- three hours later, with one of them worked in between ---------------------

{
    $now = '2026-08-17T11:30:00Z';
    $tira->comment_add( project => $root, ref => $worked->{ref}, author => 'claude',
        text => 'still on this' );

    $now = '2026-08-17T12:00:00Z';
    my $found = still();

    ok( $found->{ $abandoned->{ref} },
        'a card nothing has happened to for longer than the age is reported' );
    ok( !$found->{ $worked->{ref} },
        'while a card somebody touched half an hour ago is not' );

    # non-empty is the whole claim: the assertions about what it says would
    # pass against a violation carrying no detail at all.
    like( $found->{ $abandoned->{ref} }{detail} // '', qr/\S/, 'and it says something' );
    like( $found->{ $abandoned->{ref} }{detail} // '', qr/implement/,
        'naming where the card is sitting' );
}

# --- and the columns work does not happen in are left alone --------------------
#
# A card resting in the backlog has not started and a card in done is over.
# Reporting either would put every board permanently in violation of its own
# history, which is the reasoning the other card rules already use.

{
    my $found = still();
    ok( !$found->{ $waiting->{ref} },  'a card resting in the backlog is not stalled' );
    ok( !$found->{ $finished->{ref} }, 'and a finished card is not stalled either' );
}

# --- touching it settles it ----------------------------------------------------

{
    $now = '2026-08-17T12:05:00Z';
    $tira->checklist_add( project => $root, ref => $abandoned->{ref},
        item => 'picked it up again', status => 'todo' );

    my $found = still();
    ok( !$found->{ $abandoned->{ref} },
        'a card somebody has touched is not reported, whatever kind of touch it was' );
}

# --- and each column says how long is too long ---------------------------------
#
# His refinement, and it is the difference between a reminder and spam: a card
# may sit in one column far longer than in another without anything being
# wrong, and some columns want no watching at all. Every column already carries
# its own limit in minutes and its own watched flag - tira.stale has judged
# cards by them since they arrived, and no rule ever had.

{
    my $slow = $tira->create_record( project => $root, type => 'ticket',
        title => 'Somewhere a card may wait' );
    $tira->record_move(author => 'claude',  project => $root, ref => $slow->{ref}, column => 'verify' );
    $tira->column_update( project => $root, type => 'ticket', name => 'verify',
        notify_after => 600 );

    $now = '2026-08-17T17:00:00Z';
    my $found = still();

    ok( !$found->{ $slow->{ref} },
        'a column that allows ten hours is not reported at five' );
    ok( $found->{ $abandoned->{ref} },
        'while a column with no limit of its own still uses the age the policy was given' );
}

# --- and a column nobody watches is left alone ----------------------------------

{
    $tira->column_update( project => $root, type => 'ticket', name => 'implement',
        watched => 0 );

    my $found = still();
    ok( !$found->{ $abandoned->{ref} },
        'an unwatched column is out of scope however old its cards are' );

    $tira->column_update( project => $root, type => 'ticket', name => 'implement',
        watched => 1 );
    ok( still()->{ $abandoned->{ref} }, 'and watching it again brings it back' );
}

# --- proved by measuring dwell instead -----------------------------------------
#
# The distinction this card exists for. With the rule reading when the card
# arrived in its column rather than when anything last happened to it, the card
# being actively worked is reported and the answer stops being about silence.

{
    no warnings 'redefine';
    local *Tira::_card_last_activity = sub {
        my ( $self, $root, $record ) = @_;
        my ($since) = $self->_dwell_start( $root, $record->{ref} );
        return $since;
    };

    $now = '2026-08-17T15:00:00Z';
    $tira->comment_add( project => $root, ref => $worked->{ref}, author => 'claude',
        text => 'working on it right now' );

    my $found = still();
    ok( $found->{ $worked->{ref} },
        'measuring dwell reports a card being worked this minute, which is the noise this avoids' );
}

done_testing;

__END__

=head1 NAME

249-a-card-nobody-has-touched.t - silence about one card, not dwell

=head1 DESCRIPTION

C<card-duration> measures how long a card has been in a named column and
C<checklist-idle> watches its checklist; neither asks whether anything has
happened to the card. C<board-still> asks that of a whole board.

C<card-still> asks it of one card, reading the same C<last_updated> stamp that
every kind of activity touches, in any column work happens in. No column is
named, so one policy covers the board.

=cut
