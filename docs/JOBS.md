# Tira repeated jobs

Printed by `d2 tira.job.help`. This is the argument for using the board's own
scheduling, with worked examples. It is not the argument list — every verb and
every option is in `docs/commands.md`, and duplicating that here is how two
documents drift apart.

**68 worked examples**, and the number is stated because it was asked to be a
hundred. Every one of these does something the others do not, and every one is
executed by `t/509` — a hundred was reachable only by writing the same example
with different words, which would have met the number and defeated the reason
for it. If a genuinely different case is missing, it belongs here; a fifty-
seventh spelling of `--schedule "0 * * * *"` does not.

---

## Reason and purpose

**The board owns repeated work.** Anything that has to happen again — a hunt, a
poll, a watcher, a reminder — belongs on the board as a job, not in a crontab
and not in a loop inside an agent session.

Three reasons, and the third is the one that actually costs.

**A session ends and takes its schedule with it.** A loop running inside an
agent session lives exactly as long as that session. The next session does not
inherit it, does not know it existed, and has no way to find out.

**A crontab entry is invisible to everybody who is not you.** It is not on the
board, so it is not in `tira.job.list`, police cannot reason about it, and the
next person to wonder why something runs at 3am has nowhere to look.

**A stopped loop and a quiet loop produce identical output: none.** This is the
one that does real damage, because it fails silently and it fails for hours. A
job on the board can be asked whether it is alive. A loop in a session cannot.

**And one bridge, not a channel each.** A job's output reaches the police
bridge. You run `d2 tira.policy.bridge` once and see everything — you do not
need a log per job and a tail per log. A monitor may keep its own log file for
your convenience; the bridge is still the channel.

---

## Problem statement

This is not hypothetical. Every example below happened on this board, and each
is why a part of this feature exists.

**Three standing hunts died and nobody noticed for hours.** On 2026-09-02 the
hourly bug hunt, the two-hourly improvement hunt and the three-hourly doc-gap
hunt were all running as in-session monitors. All three stopped. Nothing said
so, because a loop that has stopped and a loop with nothing to report look the
same from outside. The owner noticed the absence; the agent had no way to. That
is why EPC-014 exists at all, and why `monitor-dead` was written.

**A monitor was reported dead while demonstrably running.** The liveness check
compared the stored command against the process table, and `d2` execs perl with
a resolved path — so the stored command never appeared in the child's argv and
every wrapped monitor read as dead. Fixed in 5.34 by comparing the start time
the board recorded against the one the process table reports (TKT-860).

**A `while` loop typed into a command field never ran once.** JOB-006 was
`while ((1)); do d2 tira.police; sleep 5; done`, created to keep police alive.
It had no pid, never fed a line, and produced 22 `monitor-dead` alarms before it
was deleted. The intent was right; typing shell into a command field is how it
failed.

**A monitor's output used to go to a log nobody read.** Until 5.42 a running
monitor wrote to a spool and the board followed it. Now the monitor tells the
board directly, through `tira.job.feed`, so each line is registered as it
arrives and the board knows *when* it last spoke.

---

## What a job is

A job has a **schedule** and one of a **message** or a **command**.

The schedule is either a cron expression — the job fires on a tick — or the
literal word `monitor`, meaning it stays running.

A message job announces its text on the bridge when due. A command job runs its
command. A job carrying both is refused, because a record with both cannot say
which the bridge should get.

A `monitor` job must have a command. A message-only monitor would never be due,
could not be started, and would be reported dead for ever — so it is refused at
the point of writing.

### What a command may contain

**A command is a program and its arguments. It is not a shell line.** Nothing
interprets it, and that is deliberate — the words you write are the words the
program receives, so a semicolon, a backtick, a `$(...)`, a pipe or a redirect
inside an argument is *text* rather than something that happens.

```
d2 tira.comment.add --ref TKT-1 --text "two words"
d2 tira.job.add --schedule '0 * * * *' --message 'hunt due'
```

**Quotes group; they do not survive into the argument.** Either style works, and
a quoted stretch arrives as one argument with the quote marks removed — which is
what lets `--text` take a sentence and `--schedule` take a cron expression.

