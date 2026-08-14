#!/usr/bin/env perl
# The same problem is not said again until there has been time to fix it.
#
# Michael, raising this: "the police sends messages on the bridge are too fast.
# Like, the same issue been seen many times within few seconds. After print out
# the issues the first time, at least give the agent a period of time to
# address the problem before printing out the second message... Becomes spammy
# and the core agent might ignore the repeated ones and also wasting the LLM
# token or credit too."
#
# He is describing the failure this whole subsystem is built to avoid, arriving
# from the inside: a channel that repeats itself is one the reader learns to
# skim, and a channel that exists to be read cannot afford that.
#
# Every pass wrote every violation that was still true. Police runs every thirty
# seconds, so a problem nobody had got to yet said the same thing twice a
# minute, for ever.
#
# Two things change. A violation is written at most once per quiet period, and
# the period grows, so a problem that persists gets quieter rather than
# buzzing at a constant rate. And "seen" counts times it was said rather than
# passes it survived - which is what the line has always claimed, and what
# makes "seen 5 times, needs your attention" mean five tellings rather than two
# and a half minutes.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-13T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Not so loud', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NLS', epic_prefix => 'NLE', ticket_prefix => 'NLT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

my %world = ( branches => [], worktrees => [], processes => [], containers => [], commits => [] );

sub sweep {
    my $result = $tira->police_pass( project => $root, store => $store, world => {%world} );
    $tira->bridge_write( store => $store, project => $root, violations => $result->{violations} );
    return $result;
}
# Violations, not lines. A replay is introduced by a header saying what it is,
# and counting that as something police said would make every number here one
# too many.
sub said {
    return scalar grep { /VIO-/ }
      @{ $tira->bridge_backlog( store => $store, lines => 500 ) };
}

# --- the first time, at once ----------------------------------------------
#
# A problem nobody has been told about waits for nothing.

sweep();
is( said(), 1, 'a problem is said the moment it is found' );

# --- and then not again, for a while ---------------------------------------

at('2026-08-13T09:00:30Z'); sweep();
at('2026-08-13T09:01:00Z'); sweep();
at('2026-08-13T09:01:30Z'); sweep();
at('2026-08-13T09:02:00Z'); sweep();
is( said(), 1, 'four more passes in two minutes say nothing more - that is the time to fix it' );

# --- still reported, just not repeated -------------------------------------
#
# Police's answer to "what is wrong" must not change. Only how often it says so
# on the bridge does - otherwise a quiet violation would look like a fixed one
# to anybody reading the pass itself.

my $quiet = sweep();
is( scalar @{ $quiet->{violations} }, 1,
    'the violation is still reported as true, because it still is' );

# --- said again once there has been time -----------------------------------

at('2026-08-13T09:06:00Z');
sweep();
is( said(), 2, 'after the quiet period it is said a second time' );

# --- and the gap grows -----------------------------------------------------
#
# A problem that persists should get quieter, not keep buzzing at the same
# rate. Five minutes later is not enough for the third telling.

at('2026-08-13T09:11:00Z'); sweep();
is( said(), 2, 'five minutes after the second telling is too soon for a third' );

at('2026-08-13T09:22:00Z'); sweep();
is( said(), 3, 'but a longer gap earns it' );

# --- seen counts tellings, not passes --------------------------------------
#
# The line says "seen N times". It has always meant to, and it used to count
# passes, so a problem nobody had touched said "seen 5 times" after two and a
# half minutes.

my ($line) = grep { /VIO-/ } @{ $tira->bridge_backlog( store => $store, lines => 1 ) };
like( $line, qr/seen 3\b/, 'the count is the number of times it has been said' );

# --- escalation follows the same clock -------------------------------------
#
# Reaching the owner's terminal at five means five tellings spread over the
# ladder, rather than five passes of thirty seconds.

my $escalated = 0;
for my $when ( '2026-08-13T10:00:00Z', '2026-08-13T11:30:00Z', '2026-08-13T13:00:00Z' ) {
    at($when);
    my $result = sweep();
    $escalated++ if @{ $result->{terminal} };
}
is( $escalated, 1, 'it reaches his terminal once, after five tellings rather than five passes' );

# --- a problem that goes away stops at once --------------------------------
#
# Nothing here may delay good news. A fixed card is silent on the next pass,
# with no quiet period involved.

