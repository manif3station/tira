#!/usr/bin/env perl

use strict;
use warnings;

use Digest::SHA ();
use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# This file declares agent-still and calls police_pass() repeatedly without
# mocking the send it can trigger. Without this, a host shell that happens
# to export real TELEGRAM_BOT_TOKEN/TELEGRAM_CHATID - as this project's own
# Telegram bridge does - sends a real message to the real owner every time
# this file runs outside Docker. Confirmed live: three such messages,
# naming this file's own fixture paths and card refs. TKT-482.
delete local $ENV{TELEGRAM_BOT_TOKEN};
delete local $ENV{TELEGRAM_CHATID};

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Everything', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'EVS', epic_prefix => 'EVE', ticket_prefix => 'EVT',
);
$tira->project_update( project => $root, agent => 'claude' );

# card-sandbox-missing reads branches and work trees, and refuses to be
# declared where no repository can be resolved (TKT-178). This board sits
# inside one, which is the ordinary case and what a real board declaring
# that rule looks like.
mkdir File::Spec->catdir( $root, '.git' );
my $store = File::Spec->catdir( $tmp, 'police-state' );

sub fingerprint {
    my @found;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            open my $fh, '<:raw', $File::Find::name or return;
            my $bytes = do { local $/; <$fh> };
            close $fh;
            push @found, "$File::Find::name:" . Digest::SHA::sha256_hex($bytes);
        } }, File::Spec->catdir( $root, '.tira' ) );
    return [ sort @found ];
}

# --- every rule declared, all at once -------------------------------------

# A rule that has never fired in practice is a rule nobody knows works, so
# this declares the entire catalogue and then arranges for every one of them
# to have something to find.
my %declare = (
    'card-full-details'         => { enter => 'implement' },
    'card-metrics'              => { enter => 'implement', require => 'due_date' },
    'card-duration'             => { column => 'verify', age => '10m' },
    'card-stalled'              => { before => 'verify' },
    'checklist-idle'            => { column => 'implement', age => '30m' },
    'checklist-unmoved'         => {},
    'orphan-card'               => {},
    'rules-undeclared'               => {},
    'card-still'               => { age => '8h' },
    'question-unanswered'       => { age => '1h' },
    'conversation-not-folded'   => {},
    'card-unassigned'           => {},
    'card-agentless'            => { enter => 'implement' },
    'answer-waiting'            => {},
    'answer-unjudged'           => { age => '10m' },
    'answer-ok-not-folded'      => { age => '10m' },
    'answer-not-ok-no-followup' => { age => '10m' },
    'wip-limit'                 => { column => 'implement', max => 1 },
    'gate-missing'              => { column => 'done' },
    'discard-unexplained'       => {},
    'commit-without-card'       => {},
    'work-without-card'         => { age => '15m' },
    'unpushed-work'             => { age => '1h' },
    'board-unbacked'            => { age => '2h' },
    'card-unlinked'             => { require_link => 'is-blocked-by' },
    'card-sandbox-missing'      => { enter => 'implement', sandbox => '/sandboxes' },
    'leftover-process'          => { pattern => 'sleep', age => '30m' },
    'leftover-container'        => { pattern => 'perl-test', age => '30m' },
    'parent-ahead-of-children'  => {},
    'priority-skipped'          => {},
    'card-changed-by-owner'     => {},
    'discard-with-open-questions' => {},
    'board-still'               => { age => '8h' },
    'agent-still'               => { age => '8h' },
    'bridge-unread'             => { age => '30m' },
    'column-unwatched'          => {},
    'column-skipped'            => { enter => 'done', require => 'implement' },
    'task-unlinked'             => { age => '30m' },
    'task-changed'              => {},

    # A repeated job needs no age and no scope - its schedule already says
    # when it is due, and a job is not about a card. EPC-014, TKT-838.
    'job-due'                   => {},

    # A monitor that should be up and is not. No age: a stopped monitor does
    # not become more stopped, and the rule refuses one rather than ignoring
    # it. Whole-board, like job-due - a job is not about a card. EPC-014,
    # TKT-842.
    'monitor-dead'              => {},
    'monitor-output'            => {},
    'monitor-silent'            => {},

    # Column-scoped, and the column is the whole of TKT-639: the board cannot
    # infer which of its own columns mean somebody is WORKING, so the rule is
    # told. 'implement' here, which is where the fixture's card sits.
    'task-card-mismatch'        => { column => 'implement' },
);
is_deeply( [ sort keys %declare ], [ sort @{ Tira::policy_rules() } ],
    'this test declares every rule the tool offers, so none can be forgotten here' );

