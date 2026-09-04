#!/usr/bin/env perl
# The jobs editor offers a restart interval on a cron job, and the save refuses it.
#
# TKT-911, EPC-014. Not a report - found reading the editor while TKT-912 was
# being fixed, and it is the same shape: a control that has nothing to decide.
#
# THE CONDITION FORGOT THE KIND. lib/Tira/views/jobs-editor.js, applyKind():
#
#   const looping = modeCommand.checked && !modeMessage.checked;
#   loopRow.hidden = !looping;
#
# It excludes a MESSAGE job, and the engine agrees with it there: "A loop can
# only wrap a command - a message job announces its text and runs nothing, so
# there is nothing to restart". It says nothing about a CRON job, and the engine
# refuses that just as plainly, two lines earlier in Tira::Job::_job_fields:
#
#   die "Restarting belongs to a 'monitor' job - a cron job fires on a tick
#        rather than staying up, so there is nothing to restart\n"
#     if $kind ne 'monitor';
#
# So on a cron job with a command the row is on screen, the checkbox ticks, the
# seconds field takes a number - and the save dies with that sentence. The form
# offers what the save refuses.
#
# HIDDEN RATHER THAN DISABLED, following TKT-912 rather than the schedule field.
# The schedule box is disabled-with-a-reason so the form keeps its shape as
# somebody clicks through it; TKT-912 narrowed that this morning, on his own
# words about the Command radio - a control with only one possible answer is not
# shape, it is noise. A loop interval on a cron job has one possible value.
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
use Tira::Job;

# --- the engine's own answer, first ------------------------------------------
#
# THE PREMISE, MEASURED RATHER THAN QUOTED. Every assertion below is only worth
# making if the save really would refuse what the form offers. If the engine
# ever started accepting a restart interval on a cron job, this file would be
# arguing for hiding a control that works.

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Loop', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'LFS', epic_prefix => 'LFE', ticket_prefix => 'LFT',
    );
}

{
    my $refused = !eval {
        $tira->job_add( project => $root, schedule => '*/30 * * * *',
            command => 'a-cron-job', restart_every => 5, author => 'claude' );
        1;
    };
    my $why = $@ // '';

    ok( $refused,
        'THE SAVE REFUSES A RESTART INTERVAL ON A CRON JOB. That is the premise '
          . 'of this whole card: the form is offering something the engine will '
          . 'not take' );

    like( $why, qr/cron job fires on a tick/,
        'and refuses it by name, with a reason a person can read - which is why '
          . 'this is a form that forgot a rule rather than a rule worth adding' );
}

{
    my $accepted = eval {
        $tira->job_add( project => $root, schedule => 'monitor',
            command => 'a-poller', restart_every => 5, author => 'claude' );
    };

    is( ( $accepted || {} )->{restart_every}, 5,
        'and accepts one on a MONITOR - the control belongs somewhere, so this '
          . 'card is about where it is shown and not about removing it' );
}

# --- the editor ---------------------------------------------------------------
#
# Source-read, the way t/500, t/508, t/510, t/517, t/528, t/530 and t/533 all
# read this file: the suite drives no browser and browser tests are his. A
# source assertion can be satisfied by code that decides correctly and still
# renders wrongly, and saying so is worth more than implying otherwise.

my $editor = do {
    open my $fh, '<:encoding(UTF-8)', 'lib/Tira/views/jobs-editor.js'
      or die "jobs-editor.js: $!";
    local $/;
    <$fh>;
};

ok( length $editor, 'the jobs editor was read' );

# SCOPED to applyKind, for the reason t/530's comment gives and t/523 learned
# the hard way: modeCommand, loopRow and monitoring all occur elsewhere in this
# file, and a whole-file match would pass today and prove nothing.
my ($apply) = $editor =~ /(const \s applyKind \s* = .*? \n \s{4} \};)/xs;

ok( defined $apply && length $apply,
    'applyKind() was extracted - the function that decides which controls are '
      . 'in play for the kind of job being edited' );

