#!/usr/bin/env perl
# A monitor that restarts itself, and a card that does not say so.
#
# TKT-915, EPC-014. His report: "If I job original added as a loop and sleep for
# 5 seconds, when I edit it that setting is gone and didn't show on the card that
# is a loop."
#
# THE CARD NEVER RENDERS IT. restart_every appears exactly three times in
# lib/Tira/views/jobs-editor.js and all three are the editor or the save:
#
#   257  loopBox.checked       = Boolean(job && job.restart_every);
#   269  loopEvery.value       = (job && job.restart_every) || 5;
#   462  payload.restart_every = loopBox.checked ? Number(loopEvery.value) : null;
#
# So a looping monitor and one that runs once look identical on the board. Both
# say "Runs continuously".
#
# AND THE FIX IS IN THE ENGINE, which is the opposite of where the card assumed.
# The card renders job.schedule_words, and the view says so itself at line 545:
# "THE WORDS, decided by the engine (Tira::Job::job_schedule_words)". That sub
# takes a schedule string and knows nothing about the interval.
#
# THE SECOND HALF OF HIS REPORT DOES NOT REPRODUCE, and this file pins that down
# rather than leaving it assumed. Walked for a monitor stored with an interval:
# loopBox is ticked at 257, loopEvery is filled at 269, applyKind() runs at 410
# and shows the row, and the engine preserves the field on update with `exists`
# rather than `defined`. Every step reads correct. So "when I edit it that
# setting is gone" is what a person concludes when the CARD never showed it -
# one fault described twice, not two faults.
#
# That is a claim, so it is asserted rather than argued: the provider carries the
# field and the editor region reads it. If he still sees it lost after this
# installs, the load path is eliminated and the next place to look is the browser
# itself, which is his - this suite drives none.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use JSON::PP ();
use Tira;
use Tira::Job;

my ( $tira, $root, $looping, $plain );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Loop', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'LPS', epic_prefix => 'LPE', ticket_prefix => 'LPT',
    );
    $looping = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller', restart_every => 5, author => 'claude' );
    $plain = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'another-poller', author => 'claude' );
}

# --- the two monitors really do differ ---------------------------------------
#
# The control, first. If the field were not stored, every assertion below would
# be about a job that has no interval, and "the words do not mention it" would
# be correct rather than a defect.

is( $looping->{restart_every}, 5,
    'a monitor created with an interval keeps it - the control, since the rest '
      . 'of this file is about a value that must be there to be described' );

ok( !$plain->{restart_every},
    'and one created without has none, so the two are genuinely different jobs '
      . 'and not the same one asked twice' );

# --- the words say so --------------------------------------------------------

{
    my $said = Tira::Job::job_schedule_words( 'monitor', $looping->{restart_every} );

    like( $said, qr/\bcontinuous/i,
        'a looping monitor still reads as running continuously, because it '
          . 'does - the interval is an addition to that phrase, not a '
          . 'replacement for it' );

    like( $said, qr/\b5\b/,
        'THE WORDS CARRY THE INTERVAL. Today job_schedule_words takes only a '
          . 'schedule string and answers "Runs continuously" for every monitor, '
          . 'so a looping one and a one-shot one are indistinguishable on the '
          . 'board - which is his "didn\'t show on the card that is a loop"' );

    isnt( $said, Tira::Job::job_schedule_words( 'monitor', $plain->{restart_every} ),
        'and the two monitors do not read identically, which is the whole '
          . 'complaint stated as a comparison' );
}

# The old call must keep working. Tira::CLI::Browser calls it with one argument
# and t/517 asserts a dozen cron phrasings through it; a second parameter that
# broke the one-argument form would take the entire schedule column with it.
is( Tira::Job::job_schedule_words('monitor'), 'Runs continuously',
    'called with a schedule alone it answers exactly as before - the browser '
      . 'and t/517 both do that, and a monitor with no interval to mention has '
      . 'nothing to add' );

is( Tira::Job::job_schedule_words('*/30 * * * *'), 'Every 30 minutes',
    'and a cron schedule is untouched by any of this' );

# --- the page is given the words, not asked to build them ---------------------

{
    require Tira::CLI::Browser;
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    my $answer = $provider{jobs}->( {} );
    my $decoded = ref $answer ? $answer : JSON::PP->new->decode($answer);
    my $listed = ref $decoded eq 'HASH'
      ? ( $decoded->{jobs} || $decoded->{items} ) : $decoded;

    my ($seen) = grep { ( $_->{id} // '' ) eq $looping->{id} } @{ $listed || [] };

    # non-empty is the whole claim: an empty listing would make both assertions
    # below vacuous and send a later fix at the provider.
    ok( $seen, 'the looping monitor came back to the page' );

    like( ( $seen || {} )->{schedule_words} // '', qr/\b5\b/,
        'AND ITS WORDS ALREADY CARRY THE INTERVAL BY THE TIME THE PAGE SEES '
          . 'THEM. The card renders schedule_words and the view says so in its '
          . 'own comment - so this is a Perl change, and jobs-editor.js needs '
          . 'no edit at all' );

    is( ( $seen || {} )->{restart_every}, 5,
        'and the raw field is there too, which is what the EDITOR reads - the '
          . 'half of his report that does not reproduce' );
}

# --- and the editor reads that raw field --------------------------------------
#
# Pinning the half that does not reproduce, so it is eliminated rather than
# assumed. Source-read, like every other jobs-editor assertion in this suite.

my $editor = Suite::view_source('jobs-editor.js');

like( $editor, qr/loopBox\.checked\s*=\s*Boolean\(\s*job\s*&&\s*job\.restart_every/,
    'the editor ticks the loop box from the stored interval' );

like( $editor, qr/loopEvery\.value\s*=\s*\(\s*job\s*&&\s*job\.restart_every\s*\)/,
    'and fills the seconds field from it' );

like( $editor, qr/applyKind\(\);\s*\n/,
    'and applyKind runs on render rather than only on a change event, which is '
      . 'what makes the row visible when the editor OPENS - the three together '
      . 'are why "lost on edit" does not reproduce by reading' );

done_testing();

__END__

=head1 NAME

533-a-loop-nobody-can-see.t - a monitor's restart interval, on the card

=head1 WHY

TKT-915. C<restart_every> appears three times in F<jobs-editor.js> and all three
are the editor or the save, so the card never renders it: a looping monitor and a
one-shot one both read "Runs continuously".

=head1 WHAT IS ASSERTED

That C<job_schedule_words> carries the interval, that it still answers exactly as
before when called with a schedule alone - L<Tira::CLI::Browser> and F<t/517> both
do that - and that the words reach the page already built, which is what makes
this a Perl change with no edit to the view.

Then, separately, that the editor reads the raw field and that C<applyKind> runs
on render. Those pin down the half of his report that does not reproduce.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered card shows the phrase. This suite drives no browser.

That "lost on edit" never happens. It cannot be reproduced by reading - every
step of the load path is correct, and the engine preserves the field on update
with C<exists> rather than C<defined> - so the conclusion here is that his
sentence describes one screen twice. If he still sees it after this installs, the
load path is eliminated by the assertions above and the browser is the next place
to look.

=cut
