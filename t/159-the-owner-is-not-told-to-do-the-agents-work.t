#!/usr/bin/env perl
# An answer's follow-through is addressed to whoever asked, not whoever answered.
#
# He read two lines off his own bridge:
#
#   NOTE    | for Michael | VIO-0018 | M5T-320 | seen 1 | Q-017 was marked ok
#             and nothing was folded into the card
#   WARNING | for Michael | VIO-0018 | M5T-320 | seen 2 | ...
#
# and asked: "why fold in for the user? it is the agent job."
#
# He is right. Every rule is addressed to whoever holds the card, which is
# correct for the rest of them - one agent per ticket, and a bridge that hands
# every agent every violation is noise by construction. But the four rules about
# what happens after an answer are not about the card, they are about the
# agent's follow-through: reading the answer, judging it, writing it into the
# card, asking anything further. The owner's part ends when he answers.
#
# So on a board where the owner holds the card, he was being told to fold in his
# own answer, and told again more loudly on the second pass.
#
# Nothing has to be inferred to fix it. A question stores the author who asked
# it and the answer stores its own author separately, so the asker is already on
# the card.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-14T12:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Whose work', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WWS', epic_prefix => 'WWE', ticket_prefix => 'WWT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# The shape he was looking at: the agent asks, the owner answers, and the owner
# holds the card.
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something the owner decided', assignee => 'michael' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    author => 'ada', text => 'Which way should this go?' );

sub violations_for {
    my ($rule) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq $rule } @{ $pass->{violations} } ];
}

# --- an answer nobody has read ----------------------------------------------------

$tira->policy_add( project => $root, rule => 'answer-waiting', action => 'bridge-reminder' );
$now = '2026-08-14T12:05:00Z';
$tira->question_answer( project => $root, ref => $card->{ref}, id => $question->{id},
    author => 'michael', text => 'Go the second way.' );

$now = '2026-08-14T12:10:00Z';
my $waiting = violations_for('answer-waiting');
is( scalar @{$waiting}, 1, 'an answer the agent has not read is reported' );
is( $waiting->[0]{assignee}, 'ada',
    'and addressed to the agent that asked, not the owner who answered and holds the card' );

# --- an answer read and not judged --------------------------------------------------

$tira->policy_add( project => $root, rule => 'answer-unjudged', age => '1m', action => 'bridge-reminder' );
$now = '2026-08-14T12:11:00Z';
$tira->question_list( project => $root, ref => $card->{ref} );   # reading is what records a read
$now = '2026-08-14T12:30:00Z';
my $unjudged = violations_for('answer-unjudged');
is( scalar @{$unjudged}, 1, 'an answer read and not judged is reported' );
is( $unjudged->[0]{assignee}, 'ada', 'and addressed to whoever asked' );

# --- the line he actually read ---------------------------------------------------------

$tira->policy_add( project => $root, rule => 'answer-ok-not-folded', age => '1m', action => 'bridge-reminder' );
$now = '2026-08-14T12:31:00Z';
$tira->question_mark( project => $root, ref => $card->{ref}, id => $question->{id}, mark => 'ok' );
$now = '2026-08-14T13:00:00Z';
my $folded = violations_for('answer-ok-not-folded');
is( scalar @{$folded}, 1, 'an answer marked ok with nothing written down is reported' );
is( $folded->[0]{assignee}, 'ada',
    'and addressed to the agent whose job the folding is, which is the whole of his complaint' );

# --- and the fourth of them ---------------------------------------------------------------

my $second = $tira->create_record( project => $root, type => 'ticket',
    title => 'Another decision', assignee => 'michael' );
$tira->record_move( project => $root, ref => $second->{ref}, column => 'implement' );
my $crossed = $tira->question_add( project => $root, ref => $second->{ref},
    author => 'ada', text => 'And this one?' );
$now = '2026-08-14T13:01:00Z';
$tira->question_answer( project => $root, ref => $second->{ref}, id => $crossed->{id},
    author => 'michael', text => 'No, not like that.' );
$tira->question_mark( project => $root, ref => $second->{ref}, id => $crossed->{id}, mark => 'not-ok' );
$tira->policy_add( project => $root, rule => 'answer-not-ok-no-followup', age => '1m',
    action => 'bridge-reminder' );
$now = '2026-08-14T13:30:00Z';
my $followup = violations_for('answer-not-ok-no-followup');
is( scalar @{$followup}, 1, 'an answer marked not-ok with nothing asked after it is reported' );
is( $followup->[0]{assignee}, 'ada', 'and addressed to whoever asked the first one' );

# --- while every other rule is still the card holder's -------------------------------------
#
# The model this is an exception to, and it must stay true: one agent per
# ticket, so a violation about a card belongs to whoever is carrying it.

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $bare = violations_for('card-full-details');
ok( scalar @{$bare}, 'a rule about the card itself still reports' );
is( $bare->[0]{assignee}, 'michael',
    'and is still addressed to whoever holds the card, which is right for every other rule' );

# --- and a question nobody signed goes to the card holder ------------------------------------
#
# An older card may carry a question with no author. Addressing that to nobody
# would be worse than addressing it to the card, so it falls back.

my $third = $tira->create_record( project => $root, type => 'ticket',
    title => 'An unsigned question', assignee => 'michael' );
$tira->record_move( project => $root, ref => $third->{ref}, column => 'implement' );
my $unsigned = $tira->question_add( project => $root, ref => $third->{ref},
    text => 'Who asked this?' );
$now = '2026-08-14T13:31:00Z';
$tira->question_answer( project => $root, ref => $third->{ref}, id => $unsigned->{id},
    author => 'michael', text => 'Nobody knows.' );
$now = '2026-08-14T13:35:00Z';
my ($fallback) = grep { $_->{ref} eq $third->{ref} } @{ violations_for('answer-waiting') };
ok( $fallback, 'a question with nobody named on it is still reported' );
is( $fallback->{assignee}, 'michael',
    'and falls back to whoever holds the card rather than being addressed to nobody' );

done_testing;

__END__

=head1 NAME

159-the-owner-is-not-told-to-do-the-agents-work.t - answer rules go to whoever asked

=head1 DESCRIPTION

Every violation was addressed to whoever holds the card. That is right for the
rest of them, and wrong for the four rules about what happens after an answer:
reading it, judging it, folding it into the card and asking anything further are
the agent's work, and the owner's part ends when he answers. On a board where he
held the card he was told to fold in his own answer, and told again more loudly
on the second pass.

Those four are now addressed to the author of the question. Nothing is inferred:
a question stores who asked and an answer stores who answered, separately. A
question with nobody named on it falls back to the card holder, and every other
rule is unchanged.

=cut
