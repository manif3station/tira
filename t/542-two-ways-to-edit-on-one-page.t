#!/usr/bin/env perl
# A job is edited in a second card; a task is edited on its own.
#
# TKT-913, EPC-014. His words: "When I edit, Why a separated card pop next to it
# as an editor and not on the actual card itself like the task card?"
#
# HE IS COMPARING IT TO SOMETHING THAT ALREADY WORKS ON THIS PAGE, which is what
# makes this a consistency defect rather than a preference. The tasklist card
# becomes its own editor - textEl.replaceChildren(input), Enter settles, Escape
# restores - and the jobs editor builds a separate panel and inserts it beside
# the card, so a reader looks at one object and types into another.
#
# THE QUESTION WAS ASKED, ANSWERED, AND IS NOW BEING OVERRULED. TKT-880 raised
# it, TKT-892 absorbed it, and the answer is written at the point of insertion:
#
#   "a heading, two radio pairs, a schedule, a command, a looping row and an
#    expectation. That is too much to inline into a card row the way a tasklist
#    card edits itself, so it stays a panel."
#
# with the compromise that the panel opens directly beneath its card rather than
# at the foot of the section. He has seen that result and asked the same
# question again, which is a rejection of the compromise rather than a repeat of
# the question - and the prior reasoning was about SIZE, which is a layout
# problem rather than a reason to keep two idioms on one page.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $jobs = Suite::view_source('jobs-editor.js');
my $tasks = Suite::view_source('tasklist-editor.js');

ok( length $jobs && length $tasks, 'both editors were read' );

# --- what a task does, which is the model he named ---------------------------
#
# The control, and it must keep passing: this card changes the jobs editor to
# match the task editor, so a change that made them match by moving the TASK
# editor would satisfy every claim below and break the thing he likes.

like( $tasks, qr/replaceChildren\(\s*input\s*\)/,
    'A TASK CARD BECOMES ITS OWN EDITOR - the card\'s own element takes the '
      . 'input, so there is one object on screen and it is the one being '
      . 'edited. That is the model he named and it is unchanged by this card' );

like( $tasks, qr/Escape/,
    'and Escape restores it, so editing is not a one-way door' );

# --- what a job does today ---------------------------------------------------

my ($open) = $jobs =~ /(const \s openEditor \s* = .*?\n \s{2} \};)/xs;

ok( defined $open && length $open,
    'the jobs editor\'s open function was extracted' );

# THE CLAIM.
unlike( $open // '', qr/insertBefore\(\s*panel/,
    'A JOB IS NOT EDITED IN A SECOND CARD BESIDE ITS OWN. Today openEditor '
      . 'builds a panel and inserts it after the card - so the job is on one '
      . 'element and the form is on another, which is exactly what he is '
      . 'asking about. TKT-892 kept it deliberately and moved it next to the '
      . 'card instead; he has seen that and asked again' );

like( $open // '', qr/is-editing/,
    'THE CARD ITSELF CARRIES THE EDITOR, marked on the card element the way a '
      . 'tasklist card marks itself - so what a reader clicked and what they '
      . 'are typing into are one object' );

# AND IT MUST COME BACK. A card that becomes an editor and cannot become a card
# again is worse than a panel: the panel at least closed.
like( $jobs, qr/closeEditor/,
    'cancelling still restores the card rather than leaving it a form - the '
      . 'assertion that stops an in-place editor being a one-way door' );

# --- and the form is the same form -------------------------------------------
#
# Controls, all of them green before this card. Moving where the editor lives
# must not change what it contains, and every one of these was settled by a
# card of its own: the schedule-kind radio (TKT-892), the mode radio hidden
# under Monitor (TKT-912), the loop row for a command-mode monitor only
# (TKT-911), and the save that sends null for a hidden row (TKT-911 again).

like( $jobs, qr/kindMonitor/, 'the schedule-kind radio survives' );
like( $jobs, qr/modeRow\.hidden = monitoring/,
    'and the mode row is still hidden under Monitor - TKT-912' );
like( $jobs, qr/looping\s*=\s*monitoring\s*&&/,
    'and the loop row is still for a command-mode monitor only - TKT-911' );
like( $jobs, qr/loopRow\.hidden\s*\n?\s*\?\s*null/,
    'and a hidden row still sends null rather than nothing, so switching a '
      . 'monitor to cron still saves - TKT-911' );

done_testing();

__END__

=head1 NAME

542-two-ways-to-edit-on-one-page.t - a job's editor, on the job's own card

=head1 WHY

TKT-913, his own report: I<"When I edit, Why a separated card pop next to it as
an editor and not on the actual card itself like the task card?">

The tasklist card becomes its own editor; the jobs editor builds a panel and
inserts it beside the card. Two idioms on one page means the newer one has to be
learned, and it exists because it was built later rather than because it is
better.

The question was asked before (TKT-880), answered by TKT-892 - the form is too
big to inline - and softened by opening the panel beneath its card. He has seen
that and asked again, which overrules it: the objection was about size, and size
is a layout problem.

=head1 WHAT IS ASSERTED

That the task editor still edits in place, because a change that made the two
match by moving the B<task> editor would satisfy everything else here and break
what he likes. Then that a job is no longer edited in a panel inserted beside
its card, that the card itself carries the editor, and that cancelling still
restores it.

Then four controls, each settled by a card of its own, that the form's contents
are unchanged: the schedule-kind radio, the mode row hidden under Monitor, the
loop row for a command-mode monitor only, and a hidden row sending null.

=head1 WHAT IS NOT ASSERTED

That it looks right. This suite drives no browser; browser checks are his.

=cut