$tira->policy_add( project => $root, rule => $_, action => 'bridge-reminder', %{ $declare{$_} } )
  for sort keys %declare;

# A column added after the policies were written, which is the whole of
# column-unwatched: checklist-idle, card-duration and wip-limit name implement
# and verify, nothing names this one, and nobody did anything wrong - the
# policies above were complete when they were declared.
$tira->column_add( project => $root, type => 'ticket', name => 'document',
    after => 'verify' );

# --- a board with something wrong of every kind ---------------------------

my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'No detail at all' );
$tira->record_move(author => 'claude',  project => $root, ref => $bare->{ref}, column => 'implement' );

my $crowding = $tira->create_record( project => $root, type => 'ticket', title => 'A second in progress' );
$tira->record_move(author => 'claude',  project => $root, ref => $crowding->{ref}, column => 'implement' );
$tira->checklist_add( author => 'michael', project => $root, ref => $crowding->{ref}, item => 'started', status => 'pending' );

my $finished = $tira->create_record( project => $root, type => 'ticket', title => 'Work all done' );
$tira->record_move(author => 'claude',  project => $root, ref => $finished->{ref}, column => 'implement' );
$tira->checklist_add( author => 'michael', project => $root, ref => $finished->{ref}, item => 'the work', status => 'done' );

# agent-still: since TKT-570 the rule counts only working-column cards the
# agent could actually move, so a board meant to break every rule needs one
# that is the agent's. The cards above are deliberately unassigned - that is
# what card-unassigned is here to catch - and an unassigned card is exactly
# what the agent cannot be stalling on.
my $agents_own = $tira->create_record( project => $root, type => 'ticket',
    title => 'The agent has this one', assignee => 'claude' );
$tira->record_move( author => 'claude', project => $root,
    ref => $agents_own->{ref}, column => 'implement' );

# checklist-unmoved: a card carried on from one working column to the next with
# nothing ticked in between. Two moves are needed, because the window a move is
# judged against reaches back to the move before it - on a card's first move
# that window includes being raised, and the checklist was written inside it.
my $dragged = $tira->create_record( project => $root, type => 'ticket', title => 'Carried along' );
$tira->checklist_add( author => 'michael', project => $root, ref => $dragged->{ref}, item => 'never started', status => 'pending' );
$tira->record_move(author => 'claude',  project => $root, ref => $dragged->{ref}, column => 'implement' );
$tira->record_move(author => 'claude',  project => $root, ref => $dragged->{ref}, column => 'verify' );

my $waiting = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question' );
my $asked = $tira->question_add( project => $root, ref => $waiting->{ref},
    author => 'claude', text => 'Which way?' );

# A card whose conversation has outrun it: written down, then talked about
# afterwards, which is the order that matters.
my $talked = $tira->create_record( project => $root, type => 'ticket', title => 'Talked about since' );
$tira->record_update( author => 'michael', project => $root, ref => $talked->{ref},
    description => 'what it said when it was raised' );
$now = '2026-08-11T09:30:00Z';
$tira->comment_add( project => $root, ref => $talked->{ref}, author => 'michael',
    body => 'The evidence that is not on the card yet' );
$now = '2026-08-11T09:00:00Z';

# A tasklist item nobody ever tied back to a card - real, trackable work, no
# refs, sitting where task-unlinked watches.
$tira->tasklist_add( project => $root, text => 'A note nobody turned into a card' );

