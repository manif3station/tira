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
# Q-119 ASKED HIM WHAT HAPPENS TO THE REMAINDER, and he answered: "Describe
# everything, marking the approximate ones as approximate - e.g. 'About every 7
# minutes (restarts each hour)'". So nothing renders as raw cron. A description
# that is not exactly true opens with a mark and says what makes it inexact,
# which is a better rule than the refusals this file first asserted: the mark
# does the work the refusal was doing, and the reader gets something.
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

# --- nothing renders as raw cron -------------------------------------------
#
# HIS ANSWER TO Q-119, 2026-09-04: "Describe everything, marking the approximate
# ones as approximate - e.g. 'About every 7 minutes (restarts each hour)'".
#
# THAT REPLACES THE RULE THIS FILE WAS FIRST WRITTEN AGAINST, and his reasoning
# is better than the one it replaces. The no-guessing principle protected a
# reader from a CONFIDENT sentence that is false. A sentence opening with
# "About" is not confident, so there is nothing to protect against - the mark
# does the work the refusal was doing, and the reader gets something instead of
# a cron string.

is( words('0 0,4,8,12,16,20 * * *'), 'Every 4 hours, on the hour',
    'an even series is described as the step it is, however it was written - '
      . 'the words follow what a schedule MEANS, not how it was typed' );

is( words('0 1,4,8,12,16,20 * * *'), 'At 01:00, 04:00, 08:00, 12:00, 16:00 and 20:00',
    'and an uneven one is listed while the list is short enough to read' );

is( words('*/7 * * * *'), 'About every 7 minutes (restarts each hour)',
    'HIS OWN EXAMPLE OF THE MARK. */7 fires at 0,7,...,56 then 0 - a gap of '
      . 'four - so "every 7 minutes" would be false. "About", with the reason '
      . 'in brackets, is true AND useful, which raw cron was not' );

is( words('*/45 * * * *'), 'About every 45 minutes (restarts each hour)',
    'and any other minute step that does not divide the hour' );

is( words('0 */5 * * *'), 'At 00:00, 05:00, 10:00, 15:00 and 20:00',
    'an uneven HOUR step is still listed rather than marked, because the list '
      . 'is exact and short - a mark is for what cannot be said exactly, not '
      . 'for everything irregular' );

like( words('23 0-20/2 * * *'), qr/\AAbout every 2 hours/,
    'A LIST TOO LONG TO READ IS MARKED RATHER THAN LEFT AS CRON. Eleven times '
      . 'is exact and unreadable; "About every 2 hours" is inexact at the wrap '
      . 'and readable, and the mark is what makes that honest' );

like( words('23 0-20/2 * * *'), qr/restarts each day/,
    'and it says WHAT makes it approximate, which is the whole difference '
      . 'between a hedge and an explanation' );

is( words('*/60 * * * *'), 'Every hour, on the hour',
    'AND WHAT IS EXACT IS NOT MARKED. */60 fires at minute 0 alone, so this is '
      . 'exactly true - marking it "About" would spend the reader\'s attention '
      . 'on a doubt that does not exist' );

# --- the day fields, which are not approximate ------------------------------
#
# THE ONE PLACE HIS INSTRUCTION IS NOT FOLLOWED LITERALLY, and it is on the card
# as well as here. Cron ORs the day fields when both are restricted: this fires
# on the 1st AND on every Monday. That is not APPROXIMATE - it is exact and
# surprising - so it gets the OR stated outright rather than a hedge. The mark
# is for imprecision, not for complexity.

like( words('0 0 1 * 1'), qr/1st/,
    'both day fields restricted is described rather than left as cron' );

like( words('0 0 1 * 1'), qr/\balso\b.*Monday/,
    'AND IT STATES THE OR OUTRIGHT. Cron fires this on the 1st AND on every '
      . 'Monday, which is the single most misread thing in cron - so the words '
      . 'say "and also", which is the one phrasing that cannot be read as an '
      . 'AND of the two conditions' );

unlike( words('0 0 1 * 1'), qr/\AAbout/,
    'and it is NOT marked approximate, because it is not - a hedge here would '
      . 'describe the wrong difficulty' );

# --- what the coverage gate found ---------------------------------------------
#
# gate-run refused at 99.3% on Tira::Job and named three lines. Two of them were
# working code nothing asked about; the third was a schedule still coming back as
# raw cron, which is the rule his Q-119 answer set, broken in a corner I had not
# looked at. An untested line and an unreachable-by-design line look identical
# until something asks why the coverage is short.

is( words('0 9 * 3 *'), 'Every day in March at 09:00',
    'a MONTH with the day of the month left open - "every day in March", which '
      . 'worked and had no test' );

is( words('0 0 1 jan *'), 'At 00:00 on 1 January',
    'and a month written by NAME, which cron accepts and a person writing a '
      . 'schedule by hand usually types' );

is( words('* 9 * * *'), 'Every minute from 09:00 to 09:59',
    'EVERY MINUTE OF ONE HOUR. This came back as raw cron: valid, common, and '
      . 'exactly describable, so it is the Q-119 rule broken in a corner. Found '
      . 'by the coverage gate rather than by me' );

is( words('* 9-17 * * *'), 'Every minute from 09:00 to 17:59',
    'and every minute across a RANGE of hours, which is the same hole' );

is( words('* 9,17 * * *'), 'Every minute of 09:00 and 17:00',
    'and across a list of them' );

is( words('* 0-20/2 * * *'),
    'About every minute from 00:00 to 20:59 (not every hour between them)',
    'AND A SET TOO LONG OR TOO UNEVEN TO LIST IS MARKED. Eleven hours, every '
      . 'other one - "from 00:00 to 20:59" is right about the span and wrong '
      . 'about the middle, so the bracket says which. Left unasserted this '
      . 'branch was the last line the coverage gate refused' );

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