# Every field the rule asks for, not four of them - the first attempt filled
# in a card the rule still considered bare, which would have proved nothing
# about whether good news travels fast.
$tira->record_update( project => $root, ref => $card->{ref},
    description => 'now it says what it is', problem_or_feature => 'a real problem',
    solution_needed => 'a real solution', priority => 3,
    key_details => ['a detail'], deliverables => ['a deliverable'],
    acceptance => ['it works'], test_steps => ['run it'],
    bdd => ['Given a card, When it is filled in, Then it is not reported'],
    atdd => ['nobody is chased about a card that is finished'],
    scope_in => ['this'], scope_out => ['that'] );
at('2026-08-13T14:00:00Z');
my $after = sweep();
is( scalar @{ $after->{violations} }, 0, 'a card that has been filled in is reported no more' );

# --- and a different problem is not held back by another's quiet -----------

my $second = $tira->create_record( project => $root, type => 'ticket', title => 'Also bare' );
$tira->record_move( project => $root, ref => $second->{ref}, column => 'implement' );
my $before = said();
at('2026-08-13T14:00:30Z');
sweep();
is( said(), $before + 1, 'a new problem is said at once, whatever another one is waiting on' );

# --- quiet asked for is not quiet spent ------------------------------------
#
# An agent can ask police for silence while it concentrates. Nothing is said to
# it while that lasts - so nothing may be counted against it either. Charging
# the ladder for tellings that were never delivered would leave an agent coming
# back from five minutes of quiet owing the longest gap for a problem nobody had
# mentioned to it, and would carry it to his terminal unheard.

my $hush = File::Spec->catdir( $tmp, 'hush' );
$tira->record_update( project => $root, ref => $second->{ref}, assignee => 'michael' );

at('2026-08-13T15:00:00Z');
my $heard = $tira->police_pass( project => $root, store => $hush, world => {%world} );
my ($mine) = grep { $_->{ref} eq $second->{ref} } @{ $heard->{violations} };
is( $mine->{seen}, 1, 'a card of his own is told about once, to begin with' );

$tira->police_suspend( project => $root, store => $hush, seconds => 300,
    reason => 'reading one thing to the bottom', author => 'michael' );

for my $minute ( 1 .. 4 ) {
    at( sprintf '2026-08-13T15:%02d:00Z', $minute );
    $tira->police_pass( project => $root, store => $hush, world => {%world} );
}

at('2026-08-13T15:06:00Z');
my $back = $tira->police_pass( project => $root, store => $hush, world => {%world} );
my ($again) = grep { $_->{ref} eq $second->{ref} } @{ $back->{violations} };
is( $again->{seen}, 2,
    'and after the quiet it is on its second telling, not its sixth - silence costs nothing' );

# --- and a world rule's own wording is filled in ---------------------------
#
# TKT-102, found in the bridge lines he pasted as evidence for this card: "the
# board has not been backed up in {age}". Two places build a violation and only
# one of them substituted, so the six rules that read the machine shipped their
# placeholders raw.

my $wording = File::Spec->catdir( $tmp, 'wording' );
$tira->policy_add( project => $root, rule => 'board-unbacked', age => '24h',
    action => 'bridge-reminder',
    message => 'the board has not been backed up in {age}, and {rule} says that matters' );

my $world_view = $tira->police_pass( project => $root, store => $wording,
    world => { %world, backed_up_at => undef } );
my ($backup) = grep { $_->{rule} eq 'board-unbacked' } @{ $world_view->{violations} };
ok( $backup, 'the board-unbacked rule fires with a wording of its own' );
like( $backup->{message}, qr/backed up in 24h/, 'and its age is filled in, not left in braces' );
like( $backup->{message}, qr/board-unbacked says/, 'and so is its rule' );
unlike( $backup->{message}, qr/[{}]/, 'nothing is left in braces at all' );

done_testing();

__END__

=head1 NAME

122-police-gives-time-to-fix.t - the same problem is not said again until there has been time to fix it

=head1 DESCRIPTION

Every pass wrote every violation that was still true, so a problem nobody had
got to yet said the same thing twice a minute for ever. The owner raised it:
it becomes spammy, the agent learns to skim the repeated ones, and it spends
tokens saying nothing new.

A violation is now written at most once per quiet period, and the period grows,
so a problem that persists gets quieter rather than louder. What police reports
as true is unchanged - only how often it says so - and a problem that is fixed
goes silent immediately, because nothing may delay good news.

=cut
