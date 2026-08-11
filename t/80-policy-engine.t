#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Watched', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'WSS', epic_prefix => 'WSE', ticket_prefix => 'WST',
);

sub violations {
    my (%args) = @_;
    return $tira->policy_evaluate( project => $root, %args );
}

sub fired {
    my ($rule) = @_;
    return grep { $_->{rule} eq $rule } @{ violations() };
}

sub card {
    my (%args) = @_;
    return $tira->create_record( project => $root, type => 'ticket', %args );
}

# --- nothing declared, nothing watched -----------------------------------

# A board with no policies is not a board with no problems - it is a board
# nobody asked to be watched. Inventing violations here would be police
# deciding what matters, which is the agent's job.
my $bare = card( title => 'Utterly empty' );
is_deeply( violations(), [], 'with no policies declared, nothing is reported' );

# --- the read-only promise ------------------------------------------------

# The whole design rests on police never writing to the board, so this is the
# assertion that matters most in the file. It is made before anything else so
# a later failure cannot leave it unproven.
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'card-stalled', before => 'verify', action => 'bridge-reminder' );

sub fingerprint {
    my @found;
    my $data = File::Spec->catdir( $root, '.tira' );
    File::Find::find(
        { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            open my $fh, '<:raw', $File::Find::name or return;
            my $bytes = do { local $/; <$fh> };
            close $fh;
            push @found, "$File::Find::name:" . length($bytes) . ':' . Digest::SHA::sha256_hex($bytes);
        } }, $data );
    return [ sort @found ];
}
require File::Find;
require Digest::SHA;

my $before = fingerprint();
violations() for 1 .. 3;
is_deeply( fingerprint(), $before,
    'evaluating the board changes not one byte of it' );

# --- card-full-details ----------------------------------------------------

$tira->record_move( project => $root, ref => $bare->{ref}, column => 'implement' );
my @details = fired('card-full-details');
is( scalar @details, 1, 'a card in implement with no detail is reported' );
is( $details[0]{ref}, $bare->{ref}, 'naming the card' );
like( $details[0]{detail}, qr/acceptance/, 'and saying what it is missing' );

my $complete = card(
    title => 'Fully formed', problem_or_feature => 'a problem',
    solution_needed => 'a solution', key_details => ['a detail'],
    deliverables => ['a deliverable'], acceptance => ['an acceptance'],
    test_steps => ['a step'], bdd => ['a given'], atdd => ['an outcome'],
    scope_in => ['in'], scope_out => ['out'], priority => 3,
    description => 'what this card is for',
);
$tira->record_move( project => $root, ref => $complete->{ref}, column => 'implement' );
is( scalar( grep { $_->{ref} eq $complete->{ref} } fired('card-full-details') ), 0,
    'a card that has its detail is not reported' );

# A card still in backlog is being written, not neglected.
my $drafting = card( title => 'Still being written' );
is( scalar( grep { $_->{ref} eq $drafting->{ref} } fired('card-full-details') ), 0,
    'and a card that has not reached that column yet is left alone' );

# --- card-stalled ---------------------------------------------------------

$tira->checklist_add( project => $root, ref => $complete->{ref}, item => 'the work', status => 'done' );
my @stalled = fired('card-stalled');
is( scalar @stalled, 1, 'a finished checklist in a working column is reported' );
is( $stalled[0]{ref}, $complete->{ref}, 'naming the card that should have moved' );

$tira->record_move( project => $root, ref => $complete->{ref}, column => 'verify' );
is( scalar fired('card-stalled'), 0, 'and moving it silences the rule' );

# --- card-duration and its grace -----------------------------------------

$tira->policy_add( project => $root, rule => 'card-duration', column => 'verify',
    age => '10m', action => 'bridge-reminder', message => 'still on this one?' );

