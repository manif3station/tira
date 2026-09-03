#!/usr/bin/env perl
# A monitor declaring how often it expects to speak, so silence can be judged.
#
# TKT-863, EPC-014, second half. The first half - the heartbeat element, the lit
# state and the dim never-spoken state - is committed in cce9f1d and asserted by
# t/508. This is what his answer to Q-115 added.
#
# THE QUESTION, AND WHY IT HAD TO BE ASKED. A monitor has no cadence anywhere in
# the record: its schedule field is the literal string 'monitor'. So "silent too
# long" had no source. And the only real monitor on this board, JOB-005
# (d2 is-agent-sleeping), is legitimately quiet for over an hour at a stretch
# because it speaks only when the owner has gone away - so any short constant
# would paint it red most of the day, and a light that is usually red is one
# nobody reads. That is the failure monitor-dead was written carefully to avoid.
#
# HIS ANSWER, 2026-09-03 19:01, option 1 of four: "Each monitor declares its own
# expectation when it is created - a field like 'expect a line every N minutes',
# empty meaning no expectation and a dim light."
#
# So the threshold is per-job and explicit, and JOB-005 simply declares nothing
# and stays dim rather than being judged by a number that never fitted it.
#
# WHAT THIS MAKES THE CARD. Until his answer this was a view change - KD2 says
# the field it needed was already reaching the browser unread. That is still
# true of lit and dim; it is not true of red, which needs a field nobody has
# written yet. So this file asserts ENGINE behaviour as well as rendering.
#
# WHY THE FIELD LANDS ON THIS CARD rather than in TKT-893, which owns what the
# board knows about a monitor: TKT-873's silence rule, absorbed into TKT-893,
# needs the identical number. This card needs it first and cannot finish without
# it, and one field added in two places is the drift the grouping was meant to
# end. TKT-863 adds it; TKT-893's rule reads it.
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

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Heartbeat', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'HBS', epic_prefix => 'HBE', ticket_prefix => 'HBT',
);

# --- a monitor can say how often it expects to speak --------------------------

my $declared = eval {
    $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'd2 tira.policy.bridge', expect_every => 5,
    );
};
my $add_error = $@;

# THESE TWO ARE A PAIR AND THE FIRST IS NEARLY WORTHLESS ALONE. Measured while
# this file was red: assertion 1 PASSED against code that has no such field,
# because job_add reads the keys it knows through _job_fields and silently
# ignores the rest - so "it did not refuse" is not "it stored anything". That is
# the same silently-discarded-argument shape this project keeps finding
# (TKT-748's --status, TKT-888's --sort), one layer down.
#
# The second assertion is the one with teeth. The first stays because a refusal
# and a discard need telling apart when this next fails.
ok( $declared && ref $declared eq 'HASH',
    'a monitor can be created with an expectation - the field his answer chose'
) or diag("job_add refused it: $add_error");

is( ( $declared || {} )->{expect_every}, 5,
    'and the number it declared is what the record carries' );

# --- and one that declares nothing is not silently given a default ------------
#
# His answer is explicit that empty means no expectation, which means DIM. A
# default here would be the board-wide constant he rejected, arriving through
# the back door - and it would paint JOB-005 red exactly as that option would.

my $silent = $tira->job_add(
    project => $root, schedule => 'monitor', command => 'd2 is-agent-sleeping' );

ok( !defined $silent->{expect_every},
    'a monitor that declares nothing has no expectation at all - not a default, '
      . 'which would be the board-wide constant he turned down' );

# --- it can be changed later, like every other field --------------------------
#
# "when it is created" is where he put it; a monitor whose cadence turns out
# wrong must not need deleting and remaking to correct it.

my $changed = eval {
    $tira->job_update( project => $root, id => $declared->{id}, expect_every => 30 );
};
my $update_error = $@;
is( ( $changed || {} )->{expect_every}, 30,
    'an expectation can be corrected without deleting the job'
) or diag("job_update refused it: $update_error");

# --- and it survives an unrelated update --------------------------------------
#
# job_update merges rather than replaces - that is what makes changing only the
# schedule safe. A new field that quietly vanishes when something else is
# touched would be worse than no field, because it would look set.

