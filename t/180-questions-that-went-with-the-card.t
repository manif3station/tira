#!/usr/bin/env perl
# A card set aside does not take an unanswered question with it.
#
# His request. A card can be discarded while it still carries questions nobody
# has answered, and nothing says so. The questions go with the card: not
# answered, not withdrawn, not asked anywhere else. They simply stop being
# visible, and the decision they were waiting on is never made.
#
# His words for what should happen: police asks the agent - what about the
# questions? Find out whether they are still valid first. If they are, move them
# to a new card or to another card they suit. Move meaning ask them where they
# belong and discard them here.
#
# Police asks and moves nothing, like every other rule in this file. Whether a
# question still matters is a judgement about the work, and a rule that carried
# questions between cards on its own would be making that judgement by machine -
# which is the one thing an enforcement system must not do, because a wrong
# guess there is indistinguishable from a decision somebody made.
#
# There is also no command that moves a question. Asking it on the new card and
# discarding it on the old IS the move, so the violation says that rather than
# naming a command that does not exist - a message pointing at a command nobody
# can run is worse than one that explains itself.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T10:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Set Aside', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SAS', epic_prefix => 'SAE', ticket_prefix => 'SAT',
);

sub carded {
    my ($title) = @_;
    return $tira->create_record( project => $root, type => 'ticket', title => $title )->{ref};
}

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'discard-with-open-questions' } @{ $pass->{violations} } ];
}

# --- a board that has not asked hears nothing ---------------------------------------
#
# First, because a rule arriving switched on changes every board that upgrades,
# underneath whoever was relying on them.

my $abandoned = carded('Set aside with a question still open');
my $open = $tira->question_add( project => $root, ref => $abandoned, author => 'claude',
    text => 'Which way should this go?', reason => 'Nothing can start until this is settled' );
$tira->record_discard( project => $root, ref => $abandoned,
    reason => 'not worth doing after all' );

is( scalar @{ reported() }, 0, 'a board that has not declared the rule hears nothing' );

$tira->policy_add( project => $root, rule => 'discard-with-open-questions',
    action => 'bridge-reminder' );

# --- the card that took a question with it -------------------------------------------

my $found = reported();
is( scalar @{$found}, 1, 'a card discarded with a question still open is reported' );
is( $found->[0]{ref}, $abandoned, 'against the card that was set aside' );
like( $found->[0]{detail}, qr/\Q$open->{id}\E/, 'naming the question that went with it' );

# --- and says what to do about it -----------------------------------------------------
#
# The three steps he asked for, in order. A violation that said only "this card
# had questions" would leave the reader to invent the procedure, and the whole
# point is that the decision the question was waiting on still has to be made.

like( $found->[0]{detail}, qr/still\b.*\b(?:matters|valid|needed)|whether it/i,
    'telling the agent to judge whether it still matters' );
like( $found->[0]{detail}, qr/ask/i, 'to ask it where it belongs' );
like( $found->[0]{detail}, qr/discard/i, 'and to discard it here' );

# It must not name a command that does not exist. There is no way to move a
# question, and inventing one in a message is how a reader ends up typing
# something the tool refuses.
unlike( $found->[0]{detail}, qr/question\.move|tira\.move/,
    'without naming a command nobody can run, because moving a question is not one' );

# --- a question that was answered is not this ------------------------------------------
#
# Otherwise the rule fires on every discarded card that ever had a conversation
# on it, which on a board with a hundred set aside is a channel nobody reads.

{
    my $settled = carded('Set aside, but the question was answered first');
    my $asked = $tira->question_add( project => $root, ref => $settled, author => 'claude',
        text => 'And this one?', reason => 'It mattered at the time' );
    $tira->question_answer( project => $root, ref => $settled, id => $asked->{id},
        author => 'michael', text => 'It does not matter, drop it' );
    $tira->record_discard( project => $root, ref => $settled,
        reason => 'answered, and the answer was to drop it' );

    is( scalar( grep { $_->{ref} eq $settled } @{ reported() } ), 0,
        'a card whose question was answered before it was set aside is not reported' );
}

# --- nor is one that was withdrawn -------------------------------------------------------
#
# Discarding the question is exactly what he asked the agent to do with the ones
# that no longer matter, so a card where that has happened is a card where the
# rule has already been obeyed.

{
    my $withdrawn = carded('Set aside, question withdrawn first');
    my $asked = $tira->question_add( project => $root, ref => $withdrawn, author => 'claude',
        text => 'Does this still apply?', reason => 'Asked while it looked necessary' );
    $tira->question_discard( project => $root, ref => $withdrawn, id => $asked->{id} );
    $tira->record_discard( project => $root, ref => $withdrawn,
        reason => 'the question stopped applying and so did the card' );

    is( scalar( grep { $_->{ref} eq $withdrawn } @{ reported() } ), 0,
        'a card whose question was withdrawn is not reported either' );
}

# --- and a live card with an open question is not this rule -------------------------------
#
# question-unanswered is the rule for a question waiting on the owner. This one
# is only about the questions that left the board with the card.

{
    my $live = carded('Still live, still asking');
    $tira->question_add( project => $root, ref => $live, author => 'claude',
        text => 'Waiting on him', reason => 'Not discarded, just waiting' );

    is( scalar( grep { $_->{ref} eq $live } @{ reported() } ), 0,
        'a live card with an open question belongs to question-unanswered, not to this' );
}

# --- and the rule refuses arguments it cannot use ---------------------------------------
#
# No age. A question that left with the card is not waiting for anything, so
# there is nothing for a grace period to be a grace for.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'discard-with-open-questions',
            age => '2h', action => 'bridge-reminder' );
        1;
    },
    'an age is refused, because a question that left with the card is not waiting' );

done_testing;

__END__

=head1 NAME

180-questions-that-went-with-the-card.t - a discarded card does not silence a question

=head1 DESCRIPTION

C<discard-with-open-questions> reports a card set aside while it still carries a
question nobody answered, names the question, and says what to do: judge whether
it still matters, ask it where it belongs, and discard it here.

Police asks and moves nothing. Whether a question still matters is a judgement
about the work, and there is no command that moves one - asking it on the new
card and discarding it on the old is the move, so the message says that rather
than naming a command nobody can run.

A question answered before the card was set aside, or withdrawn, is not
reported; nor is an open question on a live card, which is
C<question-unanswered>'s business.

=cut
