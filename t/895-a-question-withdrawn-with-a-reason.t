#!/usr/bin/env perl
# A question asked by mistake had exactly two honest exits: get a real
# answer nobody owed, or fake one to satisfy the gate.
#
# FOUND BY HITTING IT, on TKT-863, 2026-09-03. Q-114 was a duplicate,
# unanswered, and the only way past the answer-unjudged gate's own fix line
# was tira.question.mark --mark ok|not-ok - a judgement of an answer that did
# not exist. TKT-627/TKT-584/TKT-455 have since corrected the gate itself so
# an unanswered question no longer blocks a move at all, and question.discard
# already keeps a struck-through question's text and already exempts it from
# the answer-unjudged gate - so most of what TKT-895 originally described has
# already been fixed by other tickets, checked directly against the current
# code (CHK-001) rather than assumed from the card's own age.
#
# WHAT WAS STILL MISSING, confirmed by his own answer to Q-153: discard never
# asked WHY. A question withdrawn on purpose and one simply forgotten looked
# identical on the card, and the only way to leave a true reason behind was
# to self-answer with it and then mark not-ok - which writes a FALSE
# "answered" record on a question the owner never actually answered.
# question.withdraw is discard with a reason REQUIRED, the same way
# police.suspend and rule.suspend already require one.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T21:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name       => 'Withdrawing',  dir           => $root,
    members    => ['ada'],        columns       => ['backlog, implement, done'],
    sow_prefix => 'WDS',          epic_prefix   => 'WDE',
    ticket_prefix => 'WDT',       author        => 'ada',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with two questions on it',
    author  => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref},
    column  => 'implement', author => 'ada',
);

# --- withdraw requires a reason, the same way a suspension does -------------

my $mistake = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada',
    text    => 'Is this a duplicate of the one I just asked?',
);

ok( !eval { $tira->question_withdraw( project => $root, id => $mistake->{id} ); 1 },
    'question_withdraw refuses with no reason at all' );
like( $@, qr/reason/i, 'and says why - a reason is what it was missing' );

ok( !eval {
        $tira->question_withdraw(
            project => $root, id => $mistake->{id}, reason => '   ',
        );
        1;
    },
    'question_withdraw refuses a whitespace-only reason, the same rule checklist.add and evidence.add already use' );

# --- withdrawing keeps the text, records why, and does not fake a judgement -

my $withdrawn = $tira->question_withdraw(
    project => $root, id => $mistake->{id}, reason => 'duplicate of the one asked right after it',
);

is( $withdrawn->{status}, 'discarded', 'a withdrawn question reads as discarded - the same struck-through state' );
is( $withdrawn->{text}, 'Is this a duplicate of the one I just asked?',
    'its text survives - withdrawn, not deleted, the same choice the discard column makes' );
is( $withdrawn->{withdrawn_reason}, 'duplicate of the one asked right after it',
    'the reason it was withdrawn is on the record - nothing was faked to get past a gate' );
ok( !$withdrawn->{answer}, 'no answer was recorded - withdrawing never pretends a judgement happened' );

ok( !eval { $tira->question_withdraw( project => $root, id => $mistake->{id}, reason => 'again' ); 1 },
    'a question already withdrawn cannot be withdrawn twice' );
like( $@, qr/already discarded/, 'and the refusal says so in the same words question.discard already uses' );

# --- and the CLI command exists, requiring the reason at the option level ---

my $second = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada',
    text    => 'Asked the wrong card entirely',
);

sub run_cli {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    my ( $out, $said ) = ( '', '' );
    open my $fh, '>', \$out  or die $!;
    open my $eh, '>', \$said or die $!;
    local *STDERR = $eh;
    my $old = select $fh;
    my $err;
    { local $@; eval { Tira::CLI->run( command => 'question.withdraw', tira => $tira, argv => \@argv ); 1 } or $err = $@; }
    select $old;
    return ( $out . $said, $err );
}

my ( $refused_out, $refused_err ) = run_cli( '--id', $second->{id} );
ok( ( $refused_err || $refused_out ) =~ /reason/i,
    'tira.question.withdraw with no --reason refuses, same as the engine method' );

my ( $ok_out, $ok_err ) = run_cli( '--id', $second->{id}, '--reason', 'wrong card, refile elsewhere' );
ok( !$ok_err, 'tira.question.withdraw --id ID --reason TEXT succeeds' )
  or diag("died with: $ok_err");

my $after = $tira->question_list( project => $root, ref => $card->{ref} );
my ($confirmed) = grep { $_->{id} eq $second->{id} } @{ $after->{questions} };
is( $confirmed->{status}, 'discarded', 'the CLI path withdrew the second question too' );
is( $confirmed->{withdrawn_reason}, 'wrong card, refile elsewhere', 'and its reason is on the record' );

# --- withdrawing an already-answered question keeps the real answer --------
#
# CODEX REVIEW: withdraw inherits discard's own rule that a question may
# already carry an answer - the answer and its mark are left exactly as they
# were. Withdrawing is for the QUESTION, not the answer; an answer somebody
# actually gave is never erased or reinterpreted by it.

my $genuinely_answered = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada', text => 'Which store?',
);
$tira->question_answer(
    project => $root, id => $genuinely_answered->{id}, text => 'Staging, the runbook says so',
);
$tira->question_mark( project => $root, id => $genuinely_answered->{id}, mark => 'ok' );

my $withdrawn_after_answer = $tira->question_withdraw(
    project => $root, id => $genuinely_answered->{id}, reason => 'kept for the record, not what this tests',
);
is( $withdrawn_after_answer->{status}, 'discarded', 'an already-answered question can still be withdrawn' );
is( $withdrawn_after_answer->{answer}{text}, 'Staging, the runbook says so',
    'and its real answer is left exactly as it was - withdraw never erases a genuine answer' );
is( $withdrawn_after_answer->{answer}{mark}, 'ok', 'its mark is untouched too' );

# --- an unanswered question still does not block a move (already fixed) ----

my $third = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada', text => 'Still open, not withdrawn',
);
my $moved = $tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref}, column => 'done', author => 'ada',
);
is( $moved->{column}, 'done',
    'an unanswered, non-withdrawn question does not block the move either - '
      . 'waiting on the owner is the normal state of a question, not the agent being sloppy' );

done_testing();

__END__

=head1 NAME

t/895-a-question-withdrawn-with-a-reason.t - a question asked by mistake can be withdrawn honestly

=head1 WHY

TKT-895, narrowed by CHK-001's own investigation: most of the original
problem (an unanswered question producing a misleading "judge it" refusal)
was already fixed by TKT-627/TKT-584/TKT-455. What remained, confirmed by
his own answer to Q-153, is that question.discard never required a reason -
so the only honest way to record WHY a question was withdrawn was to
self-answer it and mark not-ok, which writes a false "answered" record on a
question the owner never actually answered.

=head1 WHAT IS ASSERTED

C<question_withdraw> (and C<tira.question.withdraw>) require a non-blank
reason, keep the question's text, record the reason, and never write an
answer - so withdrawing is distinguishable on the record from an answer that
was actually given.

=head1 WHAT IS NOT ASSERTED

That an unanswered question ever blocked a move - it does not, and this file
proves that is still true rather than assuming it. Deleting a question, or
any change to what C<question.mark> means for a question that was actually
answered, are both out of scope per the card's own C<scope.excluded>.

=cut
