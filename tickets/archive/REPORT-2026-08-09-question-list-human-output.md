# Tira bugs still open against 0.90

Written 2026-08-09 by the developer-dashboard project. **The file was cleaned first,
as instructed.** Everything previously here has been re-verified against the
installed Tira 0.90 (`lib/Tira.pm`, 3965 lines — identical to the copy in
`~/projects/skills/skills/tira`, so the installed one IS the latest). Anything that
now passes has been removed rather than left to age.

## Already fixed in 0.90 — removed from this file

- **Human renders no longer warn.** `tira.ticket.show -o human` produced an
  uninitialized-value warning from `Tira.pm` line 3551. Re-run today: zero warnings.
- **`tira.question.list -o human` works.** It used to print the card with an empty
  title and no questions at all. It now renders the heading, each question with its
  status, the `_Why:_` reason, and the numbered options. Verified on Q-003/DD-522:
  the question, its reason and all three options are shown.

You were right that these were fixed. They are recorded here only so nobody
re-reports them.

---

# STILL OPEN 1 (the serious one) — `collector/tira-remind` takes no lock

Re-checked today against 0.90. The file is still 91 lines and
`grep -nE 'lock|flock|LOCK|pidfile|already running|O_EXCL'` over it returns
**nothing**.

It spawns the agent synchronously, once per collector tick:

    my $status = system( $agent_binary, '-p', '--resume', $session, $message->{text} );

**Why that is a defect rather than a scheduling choice.** `system()` blocks, so a run
lasts as long as the agent does, and a real agent session routinely outruns the
collector interval — 900 seconds here. When it does, the next tick starts a second
agent against the same board with the same session while the first is still working.
Tira has nothing to stop it because it assumes the scheduler serialises runs; the
scheduler's own overlap protection applies to one supervisor loop and says nothing
about a second loop existing. **Neither side owns the assumption.**

**Observed damage** on this project in one day: a ticket's edits to five files made,
left uncommitted for minutes, and gone; a coverage pass discarded because the tree
changed underneath it; two commits landed mid-edit; and one card moved and given
five comments by a second agent while the first was writing about that same card.

**Correction to how this has been described elsewhere, including by me:** it is one
agent per RUN, not one per card. `notification_message` aggregates every stale card
into a single message. The multiplication comes from overlapping runs, and that
distinction decides what the fix must be.

**Suggested fix.** Take a lock inside `tira-remind` itself, keyed on the project
root, and exit quietly when it is already held — a skipped reminder is not a fault.
That makes the guarantee Tira's own rather than borrowed from whatever invokes it.

**Trap worth passing on**, since it has now bitten twice here: detecting a running
agent with `pgrep -f` also matches the guard doing the matching, and any shell that
merely mentions the pattern. It jams shut and looks like it is working. Read
`/proc/<pid>/exe` and skip your own process tree.

**Acceptance:** two concurrent runs produce exactly one agent; the second exits 0,
not as an error; a stale lock from a killed run does not block reminders for ever.

---

# STILL OPEN 2 — a new board leaves the protected `discard` column watched

Reproduced today on a throwaway board created with `tira.project.create`:

    backlog      watched=1 protected=True
    discard      watched=1 protected=True

Discarding a card is itself a move, so the one action that ends a card's life starts
its reminder clock. Every newly created board therefore chases its own discarded
cards for ever, until somebody notices and sets `watched` false by hand.

This board is already immune — `watched: false` is set explicitly on all three board
types and checked hourly — so nothing here is broken. The defect is what the NEXT
board anyone creates inherits.

**Suggested fix:** create `discard` with `watched` false, or treat an absent
`watched` on a protected terminal column as false rather than true.

---

# STILL OPEN 3 — a comment does not reset a card's reminder clock

Confirmed in the source rather than by waiting. `_dwell_start` (Tira.pm:1670) walks
the journal backwards and accepts an entry only when both hold:

    next if index( $line, '"field":"column"' ) < 0 || index( $line, '"op":"move"' ) < 0;

So only a column move restarts the clock. A comment is not a move, and nothing else
in `dwell_list` consults comment activity.

**Why it matters:** the reminder's own advice is to leave a comment saying what the
card is waiting for. Doing exactly that reads as activity to a person and as nothing
at all to the reminder, so a card being actively discussed keeps being chased.

**Suggested fix:** let the latest comment stamp count as activity too, or say
explicitly in the reminder text that only a move will silence it.

---

## Verification note

Every claim above was re-run today against 0.90 rather than carried forward: the two
fixed items by running the commands, open item 1 by grepping the shipped script, open
item 2 by creating a fresh board and reading its columns, open item 3 by reading
`_dwell_start`. Nothing here is inherited from an earlier report.
