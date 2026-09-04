#!/usr/bin/env perl
# card-stalled accepts an age, stores it, shows it back, and nothing reads it.
#
# TKT-933. His screenshot: the policy declare form let him set a stall
# threshold on card-stalled. It was accepted, stored, and shown back - and
# the rule's own body (lib/Tira.pm, the card-stalled block) never once reads
# it. A threshold typed into the form does nothing, silently.
#
# HIS ANSWER, Q-120/Q-122, 2026-09-05 00:02: "Refuse an age on card-stalled,
# and name card-duration in the refusal." Somebody typing 30m into this rule's
# form wanted a duration threshold, and card-duration is the rule that reads
# one - the refusal should send them there rather than storing a number that
# does nothing.
#
# THE THIRD ACCEPTANCE CRITERION is the reason this file is not four lines:
# "Every rule whose spec omits an option it accepts is checked the same way,
# rather than fixing the one he happened to find." A sweep of every rule's
# body against %POLICY_RULES found eighteen more - none declared in `needs`
# or `forbids`, none read anywhere in the engine - so an age set on any of
# them is accepted, stored, and does exactly nothing, the same shape as the
# one he found. Each is refused the same way conversation-not-folded and
# monitor-dead already are, with the same generic message, because none of
# them has a sibling rule worth naming the way card-duration is card-stalled's.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Aged', dir => $root,
    members => ['claude'], columns => ['backlog, implement, done'],
    sow_prefix => 'AGS', epic_prefix => 'AGE', ticket_prefix => 'AGT',
);

# --- the one he found, with the answer he gave -----------------------------

{
    my $refused = !eval {
        $tira->policy_add( project => $root, rule => 'card-stalled',
            before => 'implement', age => '30m', action => 'bridge-reminder' );
        1;
    };
    ok( $refused,
        'CARD-STALLED REFUSES AN AGE rather than storing a threshold nothing '
          . 'reads' ) or diag('policy_add accepted it - the bug is still there');
    like( $@, qr/takes no --age/, 'says it takes no --age' );
    like( $@, qr/card-duration/,
        'AND NAMES CARD-DURATION - his exact answer: someone typing 30m here '
          . 'wanted the rule that actually reads a duration' );
}

# --- and it still works with the option it actually needs ------------------

{
    my $policy = $tira->policy_add( project => $root, rule => 'card-stalled',
        before => 'implement', action => 'bridge-reminder' );
    is( $policy->{rule}, 'card-stalled',
        'declaring it without an age still works - the fix refuses the '
          . 'option nothing reads, not the rule itself' );
}

# --- the sweep: every other rule with the same shape of gap -----------------
#
# None of these declares age in `needs` or `forbids`, and grepping each
# rule's own block in the engine for `policy->{age}` (word-bounded, so
# "agent" does not count) finds nothing - the same silent-accept-and-ignore
# shape card-stalled had.

# t/79 requires each of these to appear literally - `rule => 'name'` and
# `age =>` in the same statement - so this is written out rather than driven
# from a table, the same discipline that check exists to enforce.
sub refuses_age {
    my ( $rule, %args ) = @_;
    my $refused = !eval { $tira->policy_add(%args); 1 };
    ok( $refused, "$rule refuses an age rather than quietly storing one nothing reads" )
      or diag("policy_add accepted --age on $rule");
    like( $@, qr/takes no --age/, "$rule says so in the words somebody typing it would read" );
}

refuses_age( 'card-full-details', project => $root,
    rule => 'card-full-details', enter => 'implement', age => '10m', action => 'bridge-reminder' );
refuses_age( 'card-metrics', project => $root,
    rule => 'card-metrics', enter => 'implement', require => 'title', age => '10m', action => 'bridge-reminder' );
refuses_age( 'checklist-unmoved', project => $root,
    rule => 'checklist-unmoved', age => '10m', action => 'bridge-reminder' );
refuses_age( 'orphan-card', project => $root,
    rule => 'orphan-card', age => '10m', action => 'bridge-reminder' );
refuses_age( 'rules-undeclared', project => $root,
    rule => 'rules-undeclared', age => '10m', action => 'bridge-reminder' );

# card-changed-by-owner's own special die (no agent declared) would otherwise
# fire before the forbids check does, so the agent is declared first.
$tira->project_update( project => $root, agent => 'claude' );
refuses_age( 'card-changed-by-owner', project => $root,
    rule => 'card-changed-by-owner', age => '10m', action => 'bridge-reminder' );

refuses_age( 'card-unassigned', project => $root,
    rule => 'card-unassigned', age => '10m', action => 'bridge-reminder' );
refuses_age( 'card-agentless', project => $root,
    rule => 'card-agentless', enter => 'implement', age => '10m', action => 'bridge-reminder' );
refuses_age( 'job-due', project => $root,
    rule => 'job-due', age => '10m', action => 'bridge-reminder' );
refuses_age( 'task-changed', project => $root,
    rule => 'task-changed', age => '10m', action => 'bridge-reminder' );
refuses_age( 'column-skipped', project => $root,
    rule => 'column-skipped', enter => 'done', require => 'implement', age => '10m', action => 'bridge-reminder' );
refuses_age( 'wip-limit', project => $root,
    rule => 'wip-limit', column => 'implement', max => 3, age => '10m', action => 'bridge-reminder' );
refuses_age( 'gate-missing', project => $root,
    rule => 'gate-missing', column => 'implement', age => '10m', action => 'bridge-reminder' );
refuses_age( 'discard-unexplained', project => $root,
    rule => 'discard-unexplained', age => '10m', action => 'bridge-reminder' );
refuses_age( 'card-unlinked', project => $root,
    rule => 'card-unlinked', require_link => 'blocks', age => '10m', action => 'bridge-reminder' );
refuses_age( 'parent-ahead-of-children', project => $root,
    rule => 'parent-ahead-of-children', age => '10m', action => 'bridge-reminder' );
refuses_age( 'commit-without-card', project => $root,
    rule => 'commit-without-card', age => '10m', action => 'bridge-reminder' );

# card-sandbox-missing needs a repository to declare at all (TKT-178) - proved
# on its own, after the sweep above, so the loop's project does not need one.
{
    mkdir File::Spec->catdir( $root, '.git' );
    my $refused = !eval {
        $tira->policy_add( project => $root, rule => 'card-sandbox-missing',
            enter => 'implement', sandbox => '/work', age => '10m',
            action => 'bridge-reminder' );
        1;
    };
    ok( $refused, 'card-sandbox-missing refuses an age too' );
    like( $@, qr/takes no --age/, 'and says so' );
}

done_testing();

__END__

=head1 NAME

544-an-age-nothing-reads.t - card-stalled, and eighteen more, silently ignore --age

=head1 WHY

TKT-933. C<card-stalled> accepted, stored and showed back a stall-threshold
age nobody's code ever read - a form field that did nothing. His answer:
refuse it, and name C<card-duration>, the rule that actually reads one.

The card's third criterion asked for the same check on every other rule.
Eighteen more accept an option (C<--age>) that appears in no C<needs> or
C<forbids> entry and is read nowhere in their own block of the engine -
the identical silent-accept-and-ignore shape, just not yet the one he
happened to type into a form.

=head1 WHAT IS ASSERTED

That C<card-stalled> refuses C<--age>, naming C<card-duration>; that it
still declares fine without one; and that each of the eighteen swept rules
refuses C<--age> with the same generic message every other C<forbids> rule
already gives.

=cut