A quote only groups when it **starts** a word. Anywhere else it is an ordinary
character, so `can't` is one word and `C:\O'Reilly\tool.exe` is one path —
neither is somebody opening a quote, and neither should stop a job running.
Before 5.42 the command was split on spaces alone, so `--text "two words"` reached
the program as three arguments with the quote marks still attached, and the job
exited 0 having done the wrong thing.

**Everything that is not a quote is literal, backslashes included.** A Windows
path keeps its separators:

```
C:\tools\bin\thing.exe --flag
```

**There is no shell, so these do nothing:**

```
d2 tira.stale ; rm -rf /        # the semicolon is an argument, not a separator
echo `id`                       # backticks are characters
echo $(whoami)                  # so is a dollar-paren
thing > /tmp/out                # nothing is redirected
a | b                           # nothing is piped
```

If you need any of that, the command is `sh` and the script is its argument —
then the shell is a thing you asked for by name rather than something the board
did on your behalf.

**An unbalanced quote is refused** rather than guessed at, and the refusal names
the quote and shows the command back. A job whose command is a typo is not a job
with no command, and it does not run half of itself.

---

## Worked examples

### Making a job

Announce something on a schedule:

```
d2 tira.job.add --schedule "0 * * * *" --message "HOURLY BUG HUNT due"
d2 tira.job.add --schedule "0 */2 * * *" --message "2-HOURLY IMPROVEMENT HUNT due"
d2 tira.job.add --schedule "0 */3 * * *" --message "3-HOURLY DOC-ACCURACY HUNT due"
d2 tira.job.add --schedule "*/30 * * * *" --message "half-hourly check due"
d2 tira.job.add --schedule "0 9 * * 1" --message "Monday morning review"
d2 tira.job.add --schedule "0 0 1 * *" --message "monthly board sweep"
```

Run a command on a schedule:

```
d2 tira.job.add --schedule "*/30 * * * *" --command "d2 tira.police.outstanding"
d2 tira.job.add --schedule "0 * * * *" --command "d2 tira.stale"
d2 tira.job.add --schedule "0 6 * * *" --command "d2 tira.backup"
d2 tira.job.add --schedule "15 * * * *" --command "d2 tira.search.index"
```

Keep something running:

```
d2 tira.job.add --schedule monitor --command "d2 tira.policy.bridge"
d2 tira.job.add --schedule monitor --command "d2 is-agent-sleeping"
```

### Reading a schedule

The five fields are minute, hour, day-of-month, month, day-of-week. These are
the shapes worth knowing, each doing something the one above it does not:

```
d2 tira.job.add --schedule "* * * * *" --message "every minute"
d2 tira.job.add --schedule "*/5 * * * *" --message "every five minutes"
d2 tira.job.add --schedule "0 * * * *" --message "on the hour"
d2 tira.job.add --schedule "30 * * * *" --message "at half past every hour"
d2 tira.job.add --schedule "0 */6 * * *" --message "every six hours"
d2 tira.job.add --schedule "0 9 * * *" --message "every day at 09:00"
d2 tira.job.add --schedule "0 9,17 * * *" --message "twice a day, 09:00 and 17:00"
d2 tira.job.add --schedule "0 9-17 * * *" --message "hourly through the working day"
d2 tira.job.add --schedule "0 9 * * 1-5" --message "weekday mornings only"
d2 tira.job.add --schedule "0 9 * * 0" --message "Sunday mornings"
d2 tira.job.add --schedule "0 0 1 * *" --message "the first of the month"
d2 tira.job.add --schedule "0 0 1 1 *" --message "once a year"
```

A step (`*/5`) is not the same as a list (`9,17`) and neither is a range
(`9-17`). `0 */6 * * *` is every six hours; `*/6 * * * *` is every six minutes,
and mistaking one for the other is the commonest way to make a job that runs
240 times a day.

### Things worth having a job for

Real tasks, rather than placeholders:

```
d2 tira.job.add --schedule "0 * * * *" --command "d2 tira.stale"
d2 tira.job.add --schedule "*/30 * * * *" --command "d2 tira.police.outstanding"
d2 tira.job.add --schedule "0 6 * * *" --command "d2 tira.backup"
d2 tira.job.add --schedule "15 * * * *" --command "d2 tira.search.index"
d2 tira.job.add --schedule "0 */4 * * *" --command "d2 tira.doctor"
d2 tira.job.add --schedule "0 8 * * 1" --message "weekly: review the discard column"
d2 tira.job.add --schedule "0 18 * * 5" --message "Friday: is anything stuck in pending-push?"
d2 tira.job.add --schedule "0 */2 * * *" --message "check the bridge has been read"
```

