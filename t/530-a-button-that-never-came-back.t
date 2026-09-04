#!/usr/bin/env perl
# The Save button is dead for every monitor.
#
# TKT-912, EPC-014. His report: "If selected monitor, you don't need to show the
# Command radio button since there is only 1 option to select and after filled in
# the command, the save button still cannot be clicked."
#
# THE SECOND HALF IS THE BLOCKING ONE and it is not a validation rejecting the
# form. It is a validation that never finishes. lib/Tira/views/jobs-editor.js:
#
#   const judge = () => {
#     const schedule = kindMonitor.checked ? "monitor" : field.value;
#     save.disabled = true;
#     ...
#     pending = window.setTimeout(() => {
#       post("/jobs/check", { schedule: schedule })
#         .then((answer) => {
#           if (field.value !== schedule) {
#             return;                        <-- LEAVES save.disabled TRUE
#           }
#
# THE GUARD COMPARES TWO DIFFERENT THINGS. It exists to throw away an answer
# that arrived after the user typed something newer, and for a cron job it is
# right: `schedule` IS `field.value`, so they match unless the box changed while
# the request was in flight.
#
# Tick Monitor and `schedule` becomes the literal string "monitor" while
# `field.value` is still whatever the schedule box holds - empty, or the cron
# text that was there before. They can never match. The callback returns on its
# first line every time, and `save.disabled = false` sits below it and never
# runs. So the button is dead from the first keystroke, whatever else is filled
# in, for every monitor.
#
# THE FIX IS TO ASK THE QUESTION THE GUARD MEANT: recompute the input the same
# way it was built, and compare that. For a cron job it is byte-for-byte today's
# behaviour, which is why the control below matters as much as the claim.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

# The editor is read as source, the way t/500, t/508, t/510, t/517 and t/528 all
# read it: this suite drives no browser and browser tests are his. A source
# assertion can be satisfied by code that compares the right things and still
# renders wrongly, and saying so is worth more than implying otherwise.
my $editor = do {
    open my $fh, '<:encoding(UTF-8)', 'lib/Tira/views/jobs-editor.js'
      or die "jobs-editor.js: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: an unreadable file would fail every assertion
# below for a reason that has nothing to do with the button.
ok( length $editor, 'the jobs editor was read' );

# --- the validator region ----------------------------------------------------
#
# SCOPED, and for a reason this suite has been bitten by twice. `field.value`
# and `schedule` both occur elsewhere in this file; a whole-file match would
# pass today and prove nothing, which is what t/523 did this morning and what
# t/528's comment warns about.

my ($judge) = $editor =~ /(const \s judge \s* = .*? \n \s* \};)/xs;

ok( defined $judge && length $judge,
    'the judge() validator was extracted - the function that disables Save '
      . 'while a schedule is being checked and is supposed to re-enable it' );

like( $judge // '', qr/save\.disabled\s*=\s*true/,
    'and it is the right region: it is what turns the button OFF, so it is '
      . 'what has to turn it back on' );

like( $judge // '', qr/save\.disabled\s*=\s*Boolean\(\s*bad\s*\)/,
    'and it contains the line that re-enables it - '
      . '`save.disabled = Boolean(bad) || !commandField.value.trim()`, which '
      . 'sits BELOW the early return and never runs for a monitor today. Not '
      . '`= false`: the button comes back only when the schedule parsed AND a '
      . 'command has been typed, which is the behaviour that must survive' );

# Comments are source too, so a comment QUOTING the old line fails this - which
# happened while fixing it, and is the same "assertion matched prose, not code"
# trap t/523 fell into this morning wearing the other coat. The fix's own
# comment now describes the old comparison in words rather than reproducing it.
unlike( $judge // '', qr/if\s*\(\s*field\.value\s*!==\s*schedule\s*\)/,
    'THE STALE-ANSWER GUARD NO LONGER COMPARES A LITERAL WITH A TEXT BOX. '
      . 'Today it is `if (field.value !== schedule) return;` while `schedule` '
      . 'was built as `kindMonitor.checked ? "monitor" : field.value` - so '
      . 'under Monitor the two can never be equal, the callback returns on its '
      . 'first line, and Save is never re-enabled' );

# The guard must still EXIST. Deleting it would fix the button by removing the
# protection it was written for: an answer about a schedule the user has since
# retyped would then paint its verdict onto the new text. That is a worse bug
# than the one being fixed and it would look like a pass here.
like( $judge // '', qr/return;/,
    'the guard is still there - a fix that simply deleted the early return '
      . 'would let a stale verdict paint itself onto a schedule the user has '
      . 'since retyped, which is what the guard was written for' );

like( $judge // '', qr/kindMonitor\.checked[^\n]*\n?[^\n]*!==|!==[^\n]*kindMonitor\.checked/,
    'AND IT ASKS THE QUESTION IT MEANT - "has the input changed since this '
      . 'request went out" - by recomputing the value the same way it was '
      . 'built, so the monitor case compares "monitor" with "monitor" instead '
      . 'of with an empty box' );

# --- and the mode radio is not offered for a monitor -------------------------
#
# The other half of his report, and the smaller one. A monitor cannot be
# message-mode: the engine refuses that pairing, because a monitor with no
# command could never be found alive in the process table. So the group offers
# one real choice and reads as an unanswered question.

my ($form) = $editor =~ /(const \s modeRow \s* = .*? const \s judge)/xs;

ok( defined $form && length $form,
    'the form region between the mode radio and the validator was extracted' );

like( $form // '', qr/modeRow\.hidden/,
    'THE MODE ROW IS HIDDEN WHEN THE JOB IS A MONITOR. His words: "you do not '
      . 'need to show the Command radio button since there is only 1 option to '
      . 'select". The file already hides loopRow and expectRow exactly this '
      . 'way when the control that owns them is not in play' );

# The row must be hidden, not removed, and the radios must still exist - the
# save path reads modeMessage.checked, and a form that deleted them would send
# a payload built from an undefined control.
like( $editor, qr/modeMessage\.checked/,
    'and the radios still exist to be read on save - hiding the row must not '
      . 'become deleting the control the payload is built from' );

done_testing();

__END__

=head1 NAME

530-a-button-that-never-came-back.t - Save stays disabled for every monitor

=head1 WHY

TKT-912. C<judge()> in F<lib/Tira/views/jobs-editor.js> disables Save while it
asks the server whether the schedule parses, then discards the answer when
C<field.value !== schedule>. C<schedule> was built as
C<kindMonitor.checked ? "monitor" : field.value>, so under Monitor the two are
never equal, the callback returns on its first line, and C<save.disabled = false>
never runs. The button is dead from the first keystroke for every monitor.

His report: I<"after filled in the command, the save button still cannot be
clicked">.

=head1 WHAT IS ASSERTED

That the guard no longer compares a literal against the schedule box, that it
still exists at all - deleting it would let a stale verdict paint itself onto a
retyped schedule, which is the fault it was written for - and that it recomputes
the value the same way it was built.

Then that the mode row is hidden for a monitor, and that the radios themselves
still exist, since the save payload reads C<modeMessage.checked>.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered button is clickable. This suite reads C<jobs-editor.js> as
source the way F<t/500>, F<t/508>, F<t/510>, F<t/517> and F<t/528> do; it drives
no browser, and browser tests are his. Code that compares the right things can
still render wrongly, and the honest limit is written here rather than implied.

The assertions are scoped to two extracted regions because C<field.value> and
C<schedule> occur elsewhere in the file, and a whole-file match would pass today.

=cut
