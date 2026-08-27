#!/usr/bin/env perl

# Reading an answer is automatic. Judging one is not, and nothing asks.
#
# lib/Tira.pm says the first half plainly - "Reading is what marks an answer
# read - the agent does nothing extra" - and question_list stamps read_at on
# the way past. Judging takes a deliberate tira.question.mark, and the only
# thing that ever asks for it is the answer-unjudged rule, two hours later, by
# which time the card is finished and the agent has moved on.
#
# So the ordinary outcome is an answer that was read, understood, acted on, and
# left unmarked. Observed on Q-084: answered 06:49:37, read 06:49:56, acted on
# within minutes, and marked ok only because somebody remembered. It happened
# again on Q-087 the same session, hours apart, by the same agent that had
# just filed the card about it.
#
# The gate here reads the question's own mark rather than a required-action
# item standing in for it. That is deliberate, and it is the card's third
# acceptance criterion: an item an agent can tick without judging is an
# acknowledgement clicked through, which is the thing being prevented. There is
# no proxy to satisfy - either the answer carries a judgement or the card does
# not leave the column it was answered in.
#
# answer-unjudged stays exactly as it is. This is the prompt at the moment it
# belongs to; that rule is the backstop for whatever escapes it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-27T09:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name       => 'Judging',      dir           => $root,
    members    => ['ada'],        columns       => ['backlog, implement, done'],
    sow_prefix => 'JGS',          epic_prefix   => 'JGE',
    ticket_prefix => 'JGT',       author        => 'ada',
);

my $card = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card with a question on it',
    author  => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref},
    column  => 'implement', author => 'ada',
);

my $question = $tira->question_add(
    project => $root, ref => $card->{ref}, author => 'ada',
    text    => 'Which way should this go?', reason => 'because it changes the shape',
);

# TIRA_HOME, because Tira::CLI discovers the project from the environment or
# the working directory and this one lives in a tempdir. Without it the move
# never runs at all - "No Tira project found from '.'" - and the assertions
# that the card STAYED put pass for a reason that has nothing to do with
# questions. That is how the first version of this file read green on two
# checks it was not making.
sub move_out {
    local $ENV{TIRA_HOME} = $root;
    my $out = '';
    my $said = '';
    open my $fh, '>', \$out or die $!;
    open my $eh, '>', \$said or die $!;
    local *STDERR = $eh;
    my $old = select $fh;
    my $err;
    {
        local $@;
        eval {
            Tira::CLI->run(
                command => 'record.move', tira => $tira,
                argv    => [ '--type', 'ticket', '--ref', $card->{ref},
                             '--column', 'done', '--author', 'ada', '-o', 'toon' ],
            );
            1;
        } or $err = $@;
    }
    select $old;
    my $now = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );

    # The refusal only, never the success output. A successful move prints the
    # whole record as TOON, and that dump contains the card's questions - so
    # returning it either way let "the refusal names the question" pass off a
    # move that was never refused. Caught by it passing while the gate did not
    # exist at all.
    #
    # Keyed on whether the card actually moved rather than on $err, because
    # Tira::CLI->run catches the die and prints "error: ..." itself instead of
    # propagating it - so $err is empty even on a refusal, and returning only
    # $err threw away the text these assertions are about.
    #
    # And STDERR, because that is where Tira::CLI->run puts the refusal - it
    # catches the die and prints "error: ..." itself rather than propagating,
    # so $@ is empty and stdout holds nothing on a refused move.
    my $refused = $now->{column} ne 'done';
    return ( $now->{column}, $refused ? ( $err // '' ) . $said . $out : '' );
}

# --- an unanswered question does not gate anything ---------------------------
#
# question-unanswered is somebody else's job and a different rule. A card can
# be worked while it waits on the owner; that is the normal state of a question.

my ( $column, undef ) = move_out();
is( $column, 'done', 'an unanswered question does not stop the card moving - waiting on the owner is not the agent being sloppy' );

$tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref},
    column  => 'implement', author => 'ada',
);

# --- answered and unjudged: the card stays put -------------------------------

$tira->question_answer(
    project => $root, ref => $card->{ref}, id => $question->{id},
    author  => 'ada', text => 'The second way, and here is why.',
);

my ( $after_answer, $refusal ) = move_out();
is( $after_answer, 'implement',
    'a card carrying an answer nobody has judged does not leave the column it was answered in' );
like( $refusal, qr/\Q$question->{id}\E/,
    'and the refusal names the question, so the agent knows which answer it means' );
like( $refusal, qr/question\.mark/,
    'and names the command that settles it, rather than leaving the reader to find it' );

# --- a backward move is unconditional ----------------------------------------
#
# TKT-455's design: retreating undoes claims of progress rather than being
# blocked by them, because the thing left unmet may be exactly what the card is
# going back to fix. An unjudged answer is a particularly good reason to
# retreat - the person who would judge it may be why. The first version of this
# gate refused backward moves, and every assertion in this file passed, because
# none of them moved a card backward.

