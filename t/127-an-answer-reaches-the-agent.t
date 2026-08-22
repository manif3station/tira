#!/usr/bin/env perl
# An answer reaches the agent that was waiting for it.
#
# He raised it: "when a question being answered, and the police is running,
# there is no message from the police printed on the bridge to get the core
# agent to get attention." Then, on the same card: "have you tested the police
# and the message on the bridge with event properly? make sure they work."
#
# The honest answer was no. Four rules touch questions and every one of them
# chases neglect after a grace period - question-unanswered wants an answer,
# answer-unjudged fires when one has sat unmarked past its age,
# answer-ok-not-folded when a settled answer was never written down,
# answer-not-ok-no-followup when a cross had no follow-up. Not one of them
# announces that an answer arrived.
#
# Measured on his board rather than assumed: answer-unjudged and
# question-unanswered are both set there at two hours. So an answer given now
# produced nothing on the bridge for two hours, and then only a complaint that
# it had not been marked - never "you have been answered, the card is yours
# again". An agent that stopped to ask something stayed stopped.
#
# The grace periods are right for what they were built for. Chasing somebody who
# has not acted needs one, or it is nagging. Announcing an answer needs none,
# because the agent could not have acted sooner: it did not know.
#
# What makes it stop is the agent reading the answer, which is already recorded
# and already happens by reading - so there is nothing to dismiss by hand and
# nothing that goes quiet because somebody said it had.
#
# Driven the way he asked: the answer is given, police passes, and the line is
# read off the bridge by the agent that holds the card.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T12:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Waiting', dir => $root, members => [ 'michael', 'ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Blocked on an answer' );
$tira->record_update( author => 'michael', project => $root, ref => $card->{ref}, assignee => 'ada' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    author => 'ada', text => 'Which way round?', reason => 'both are defensible' );

# The rule as an agent would set it: no age, because there is nothing to wait
# for. The other question rules all take one and all of them are about neglect.
$tira->policy_add( project => $root, rule => 'answer-waiting',
    action => 'bridge-reminder' );

sub sweep {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    $tira->bridge_write( store => $store, project => $root,
        violations => $pass->{violations} );
    return $pass;
}
sub heard_by {
    my ($agent) = @_;
    return join "\n", @{ $tira->bridge_backlog( store => $store, lines => 500, agent => $agent ) };
}

# --- an unanswered question is not news -------------------------------------
#
# The rule is about answers arriving. A question nobody has answered is what
# question-unanswered is for, and saying it twice would be the noise TKT-099
# was raised about.

sweep();
is( heard_by('ada'), '', 'a question still waiting is not announced as answered' );

# --- the answer arrives -------------------------------------------------------

$now = '2026-08-13T12:00:30Z';
$tira->question_answer( project => $root, id => $question->{id},
    text => 'The second way', author => 'michael' );

$now = '2026-08-13T12:01:00Z';
my $pass = sweep();
my ($told) = grep { $_->{rule} eq 'answer-waiting' } @{ $pass->{violations} };
ok( $told, 'an answered question is reported on the very next pass' );
is( $told->{ref}, $card->{ref}, 'about the card it is on' );
like( $told->{detail}, qr/\Q$question->{id}\E/, 'naming the question' );
like( $told->{detail}, qr/answered/, 'and saying what happened, not that something is wrong' );

# --- and it reaches the agent holding the card ------------------------------
#
# The half he asked about. A violation police knows and nobody hears is the
# same silence in a different file.

like( heard_by('ada'), qr/\Q$card->{ref}\E/, 'the agent holding the card hears it' );
like( heard_by('ada'), qr/\Q$question->{id}\E/, 'with the question named on the line' );
is( heard_by('michael'), '', 'and the agent who answered is not told about its own answer' );

# --- with no grace at all ------------------------------------------------------
#
# Thirty seconds after the answer. answer-unjudged on his board would have said
# nothing for two hours.

like( $told->{detail}, qr/12:00:30/, 'thirty seconds after the answer was given' );

# --- reading it is what stops it ----------------------------------------------
#
# Reading is already recorded, and already happens by reading, so there is
# nothing to dismiss by hand - and nothing that goes quiet because somebody
# said it had.