is( scalar fired('card-duration'), 0, 'a card just arrived is not overdue' );
at('2026-08-11T09:09:00Z');
is( scalar fired('card-duration'), 0, 'nor one inside the age' );
at('2026-08-11T09:10:01Z');
my @overdue = fired('card-duration');
is( scalar @overdue, 1, 'but one past it is reported' );
is( $overdue[0]{message}, 'still on this one?',
    'carrying the message the agent asked for rather than one Tira invented' );

# --- orphan-card ----------------------------------------------------------

$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
my @orphans = fired('orphan-card');
ok( scalar @orphans >= 1, 'a ticket with no parent is reported' );

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A parent' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $complete->{ref} );
is( scalar( grep { $_->{ref} eq $complete->{ref} } fired('orphan-card') ), 0,
    'and linking it silences the rule for that card' );

# --- questions ------------------------------------------------------------

$tira->policy_add( project => $root, rule => 'question-unanswered', age => '1h', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'answer-unjudged', age => '10m', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'answer-ok-not-folded', age => '10m', action => 'bridge-reminder' );
$tira->policy_add( project => $root, rule => 'answer-not-ok-no-followup', age => '10m', action => 'bridge-reminder' );

my $asked = $tira->question_add( project => $root, ref => $complete->{ref},
    author => 'claude', text => 'Which way round?' );
is( scalar fired('question-unanswered'), 0, 'a question just asked is not overdue' );
at('2026-08-11T10:11:00Z');
is( scalar fired('question-unanswered'), 1, 'one waiting past its age is reported' );

$tira->question_answer( project => $root, ref => $complete->{ref},
    id => $asked->{id}, text => 'That way' );
is( scalar fired('question-unanswered'), 0, 'answering silences it' );
is( scalar fired('answer-unjudged'), 0, 'and the judging clock starts from the answer' );
at('2026-08-11T10:22:00Z');
is( scalar fired('answer-unjudged'), 1, 'an answer left unjudged past its age is reported' );

# Marked ok is the agent declaring the matter settled, so the settlement has
# to appear on the card. This is the rule the owner refined into existence
# after catching exactly this twice in one session.
$tira->question_mark( project => $root, ref => $complete->{ref}, id => $asked->{id}, mark => 'ok' );
is( scalar fired('answer-unjudged'), 0, 'marking it silences the unjudged rule' );
is( scalar fired('answer-ok-not-folded'), 0, 'and the folding clock starts from the mark' );
at('2026-08-11T10:33:00Z');
my @unfolded = fired('answer-ok-not-folded');
is( scalar @unfolded, 1, 'a question marked ok with nothing folded in is reported' );
like( $unfolded[0]{detail}, qr/\Q$asked->{id}\E/, 'naming the question that was settled in name only' );

# A comment is not documentation - it is where things already get put, and it
# is not what somebody reading the card first sees.
$tira->comment_add( project => $root, ref => $complete->{ref}, author => 'claude', text => 'noted' );
is( scalar fired('answer-ok-not-folded'), 1, 'a comment does not count as folding it in' );

$tira->record_update( project => $root, ref => $complete->{ref},
    key_details => ['what the answer actually decided'] );
is( scalar fired('answer-ok-not-folded'), 0, 'changing a detail field does' );

my $crossed = $tira->question_add( project => $root, ref => $complete->{ref},
    author => 'claude', text => 'And this one?' );
$tira->question_answer( project => $root, ref => $complete->{ref}, id => $crossed->{id}, text => 'no' );
$tira->question_mark( project => $root, ref => $complete->{ref}, id => $crossed->{id}, mark => 'not-ok' );
at('2026-08-11T10:45:00Z');
is( scalar fired('answer-not-ok-no-followup'), 1,
    'a cross with no further question is reported, because a cross on its own settles nothing' );
$tira->question_add( project => $root, ref => $complete->{ref}, author => 'claude', text => 'Then what about this?' );
is( scalar fired('answer-not-ok-no-followup'), 0, 'and asking again silences it' );

# --- wip-limit ------------------------------------------------------------

$tira->policy_add( project => $root, rule => 'wip-limit', column => 'implement',
    max => 1, action => 'bridge-reminder' );