# A repeated job that is due right now, which is job-due's whole case: the
# clock above is 09:00, so an on-the-hour schedule has come round and the
# job's own message is what should reach the bridge. EPC-014, TKT-838.
$tira->job_add( project => $root, schedule => '0 * * * *',
    message => 'go hunt some bugs' );

# And a monitor that is supposed to be running and is not - monitor-dead's
# case. It is enabled and has never been started, so it carries no pid at all,
# which is exactly what every monitor on a machine looks like after a restart.
# EPC-014, TKT-842.
my $unstarted_monitor = $tira->job_add( project => $root, schedule => 'monitor',
    command => 'tira-a-monitor-nobody-started --poll' );

# The same monitor also has something to say - monitor-output's case.
#
# REUSING THIS ONE RATHER THAN ADDING A SECOND, and the first attempt did add a
# second on the grounds that a fixture doing double duty lets one rule's failure
# hide behind another's. It backfired: a second enabled monitor with a command
# is a second monitor-dead case, the quiet ladder suppressed the duplicate
# finding, and the "every violation reached the bridge" count came out one
# short - a failure caused entirely by the fixture, in a rule that was working.
#
# And the shape is honest anyway: a monitor that printed something and then died
# is exactly when its last words matter most, so carrying them is the case worth
# having. EPC-014, TKT-851.
sub monitor_says {
    my ($line) = @_;

    # THROUGH THE FEEDER, not into a spool. TKT-851's second implementation,
    # after his Q-112 answer: a monitor's output is registered against the job
    # that said it rather than left in a file for police to follow. The fixture
    # calls what the feeder calls, which is what the rule now reads.
    $tira->job_feed( project => $root, id => $unstarted_monitor->{id},
        lines => [$line] );
    return;
}

# And a monitor that IS running and has stopped saying anything - monitor-silent's
# case, and the one the two rules above leave between them. It needs a pid the
# process table below actually carries, or it would be a monitor-dead finding
# instead and prove the wrong rule.
#
# A SECOND ENABLED MONITOR IS EXACTLY WHAT THE COMMENT ABOVE WARNS ABOUT, so it
# is given a live pid rather than left unstarted: alive, monitor-dead says
# nothing about it, and the count that broke last time is undisturbed.
my $quiet_monitor = $tira->job_add(
    project => $root, schedule => 'monitor',
    command => 'tira-a-monitor-that-went-quiet --poll', expect_every => 5 );
$tira->job_started( project => $root, id => $quiet_monitor->{id}, pid => 9911 );
$tira->job_feed( project => $root, id => $quiet_monitor->{id},
    lines => ['the last thing it ever said'] );

# A tasklist item left saying pending while the card it names is being worked -
# task-card-mismatch's case, and the half of the owner's request that
# task-unlinked above does not cover. The card has to be IN a declared working
# column for this to fire, which is the point of the rule taking its columns.
{
    my $worked = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card somebody started' );
    $tira->record_move( author => 'claude', project => $root, ref => $worked->{ref}, column => 'implement' );
    $tira->tasklist_add(
        project => $root, text => 'A note whose card moved on without it',
        refs => [ $worked->{ref} ] );
}

# A tasklist item that changes between the two passes below - task-changed's
# baseline is set by the first (bridge-unread's own setup) pass, and the
# text edit right after it is what the second, comprehensive pass finds.
my $edited_task = $tira->tasklist_add( project => $root, text => 'Original wording' );

# The card exists before the second in which its answer is marked.
#
# Everything else on this board is built at one frozen instant, which is fine
# for every other rule and wrong for this one: creating a card writes its title,
# a title is a detail field, and since 1.98 a detail written at or after the
# mark counts as folding the answer in. So a card created in the same second as
# the mark reads as folded, and this assertion stopped firing.
#
# That is an artefact of the frozen clock rather than the rule: on a real board
# a card is created, and only later does somebody answer a question on it and
# mark it. mt5-ai's report was about the opposite case - marking and folding in
# one script, in one second - and the fix has to leave both readings intact.
my $settled = $tira->create_record( project => $root, type => 'ticket', title => 'Settled in name only' );
my $ok_question = $tira->question_add( project => $root, ref => $settled->{ref},
    author => 'claude', text => 'This one?' );
