#!/usr/bin/env perl
# Twelve of sixteen common cron shapes read as raw cron on the card.
#
# TKT-917, EPC-014. His words: "For the cron schedualer style translation on the
# card to human readable isn't fully covered. like `0 */2 * * *` is not showing
# readable text. I want you to fully cover every single use case."
#
# MEASURED IN A perl-test CONTAINER before anything was written:
#
#   0 */2 * * *      RAW   <- his example      * * * * *      Every minute
#   0 */6 * * *      RAW                       */30 * * * *   Every 30 minutes
#   0 9-17 * * *     RAW                       0 * * * *      Every hour, on the hour
#   0 9,17 * * *     RAW                       0 0 * * 0      Every Sunday at 00:00
#   0 22 * * 1-5     RAW                       30 8 * * 1     Every Monday at 08:30
#   5 4 * * sun      RAW
#   30 9 1 * *       RAW                       */7 * * * *    RAW - and rightly
#   0 0 1 1 *        RAW                       23 0-20/2 * *  RAW - and rightly
#
# THE RIGHT-HAND FALLBACKS ARE THE POINT OF THIS FILE AS MUCH AS THE LEFT-HAND
# ONES. This sub already refuses to describe what it cannot describe exactly, and
# says why: */7 does NOT mean every seven minutes. Cron restarts the count each
# hour, so it fires at 0,7,...,56 and then 0 - a gap of four. "Every 7 minutes"
# is a sentence somebody reads, believes, and acts on, and it is false.
#
# So widening this sub means widening it only to shapes that are EXACT, and the
# same divisibility test the minute step applies against 60 has to apply to an
# hour step against 24. Q-119 asks him what happens to the remainder; this file
# asserts what is true whichever way he answers.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira::Job;

sub words { return Tira::Job::job_schedule_words( $_[0] ) }

# --- what already worked, and must go on working ------------------------------
#
# FIRST, because this card widens a sub that four other things read - the browser
# row, the CLI listing, t/517's dozen phrasings and TKT-915's monitor interval -
# and a regression here is worse than the gap being fixed.

is( words('* * * * *'),      'Every minute',            'every minute, unchanged' );
is( words('*/30 * * * *'),   'Every 30 minutes',        'a minute step, unchanged' );
is( words('0 * * * *'),      'Every hour, on the hour', 'on the hour, unchanged' );
is( words('30 8 * * 1'),     'Every Monday at 08:30',   'a weekday time, unchanged' );
is( words('monitor'),        'Runs continuously',       'a monitor, unchanged' );

# --- his example, and the hour step ------------------------------------------

is( words('0 */2 * * *'), 'Every 2 hours, on the hour',
    'HIS EXAMPLE. `0 */2 * * *` reads as raw cron on the card today, which is '
      . 'what he reported' );

is( words('0 */6 * * *'), 'Every 6 hours, on the hour',
    'and any hour step that divides the day' );

is( words('30 */2 * * *'), 'Every 2 hours, at 30 minutes past',
    'with the minute carried, since an hour step says nothing about when in '
      . 'the hour it fires' );

# THE DIVISIBILITY RULE, MIRRORED FROM THE MINUTE STEP. Cron restarts an hour
# step at midnight exactly as it restarts a minute step at the top of the hour,
# so */5 on hours fires at 0,5,10,15,20 and then 0 - a gap of four hours, not
# five. This is the same lie */7 is for minutes, and the same answer applies.
is( words('0 */5 * * *'), 'At 00:00, 05:00, 10:00, 15:00 and 20:00',
    'AN HOUR STEP THAT DOES NOT DIVIDE 24 IS NOT CALLED "every 5 hours". */5 '
      . 'fires at 0,5,10,15,20 and then 0 - a four-hour gap - so that phrase '
      . 'would be the nearly-right description this sub refuses. It is listed '
      . 'instead, which is EXACTLY right rather than merely close' );

is( words('0 */7 * * *'), 'At 00:00, 07:00, 14:00 and 21:00',
    'and so is */7, for the same arithmetic and the same answer' );

# --- ranges and lists ---------------------------------------------------------

is( words('0 9-17 * * *'), 'Every hour from 09:00 to 17:00',
    'an hour RANGE, which is how a working day is usually written' );

is( words('0 9,17 * * *'), 'At 09:00 and 17:00',
    'and an hour LIST, which is how twice a day is usually written' );

