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
# AND HIDING A ROW IS NOT THE WHOLE OF IT, which the first version of this file
# missed and the card's own walkthrough caught. The save skipped a field whose
# row was hidden, and job_update merges what a payload does not mention with
# what the record holds - so a monitor with an interval, switched to cron, had
# its own interval merged back in and refused. Hiding the row took away the
# untick that used to be the way out. The engine section below measures that on
# a real board before the assertions about the save are made.
#
# WRITTEN RED, twice.

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

    # $@ read immediately and matched rather than merely counted, which is
    # t/149's rule: ok(!eval{...}) passes against a typo in an argument name,
    # and the assertion would then be hiding the failure it looks like it
    # catches.
    like( $@, qr/cron job fires on a tick/,
        'THE SAVE REFUSES A RESTART INTERVAL ON A CRON JOB, and refuses it by '
          . 'name. That is the premise of this whole card: the form is offering '
          . 'something the engine will not take, with a reason a person can '
          . 'read - so this is a form that forgot a rule rather than a rule '
          . 'worth adding' );

    ok( $refused, 'and nothing was stored' );
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

# --- and what happens when a monitor is turned into a cron job ----------------
#
# THE CARD'S OWN TEST STEP, walked against the engine: "set restart-every on a
# monitor, switch the schedule to cron, and confirm the control cannot be set".
# It is the half that hiding a row does not answer by itself, and it is where
# the first version of this fix made things WORSE than it found them.
#
# job_update validates the job as it WOULD be, merging what the payload does not
# mention with what the record already holds. That is deliberate and right - an
# edit naming only the command must not silently drop how often a monitor said
# it would speak. But the save omits a field whose row is hidden, on the same
# "absent means leave it alone" reasoning, and the two together turn "the user
# cannot set it" into "the stored value is carried into a kind that refuses it".

my $switching = $tira->job_add( project => $root, schedule => 'monitor',
    command => 'a-third-poller', restart_every => 5, expect_every => 10,
    author => 'claude' );

is( $switching->{restart_every}, 5, 'a monitor with an interval' );
is( $switching->{expect_every},  10, 'and an expectation - the control, since '
      . 'both are about to be carried across a kind change' );

{
    my $saved = eval {
        $tira->job_update( project => $root, id => $switching->{id},
            schedule => '0 * * * *', author => 'claude' );
    };
    my $why = $@ // '';

    like( $why, qr/nothing to restart/,
        'A PAYLOAD THAT MENTIONS ONLY THE SCHEDULE IS REFUSED, which is exactly '
          . 'what the editor sends once the loop row is hidden. The interval is '
          . 'merged from the record into a cron job and the engine will not '
          . 'have it - so the save fails over a control that is no longer on '
          . 'screen, and before this card it could at least be unticked' );

    ok( !$saved, 'and nothing was written' );
}

{
    my $saved = eval {
        $tira->job_update( project => $root, id => $switching->{id},
            schedule => '0 * * * *', restart_every => undef, author => 'claude' );
    };
    my $why = $@ // '';

    like( $why, qr/no heartbeat to miss/,
        'AND THE SAME TRAP IS ALREADY THERE ON THE OTHER FIELD. expectRow has '
          . 'always been hidden for a cron job, so a monitor with an '
          . 'expectation could never be turned into one from the page at all - '
          . 'it died here before this card existed. One mechanism, used twice' );

    ok( !$saved, 'and nothing was written for that one either' );
}

{
    my $saved = eval {
        $tira->job_update( project => $root, id => $switching->{id},
            schedule => '0 * * * *', restart_every => undef,
            expect_every => undef, author => 'claude' );
    };

    is( ( $saved || {} )->{schedule_kind}, 'cron',
        'WITH BOTH SENT AS EXPLICIT NULLS THE SAVE GOES THROUGH - so what the '
          . 'page owes is a null rather than a silence. Hidden means precisely '
          . '"the engine refuses this field for this kind", which is why '
          . 'clearing it cannot wipe anything that was allowed to stay' );

    is( ( $saved || {} )->{restart_every}, undef, 'the interval is cleared' );
    is( ( $saved || {} )->{expect_every},  undef, 'and so is the expectation' );
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
like( $editor, qr/loopBox\.checked\s*\?\s*Number\(\s*loopEvery\.value\s*\)/,
    'and the controls themselves still exist to be read on save - hiding a row '
      . 'must not become deleting what the payload is built from' );

# --- and the save says so out loud --------------------------------------------
#
# The other half of the fix, and the half the first version of this card got
# wrong. The engine calls above prove that omitting these fields is not
# neutral: the record's own value is merged in and refused. So a hidden row
# must send an explicit null.

my ($save) = $editor =~ /(const \s payload \s* = .*? \n \s{4} \})/xs;

ok( defined $save && length $save,
    'the save payload was extracted - the region that decides which fields go '
      . 'to the engine at all' );

like( $save // '', qr/loopRow\.hidden\s*\n?\s*\?\s*null/,
    'A HIDDEN LOOP ROW SENDS NULL RATHER THAN NOTHING. Today the save skips the '
      . 'field entirely when the row is out of play, and job_update then merges '
      . 'the stored interval into a cron job and refuses it - a failure about a '
      . 'control the user cannot see, where before this card they could at '
      . 'least untick it' );

like( $save // '', qr/expectRow\.hidden\s*\n?\s*\?\s*null/,
    'AND SO DOES A HIDDEN EXPECTATION ROW. That row has been hidden for a cron '
      . 'job since it was written, so a monitor that declared how often it '
      . 'speaks could never be turned into a cron job from the page at all. '
      . 'Same mechanism, same fix, and fixing only the loop half would leave a '
      . 'form that still cannot make the change' );

like( $save // '', qr/loopBox\.checked\s*\?\s*Number/,
    'and a row that IS in play still sends what the controls hold, ticked or '
      . 'unticked - the null is what hidden means, not what the field is worth' );

like( $save // '', qr/expectField\.value\s*===\s*""\s*\?\s*null/,
    'with an empty expectation still meaning no expectation rather than zero, '
      . 'which is his Q-115 answer and is untouched by any of this' );

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

Then B<what hiding a row obliges the save to do>, which is the half the first
version of this fix got wrong. C<job_update> validates the job as it I<would>
be, merging fields the payload does not mention with what the record holds - so
omitting a hidden field carries a stored interval into a cron job, where the
engine refuses it. The save must send an explicit C<null>. That is asserted for
B<both> rows: the expectation row has been hidden for a cron job since it was
written, so a monitor that declared how often it speaks could never be turned
into a cron job from the page at all.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered row disappears. This suite reads F<jobs-editor.js> as source
the way F<t/500>, F<t/508>, F<t/510>, F<t/517>, F<t/528>, F<t/530> and F<t/533>
do; it drives no browser, and browser tests are his.

The editor assertions are scoped to the extracted C<applyKind> region, because
C<modeCommand>, C<loopRow> and C<monitoring> all occur elsewhere in the file and
a whole-file match would pass against today's code.

=cut