### Seeing what exists

```
d2 tira.job.list
d2 tira.job.list -o json
d2 tira.job.list -o toon
```

### Changing one

Only what you name changes; everything else stays as it was.

```
d2 tira.job.update --id JOB-001 --schedule "0 */4 * * *"
d2 tira.job.update --id JOB-001 --message "a different announcement"
d2 tira.job.update --id JOB-001 --command "d2 tira.police.outstanding"
d2 tira.job.update --id JOB-001 --enabled 0
d2 tira.job.update --id JOB-001 --enabled 1
```

Switching mode really does switch it — setting a message clears the command, and
setting a command clears the message:

```
d2 tira.job.update --id JOB-002 --message "now an announcement"
d2 tira.job.update --id JOB-002 --command "now a command again"
```

### Starting, stopping, running and removing

A monitor is started and stopped; a cron job is run now regardless of its
schedule.

```
d2 tira.job.start --id JOB-005
d2 tira.job.stop --id JOB-005
d2 tira.job.run --id JOB-001
d2 tira.job.delete --id JOB-006
```

**Stop before you change a running monitor.** The board refuses to change a
running monitor's command, to disable it, or to delete it, because each of those
would leave the board saying something untrue about a process that is still
there. Stopping is what lets go of it:

```
d2 tira.job.stop --id JOB-005
d2 tira.job.update --id JOB-005 --command "d2 tira.police.outstanding"
```

**And a monitor's card shows its recent output, since 5.48.** The black panel
under a job card used to be filled from one place only: the answer to a **Run
now** click. A monitor has no Run now — its button is **Start**, because a
monitor has no schedule to bypass — and starting one hands back a job record
rather than output, so a monitor's card could never show a line. Reading the
job's output queue would not have helped either, since that queue exists to be
emptied by the police pass. The record keeps a short tail of its own now, which
the drain leaves alone, and the card paints from it as it renders. It holds one
feeder delivery's worth, newest first out.

**A monitor's output reaches the bridge, and until 5.47 it did not.** The feeder
puts a monitor's words on its job record; the `monitor-output` police rule reads
them, announces them, and they are then removed so the bridge does not repeat
itself. Every part of that worked except the announcement: the rule tags its
finding with the job id and the words, so two passes carrying different output
are not mistaken for one rule repeating itself, and that tag was being dropped
before it reached the ledger. Every `monitor-output` finding a board ever made
was therefore filed as the same one, and everything after the first was
suppressed as a repeat. The removal happened anyway. So a monitor could speak all
day, its `last spoke` time move on every batch, and not one word appear anywhere
— which is exactly what happened to `JOB-006` while it tailed a Telegram log.
TKT-925.

**Stopping stops all of it.** A monitor is not one process: a shell owns the
pipe, the command runs on one side of it and the feeder reads the other, and
`--restart-every` adds a loop. Until 5.45 the stop signalled only the pid the
board recorded, and the rest kept running as orphans while the record was
cleared - so the board forgot a monitor that was still going, and the next
`tira.job.start` started a second one beside it. A monitor now runs in a process
group of its own and the stop signals the group.

The answer says which happened, in `signalled`: `group` means the whole monitor
was signalled, `gone` means there was nothing there, and `process` means only
the recorded process was reached - which happens for a monitor started before
5.45, and means whatever else it forked is still running.

Stopping works whether or not the process is still alive - a pid whose process
already died is exactly the record somebody needs to clear. Changing the
*schedule* of a running monitor is not refused, and neither is anything about a
monitor that was never started or any cron job.

### Keeping a command running

Instead of typing a loop, say how long to wait before running it again:

```
d2 tira.job.add --schedule monitor --command "d2 tira.stale" --restart-every 5
d2 tira.job.update --id JOB-001 --restart-every 30
```

Whole seconds, greater than zero. Leaving it out means no restarting, which is
not the same as zero. It belongs to a monitor running a command: a cron job
fires on a tick rather than staying up, and a message job announces text and
runs nothing, so both are refused:

```
d2 tira.job.add --schedule "0 * * * *" --command "d2 tira.stale" --restart-every 5
```