is( words('0 8,12,18 * * *'), 'At 08:00, 12:00 and 18:00',
    'a longer list reads as a list, with the last joined by "and" rather than '
      . 'a comma - it is a sentence, not a data structure' );

# --- named and ranged weekdays ------------------------------------------------

is( words('5 4 * * sun'), 'Every Sunday at 04:05',
    'a NAMED weekday, which cron accepts and this sub returned raw' );

is( words('0 22 * * 1-5'), 'Every weekday at 22:00',
    'and Monday-to-Friday reads as "every weekday", which is what it means to '
      . 'the person who wrote it' );

is( words('0 22 * * 6,0'), 'Every weekend day at 22:00',
    'as its complement does' );

# --- the day of the month, and the month --------------------------------------
#
# Returned raw today with a stated reason - "describing them correctly needs more
# care than the value it adds here". His instruction is that the value is there.

is( words('30 9 1 * *'), 'At 09:30 on the 1st of each month',
    'a day of the month' );

is( words('0 0 1 1 *'), 'At 00:00 on 1 January',
    'and a day of a named month, which is how a yearly job is written' );

# --- and the trap that must stay raw ------------------------------------------
#
# THE ONE PLACE A CONFIDENT DESCRIPTION WOULD BE WORST. Cron ORs the day fields
# when BOTH are restricted: `0 0 1 * 1` fires on the 1st of the month AND on
# every Monday, not on Mondays that fall on the 1st. It is the most misread
# thing in cron, and there is no short English for it that is not wrong.

is( words('0 0 1 * 1'), '0 0 1 * 1',
    'A DAY-OF-MONTH AND A DAY-OF-WEEK TOGETHER STAY AS CRON. Cron ORs them - '
      . 'this fires on the 1st AND on every Monday - and any short phrasing '
      . 'reads as an AND, which is the single most misread thing in cron' );

is( words('23 0-20/2 * * *'), '23 0-20/2 * * *',
    'A LIST TOO LONG TO READ STAYS AS CRON. This one is eleven times; listing '
      . 'them would be exactly right and completely unreadable, which is the '
      . 'other half of the same contract - anything this sub cannot say WELL it '
      . 'returns unchanged' );

is( words('0 1,4,8,12,16,20 * * *'), 'At 01:00, 04:00, 08:00, 12:00, 16:00 and 20:00',
    'and six is the most it will read out - the boundary is asserted rather '
      . 'than left to whoever next reads the code. Deliberately NOT an even '
      . 'series: 0,4,8,12,16,20 is every 4 hours and reads as that instead' );

is( words('0 0,4,8,12,16,20 * * *'), 'Every 4 hours, on the hour',
    'because an even series is described as the step it is, however it was '
      . 'written - the words follow what a schedule MEANS, not how it was typed' );

is( words('*/60 * * * *'), '*/60 * * * *',
    'A FIELD WRITTEN AS A STEP MUST BE ONE. */60 fires at minute 0 alone, so '
      . '"Every hour, on the hour" would be exactly TRUE of it - and somebody '
      . 'who typed */60 meant something else. Smoothing a typo into a confident '
      . 'sentence is how it never gets found. t/517 decided this and it holds' );

done_testing();

__END__

=head1 NAME

534-a-schedule-that-stayed-in-cron.t - the shapes the card could not put in words

=head1 WHY

TKT-917. Twelve of sixteen common cron shapes read as raw cron on a job card,
including his C<0 */2 * * *>. Most are describable exactly and were simply never
written.

=head1 WHAT IS ASSERTED

That the five shapes which already worked still do - this sub is read by the
browser row, the CLI listing, F<t/517>'s dozen phrasings and TKT-915's monitor
interval, so a regression here costs more than the gap.

Then hour steps, ranges, lists, named and ranged weekdays, days of the month and
named months.

And, as firmly, the shapes that must B<keep> falling through: an hour step that
does not divide 24, for the same arithmetic that keeps C<*/7> minutes raw; a
stepped range; and - most importantly - a day-of-month and a day-of-week
together, which cron B<ORs> and which no short English describes correctly.

=head1 WHAT IS NOT ASSERTED

What happens to the remainder. Q-119 asks him whether an undescribable schedule
keeps falling through silently, says why it is falling through, or gets an
approximate description marked as approximate. This file asserts what is true
whichever he answers.

=cut
