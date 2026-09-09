#!/usr/bin/env perl
# TKT-848, his own answer to Q-106, verbatim: "Use yellow box highlight if
# question more than zero. Like the card(s) which got question on."
#
# Broader than `waiting` (owner's move, unanswered only) and `to_review`
# (agent's move, answered-but-unjudged): his answer counts a card the moment
# it carries a question at all, whatever state that question is in - even one
# fully answered and judged, which today lights up neither existing flag.
#
# Modeled directly on t/59-waiting-cards.t's own dashboard()-level harness.
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

my $asked     = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question' );
my $resolved  = $tira->create_record( project => $root, type => 'ticket', title => 'Answered and judged' );
my $set_aside = $tira->create_record( project => $root, type => 'ticket', title => 'Discarded question only' );
my $silent    = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing asked' );

$tira->question_add( project => $root, ref => $asked->{ref}, text => 'Which one?' );

my $q = $tira->question_add( project => $root, ref => $resolved->{ref}, text => 'And this?' );
$tira->question_answer( project => $root, ref => $resolved->{ref}, id => $q->{id}, text => 'This one.' );
$tira->question_mark( project => $root, ref => $resolved->{ref}, id => $q->{id}, mark => 'ok' );

my $dropped = $tira->question_add( project => $root, ref => $set_aside->{ref}, text => 'Never mind' );
$tira->question_discard( project => $root, ref => $set_aside->{ref}, id => $dropped->{id} );

sub has_question_for {
    my ($ref) = @_;
    my $board = $tira->dashboard( project => $root, type => 'ticket' );
    for my $column ( values %{ $board->{ticket} } ) {
        for my $card ( @{$column} ) {
            return $card->{has_question} if $card->{ref} eq $ref;
        }
    }
    return undef;
}

ok( has_question_for( $asked->{ref} ), 'HELD: an unanswered question marks the card - the ordinary case' );

ok( has_question_for( $resolved->{ref} ),
    'HIS LITERAL ANSWER: a question fully answered AND judged still marks the '
      . 'card - "if question more than zero", not "if unanswered". Neither '
      . '`waiting` nor `to_review` fires here, and the highlight must anyway' );

ok( !has_question_for( $set_aside->{ref} ),
    'a DISCARDED question does not count - the same discarded_at exclusion '
      . '`_card_blocked` and `_card_to_review` already use' );

ok( !has_question_for( $silent->{ref} ), 'a card with no questions is not marked' );

# --- Codex review: answered-but-unjudged also fires to_review - CSS cascade
# order must not let its grey style silently outrank the yellow highlight ---

my $unjudged = $tira->create_record( project => $root, type => 'ticket', title => 'Answered, not yet judged' );
my $q2 = $tira->question_add( project => $root, ref => $unjudged->{ref}, text => 'Which way?' );
$tira->question_answer( project => $root, ref => $unjudged->{ref}, id => $q2->{id}, text => 'This way.' );

ok( has_question_for( $unjudged->{ref} ),
    'AN ANSWERED-BUT-UNJUDGED QUESTION ALSO COUNTS: it is `to_review` too, so '
      . 'the CSS has to make card--has-question win the cascade rather than '
      . 'letting the grey to-review style silently outrank the yellow one - '
      . 'his answer to Q-106 has no exception for this state' );

my $css_precedence = Suite::view_source('dashboard.css');
like( $css_precedence, qr/\.card--to-review\.card--has-question/,
    'a higher-specificity rule exists for the combined case, so the later '
      . '.card--to-review rule in the stylesheet cannot quietly win over the '
      . 'earlier .card--has-question one on the same card' );

# --- the browser marks the card with it -------------------------------------

my $js = Suite::view_source('live-helpers.js');
like( $js, qr/has_question/,
    'the card markup reads has_question, so the browser actually renders the '
      . 'flag rather than the engine computing it for nobody' );

# --- and CSS gives it the yellow box highlight he asked for ----------------

my $css = Suite::view_source('dashboard.css');
like( $css, qr/card--has-question/,
    'a CSS rule exists for the class, so the flag is not silently unstyled - '
      . 'the accepted-and-ignored fault this project keeps finding' );

done_testing();

__END__

=head1 NAME

848-a-question-that-does-not-fade.t - a card keeps its highlight until the question itself is gone

=head1 WHY

TKT-848, his own answer to Q-106: "Use yellow box highlight if question more
than zero." A card carrying a question is marked regardless of whether it has
been answered or judged - only a discarded question, or no question at all,
leaves it unmarked.

=cut