This is what JOB-006 in the problem statement was reaching for. The difference is
that the board can see it: an interval is a field it can report, where a `while`
loop inside a command is one opaque string.

### A monitor telling the board it is alive

A started monitor is piped through the feeder automatically. You only call this
directly if you are writing something that reports on its own behalf:

```
d2 tira.job.feed --id JOB-005
```

**It refuses a job it cannot find, and a cron job, before it reads anything**
(5.51). Given an id that names nothing it used to wait on standard input for
ever - never looking the job up, so never discovering there was nothing to feed.
A cron job is refused for the reason a cron job cannot be *started* either: it is
not up between runs, so nothing is feeding on its behalf. TKT-928.

### Saying how often a monitor should speak

A monitor can declare its own cadence, and a stopped-but-alive monitor is
visible on the dashboard because of it:

```
d2 tira.job.add --schedule monitor --command "d2 tira.policy.bridge" --expect-every 5
d2 tira.job.update --id JOB-001 --expect-every 60
```

It is a whole number of minutes and must be greater than zero; `--expect-every 0`
is refused rather than read as "never expect anything".

Leaving it out is not zero and not a default - it means this monitor declares no
expectation, and the dashboard shows it dim rather than judging it. That is
deliberate: a monitor that speaks only when something happens can be quiet for
hours and be perfectly healthy, and a light that is usually red is one nobody
reads.

**What you will see on the dashboard**, for an enabled monitor:

| state | when |
| --- | --- |
| lit | it spoke within its declared expectation, or it declares none |
| red | it has been silent longer than the expectation it declared |
| dim | it has never spoken at all, whatever it declares |

A **cron job** shows no heartbeat and a **disabled monitor** shows none either -
the same two silences `monitor-dead` already keeps, for the same reason. Neither
is supposed to be up, so neither has a heartbeat to miss.

That is also why the expectation belongs to a monitor. A cron job is refused
one, rather than storing a number nothing would ever read:

```
d2 tira.job.add --schedule "0 * * * *" --command "d2 tira.stale" --expect-every 5
```

### Watching all of it

One bridge, for every job and every police finding:

```
d2 tira.policy.bridge
d2 tira.police.outstanding
```

### From the dashboard rather than a terminal

Everything above is the CLI, and until 5.42 the dashboard could do a strict
subset of it: a job could be listed, run, and given a new schedule. It could not
be corrected, stopped, or removed, and the two newest fields could not be set
from there at all.

That was his complaint, in his own words: *"In the UI there is no way i can
delete any existing job card / I cannot edit and card / I cannot pick between
command or message."*

The Repeated Jobs section now offers, on each card:

| Control | What it does | The verb underneath |
| --- | --- | --- |
| **Edit** | opens one form, pre-filled from the job | `tira.job.update` |
| **Run now** / **Start** | runs a cron job now, or starts a monitor | `tira.job.start` |
| **Stop**, **Restart** | only on a monitor the board can see running | `tira.job.stop` |
| **Enable** / **Disable** | stops a job being due, without removing it | `tira.job.update` |
| **Delete** | removes the job, after a confirm | `tira.job.delete` |

**Save waits for the schedule to be checked, and until 5.46 it waited for ever
on a monitor.** The button is disabled while the form asks the server whether the
schedule parses, and re-enabled when the answer arrives - unless the input
changed while the request was in flight, in which case the stale answer is
discarded rather than painted onto text the user has since retyped. That
staleness test compared the schedule box against the value that had been sent.
For a cron job they are the same string; for a monitor the value sent is the
literal `monitor` while the box holds whatever was typed before, or nothing, so
they could never match and the answer was discarded every time. The line that
re-enables Save sits below that test and never ran, so the button was dead from
the first keystroke of any monitor - which is exactly what he reported: *"after
filled in the command, the save button still cannot be clicked"*. The command was
never the point; the code that reads it was never reached. TKT-912.

**The buttons follow the job's state rather than offering everything.** A
monitor the board can see running offers Stop and Restart and does *not* offer
Start - offering it would be the board inviting a second process to sit beside
the first. A monitor whose liveness cannot be determined - the process table
could not be read - keeps the button it already had rather than guessing, which
is the same distinction the running indicator beside it makes.