$now = '2026-08-13T12:02:00Z';
$tira->question_list( project => $root, ref => $card->{ref} );
$now = '2026-08-13T12:02:30Z';
my $after = sweep();
is( scalar( grep { $_->{rule} eq 'answer-waiting' } @{ $after->{violations} } ), 0,
    'once the agent has read the answer it is not reported again' );

# --- a second answer is announced again ---------------------------------------
#
# An answer reworded is news the agent has not seen. Going quiet for ever after
# the first read would lose it.

$now = '2026-08-13T12:03:00Z';
$tira->question_answer( project => $root, id => $question->{id},
    text => 'On reflection, the first way', author => 'michael' );
$now = '2026-08-13T12:03:30Z';
my $again = sweep();
is( scalar( grep { $_->{rule} eq 'answer-waiting' } @{ $again->{violations} } ), 1,
    'an answer changed after it was read is announced again' );

# --- and an answer already judged is not chased ---------------------------------
#
# Marking an answer does not record a read, so a board with history would be
# chased about every answer it has ever settled. Nobody can judge an answer they
# have not read, so a mark settles this as surely as a read does. Found the day
# the rule was first declared on the development board: eleven answers, every
# one marked ok, every one from days earlier.

$now = '2026-08-13T12:03:45Z';
$tira->question_mark( project => $root, id => $question->{id}, mark => 'ok' );
$now = '2026-08-13T12:04:00Z';
my $judged = sweep();
is( scalar( grep { $_->{rule} eq 'answer-waiting' } @{ $judged->{violations} } ), 0,
    'an answer that has been judged is not announced, because judging it means reading it' );

# --- a discarded question is not announced ------------------------------------

$now = '2026-08-13T12:04:00Z';
$tira->question_discard( project => $root, id => $question->{id} );
$now = '2026-08-13T12:04:30Z';
my $gone = sweep();
is( scalar( grep { $_->{rule} eq 'answer-waiting' } @{ $gone->{violations} } ), 0,
    'a question set aside is not announced, whatever its answer says' );

# --- and a board without the rule hears nothing -------------------------------

my $quiet_root = File::Spec->catdir( $tmp, 'quiet' );
$tira->project_new(
    name => 'No rule', dir => $quiet_root, members => ['ada', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QTS', epic_prefix => 'QTE', ticket_prefix => 'QTT',
);
$tira->policy_add( project => $quiet_root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $other = $tira->create_record( project => $quiet_root, type => 'ticket', title => 'Elsewhere' );
my $unread = $tira->question_add( project => $quiet_root, ref => $other->{ref},
    author => 'ada', text => 'Anything?', reason => 'because' );
$tira->question_answer( project => $quiet_root, id => $unread->{id}, text => 'Yes', author => 'michael' );

my $elsewhere = $tira->police_pass( project => $quiet_root,
    store => File::Spec->catdir( $tmp, 'other-police' ), world => {} );
is( scalar( grep { $_->{rule} eq 'answer-waiting' } @{ $elsewhere->{violations} } ), 0,
    'a board that has not added the rule hears nothing about answers' );

# --- the rule needs nothing declared with it ----------------------------------
#
# Every other question rule takes an age. This one must not, because an age
# would be a grace, and the whole point is that there is none.

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'answer-waiting',
        age => '10m', action => 'bridge-reminder' );
    1;
};
ok( $refused, 'an age on this rule is refused, because a grace is the thing it exists without' );
like( $@, qr/takes no --age/, 'refused for the age, in the words somebody typing it would read' );

done_testing;

__END__

=head1 NAME

127-an-answer-reaches-the-agent.t - an answer reaches the agent that was waiting

=head1 DESCRIPTION

Four rules touched questions and every one chased neglect after a grace period.
None announced that an answer had arrived, so an agent that stopped to ask
something stayed stopped: on a board with C<answer-unjudged> at two hours, an
answer produced nothing for two hours and then only a complaint that it had not
been marked.

C<answer-waiting> announces it on the next pass with no grace, because the agent
could not have acted sooner - it did not know. Reading the answer is what stops
it, which is already recorded and already happens by reading, so there is
nothing to dismiss by hand. An answer changed after it was read is announced
again; a discarded question is not announced at all.

=cut
