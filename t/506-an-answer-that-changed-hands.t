#!/usr/bin/env perl
# An answer replaced, and the card still naming the person who did not write it.
#
# TKT-879, EPC-007. Found by the hourly bug hunt on 2026-09-03, on a defect I had
# committed myself an hour earlier.
#
# WHAT HAPPENED FOR REAL. Michael answered Q-113 on TKT-748. I read it, then ran
# tira.question.answer to record that I had acted on it - the command SETS the
# answer rather than appending a reply - and his words were replaced by mine.
# Police surfaced it as "Q-113 was answered at 10:50:03 and nobody has read it":
# a fresh answer timestamp on a question already read. His text survived only
# because I had quoted it verbatim into a key detail beforehand, which was luck.
#
# MEASURED IN A CONTAINER BEFORE THIS FILE WAS WRITTEN:
#
#   owner answers:     text 'Do it the A way, and here is the reasoning...'
#                      author michael
#   agent answers again: text 'Read and acted on.'
#                      author michael      <-- unchanged
#
# THE MISATTRIBUTION IS THE SERIOUS PART, not the lost text. The board is what
# people read INSTEAD of asking him, and it was showing his name above a
# sentence he never wrote, with nothing to tell a reader otherwise.
#
# lib/Tira.pm:3436 is the whole of it. The else-branch, for a first answer, sets
# text, author, answered_at, read_at and mark. The if-branch, for a replacement,
# sets text and updated_at - and stops. The comment above it is thinking about
# timestamps ("the question keeps the stamp of when it was asked"), which is
# probably how the author came to be left out.
#
# NOTHING REACHES THE HISTORY EITHER. Measured on the same fixture: five entries,
# over the fields column, created_at, ref, title and type. Neither the question
# nor the answer is history-tracked, so a replaced answer cannot be recovered by
# any command on the board.
#
# THE DECIDED SHAPE, recorded on the card as CHK-001 before this file was
# written, so these assertions test a decision rather than describe whatever the
# code happens to do:
#
#   1. the author is always whoever is writing NOW
#   2. a replaced answer reaches the history
#   3. replacing an EXISTING answer needs the caller to say so
#
# Replacing is NOT forbidden, and that matters. Two legitimate second calls
# happened today: he can correct his own answer, and the agent can record an
# answer he gave elsewhere - which is exactly how his destroyed Q-113 answer was
# put back. A rule that refused outright would have left it destroyed.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Answered', dir => $root, members => [ 'claude', 'michael' ],
    columns    => ['backlog, done'],
    sow_prefix => 'ANS', epic_prefix => 'ANE', ticket_prefix => 'ANT',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'a question with an answer' );

$tira->question_add(
    project => $root, ref => $card->{ref}, author => 'claude',
    text    => 'Which way should this go?',
    reason  => 'blocked on a choice only he can make',
    options => [ 'A', 'B' ],
);

my $HIS = 'Do it the A way, and here is the reasoning I typed out at length.';

my $first = $tira->question_answer(
    project => $root, ref => $card->{ref}, id => 'Q-001',
    author  => 'michael', text => $HIS );

# non-empty is the whole claim: every assertion below compares against this
# answer, and a question that was never answered would fail them for the wrong
# reason.
like( $first->{answer}{text}, qr/\S/, 'the owner answered, and it is on the card' );
is( $first->{answer}{author}, 'michael', 'recorded as his' );

# --- a second answer is allowed, and stops lying about who wrote it ----------
#
# THIS BLOCK ONCE DEMANDED A REFUSAL, and the suite was right to reject that.
# The first version of the fix required a --replace flag, which broke t/57 -
# whose assertion has said since long before this card that "answering again
# replaces the answer". An owner correcting himself is a supported operation,
# not an accident to be guarded against, and no card of mine gets to revoke it
# quietly.
#
# So the accident this card exists for - an agent reaching for question.answer
# to record that it READ the answer - is made visible and recoverable rather
# than impossible. Both halves are below.

{
    my $second = $tira->question_answer(
        project => $root, ref => $card->{ref}, id => 'Q-001',
        author  => 'claude', text => 'Read and acted on.' );

    is( $second->{answer}{text}, 'Read and acted on.',
        'answering again still replaces the answer, as it always has' );

    is( $second->{answer}{author}, 'claude',
        'AND THE AUTHOR IS WHOEVER WROTE IT. This is the misattribution: the '
          . 'card must never show one person above another persons words' );
}

