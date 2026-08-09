#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Review', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'RVS', epic_prefix => 'RVE', ticket_prefix => 'RVT' );

# One card of every state a question can leave behind.
my %card = map {
    $_ => $tira->create_record( project => $root, type => 'ticket', title => "Card $_" )
} qw(unanswered answered marked discarded silent);

my $waiting = $tira->question_add(
    project => $root, ref => $card{unanswered}{ref}, text => 'Still waiting on you' );
my $answered = $tira->question_add(
    project => $root, ref => $card{answered}{ref}, text => 'Answered, not yet judged' );
my $judged = $tira->question_add(
    project => $root, ref => $card{marked}{ref}, text => 'Answered and judged' );
my $aside = $tira->question_add(
    project => $root, ref => $card{discarded}{ref}, text => 'Set aside' );

$tira->question_answer( project => $root, id => $answered->{id}, text => 'Here you are.' );
$tira->question_answer( project => $root, id => $judged->{id}, text => 'And here.' );
$tira->question_mark( project => $root, id => $judged->{id}, mark => 'ok' );
$tira->question_discard( project => $root, id => $aside->{id} );

sub flags {
    my ($key) = @_;
    my $board = $tira->dashboard( project => $root, type => 'ticket', summary => 1, with_questions => 1 );
    for my $column ( values %{ $board->{ticket} } ) {
        for my $entry ( @{$column} ) {
            return $entry if $entry->{ref} eq $card{$key}{ref};
        }
    }
    return {};
}

# The toggle's whole point: answers the owner has given that the agent has not
# yet accepted or rejected. Not the same as waiting, which includes questions
# the owner has not answered at all.
ok( flags('answered')->{to_review}, 'an answered question nobody has marked is for review' );
ok( !flags('unanswered')->{to_review},
    'a question still waiting on the owner is not: that is his to do, not the agent\'s' );
ok( !flags('marked')->{to_review}, 'once marked it leaves the review list' );
ok( !flags('discarded')->{to_review}, 'a discarded question needs no judgement' );
ok( !flags('silent')->{to_review}, 'and a card nobody asked about is never in it' );

# A cross is a judgement too, so it clears the card just as a tick does.
$tira->question_mark( project => $root, id => $answered->{id}, mark => 'not-ok' );
ok( !flags('answered')->{to_review}, 'marking it not-ok also settles the judgement' );

# The two flags mean different things and must not be confused.
$tick = '2026-08-09T10:00:00Z';
my $fresh = $tira->question_add(
    project => $root, ref => $card{marked}{ref}, text => 'A new one on a judged card' );
ok( flags('marked')->{waiting}, 'a new question makes the card wait again' );
ok( !flags('marked')->{to_review}, 'but there is nothing to review until it is answered' );
$tira->question_answer( project => $root, id => $fresh->{id}, text => 'Done.' );
ok( flags('marked')->{to_review}, 'and then there is' );

# The board offers the toggle and can draw the difference.
my $html = $tira->format_output(
    $tira->dashboard( project => $root, type => 'ticket', summary => 1, with_questions => 1 ),
    output => 'table', project => $root, live => 1 );
like( $html, qr/class="board-review"/, 'the board control offers the toggle' );
like( $html, qr/aria-pressed="false"/, 'switched off, so the board shows everything to begin with' );
like( $html, qr/card--to-review/, 'a card with an answer to judge is marked as such' );
like( $html, qr/let reviewOnly=false/, 'and the filter starts off' );
like( $html, qr/\Q!reviewOnly||item.querySelector(".card--to-review")\E/,
    'the toggle narrows the same render that owns filtering, paging and counts' );
like( $html, qr/data-review/, 'every board carries the control' );

done_testing;

__END__

=head1 NAME

65-review-toggle.t - the board toggle for answers waiting to be judged

=head1 DESCRIPTION

An agent needs to find the answers it has been given but not yet
accepted or rejected. That is a different question from which cards are
waiting on somebody: a card whose question the owner has not answered
is his to deal with, not the agent's. Proves the flag covers answered
and unmarked only, that a cross clears it as surely as a tick, that
discarded questions need no judgement, and that the toggle narrows the
same render which already owns filtering, paging and the counts, so
they cannot disagree.

=cut
