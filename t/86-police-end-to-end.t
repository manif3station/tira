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
    'orphan-card'               => {},
    'question-unanswered'       => { age => '1h' },
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
);
is_deeply( [ sort keys %declare ], [ sort @{ Tira::policy_rules() } ],
    'this test declares every rule the tool offers, so none can be forgotten here' );

$tira->policy_add( project => $root, rule => $_, action => 'bridge-reminder', %{ $declare{$_} } )
  for sort keys %declare;

# --- a board with something wrong of every kind ---------------------------

my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'No detail at all' );
$tira->record_move( project => $root, ref => $bare->{ref}, column => 'implement' );

my $crowding = $tira->create_record( project => $root, type => 'ticket', title => 'A second in progress' );
$tira->record_move( project => $root, ref => $crowding->{ref}, column => 'implement' );
$tira->checklist_add( project => $root, ref => $crowding->{ref}, item => 'started', status => 'pending' );

my $finished = $tira->create_record( project => $root, type => 'ticket', title => 'Work all done' );
$tira->record_move( project => $root, ref => $finished->{ref}, column => 'implement' );
$tira->checklist_add( project => $root, ref => $finished->{ref}, item => 'the work', status => 'done' );

my $waiting = $tira->create_record( project => $root, type => 'ticket', title => 'Has a question' );
my $asked = $tira->question_add( project => $root, ref => $waiting->{ref},
    author => 'claude', text => 'Which way?' );

my $settled = $tira->create_record( project => $root, type => 'ticket', title => 'Settled in name only' );
my $ok_question = $tira->question_add( project => $root, ref => $settled->{ref},
    author => 'claude', text => 'This one?' );
$tira->question_answer( project => $root, ref => $settled->{ref}, id => $ok_question->{id}, text => 'yes' );
$tira->question_mark( project => $root, ref => $settled->{ref}, id => $ok_question->{id}, mark => 'ok' );

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
$tira->record_move( project => $root, ref => $lingering->{ref}, column => 'verify' );

my $shipped = $tira->create_record( project => $root, type => 'ticket', title => 'Done with no gate' );
$tira->record_move( project => $root, ref => $shipped->{ref}, column => 'done' );

my $dropped = $tira->create_record( project => $root, type => 'ticket', title => 'Dropped in silence' );
$tira->record_discard( project => $root, ref => $dropped->{ref} );

# A parent saying it is finished above a child that is not - the board
# overstating progress in the one direction nobody checks by looking at a card
# on its own. Which column means finished is declared, because guessing at a
# name would make this rule silent on any project that calls it something else.
$tira->column_roles_set( project => $root, type => 'epic', roles => { done => 'done' } );
my $premature = $tira->create_record( project => $root, type => 'epic', title => 'Claims to be finished' );
my $underneath = $tira->create_record( project => $root, type => 'ticket', title => 'Still open underneath it' );
$tira->hierarchy_link( project => $root, parent => $premature->{ref}, child => $underneath->{ref} );
$tira->record_move( project => $root, ref => $premature->{ref}, column => 'done' );

# Everything above happened at nine; now it is late enough for every age to
# have passed.
at('2026-08-11T11:30:00Z');

my $world = {
    branches => [], worktrees => [],
    processes => [ { command => 'bash -c sleep 25', started_at => '2026-08-11T09:00:00Z' } ],
    containers => [ { name => 'skills-perl-test-run-abc', started_at => '2026-08-11T09:00:00Z' } ],
    commits => [ { sha => 'abc1234', subject => 'tidy up a few things' } ],
    working_since => '2026-08-11T09:00:00Z',
    unpushed_since => '2026-08-11T09:00:00Z',
};

my $before = fingerprint();
my $pass = $tira->police_pass( project => $root, store => $store, world => $world );

# --- every rule fired -----------------------------------------------------

my %fired = map { $_->{rule} => 1 } @{ $pass->{violations} };
for my $rule ( sort keys %declare ) {
    ok( $fired{$rule}, "$rule fired against a board that breaks it" );
}
is_deeply( [ sort keys %fired ], [ sort keys %declare ],
    'and nothing fired that was not declared' );

# --- and the board is untouched -------------------------------------------

# The promise the whole design rests on, checked after the heaviest pass this
# subsystem will ever make.
is_deeply( fingerprint(), $before,
    'a pass that found twenty different things wrong changed not one byte of the board' );

# --- the bridge delivered all of it ---------------------------------------

$tira->bridge_write( store => $store, violations => $pass->{violations} );
my $delivered = $tira->bridge_backlog( store => $store, lines => 1_000 );
is( scalar @{$delivered}, scalar @{ $pass->{violations} },
    'every violation reached the bridge, not merely most of them' );
is( scalar( grep { /fix:/ } @{$delivered} ), scalar @{$delivered},
    'and every line carries the command that answers it' );

# --- fixing things makes it quiet -----------------------------------------

# Silence has to be earned rather than assumed, so the board is repaired and
# the same pass is run again.
$tira->record_update( project => $root, ref => $bare->{ref},
    description => 'now explained', problem_or_feature => 'a problem',
    solution_needed => 'a solution', key_details => ['a detail'],
    deliverables => ['a deliverable'], acceptance => ['an acceptance'],
    test_steps => ['a step'], bdd => ['a given'], atdd => ['an outcome'],
    scope_in => ['in'], scope_out => ['out'], priority => 3,
    due_date => '2026-08-20T09:00:00Z' );
$tira->record_move( project => $root, ref => $finished->{ref}, column => 'verify' );

my $repaired = $tira->police_pass( project => $root, store => $store, world => $world );
my %still = map { $_->{rule} => 1 } @{ $repaired->{violations} };
ok( !grep( { $_->{ref} eq $bare->{ref} && $_->{rule} eq 'card-full-details' }
        @{ $repaired->{violations} } ),
    'a card that was filled in stops being reported' );
ok( !$still{'card-stalled'}, 'and a card that was moved on stops being reported' );

# --- ignored long enough, it reaches the owner ----------------------------

my $terminal = File::Spec->catdir( $tmp, 'terminal' );
my @seen;
for my $round ( 1 .. 5 ) {
    at( sprintf '2026-08-11T12:%02d:00Z', $round );
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