**The form is one form.** Creating and editing use the same fields, and editing
fills them from the job. The schedule kind is a pair of radio buttons rather
than the word `monitor` typed into a schedule box, which was a magic value
somebody had to know. Command or Message is a second pair, and since 5.46 that
pair is not shown at all under Monitor - his words, *"you don't need to show the
Command radio button since there is only 1 option to select"*. A group with one
choice reads as a question nobody has answered. The row is hidden rather than
removed: the save reads which mode is ticked, and the form itself ticks Command
when a message job is switched to Monitor, so deleting the controls would build
the payload from one that no longer exists. The page is making a choice there,
but it is not the authority for it - the engine refuses that pairing outright,
and the page is declining to offer what the save would reject:

```
A 'monitor' job runs a command - give --command, not --message. A monitor stays
running rather than firing on a tick, so there is nothing for it to announce
```

A monitor with no command could never be found alive in the process table, so it
would be reported dead for ever.

**Looping is a checkbox with an interval**, off unless asked for, defaulting to
five seconds, and **since 5.52 it is offered only where the save would take it**.
The row was shown for anything in command mode, which is the message rule applied
and the cron rule forgotten — the engine refuses an interval on a cron job in the
line before it refuses one on a message job, *"a cron job fires on a tick rather
than staying up, so there is nothing to restart"*. So a cron job showed a
checkbox that ticked and a seconds field that took a number, and the save died on
it. It is now a **monitor** in command mode or nothing, which is exactly the set
`_job_fields` accepts. Hidden rather than disabled, for 5.46's reason rather than
the schedule box's: the box is disabled-with-a-reason because the form should
keep its shape, and a control whose only possible answer is *no* is not shape.
TKT-911.

**A hidden row sends an explicit null**, and that is the half worth reading twice.
`job_update` validates the job as it *would* be, merging any field the payload
does not mention with what the record already holds — deliberately, so an edit
naming only the command cannot drop how often a monitor said it would speak. The
save used to skip a field whose row was hidden, on the mirror-image reasoning.
Together those two make hiding a row dangerous rather than tidy: a monitor with an
interval, switched to cron, sent no interval, had its own merged back in, and was
refused for holding one — a save that fails over a control that is no longer on
screen, where before it could at least be unticked. The expectation row had that
fault from the day it was written, since it has always been hidden for a cron job:
a monitor that declared how often it speaks could not be turned into a cron job
from this page at all. Both send null now. Hidden means exactly *the engine
refuses this field for this kind*, so null is the only legal value and clearing it
cannot take away anything that was allowed to stay.

Unticking it *removes* the interval rather than leaving the old one
in place, and clearing the expectation field removes the expectation - the form
can unset what it can set. That is not free: an absent field and an empty one
mean different things to the engine, absent meaning "leave it alone" and empty
meaning "take it away", and a save that does not mention a field still leaves it
untouched, so an unrelated edit cannot wipe what a monitor declared about
itself. Do not set it below about two seconds. The reason is measured
rather than theoretical: the feeder that collects a monitor's output flushes
after 25 lines or two seconds of quiet, and a command restarting every second
never leaves a two-second gap - so a perfectly healthy monitor reports no output
at all and reads as dead.

**The schedule reads as words on the card face**, with the cron string kept as
the tooltip. It is still *stored* as cron; the words are produced by the engine,
not by the browser, for the same reason the schedule check is - two readings of
one format drift apart, and only one of them can be the one that decides.
Anything the engine cannot describe with certainty is shown unchanged, because a
nearly-right description would be believed and the cron never read again.

**Since 5.50 nothing renders as raw cron.** It reads the values a field
*selects* rather than the text it was written as, so `0 0,4,8,12,16,20 * * *`
reads as *Every 4 hours* however it was typed — and anything it cannot say
exactly is **marked** rather than withheld:

```
*/7 * * * *        ->  About every 7 minutes (restarts each hour)
23 0-20/2 * * *    ->  About every 2 hours from 00:23 to 20:23 (restarts each day)
*/60 * * * *       ->  Every hour, on the hour
0 0 1 * 1          ->  At 00:00 on the 1st of each month, and also every Monday
```

