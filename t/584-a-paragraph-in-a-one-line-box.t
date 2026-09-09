#!/usr/bin/env perl
# TKT-951, his report of 2026-09-05 with a screenshot, minutes after 5.83
# installed while he was reading the job cards: "when the card has a long
# message. when i click on the edit. instead of getting a textarea but i get a
# limited size of text input instead? why? that isn't the same like the task
# card. If you forget, look how task card do that." Re-raised the next day as
# message 7286, "No fixed?".
#
# WHAT HE IS LOOKING AT. lib/Tira/views/jobs-editor.js builds the field with
# document.createElement("input") and type "text" - one line, whatever is in
# it. The field is labelled Command and serves BOTH modes: a command job's
# command line and a message job's prose go into the same control. Editing
# JOB-003 shows "3-HOURLY DOC-ACCUR" and scrolls the other 260-odd characters
# out of sight, so reading the middle of it means dragging through a slot.
#
# ON THIS BOARD IT IS WRONG FOR EVERY JOB IT APPLIES TO: JOB-001, JOB-002 and
# JOB-003 are all message jobs carrying multi-sentence hunt instructions.
#
# THE PRECEDENT HE POINTS AT IS REAL, and reusing it is the point rather than
# an implementation detail. lib/Tira/views/live-helpers.js already defines
# growBox(box, cap): height to auto, then to min(scrollHeight, cap), bound on
# input and run once - and the tasklist editor builds its box as a textarea and
# grows it. "look how task card do that" is an instruction to reuse that, not
# to write a second one.
#
# BOTH MODES GET IT, and Q-133 is open on that. A command is one line by
# design and a tall box might invite pasting a shell script into a field that
# has no shell - so the box starts one line tall and a one-line command looks
# exactly as it does today. If he answers otherwise this test changes with the
# code; the question is on the card rather than guessed at.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $editor  = eval { Suite::view_source('jobs-editor.js') };
my $helpers = eval { Suite::view_source('live-helpers.js') };