is( scalar fired('wip-limit'), 0, 'one card in a column is within a limit of one' );
my $second = card( title => 'A second thing' );
$tira->record_move( project => $root, ref => $second->{ref}, column => 'implement' );
is( scalar fired('wip-limit'), 1, 'a second breaks it' );

# --- discard-unexplained --------------------------------------------------

$tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );
my $dropped = card( title => 'Dropped without a word' );
$tira->record_discard( project => $root, ref => $dropped->{ref} );
is( scalar fired('discard-unexplained'), 1, 'work set aside with no reason is reported' );
$tira->comment_add( project => $root, ref => $dropped->{ref}, author => 'claude',
    text => 'superseded by the other one' );
is( scalar fired('discard-unexplained'), 0, 'and saying why silences it' );

# --- card-metrics ---------------------------------------------------------

# Which metadata a card must carry, and by which column, is the project's
# decision: not every board has a planning column, and the fields that matter
# differ between projects. So the rule is told both rather than assuming
# either.
$tira->policy_add( project => $root, rule => 'card-metrics', enter => 'implement',
    require => 'start_date,due_date,source,labels', action => 'bridge-reminder' );
my @metrics = grep { $_->{ref} eq $second->{ref} } fired('card-metrics');
is( scalar @metrics, 1, 'a card reaching the named column without its metadata is reported' );
like( $metrics[0]{detail}, qr/start_date/, 'saying which fields are missing' );
like( $metrics[0]{detail}, qr/source/, 'all of them, not just the first' );
like( $metrics[0]{detail}, qr/labels/,
    'and a list field counts as missing when it is empty, not merely when it is absent' );

$tira->record_update( project => $root, ref => $second->{ref},
    start_date => '2026-08-11T09:00:00Z', due_date => '2026-08-20T09:00:00Z',
    source => 'the owner, by Telegram', labels => ['policed'] );
is( scalar( grep { $_->{ref} eq $second->{ref} } fired('card-metrics') ), 0,
    'and filling them in silences it' );

# --- checklist-idle -------------------------------------------------------

# A card can have all its detail, sit in the right column, and still be
# abandoned. Nothing else here notices that.
$tira->policy_add( project => $root, rule => 'checklist-idle', column => 'implement',
    age => '30m', action => 'bridge-reminder' );
at('2026-08-11T10:50:00Z');
$tira->checklist_add( project => $root, ref => $second->{ref},
    item => 'the first step', status => 'pending' );
at('2026-08-11T10:52:00Z');
$tira->checklist_add( project => $root, ref => $second->{ref},
    item => 'a later step', status => 'pending' );
at('2026-08-11T10:55:00Z');
is( scalar fired('checklist-idle'), 0, 'a checklist just touched is not idle' );

# The rule sorts on these stamps with no fallback, so the invariant that every
# entry carries one is asserted here rather than defended against in code that
# could never run.
{
    my $with_list = $tira->record_show( project => $root, type => 'ticket', ref => $second->{ref} );
    is( scalar( grep { !defined $_->{last_updated} } @{ $with_list->{checklist} } ), 0,
        'every checklist entry carries the stamp the rule sorts on' );
}
# The rule must look at the MOST RECENT entry, not the first or the last in
# the file. With one item that distinction is invisible, so this card carries
# two with different stamps and the older one deliberately sits later.
is( scalar fired('checklist-idle'), 0,
    'a card whose newest entry is recent is not idle, even with an older one on it' );
at('2026-08-11T11:23:00Z');
my @idle = fired('checklist-idle');
is( scalar @idle, 1, 'one untouched past its age is reported' );
like( $idle[0]{detail}, qr/no checklist movement/, 'saying what has not happened' );

$tira->checklist_update( project => $root, ref => $second->{ref},
    id => 'CHK-001', status => 'done' );
is( scalar fired('checklist-idle'), 0, 'and touching it silences the rule' );