The mark is for **inexactness, not complexity** — `*/60` fires at minute 0 alone,
so that phrase is exactly true and is said plainly — and it carries its reason,
because *About every 7 minutes* alone is a hedge while `(restarts each hour)` is
an explanation. The day-field OR is **stated** rather than marked: cron fires
`0 0 1 * 1` on the 1st *and* on every Monday, exactly, and *and also* is the one
phrasing that cannot be read as an AND. TKT-917.

**A monitor is one process, since 5.53, and its `ps` line says whose it is.**
It used to be three - a `perl -e` shim that set a process group and exec'd `sh`,
a fixed `sh` script that owned the pipe and looped, and the command - with the
feeder reading the far end. His own `JOB-006` showed all of that in `ps`, plus a
resolved absolute path into the install, and **it never said which board the job
belonged to**. Job ids are per-board and one machine runs this skill for several
projects, so `JOB-006` exists four times over; that omission is how another
project's monitors were once reported as his.

```
tira.job.feeder JOB-006 [Tira Development] -- tail -F -n0 /home/mv/dd-tg/bot.log
```

The board's **name**, never its path — the path travels in `TIRA_HOME` exactly so
it stays out of the process table. The verb is
`tira.job.feeder --id ID [--interval SECONDS] [--command TEXT]`, and `job.start`
spawns it in place of the shim and the script; the recorded pid is still the
supervisor's, so a restart stays invisible to `monitor-dead`.

**It also fixed a monitor that could not start at all.** The spawn found its
entrypoint by counting three directories up from its own file, which stopped
being right the moment that code was lifted one level deeper (5.45): the path
became `<root>/lib/skills/job/cli/feed`, `exec` failed, and the board recorded a
pid for a process that was already a zombie. Every test passed the path in, so
none of them compared what the spawn *computes* with what exists. It walks up for
the skill root now, the same way the entrypoint scripts do.

It is a **subtraction** from the three cards that built the old shape rather than
a fourth mechanism beside them, which is the test of whether it was written
correctly. The command is split by the engine's own splitter and run through
`open3` as a list, so a semicolon or a backtick is still an argument and there is
no longer a shell to keep it away from. The reader is the same process that owns
the pipe, so it cannot be forgotten. The `setpgrp` is inside the process that
owns the child. TKT-927.

**A looping monitor says so, since 5.49.** `--restart-every` appeared nowhere on
a card before that: the interval was in the editor and in the save and in no
third place, so a monitor that restarts itself and one that runs once read
identically on the board. It is added to the phrase rather than replacing it,
because both are true and the first matters more - it does run continuously, and
the interval is how it comes back when the command inside it ends. TKT-915.

```
monitor                       ->  Runs continuously
monitor, restart every 5s     ->  Runs continuously, restarting 5 seconds after it ends
monitor, restart every 1s     ->  Runs continuously, restarting 1 second after it ends
*/30 * * * *       ->  Every 30 minutes
0 * * * *          ->  Every hour, on the hour
0 9 * * *          ->  Every day at 09:00
30 8 * * 1         ->  Every Monday at 08:30
0 */2 * * *        ->  Every 2 hours, on the hour
30 */2 * * *       ->  Every 2 hours, at 30 minutes past
0 9-17 * * *       ->  Every hour from 09:00 to 17:00
0 9,17 * * *       ->  At 09:00 and 17:00
0 22 * * 1-5       ->  Every weekday at 22:00
5 4 * * sun        ->  Every Sunday at 04:05
30 9 1 * *         ->  At 09:30 on the 1st of each month
0 0 1 1 *          ->  At 00:00 on 1 January
0 */5 * * *        ->  At 00:00, 05:00, 10:00, 15:00 and 20:00
* 9 * * *          ->  Every minute from 09:00 to 09:59
* 9-17 * * *       ->  Every minute from 09:00 to 17:59
0 9 * 3 *          ->  Every day in March at 09:00
0 0 1 jan *        ->  At 00:00 on 1 January
17 3 5,20 */2 1-5  ->  17 3 5,20 */2 1-5
0 0 1 * 1          ->  0 0 1 * 1
23 0-20/2 * * *    ->  23 0-20/2 * * *
*/60 * * * *       ->  */60 * * * *
*/7 * * * *        ->  */7 * * * *
```