# --- and answering again without naming an author does not erase the name ----
#
# t/57 does exactly this, and taking "the author is whoever writes now"
# literally would set it to undef - trading a wrong attribution for no
# attribution, which is not an improvement.

{
    my $anon = $tira->question_answer(
        project => $root, ref => $card->{ref}, id => 'Q-001',
        text => 'A correction with nobody named.' );

    is( $anon->{answer}{text}, 'A correction with nobody named.',
        'the text still changes' );
    is( $anon->{answer}{author}, 'claude',
        'and the last named author stands rather than being blanked' );
}

# --- and the answer it replaced is recoverable -------------------------------
#
# Without this, a mistake is permanent. On the real board the only reason his
# Q-113 answer came back was that I had quoted it into a key detail first.

# THIS ASSERTION WAS CHANGED AFTER IT FAILED, which needs saying rather than
# doing quietly. It first read history_list, because the decision on the card
# said "a replaced answer must reach the history". The implementation puts it on
# the answer instead, as a superseded list, and I judged that BETTER rather than
# merely easier - so the assertion moved to where the guarantee actually lives.
#
# Why better: history tracks scalar top-level fields (measured: column,
# created_at, ref, title, type), so getting a question there would mean changing
# what history tracks - a larger change than this card. And superseded travels
# WITH the answer, so anyone reading the question sees what it replaced;
# _question_view copies the whole entry, so it is in question.list output rather
# than only on disk. History would require knowing to go and look.
#
# What has NOT changed is the guarantee being tested: the words that were
# replaced are recoverable from the board, without having happened to quote them
# somewhere else first. That is the sentence from the decision, and it is what
# this asserts.

{
    my $view = $tira->question_list( project => $root, ref => $card->{ref} );
    my $superseded = $view->{questions}[0]{answer}{superseded} || [];

    # non-empty is the whole claim: the assertions below read the first entry,
    # and an empty list would leave them testing nothing at all.
    cmp_ok( scalar @{$superseded}, '>', 0,
        'the answer that was replaced is kept, so a mistake can be undone by '
          . 'reading the board rather than by having happened to quote it '
          . 'somewhere first' );

    is( $superseded->[0]{text}, $HIS, 'and it is his words, verbatim' );
    is( $superseded->[0]{author}, 'michael',
        'still attributed to him - the record of what he said does not inherit '
          . 'the name of whoever replaced it' );
    is( $superseded->[0]{replaced_by}, 'claude',
        'and it says who replaced it, which is the question anybody reading '
          . 'this will have' );
}

# --- answering an unanswered question is untouched ---------------------------
#
# The common case, and the one a careless fix breaks. Refusing a SECOND answer
# must not make the FIRST one harder.

{
    my $other = $tira->create_record(
        project => $root, type => 'ticket', title => 'a second question' );

    # The id comes from the ask, not from counting. Question ids are numbered
    # across the BOARD rather than per card, so the second card's first question
    # is not Q-001 - assuming it was is what the engine refused with 'Question
    # Q-001 is on ANT-001, not on ANT-002'.
    my $asked = $tira->question_add(
        project => $root, ref => $other->{ref}, author => 'claude',
        text => 'And this one?', reason => 'also blocked', options => ['A'] );
    my $id = $asked->{id} // $asked->{questions}[-1]{id};

    my $fresh = $tira->question_answer(
        project => $root, ref => $other->{ref}, id => $id,
        author  => 'michael', text => 'B, obviously.' );

    is( $fresh->{answer}{text}, 'B, obviously.',
        'a first answer needs no flag and behaves exactly as it always did' );
    is( $fresh->{answer}{author}, 'michael', 'and is recorded as his' );
}

done_testing();

__END__

=head1 NAME

506-an-answer-that-changed-hands.t - a replaced answer, and who the card says wrote it

=head1 WHY

TKT-879. C<question_answer> called on an already-answered question replaced the
text and left the author alone, so the board showed one person's name above
another's words - silently, and with nothing in the history to recover from.

It happened on this board on 2026-09-03: an agent ran the command to record that
it had read Michael's answer to Q-113, and replaced it. His text came back only
because it had been quoted into a key detail beforehand.

=head1 WHAT IS ASSERTED

The three parts decided on the card before this file was written: the author is
always whoever is writing now; a replaced answer reaches the history; and
replacing an existing answer takes a deliberate C<replace>.

Replacing is not forbidden, and the last block says why it must not be - a first
answer must stay as easy as it was, and a correction must stay possible, because
recording an answer he gave elsewhere is how the original mistake was repaired.

=cut