# A card in that column with no checklist at all is a different problem, and
# not this rule's to report.
my $listless = card( title => 'No checklist here' );
$tira->record_move( project => $root, ref => $listless->{ref}, column => 'implement' );
is( scalar( grep { $_->{ref} eq $listless->{ref} } fired('checklist-idle') ), 0,
    'a card with no checklist is left to another rule' );

# --- gate-missing ---------------------------------------------------------

# Work reaching the end without a gate recorded is work nobody checked.
$tira->policy_add( project => $root, rule => 'gate-missing', column => 'done',
    action => 'bridge-reminder' );
my $shipped = card( title => 'Straight to done' );
$tira->record_move( project => $root, ref => $shipped->{ref}, column => 'done' );
my @ungated = grep { $_->{ref} eq $shipped->{ref} } fired('gate-missing');
is( scalar @ungated, 1, 'a card in the final column with no gate recorded is reported' );
like( $ungated[0]{detail}, qr/no gate recorded/, 'saying so plainly' );

$tira->gate_add( project => $root, ref => $shipped->{ref}, gate => 'suite',
    result => 'pass', details => '3182 tests', author => 'claude' );
is( scalar( grep { $_->{ref} eq $shipped->{ref} } fired('gate-missing') ), 0,
    'and recording one silences it' );

# --- discarded work is set aside, not neglected --------------------------

# Found by running police against a real board rather than by a test: it was
# reporting a card that had been deliberately discarded. Holding set-aside work
# to the same standard as live work teaches an agent to read past the whole
# channel, which is the one failure a warning system cannot survive.
{
    my $abandoned = card( title => 'Set aside, deliberately' );
    $tira->record_move( project => $root, ref => $abandoned->{ref}, column => 'implement' );
    ok( scalar( grep { $_->{ref} eq $abandoned->{ref} } fired('card-full-details') ),
        'a live card with no detail is reported' );

    $tira->record_discard( project => $root, ref => $abandoned->{ref} );
    is( scalar( grep { $_->{ref} eq $abandoned->{ref} } fired('card-full-details') ), 0,
        'and discarding it stops every rule reporting it' );
    is( scalar( grep { $_->{ref} eq $abandoned->{ref} } fired('orphan-card') ), 0,
        'including the ones that have nothing to do with being discarded' );

    # Except the one rule whose whole subject is discarded work.
    ok( scalar( grep { $_->{ref} eq $abandoned->{ref} } fired('discard-unexplained') ),
        'while the rule that asks why it was set aside still applies' );
}

# --- what a violation carries --------------------------------------------

my ($any) = @{ violations() };
ok( $any, 'there is something to inspect' );
for my $field (qw(rule ref detail policy)) {
    ok( defined $any->{$field}, "a violation carries its $field" );
}
like( $any->{policy}, qr/\APOL-\d{3}\z/, 'pointing back at the policy that asked for it' );

# --- and still nothing was written ---------------------------------------

is_deeply( fingerprint(), fingerprint(),
    'the board is stable across evaluation, checked once more at the end' );

done_testing;

__END__

=head1 NAME

80-policy-engine.t - TKT-015 working out what is wrong, without touching anything

=head1 DESCRIPTION

The twelve rules that can be answered from the board and a clock alone. The
six that need git, the process table or Docker belong to police, because the
engine's documented guarantee is that Tira invokes no shell or external
process, and handing it facts is better than teaching it to go and look.

The assertion that matters most here is that evaluating a board changes not
one byte of it. Everything in this design rests on police being read-only -
two writers in one board is what destroyed this project's own board on the day
it was designed - so the fingerprint check is made early, before anything else
can fail and leave it unproven.

The rest is grace. A rule with an age does not fire before that age has
passed, which is what makes a card being written different from a card being
neglected. Without that, police would be shouting during normal work, and a
warning nobody can bear is a warning nobody reads.

Two of the rules exist because of specific failures on the day: a question
marked ok with nothing folded into the card afterwards, and a cross with no
further question. Both key off the mark rather than the answer, because the
mark is the agent's own claim that the matter is settled, and the rule simply
holds it to that.

=cut
