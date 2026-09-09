#!/usr/bin/env perl
# TKT-1035, his reversal of TKT-848. His original answer to Q-106 shipped a
# broad rule - "Use yellow box highlight if question more than zero" - that
# kept a card highlighted yellow forever, even once every question on it was
# answered AND judged. Seeing that live (a copy of a real board, questions all
# settled, cards still lit up), his own words:
#
#   "Only highlight the card that got questions not answered"
#   "When answered but not being read or mark will be dim down"
#   "When all marked the card back to normal but not highlighted"
#   "I think that should be my expectation, not sure how it ends up being
#    altered" / "Go restore that"
#
# Three states, not the two `has_question` collapsed into one:
#   unanswered      -> yellow  (_card_waiting, unchanged)
#   answered, unmarked -> dim/grey (_card_to_review, unchanged - marking is
#                          what settles it, not a separate read_at check;
#                          t/65's own "once marked it leaves the review list"
#                          contract holds regardless of whether it was ever
#                          separately read via question_list)
#   answered AND marked -> normal, no class at all
#
# has_question/.card--has-question is retired - nothing is left for it to mean
# that the other two do not already cover between them.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite;
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Marked', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'MKS', epic_prefix => 'MKE', ticket_prefix => 'MKT' );

my $asked        = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question' );
my $settled      = $tira->create_record( project => $root, type => 'ticket', title => 'Answered, read, and judged' );
my $set_aside    = $tira->create_record( project => $root, type => 'ticket', title => 'Discarded question only' );
my $silent       = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing asked' );
my $unjudged     = $tira->create_record( project => $root, type => 'ticket', title => 'Answered, read, not marked' );
my $unread       = $tira->create_record( project => $root, type => 'ticket', title => 'Answered, not yet read' );

$tira->question_add( project => $root, ref => $asked->{ref}, text => 'Which one?' );

my $q = $tira->question_add( project => $root, ref => $settled->{ref}, text => 'And this?' );
$tira->question_answer( project => $root, ref => $settled->{ref}, id => $q->{id}, text => 'This one.' );
$tira->question_list( project => $root, ref => $settled->{ref} );    # marks read_at
$tira->question_mark( project => $root, ref => $settled->{ref}, id => $q->{id}, mark => 'ok' );

my $dropped = $tira->question_add( project => $root, ref => $set_aside->{ref}, text => 'Never mind' );
$tira->question_discard( project => $root, ref => $set_aside->{ref}, id => $dropped->{id} );

my $q3 = $tira->question_add( project => $root, ref => $unjudged->{ref}, text => 'Which way?' );
$tira->question_answer( project => $root, ref => $unjudged->{ref}, id => $q3->{id}, text => 'This way.' );
$tira->question_list( project => $root, ref => $unjudged->{ref} );    # read, but not yet marked

# Answered but never read via question_list at all - marking alone still has
# to settle it, per t/65's own long-standing contract ("once marked it leaves
# the review list"). Reading is not a separate gate marking must also clear.
my $q4 = $tira->question_add( project => $root, ref => $unread->{ref}, text => 'And what about this?' );
$tira->question_answer( project => $root, ref => $unread->{ref}, id => $q4->{id}, text => 'Like so.' );
$tira->question_mark( project => $root, ref => $unread->{ref}, id => $q4->{id}, mark => 'ok' );

sub flags_for {
    my ($ref) = @_;
    my $board = $tira->dashboard( project => $root, type => 'ticket' );
    for my $column ( values %{ $board->{ticket} } ) {
        for my $card ( @{$column} ) {
            next if $card->{ref} ne $ref;
            return { waiting => $card->{waiting}, to_review => $card->{to_review} };
        }
    }
    return undef;
}

# --- unanswered stays yellow, unchanged -------------------------------------

my $flags = flags_for( $asked->{ref} );
ok( $flags->{waiting}, 'an unanswered question still highlights the card yellow' );
ok( !$flags->{to_review}, 'and does not also read as to-review' );

# --- HIS REVERSAL: answered AND read AND marked goes back to NORMAL --------

$flags = flags_for( $settled->{ref} );
ok( !$flags->{waiting},
    'HIS REVERSAL: a question answered, read, and judged no longer highlights - '
      . '"When all marked the card back to normal but not highlighted"' );
ok( !$flags->{to_review}, 'and does not dim either - it is fully settled' );

# --- a discarded question never counted, still does not --------------------

$flags = flags_for( $set_aside->{ref} );
ok( !$flags->{waiting} && !$flags->{to_review},
    'a DISCARDED question does not count toward either state' );

$flags = flags_for( $silent->{ref} );
ok( !$flags->{waiting} && !$flags->{to_review}, 'a card with no questions is marked neither way' );

# --- answered but not yet MARKED dims -----------------------------------

$flags = flags_for( $unjudged->{ref} );
ok( !$flags->{waiting}, 'an answered question does not stay in the owner-waiting state' );
ok( $flags->{to_review},
    'HIS WORDS: "When answered but not being read or mark will be dim down" - '
      . 'answered but not yet judged dims' );

# --- marking alone settles it, whether or not it was ever separately read --

$flags = flags_for( $unread->{ref} );
ok( !$flags->{waiting}, 'an answered-and-marked-but-never-read question does not stay waiting' );
ok( !$flags->{to_review},
    'and does not dim either - marking is what settles a question, per t/65\'s '
      . 'own contract, not a separate read_at check on top of it' );

# --- has_question is retired from the dashboard payload itself -------------

my $full_board = $tira->dashboard( project => $root, type => 'ticket' );
my @all_cards = map { @{$_} } values %{ $full_board->{ticket} };
ok( @all_cards, 'at least one card was read to check its shape' );
ok( !( grep { exists $_->{has_question} } @all_cards ),
    'has_question is gone from the dashboard payload' );

# --- the browser no longer renders the retired class ------------------------

my $js = Suite::view_source('live-helpers.js');
like( $js, qr/card--to-review/, 'the browser markup was actually read - card--to-review is still there' );
unlike( $js, qr/has_question/, 'the browser markup no longer reads has_question' );

my $css = Suite::view_source('dashboard.css');
like( $css, qr/\.card--to-review\b/, 'the stylesheet was actually read - card--to-review still has a rule' );
unlike( $css, qr/card--has-question/, 'the retired class carries no stylesheet rule either' );

done_testing();

__END__

=head1 NAME

848-a-question-that-does-not-fade.t - a card's highlight matches his current, live decision

=head1 WHY

TKT-848 shipped his answer to Q-106 literally - any question, answered or not,
kept a card highlighted forever. TKT-1035 is his own reversal after seeing
that live: only an unanswered question should highlight; an answered but
unmarked question should dim instead; and a question fully answered and
marked should leave the card looking normal again.

=head1 WHAT IS ASSERTED

C<_card_waiting> is unchanged (unanswered only). C<_card_to_review> is also
unchanged (unmarked, regardless of C<read_at>) - a widened version checking
C<read_at> too was tried and reverted, since it broke t/65's own
long-standing "once marked it leaves the review list" contract; marking is
what settles a question, not a separate read gate on top of it.
C<has_question> and its class are gone from the engine, the
browser markup, and the stylesheet.

=cut
