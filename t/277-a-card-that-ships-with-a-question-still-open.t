#!/usr/bin/env perl
# A card that reaches an ending with an unanswered question is not silent about it.
#
# discard-with-open-questions guarded exactly one ending, checked by a literal
# string: "next if ( $record->{column} // '' ) ne 'discard'". A card reaching
# done with a question still open passed through police in silence.
#
# Caught live, 2026-08-18. TKT-349 reached done with Q-047 still open - the
# agent had recorded his answer as a comment rather than an answer, so the
# question sat unresolved on a closed card, and police said nothing through a
# full pass on a board with thirty policies declared. He asked: "and TKT-349 is
# done. why open question in a done card for?" and then: "crazy" - correctly.
#
# The done case is the worse one. A discarded card's open question is usually
# moot - the work is not happening. A done card's question was load-bearing on
# work that shipped: Q-047 asked which columns should notify him, and a
# different answer would have shipped the wrong configuration with the very
# question that would have caught it sitting closed and unread.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub board {
    my (%args) = @_;
    my $tira = Tira->new( clock => sub {'2026-08-18T19:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, $args{name} );
    $tira->project_new(
        name    => $args{name},
        dir     => $root,
        members => [ 'claude', 'michael' ], agent => 'claude',
        columns => [ $args{columns} // 'backlog, implement, done' ],
        sow_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'S',
        epic_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'E',
        ticket_prefix => uc( substr( $args{name}, 0, 2 ) ) . 'T',
    );
    $tira->policy_add( project => $root, rule => 'discard-with-open-questions',
        action => 'bridge-reminder' );
    return ( $tira, $root );
}

# --- reaching done with an open question is reported --------------------------------

{
    my ( $tira, $root ) = board( name => 'shipped' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Ships with a loose end' );
    $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which columns should notify you?' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $card->{ref} } @{$violations};
    ok( $found, 'a card reaching done with an open question is reported' );
    like( $found->{message} // $found->{detail} // '', qr/Q-\d+/,
        'and the question is named, so the reader does not have to open the card' )
      if $found;
}

# --- discard still behaves exactly as it always did -----------------------------------
#
# The regression guard this card's own acceptance criteria demand.

{
    my ( $tira, $root ) = board( name => 'setaside' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Set aside with a question' );
    $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Still relevant?' );
    $tira->record_discard(author => 'claude',  project => $root, ref => $card->{ref} );

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $card->{ref} } @{$violations};
    ok( $found, 'discard is reported exactly as before' );
}

# --- a board whose ending column has another name is covered too --------------------
#
# Proves _ending_columns is doing the work, not a hardcoded list of names.

{
    my ( $tira, $root ) = board( name => 'named', columns => 'backlog, implement, shipped' );
    $tira->column_update( project => $root, type => 'ticket', name => 'shipped', terminal => 1 );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Ships under a different name' );
    $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Ready?' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'shipped' );

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $card->{ref} } @{$violations};
    ok( $found, "an ending column named 'shipped' is covered without the rule naming it" );
}

# --- an answered question reaching done is not reported --------------------------------
#
# Proves this is not "any card in an ending column" - only an unresolved one.

{
    my ( $tira, $root ) = board( name => 'answered' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Ships clean' );
    my $q = $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Ready?' );
    $tira->question_answer( project => $root, id => $q->{id}, author => 'michael', text => 'yes' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $card->{ref} } @{$violations};
    ok( !$found, 'a card whose question was answered before it shipped is not reported' );
}

# --- a mixed board (sow, epic, ticket) resolves each record by its own type ----------
#
# _ending_columns needs the RECORD's own type - $all is unscoped by type - so
# this proves a sow reaching its ending is checked against the sow board's
# endings, not the ticket board's.

{
    my ( $tira, $root ) = board( name => 'mixed' );
    my $sow = $tira->create_record( project => $root, type => 'sow',
        title => 'A statement of work with a loose end' );
    $tira->question_add( project => $root, ref => $sow->{ref}, author => 'claude',
        text => 'Scope settled?' );
    $tira->record_move(author => 'claude',  project => $root, ref => $sow->{ref}, column => 'implement' );
    $tira->record_move(author => 'claude',  project => $root, ref => $sow->{ref}, column => 'done' );

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $sow->{ref} } @{$violations};
    ok( $found, 'a sow reaching done with an open question is reported too' );
}

# --- proved by reverting to the literal discard check ---------------------------------

{
    my ( $tira, $root ) = board( name => 'proof' );
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Ships with a loose end' );
    $tira->question_add( project => $root, ref => $card->{ref}, author => 'claude',
        text => 'Which columns?' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );

    no warnings 'redefine';
    local *Tira::_ending_columns = sub { return {} };

    my $violations = $tira->policy_evaluate( project => $root );
    my ($found) = grep { $_->{rule} eq 'discard-with-open-questions'
        && $_->{ref} eq $card->{ref} } @{$violations};
    ok( !$found,
        'without _ending_columns, the done case goes silent again - the exact regression this fixes' );
}

done_testing;

__END__

=head1 NAME

277-a-card-that-ships-with-a-question-still-open.t - TKT-401

=head1 DESCRIPTION

C<discard-with-open-questions> checked C<column eq 'discard'> literally, so a
card reaching C<done> with an unanswered question passed through police in
silence - caught when TKT-349 shipped with Q-047 still open. The rule now
checks every ending column the board declares, discard included, without
naming discard as a special case that could drift from C<_ending_columns>.

=cut