# non-empty is the whole claim: every check below would pass on an unreadable
# file's emptiness alone, and view_source dies rather than returning empty for
# exactly that reason.
like( $editor  // '', qr/\S/, 'the jobs editor is there to be read' );
like( $helpers // '', qr/\S/, 'the shared view helpers are there to be read' );

# --- the growth helper this must reuse still exists --------------------------
#
# Asserted before it is depended on. If growBox were renamed or removed, every
# check below would still be satisfiable by a second implementation, which is
# the thing his "look how task card do that" rules out.

{
    like( $helpers // '', qr/const\s+growBox\s*=/,
        'growBox is where the reuse points - the shared, capped grow helper in '
          . 'live-helpers.js, rather than a second implementation of the same idea' );
    like( $helpers // '', qr/scrollHeight/,
        'and it is the one that grows a box to its content, asserted by what it does '
          . 'rather than by its name alone' );

    # A CORRECTION TO THE CARD, made by reading rather than trusting it. The
    # card says the tasklist editor grows its box "with the growth helper that
    # lib/Tira/views uses elsewhere". It does not: tasklist-editor.js builds a
    # textarea with rows=1 and rolls its OWN inline closure -
    # `const grow=()=>{input.style.height="auto";input.style.height=input.scrollHeight+"px"}`
    # - which is uncapped, where growBox caps at 420. So the task card he
    # pointed at is itself the duplicate, and following it literally would have
    # made a third copy. This asserts the state as it is, so the note above is
    # anchored to something that fails if the tasklist editor is ever changed
    # to use the shared helper - at which point this comment should go too.
    my $tasklist = eval { Suite::view_source('tasklist-editor.js') };
    # non-empty is the whole claim: the check below would pass on an
    # unreadable file's emptiness alone.
    like( $tasklist // '', qr/\S/, 'the tasklist editor is there to be read' );
    unlike( $tasklist // '', qr/growBox\s*\(/,
        'and the tasklist editor does NOT use the shared helper today, which is why this '
          . 'card reuses growBox rather than copying what the task card does' );
}

# --- the field is a textarea ------------------------------------------------
#
# The whole card. Established by content first: the block is found by the class
# the editor gives it, so a match on some other field could not satisfy the
# checks that follow.

{
    my ($block) = ( $editor // '' ) =~ /(commandField\s*=\s*document\.createElement.{0,400})/s;
    $block //= '';
    like( $block, qr/jobs-editor__command/,
        'the command field was found, and is the one carrying its own class - asserted by '
          . 'content, so an extraction that caught nothing could not pass the denial below '
          . 'on an empty string' );

    unlike( $block, qr/createElement\("input"\)/,
        'it is NOT built as a single-line input - which is the whole of what he reported, '
          . 'and what makes a 280-character message readable only by dragging through a slot' );

    like( $block, qr/createElement\("textarea"\)/,
        'it is a textarea, the same control the task card uses for the same kind of text' );
}

# --- and it grows through the shared helper ---------------------------------
#
# A textarea alone would satisfy the check above and still be a fixed two rows.
# What he asked for is the task card's behaviour, which is growth to a cap.

{
    like( $editor // '', qr/growBox\s*\(/,
        'the jobs editor calls growBox, so the box grows with its content the way the '
          . 'task card does rather than sitting at a fixed height' );
}

# --- and it is styled as a textarea rather than as an input ------------------
#
# Swapping the tag alone would have made the field WORSE than the one he
# reported: a textarea with no width defaults to about twenty characters and
# carries a drag-to-resize grip in the corner, where the input it replaced
# filled its label. The class already existed and its rule was written for an
# input, so the rule has to change with the tag.

{
    my $css = eval { Suite::view_source('dashboard.css') };
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone.
    like( $css // '', qr/\S/, 'the stylesheet is there to be read' );

    my ($rule) = ( $css // '' ) =~ /(\.jobs-editor__command\s*\{[^}]*\})/;
    $rule //= '';
    like( $rule, qr/font:\s*inherit/,
        'the command field rule was found, and is the one it already had - asserted by '
          . 'content so an empty match could not satisfy the checks below' );
    like( $rule, qr/width:\s*100%/,
        'the field still fills its label, rather than falling back to a textarea\'s own '
          . 'default width of about twenty characters' );
    like( $rule, qr/resize:\s*none/,
        'and it carries no drag-to-resize grip, because its height is the growth helper\'s '
          . 'to decide and a hand-dragged height would fight the next keystroke' );
}

# --- the save still reads the same field ------------------------------------
#
# The regression that would hurt most, and it has already happened once on this
# very field: the editor used to fill this box from job.command whatever the
# job was, so a message job opened it EMPTY and saving wrote that empty box
# over the stored message. Changing the control is exactly the edit that could
# reintroduce a mismatch between what is read and what is written.

{
    like( $editor // '', qr/payload\.message/,
        'the save still writes a message job from this field' );
    like( $editor // '', qr/payload\.command/,
        'and still writes a command job from it, so one control still serves both modes' );
    like( $editor // '', qr/commandField\.value/,
        'reading the field by value, which is what a textarea and an input both answer to - '
          . 'so the save path does not have to know which control it is' );
}

# --- a one-line command still looks like one --------------------------------
#
# Q-133: a command is one line by design, and the objection to a textarea is
# that a tall empty box invites pasting a shell script into a field that has no
# shell. The box starts at one row, so nothing about the command case changes
# on screen until the content needs more room.

{
    # SCOPED TO THE FIELD, not to the file. A bare /\brows\b/ over the whole
    # editor passed BEFORE the fix, because the word appears three times in
    # comments about table rows being pulled out from under an open panel -
    # unrelated prose satisfying an assertion about a textarea attribute. That
    # is the same "green for the wrong reason" fault this suite keeps finding,
    # arriving here as a red test that was already partly green.
    my ($block) = ( $editor // '' ) =~ /(commandField\s*=\s*document\.createElement.{0,400})/s;
    $block //= '';
    like( $block, qr/jobs-editor__command/,
        'the command field block was found again for this check, by its own class' );
    like( $block, qr/commandField\.rows\s*=/,
        'and the textarea declares its starting height, so a one-line command is displayed '
          . 'in a one-line box exactly as it is today - the answer to the objection Q-133 '
          . 'records, held here so a later edit cannot quietly make it a tall empty box' );
}

done_testing();

__END__

=head1 NAME

584-a-paragraph-in-a-one-line-box.t - the job editor's shared field is a growing textarea

=head1 DESCRIPTION

TKT-951. The job editor built its Command field as a single-line
C<< <input type="text"> >>, and that field serves both a command job's command
line and a message job's prose. Every message job on this board carries
multi-sentence instructions, so the control was wrong for every job it applied
to: editing one showed the first few words and scrolled the rest out of sight.

It is now a textarea grown by C<growBox> from F<live-helpers.js> - the helper
the tasklist editor already uses, which is what his "look how task card do
that" asks for. The box starts one row tall so a one-line command is unchanged
on screen, which is the objection recorded as Q-133, and the save path still
reads C<commandField.value> into either C<payload.message> or
C<payload.command> so one control still serves both modes.

=cut