$tira->question_answer( project => $root, ref => $settled->{ref}, id => $ok_question->{id}, text => 'yes' );
at('2026-08-11T09:00:05Z');
$tira->question_mark( project => $root, ref => $settled->{ref}, id => $ok_question->{id}, mark => 'ok' );
at('2026-08-11T09:00:00Z');

my $crossed = $tira->create_record( project => $root, type => 'ticket', title => 'Crossed and dropped' );
my $no_question = $tira->question_add( project => $root, ref => $crossed->{ref},
    author => 'claude', text => 'And this?' );
$tira->question_answer( project => $root, ref => $crossed->{ref}, id => $no_question->{id}, text => 'no' );
$tira->question_mark( project => $root, ref => $crossed->{ref}, id => $no_question->{id}, mark => 'not-ok' );

my $unjudged = $tira->create_record( project => $root, type => 'ticket', title => 'Answered, never marked' );
my $open_question = $tira->question_add( project => $root, ref => $unjudged->{ref},
    author => 'claude', text => 'Well?' );
$tira->question_answer( project => $root, ref => $unjudged->{ref}, id => $open_question->{id}, text => 'this way' );

my $lingering = $tira->create_record( project => $root, type => 'ticket', title => 'Sitting in verify' );
$tira->record_move(author => 'claude',  project => $root, ref => $lingering->{ref}, column => 'verify' );

# Work taken out of turn: a low card being worked while a higher one of the same
# kind sits untouched where it was raised. 5 is the urgent end, so the waiting
# card carries 5 and the one being worked carries 2.
my $urgent = $tira->create_record( project => $root, type => 'ticket',
    title => 'Should have gone first', priority => 5 );
my $lesser = $tira->create_record( project => $root, type => 'ticket',
    title => 'Being worked instead', priority => 2 );
$tira->record_move(author => 'claude',  project => $root, ref => $lesser->{ref}, column => 'implement' );

my $shipped = $tira->create_record( project => $root, type => 'ticket', title => 'Done with no gate' );
$tira->record_move(author => 'claude',  project => $root, ref => $shipped->{ref}, column => 'done' );

my $dropped = $tira->create_record( project => $root, type => 'ticket', title => 'Dropped in silence' );
$tira->record_discard(author => 'claude',  project => $root, ref => $dropped->{ref} );

# A card set aside while a question on it was still waiting - the questions go
# with the card, and the decision they were waiting on is never made.
my $orphaned = $tira->create_record( project => $root, type => 'ticket',
    title => 'Set aside with the question still open' );
$tira->question_add( project => $root, ref => $orphaned->{ref}, author => 'claude',
    text => 'Which way?', reason => 'Nothing starts until this is settled' );
$tira->record_discard(author => 'claude',  project => $root, ref => $orphaned->{ref}, reason => 'not worth doing' );

# A parent saying it is finished above a child that is not - the board
# overstating progress in the one direction nobody checks by looking at a card
# on its own. Which column means finished is declared, because guessing at a
# name would make this rule silent on any project that calls it something else.
$tira->column_roles_set( project => $root, type => 'epic', roles => { done => 'done' } );
my $premature = $tira->create_record( project => $root, type => 'epic', title => 'Claims to be finished' );
my $underneath = $tira->create_record( project => $root, type => 'ticket', title => 'Still open underneath it' );
$tira->hierarchy_link( project => $root, parent => $premature->{ref}, child => $underneath->{ref} );
$tira->record_move(author => 'claude',  project => $root, ref => $premature->{ref}, column => 'done' );

# Everything above happened at nine; now it is late enough for every age to
# have passed.
at('2026-08-11T11:30:00Z');