my $back_out = '';
{
    local $ENV{TIRA_HOME} = $root;
    open my $fh, '>', \$back_out or die $!;
    open my $eh, '>', \my $back_said or die $!;
    local *STDERR = $eh;
    my $old = select $fh;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $card->{ref},
                         '--column', 'backlog', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}
my $retreated = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is( $retreated->{column}, 'backlog',
    'a card carrying an unjudged answer can still be sent BACKWARD - the answer may be what it is retreating to reconsider' );

$tira->record_move(
    project => $root, type => 'ticket', ref => $card->{ref},
    column  => 'implement', author => 'ada',
);

# --- reading it is not judging it --------------------------------------------
#
# This is the whole point. question_list stamps read_at, and an agent that has
# read an answer has usually already acted on it. If reading released the gate,
# the gate would release itself on the way past and prove nothing.

$tira->question_list( project => $root, ref => $card->{ref} );
my ( $after_read, undef ) = move_out();
is( $after_read, 'implement',
    'reading the answer does not release the gate - reading is automatic, and a check that satisfies itself is not a check' );

# --- judging it releases the card --------------------------------------------

$tira->question_mark(
    project => $root, ref => $card->{ref}, id => $question->{id}, mark => 'ok',
);
my ( $after_mark, undef ) = move_out();
is( $after_mark, 'done', 'judging the answer lets the card move' );

# --- not-ok is a judgement too -----------------------------------------------
#
# The gate asks for a judgement, not for agreement. An answer marked not-ok has
# been read and assessed, which is what the card is for; TKT-457's rule that a
# cross on its own settles nothing is answer-not-ok-unresolved's job, not this
# gate's.

my $second = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card whose answer was rejected',
    author  => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $second->{ref},
    column  => 'implement', author => 'ada',
);
my $rejected = $tira->question_add(
    project => $root, ref => $second->{ref}, author => 'ada',
    text    => 'Is this the shape?', reason => 'it decides the build',
);
$tira->question_answer(
    project => $root, ref => $second->{ref}, id => $rejected->{id},
    author  => 'ada', text => 'No, and here is what instead.',
);
$tira->question_mark(
    project => $root, ref => $second->{ref}, id => $rejected->{id}, mark => 'not-ok',
);

my $out = '';
{
    local $ENV{TIRA_HOME} = $root;
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $second->{ref},
                         '--column', 'done', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}
my $rejected_card = $tira->record_show( project => $root, type => 'ticket', ref => $second->{ref} );
is( $rejected_card->{column}, 'done',
    'not-ok is a judgement and releases the card too - the gate wants an assessment, not agreement' );

# --- a discarded question is not an outstanding answer -----------------------

my $third = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card whose question was withdrawn',
    author  => 'ada',
);
$tira->record_move(
    project => $root, type => 'ticket', ref => $third->{ref},
    column  => 'implement', author => 'ada',
);
my $withdrawn = $tira->question_add(
    project => $root, ref => $third->{ref}, author => 'ada',
    text    => 'A question that stopped mattering', reason => 'it stopped mattering',
);
$tira->question_answer(
    project => $root, ref => $third->{ref}, id => $withdrawn->{id},
    author  => 'ada', text => 'Never mind.',
);
$tira->question_discard( project => $root, ref => $third->{ref}, id => $withdrawn->{id} );

my $discard_out = '';
{
    local $ENV{TIRA_HOME} = $root;
    open my $fh, '>', \$discard_out or die $!;
    my $old = select $fh;
    eval {
        Tira::CLI->run(
            command => 'record.move', tira => $tira,
            argv    => [ '--type', 'ticket', '--ref', $third->{ref},
                         '--column', 'done', '--author', 'ada', '-o', 'toon' ],
        );
    };
    select $old;
}
my $third_card = $tira->record_show( project => $root, type => 'ticket', ref => $third->{ref} );
is( $third_card->{column}, 'done',
    'a discarded question does not gate the card - a withdrawn question has no answer anybody owes a judgement on' );

done_testing();

__END__

=head1 NAME

t/407-an-answer-read-and-left-unjudged.t - a card does not leave the column an
answer was given in until that answer has been judged

=head1 DESCRIPTION

Reading an answer is automatic; judging one is a deliberate act nothing asks
for until C<answer-unjudged> fires hours later, by which time the work is
finished. These assertions move the prompt to the moment it belongs to: the
card cannot leave the column its answer was given in while that answer carries
no mark.

The gate reads the question's own C<mark> rather than a required-action item
standing in for it, which is TKT-584's third acceptance criterion - an item an
agent can tick without judging would be an acknowledgement clicked through,
and there would be nothing to stop it being ticked in the same breath as
everything else.

Four things are deliberately NOT gated: an unanswered question, because waiting
on the owner is the normal state of one; a discarded question, which nobody
owes a judgement on; an answer marked C<not-ok>, because the gate wants an
assessment rather than agreement; and reading, which happens on the way past
and would release the gate without anybody deciding anything.

=cut