my $touched = $tira->job_update(
    project => $root, id => $declared->{id}, schedule => 'monitor' );
is( $touched->{expect_every}, 30,
    'and it survives an update that names something else, the way command and '
      . 'message already do' );

# --- a cron job has no use for one, and is told so ---------------------------
#
# A cron job is not supposed to be up between runs, so it has no heartbeat and
# gets no light. An expectation on one would be a number nothing reads - which
# is the shape of the silently-ignored argument this project keeps finding
# (TKT-748, TKT-888).

{
    my $refused = eval {
        $tira->job_add(
            project => $root, schedule => '0 * * * *',
            command => 'd2 tira.stale', expect_every => 5 );
        1;
    };
    my $why = $@;
    ok( !$refused, 'a cron job is refused an expectation rather than storing one nothing reads' );
    like( $why, qr/monitor/i,
        'and the refusal says why - it belongs to a monitor, which is the word '
          . 'the caller needs to know they wanted' );
}

# --- the view reads it -------------------------------------------------------

my $js = do {
    open my $fh, '<:raw', 'lib/Tira/views/jobs-editor.js' or die "jobs-editor.js: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: the assertions below read this file, and an
# unreadable one would fail them for the wrong reason.
like( $js, qr/\S/, 'the jobs editor is there to be read' );

like(
    $js,
    qr/expect_every/,
    'the heartbeat reads the declared expectation, which is what decides red'
);

like(
    $js,
    qr/"stale"/,
    'and there is a stale state for a monitor that has outrun its own '
      . 'expectation - distinct from unknown, which means it declared nothing'
);

# THE COMPARISON MUST USE THE TIMESTAMP, NOT THE WORDS. sinceWords rounds both
# ways - 89 minutes reads "1 hour ago" and 91 reads "2 hours ago" - so a
# threshold measured against that label is wrong by up to half a unit in a
# direction nobody chose. Found by running the real function over eight cases
# while the first half of this card was being built, and warned about in the
# code at the point somebody would reach for it.
unlike(
    $js,
    qr/sinceWords\([^)]*\)\s*[<>]/,
    'and it is not compared against the rounded words, which round both ways'
);

# --- and the stylesheet can draw it ------------------------------------------

my $css = do {
    open my $fh, '<:raw', 'lib/Tira/views/dashboard.css' or die "dashboard.css: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: the rule below is looked up in this text.
like( $css, qr/\S/, 'the stylesheet is there to be read' );

like(
    $css,
    qr/\.jobs-card__beat\[data-beat="stale"\]/,
    'the stale state has a rule of its own, rather than inheriting the lit one'
);

# --- what must not change ----------------------------------------------------
#
# The first half of this card is committed and t/508 holds it. These are here
# because the field is a chance to break them: a heartbeat rewritten around
# expect_every could easily stop rendering for a monitor that has none.

like(
    $js,
    qr/"unknown"/,
    'a monitor that declares nothing still renders as unknown, which is his '
      . 'answer for the empty case rather than a colour'
);

like(
    $js,
    qr/jobs-card__up/,
    'and TKT-861 running indicator is still there beside it - up and speaking '
      . 'remain two facts'
);

done_testing();

__END__

=head1 NAME

510-a-monitor-that-says-how-often-it-speaks.t - the declared expectation, and red

=head1 WHY

TKT-863's second half. A monitor has no cadence in the record - its schedule is
the literal string C<monitor> - so "silent too long" had no source, and the only
real monitor on this board is legitimately quiet for over an hour because it
speaks only when the owner is away.

Q-115 asked the owner where the expectation should come from. He chose: each
monitor declares its own, and declaring nothing means a dim light rather than a
judgement.

=head1 WHAT IS ASSERTED

That a monitor can declare an expectation and have it stored, corrected, and
survive an unrelated update; that a monitor which declares nothing is given no
default, since a default is the board-wide constant he turned down arriving by
the back door; that a cron job is refused one rather than storing a number
nothing reads; and that the view renders a stale state distinct from unknown,
comparing against C<last_output_at> rather than the rounded words.

=cut