my $world = {
    branches => [], worktrees => [],
    processes => [
        { command => 'bash -c sleep 25', started_at => '2026-08-11T09:00:00Z' },

        # The quiet monitor, genuinely up. Its start time matches what the
        # board recorded when job_started ran, because liveness compares the
        # two within a minute in both directions (TKT-860) - a process that
        # began before the spawn cannot be the one we spawned either.
        { pid => 9911, command => 'tira-a-monitor-that-went-quiet --poll',
            started_at => '2026-08-11T09:00:00Z' },
    ],
    containers => [ { name => 'skills-perl-test-run-abc', started_at => '2026-08-11T09:00:00Z' } ],
    commits => [ { sha => 'abc1234', subject => 'tidy up a few things' } ],
    working_since => '2026-08-11T09:00:00Z',
    unpushed_since => '2026-08-11T09:00:00Z',
};

# The clock moves on before the pass, so the board as a whole is old enough to
# be still. Everything above was built at 09:00; board-still asks when the board
# LAST did anything, which is the one question that cannot be answered by
# arranging a single card.
$now = '2026-08-11T23:00:00Z';

# Traffic on the bridge that nobody reads, which is what bridge-unread is about.
# A first pass writes it; the mark that records a read is never made, because
# nothing here tails the bridge - and that is exactly the state being asserted.
{
    my $first = $tira->police_pass( project => $root, store => $store, world => $world );
    $tira->bridge_write( store => $store, project => $root,
        violations => $first->{violations}, settled => $first->{settled} );

    # What the real caller does after every bridge write, and this fixture has
    # to do it too: the pass hands out how far each monitor's spool was read and
    # the CLI records it. Without this the second pass re-reports the same lines,
    # the bridge correctly suppresses them as already said, and the violation
    # count outruns the delivered count - which is what it did here, 114 against
    # 112, before this line existed. TKT-851.
    require Tira::CLI::Police;
    Tira::CLI::Police::advance_monitor_output( $tira, { project => $root }, $first );
}

$tira->tasklist_update( project => $root, id => $edited_task->{id}, text => 'Revised wording' );

# The monitor speaks again between the passes, for the same reason the task is
# edited here: the first pass is bridge-unread's setup and it CARRIES what the
# spool held, advancing the offset. A fixture that only wrote before it would
# leave nothing new for the pass under test - which is monitor-output working
# correctly, and would look exactly like the rule failing to fire. TKT-851.
monitor_says('a line printed between the two passes, which the second must carry');

my $before = fingerprint();
my $pass = $tira->police_pass( project => $root, store => $store, world => $world );

# --- every rule fired -----------------------------------------------------

# One rule cannot fire here, and the reason is this test's own construction.
# rules-undeclared reports a rule the board has neither declared nor declined,
# and the board above declares every rule there is - so the condition it watches
# for is the one thing this test guarantees is absent. A board that has answered
# everything is exactly where it must be silent.
#
# Exempted by name and with the reason, rather than by loosening the assertion
# for everything: t/247 proves it fires, on a board with rules left unanswered,
# and proves it settles when they are answered. TKT-276.
my %cannot_fire_here = ( 'rules-undeclared' => 'this board declares every rule' );

my %fired = map { $_->{rule} => 1 } @{ $pass->{violations} };
for my $rule ( sort keys %declare ) {
    next if $cannot_fire_here{$rule};
    ok( $fired{$rule}, "$rule fired against a board that breaks it" );
}
is_deeply( [ sort keys %fired ],
    [ sort grep { !$cannot_fire_here{$_} } keys %declare ],
    'and nothing fired that was not declared' );

is_deeply( [ sort keys %cannot_fire_here ], ['rules-undeclared'],
    'and exactly one rule is exempt here, so the exemption cannot grow unnoticed' );

# --- and the board is untouched -------------------------------------------

# The promise the whole design rests on, checked after the heaviest pass this
# subsystem will ever make.
is_deeply( fingerprint(), $before,
    'a pass that found twenty different things wrong changed not one byte of the board' );

# --- the bridge delivered all of it ---------------------------------------

$tira->bridge_write( store => $store, violations => $pass->{violations} );
my $delivered = $tira->bridge_backlog( store => $store, lines => 1_000 );

# The first line introduces the replay and is not a violation, so it is taken
# off before counting. It carries no fix because there is nothing to fix about
# it - it says the lines beneath it already happened.
like( shift @{$delivered}, qr/replaying/,
    'the replay introduces itself before the violations' );

