#!/usr/bin/env perl
# A violation says what would clear it.
#
# developer-dashboard declared answer-ok-not-folded, which reads "settled in
# name only: marked ok, nothing written down". It found seven genuine cases they
# would never have found themselves - decisions the owner made, that both
# parties believed were handled, that had stopped existing anywhere a person
# would look. They are not asking for the rule to change.
#
# What is not said anywhere is WHERE it must be written down. They probed both
# attempts as they happened:
#
#   1. wrote the decision as a comment, in full, naming the question, the
#      answer and its consequence
#   2. next pass: said again, escalated to WARNING at seen 2
#   3. wrote the same words into a record field with --key-detail
#   4. next pass: SETTLED
#
# So a comment does not count and a field does. And discard-unexplained,
# declared minutes earlier on the same board, IS cleared by a comment alone.
#
# The difference is deliberate and defensible: a discard reason is a note
# somebody leaves, and a folded answer is content an agent reads back off the
# card. What was wrong is that neither rule said which it wanted, so learning
# the convention from one taught the wrong thing about the other - and cost an
# escalation to discover.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T15:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $store = File::Spec->catdir( $tmp, 'police' );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Written down', dir => $root, members => [ 'michael', 'ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WDS', epic_prefix => 'WDE', ticket_prefix => 'WDT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A decision the owner made' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    author => 'ada', text => 'Which way should this go?' );
$now = '2026-08-14T15:05:00Z';
$tira->question_answer( project => $root, ref => $card->{ref}, id => $question->{id},
    author => 'michael', text => 'The second way.' );
$tira->question_mark( project => $root, ref => $card->{ref}, id => $question->{id}, mark => 'ok' );

$tira->policy_add( project => $root, rule => 'answer-ok-not-folded', age => '1m',
    action => 'bridge-reminder' );

sub folded {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'answer-ok-not-folded' } @{ $pass->{violations} } ];
}

# --- the violation says where -------------------------------------------------------

$now = '2026-08-14T15:30:00Z';
my $found = folded();
is( scalar @{$found}, 1, 'an answer marked ok with nothing written down is reported' );
like( $found->[0]{detail}, qr/\Q$question->{id}\E/, 'naming the question' );
like( $found->[0]{detail}, qr/field/i,
    'and saying where the decision has to be written, which is the whole of their report' );
like( $found->[0]{detail}, qr/comment/i,
    'and that a comment is not that place, because that is the attempt they made first' );

# --- and following it clears it -------------------------------------------------------
#
# The test their report is really asking for: do what the message says and the
# violation goes away. A message naming a remedy that does not work would be
# worse than the silence it replaced.

$now = '2026-08-14T15:31:00Z';
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'ada',
    text => 'The owner chose the second way, and here is what it means for this card.' );
$now = '2026-08-14T15:40:00Z';
is( scalar @{ folded() }, 1,
    'a comment does not clear it, which is what they found by escalating to a warning' );

$now = '2026-08-14T15:41:00Z';
$tira->record_update( project => $root, ref => $card->{ref},
    key_details => ['The owner chose the second way, so the drain is widened rather than queued.'] );
$now = '2026-08-14T15:50:00Z';
is( scalar @{ folded() }, 0, 'and writing it into a field does' );

# --- while the rule beside it says what it accepts --------------------------------------
#
# The sharper half of their report. Two rules in the same set with different
# notions of where an explanation belongs, and a reader who learns one learns
# the wrong thing about the other.

my $dropped = $tira->create_record( project => $root, type => 'ticket', title => 'Set aside' );
$tira->record_move(author => 'claude',  project => $root, ref => $dropped->{ref}, column => 'discard' );
$tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );

sub unexplained {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'discard-unexplained' } @{ $pass->{violations} } ];
}

$now = '2026-08-14T15:51:00Z';
my $why = unexplained();
is( scalar @{$why}, 1, 'a discard with no reason is reported' );
like( $why->[0]{detail}, qr/comment/i,
    'and says a comment is what it wants, which is what it has always accepted' );

$tira->comment_add( project => $root, ref => $dropped->{ref}, author => 'ada',
    text => 'Overtaken by the other approach.' );
$now = '2026-08-14T15:52:00Z';
is( scalar @{ unexplained() }, 0, 'and a comment clears it, unchanged' );

# --- the guide says the same thing the messages do ----------------------------------------
#
# A convention that lives only in a violation is one you meet by tripping over
# it. Theirs cost an escalation to discover.

my $guide = Tira::CLI::_policy_help();
like( $guide, qr/answer-ok-not-folded[^\n]*field/i,
    'the guide says a folded answer belongs in a field' );
like( $guide, qr/discard-unexplained[^\n]*comment/i,
    'and that a discard reason is a comment' );

done_testing;

__END__

=head1 NAME

164-written-down-says-where.t - a violation says what would clear it

=head1 DESCRIPTION

C<answer-ok-not-folded> reported an answer marked ok with "nothing written
down" and did not say where. A comment carrying the whole decision did not clear
it; the same words in a record field did - and C<discard-unexplained>, in the
same set, is cleared by a comment alone.

The difference is deliberate: a discard reason is a note somebody leaves, and a
folded answer is content an agent reads back. Both messages now say which they
want, following either one clears it, and the guide says the same as the
messages.

=cut