like( $apply // '', qr/loopRow\.hidden\s*=/,
    'and it is the right region: it is what shows and hides the loop row' );

like( $apply // '', qr/const\s+monitoring\s*=\s*kindMonitor\.checked/,
    'and it already knows which kind is selected - the fact the loop line '
      . 'needs is sitting three lines above it' );

# THE CLAIM.
like( $apply // '', qr/looping\s*=\s*monitoring\s*&&/,
    'THE LOOP ROW IS FOR MONITORS ONLY. Today the condition is '
      . '`modeCommand.checked && !modeMessage.checked`, which excludes a '
      . 'message job because the engine refuses a loop there - and forgets that '
      . 'the engine refuses one on a cron job in the very next breath. So a '
      . 'cron job shows a checkbox and a seconds field whose use is rejected on '
      . 'save' );

# THE CONTROL, and the one that stops this fix going too far. `looping =
# monitoring` alone would hide the row for a message-mode job too - except that
# a message job can never be a monitor, so the assertion above would pass while
# the mode test quietly disappeared. It matters for a MESSAGE job on a cron
# schedule, which is a real and common job on this board.
like( $apply // '', qr/looping\s*=[^\n;]*modeCommand\.checked/,
    'AND STILL FOR COMMAND MODE ONLY. A fix that reduced the condition to the '
      . 'kind alone would offer a restart interval on a cron MESSAGE job, which '
      . 'the engine refuses for its own separate reason - "a message job '
      . 'announces its text and runs nothing"' );

like( $apply // '', qr/looping\s*=[^\n;]*!modeMessage\.checked/,
    'both halves of the mode test survive, not just the one named in the line '
      . 'above - they are separate controls and either can be the checked one' );

# The row must be HIDDEN rather than removed, for the same reason TKT-912 gave
# about the mode radios: the save path reads the controls inside it.
like( $editor, qr/if\s*\(\s*!loopRow\.hidden\s*\)/,
    'and the save still asks whether the row is in play before sending an '
      . 'interval - which is what makes hiding it sufficient: a cron job stops '
      . 'sending restart_every at all rather than sending a null the engine '
      . 'would have to forgive' );

like( $editor, qr/loopBox\.checked\s*\?\s*Number\(\s*loopEvery\.value\s*\)/,
    'and the controls themselves still exist to be read on save - hiding a row '
      . 'must not become deleting what the payload is built from' );

done_testing();

__END__

=head1 NAME

536-a-loop-offered-where-it-is-refused.t - the restart row on a cron job

=head1 WHY

TKT-911. C<applyKind()> in F<lib/Tira/views/jobs-editor.js> shows the
"Restart when it ends, every N seconds" row whenever the job is in command mode,
without asking whether it is a B<monitor>. On a cron job the row is on screen and
the save dies: C<Tira::Job::_job_fields> refuses a restart interval there by name
- I<"a cron job fires on a tick rather than staying up, so there is nothing to
restart">.

The same condition already excludes a B<message> job, for the engine's other
refusal. It is one rule applied and its neighbour forgotten.

=head1 WHAT IS ASSERTED

First the premise, measured rather than quoted: that the engine really does
refuse an interval on a cron job and really does accept one on a monitor. Then
that C<looping> tests the kind, that it B<still> tests the mode - a fix reduced
to the kind alone would offer the row on a cron message job, which the engine
refuses for its own separate reason - and that the row is hidden rather than
removed, since the save path reads the controls inside it.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered row disappears. This suite reads F<jobs-editor.js> as source
the way F<t/500>, F<t/508>, F<t/510>, F<t/517>, F<t/528>, F<t/530> and F<t/533>
do; it drives no browser, and browser tests are his.

The editor assertions are scoped to the extracted C<applyKind> region, because
C<modeCommand>, C<loopRow> and C<monitoring> all occur elsewhere in the file and
a whole-file match would pass against today's code.

=cut