That last pair is the rule doing its job rather than failing at it. A step is
only "every N minutes" when N divides the hour: cron restarts the step at the
top of each hour, so `*/7` fires at 0, 7, ... 56 and then at 0 again - a gap of
**four** minutes, not seven. `*/60` and anything larger fire at minute zero only,
which is hourly. Those are shown as themselves, because "every 7 minutes" is
exactly the nearly-right phrase somebody would believe and then stop checking
the cron.

**Run now writes into a tail at the foot of the card** - the last hundred lines, scrolled
to the newest, with anything under a minute old in yellow. It survives the
section's own thirty-second refresh, which is the part that took care: a log
owned by the card element would be wiped twice a minute by the reload that
rebuilds every card, leaving less behind than the single status line it replaced.

Deleting a **running** monitor is refused, and the page shows the engine's own
words rather than a softened version of them. The refusal names
`tira.job.stop`, because the useful thing to know is not that the delete failed
but what to do first.

### This page

`tira.job.help` is itself one of the job verbs, and the only one that takes no
arguments at all - no `--id`, no `--schedule`, no project. It prints this
document:

```
d2 tira.job.help
```

---

## The refusals, and why they exist

An engine that refuses is telling you something. These are the ones worth
knowing before you meet them - not a complete list, because the engine grows
guards as it learns, and a document claiming to hold all of them would be wrong
the first time one was added. When a refusal here is not one of these, read what
it says: they name the thing rather than the flag, on purpose.

**Both a command and a message.** A record carrying both cannot say which the
bridge should get.

```
d2 tira.job.add --schedule "0 * * * *" --command "echo hi" --message "hi"
```

**Neither a command nor a message.** There is nothing for the job to do.

```
d2 tira.job.add --schedule "0 * * * *"
```

**A monitor carrying a message.** A monitor stays running rather than firing on
a tick, so a message-only monitor is never due, cannot be started, and would be
reported dead for ever.

```
d2 tira.job.add --schedule monitor --message "I stay running"
```

**A schedule that is not a cron expression and not `monitor`.** Note that a
misspelling is not a monitor — it is parsed as cron and refused there.

```
d2 tira.job.add --schedule "moniter" --command "d2 tira.police"
```

**No schedule at all.**

```
d2 tira.job.add --command "d2 tira.police"
```

**A cron expression with the wrong number of fields.** Five, always.

```
d2 tira.job.add --schedule "0 *" --message "too few"
d2 tira.job.add --schedule "0 0 0 0 0 0" --message "too many"
```

**A field out of range.** There is no 25th hour and no 13th month.

```
d2 tira.job.add --schedule "0 25 * * *" --message "no such hour"
d2 tira.job.add --schedule "0 0 * 13 *" --message "no such month"
```

**An id that is not on the board.**

```
d2 tira.job.update --id JOB-999 --schedule "0 * * * *"
d2 tira.job.delete --id JOB-999
```

**Starting a cron job.** `start` is for monitors; a cron job fires on its tick,
and `run` is how you make it happen now.

```
d2 tira.job.start --id JOB-001
```

---

## Instead of the habit

**Instead of a crontab entry**, make a cron-kind job. It is visible in
`tira.job.list`, police can see it is due, and it survives you.

```
d2 tira.job.add --schedule "0 * * * *" --command "d2 tira.stale"
```

**Instead of a loop in your session**, make a monitor and start it. It outlives
the session, and `monitor-dead` will say so if it stops.

```
d2 tira.job.add --schedule monitor --command "d2 tira.policy.bridge"
d2 tira.job.start --id JOB-001
```

**Instead of a `while` loop typed into a command field** — do not. It is shell
inside a field that is deliberately not run through a shell, and JOB-006 is the
proof that it can be typed and never work. A supervised command is its own
feature; ask for it rather than writing shell.

**Instead of a log per job and a tail per log**, run the bridge once.

```
d2 tira.policy.bridge
```

**Instead of wondering whether a monitor is still working**, ask:

```
d2 tira.job.list
d2 tira.police.outstanding
```

A monitor that has stopped is reported by `monitor-dead`. A monitor that is
alive but wedged — process up, polling stopped — is what `last_output_at` and
the dashboard's heartbeat are for.

---

## What this document does not say

Every option of every verb: that is `docs/commands.md`, and it is the reference.
This page is the reason.

The police rules that watch jobs — `job-due`, `monitor-dead` — are documented in
`docs/POLICIES.md`, with what each one does *not* catch, which is the part worth
reading.
