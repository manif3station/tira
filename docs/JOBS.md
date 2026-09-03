# Tira repeated jobs

Printed by `d2 tira.job.help`. This is the argument for using the board's own
scheduling, with worked examples. It is not the argument list — every verb and
every option is in `docs/commands.md`, and duplicating that here is how two
documents drift apart.

**65 worked examples**, and the number is stated because it was asked to be a
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