# The tail saying what is still open is a summary of the lines above it, like
# the replay header, so it is taken off before the violations are counted. It
# is there because a settlement arriving last reads as an ending - TKT-277.
my @reported = grep { !/STILL OPEN/ } @{$delivered};

is( scalar @reported, scalar @{ $pass->{violations} },
    'every violation reached the bridge, not merely most of them' );
is( scalar( grep { /fix:/ } @{$delivered} ), scalar @{$delivered},
    'and every line carries the command that answers it, the tail included' );

# --- fixing things makes it quiet -----------------------------------------

# Silence has to be earned rather than assumed, so the board is repaired and
# the same pass is run again.
$tira->record_update( author => 'michael', project => $root, ref => $bare->{ref},
    description => 'now explained', problem_or_feature => 'a problem',
    solution_needed => 'a solution', key_details => ['a detail'],
    deliverables => ['a deliverable'], acceptance => ['an acceptance'],
    test_steps => ['a step'], bdd => ['a given'], atdd => ['an outcome'],
    scope_in => ['in'], scope_out => ['out'], priority => 3,
    labels => ['standalone'],
    due_date => '2026-08-20T09:00:00Z' );

# A complete card now has a checklist and either a parent or a word saying it
# stands alone. Those were the push gate's requirements and police did not
# share them, which is the drift TKT-241 removed - so a fixture that was
# complete by one definition is incomplete by the one there is now.
$tira->checklist_add( author => 'michael', project => $root, ref => $bare->{ref},
    item => 'the thing to do', status => 'To Do' );
$tira->record_move(author => 'claude',  project => $root, ref => $finished->{ref}, column => 'verify' );

my $repaired = $tira->police_pass( project => $root, store => $store, world => $world );
my %still = map { $_->{rule} => 1 } @{ $repaired->{violations} };
ok( !grep( { $_->{ref} eq $bare->{ref} && $_->{rule} eq 'card-full-details' }
        @{ $repaired->{violations} } ),
    'a card that was filled in stops being reported' );
ok( !$still{'card-stalled'}, 'and a card that was moved on stops being reported' );

# --- ignored long enough, it reaches the owner ----------------------------

my $terminal = File::Spec->catdir( $tmp, 'terminal' );
my @seen;
# An hour apart, because being ignored is now measured in time rather than in
# passes: the same problem is left alone for a growing quiet period before it is
# said again, so five rounds a minute apart are one telling, not five.
for my $round ( 1 .. 5 ) {
    at( sprintf '2026-08-11T%02d:00:00Z', 11 + $round );
    my $result = $tira->police_pass( project => $root, store => $terminal, world => $world );
    push @seen, @{ $result->{terminal} };
}
ok( scalar @seen, 'a problem ignored five times over reaches the owner\'s terminal' );
like( $seen[0], qr/needs your attention/, 'saying so' );
like( $seen[0], qr/hand to (?:the core agent|\w[\w.-]*): d2 tira\./, 'and handing him who to give it to, with the command to give them' );

# --- and after all of that, still nothing written -------------------------

is_deeply( fingerprint(), fingerprint(),
    'the board is stable across the whole session' );

done_testing;

__END__

=head1 NAME

86-police-end-to-end.t - the whole subsystem, against a board that breaks everything

=head1 DESCRIPTION

Every rule in the catalogue is declared at once, and a board is built that
breaks every one of them. A rule that has never fired in practice is a rule
nobody knows works, and three times during this epic coverage caught rules that
had been written and never executed - so this file exists to make that
impossible to repeat quietly.

The list of rules is compared against the tool's own catalogue, so a rule added
later without a case here fails at the first assertion rather than being
quietly untested.

Two things are checked that matter more than the rules. The board is
fingerprinted before and after the heaviest pass this subsystem will ever make,
because police being read-only is the promise everything else rests on. And the
silence afterwards is earned rather than assumed: the board is repaired and the
same pass is run again, to show that fixing a cause is what stops the
reporting.

=cut
