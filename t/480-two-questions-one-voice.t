#!/usr/bin/env perl
# TKT-698. The violation ledger keys an entry by (rule, policy, ref) alone.
# Several rules loop over a card's QUESTIONS and report each one with the
# CARD's ref, so two findings about the same card collide into one ledger
# entry: the second is marked quiet by the escalation ladder and never
# reaches the bridge, both share one seen count and first_seen, and marking
# one question leaves the same VIO number describing the other with a
# history that belongs to neither.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $clock = '2026-09-01T09:00:00Z';
my $tira  = Tira->new( clock => sub { $clock } );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );
$tira->project_new(
    name => 'Voiced', dir => $root, members => ['ada'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PTS', epic_prefix => 'PTE', ticket_prefix => 'PTK',
);
$tira->policy_add( project => $root, rule => 'question-unanswered', age => '0s', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Two open questions' );
my $q1 = $tira->question_add( project => $root, ref => $card->{ref}, author => 'ada', text => 'Q one?', reason => 'r1' );
my $q2 = $tira->question_add( project => $root, ref => $card->{ref}, author => 'ada', text => 'Q two?', reason => 'r2' );
$clock = '2026-09-01T09:00:01Z';

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { $_->{rule} eq 'question-unanswered' } @{ $pass->{violations} } ];
}

my $first = findings();
is( scalar @{$first}, 2, 'a card with two unanswered questions produces two findings' );

my %ids = map { $_->{id} => 1 } @{$first};
is( scalar keys %ids, 2, 'the two findings are told apart in the ledger - not one shared VIO id' );

ok( ( !grep { $_->{quiet} } @{$first} ), 'neither finding is silenced by the other having spoken first' );

# --- each settles on its own history --------------------------------------

$tira->question_answer( project => $root, ref => $card->{ref}, id => $q1->{id}, text => 'Answer one', author => 'ada' );
my $after_answer = findings();
is( scalar @{$after_answer}, 1, 'answering one question leaves exactly one finding - the other question' );
is( $after_answer->[0]{detail}, "$q2->{id} has been waiting since $q2->{asked_at}",
    'the remaining finding is genuinely about the still-open question, not a renamed one' );
is( $after_answer->[0]{id}, ( grep { $_->{detail} =~ /\Q$q2->{id}\E/ } @{$first} )[0]{id},
    q{the remaining finding keeps the VIO id it always had, not the answered one's} );

# --- a card with one question is unchanged in ref, id and wording ---------

my $single_card = $tira->create_record( project => $root, type => 'ticket', title => 'One question' );
$tira->question_add( project => $root, ref => $single_card->{ref}, author => 'ada', text => 'Alone?', reason => 'r' );
$clock = '2026-09-01T09:00:02Z';
my $pass2 = $tira->police_pass( project => $root, store => $store, world => {} );
my ($single) = grep { $_->{rule} eq 'question-unanswered' && $_->{ref} eq $single_card->{ref} } @{ $pass2->{violations} };
ok( $single, 'the single-question card still produces a finding' );
is( $single->{ref}, $single_card->{ref}, 'and its ref is still the plain card ref - the common case does not change shape' );

# --- task-unlinked (already safe, keyed on the item id) is not broken ------

$tira->tasklist_add( project => $root, text => 'first orphan task' );
$tira->tasklist_add( project => $root, text => 'second orphan task' );
$tira->policy_add( project => $root, rule => 'task-unlinked', age => '0s', action => 'bridge-reminder' );
$clock = '2026-09-01T09:00:03Z';
my $pass3 = $tira->police_pass( project => $root, store => $store, world => {} );
my @unlinked = grep { $_->{rule} eq 'task-unlinked' } @{ $pass3->{violations} };
is( scalar @unlinked, 2, 'task-unlinked with two unlinked tasks still produces two entries - the existing safe shape is untouched' );

done_testing;

__END__

=head1 NAME

t/480-two-questions-one-voice.t - two open questions on one card are two
findings, not one shared voice

=head1 DESCRIPTION

C<_violation_key> joined only C<(rule, policy, ref)>. Rules that loop over a
card's questions and report each with the card's own C<ref> -
C<question-unanswered>, C<answer-unjudged>, C<answer-waiting>,
C<answer-ok-not-folded>, C<answer-not-ok-no-followup> - produced findings
that collided into one ledger entry whenever a card carried more than one
open question: the second was marked quiet by the escalation ladder and
never reached the bridge, both shared a single C<seen> count and
C<first_seen>, and answering one question left the same VIO number
describing the other.

Each finding of this shape now carries the question's own id as a ledger
C<sub_key>, distinct from C<ref> - which stays the card ref everywhere else
(suspension, decline, the bridge's fix command) so nothing about how a
finding is addressed or acted on changes; only its identity in the ledger
does. C<discard-with-open-questions>, on inspection, already reports one
finding per card naming every open question in a single message - it was
never actually affected by this collision, despite an earlier description
of this ticket assuming otherwise. TKT-698.

=cut
