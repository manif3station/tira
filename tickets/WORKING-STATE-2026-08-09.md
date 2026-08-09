# Working state, 2026-08-09

Everything in flight and everything queued, so nothing depends on my
memory. Written at the owner's instruction.

## Shipped today (all pushed)

`0.65` through `0.96`, thirty-two releases. The large pieces:

- **EPIC-457** stale-card reminders, complete: dwell, per-column
  limits, notification history, sticky warnings, ten escalation tones,
  settings, the collector.
- **EPIC-469** questions on cards, largely complete: ask/list/answer/
  update/mark/discard, project-wide `Q` references, reason and choices,
  voice notes, reminders, the card dialog panel, the two board toggles,
  the yellow and greyed-out card states, blocked cards exempt from
  chasing.
- Loose defects: the reentrant lock (`DD-444`), nesting refusal
  (`DD-447`), wrapping boards (`DD-453`), the mojibake icons
  (`DD-468`), the human question view (`DD-478`), the vanishing yellow
  (`DD-480`), the erased panel (`DD-484`), self-restarting dashboards
  (`DD-488`).

## In flight right now

**`DD-492` — record reminders.** Built and green: a new record is told
it has no description, no reporter, no gate and no question, in one
terse line. The owner chose those four (message 3218). The engine
returns the record unchanged and the CLI attaches the advice, because
an existing test rightly insisted that what you get back is exactly
what is on disk. Documented in both manuals as UC-114. **Gate running;
not yet committed.**

## Queued, in the order I intend to take them

1. **`DD-493` — the attachment count that reads as zero.** Reported by
   another agent from real use: `attachment.list` counts only what is
   attached to the card, so a card whose files hang off comments
   reports zero. The agent read that as failure and only found the
   audio by digging a level deeper. A count that says zero when files
   exist is a lie by omission, and it cost somebody real time.
   *Investigating now.*

2. **`DD-494` — a question cannot hold an attachment.** Same report.
   `question.ask` takes text, reason, choices and now a voice note, but
   no general attachment, so a screenshot or a log has to be bound to a
   comment that names the question. Worth deciding deliberately:
   general attachments on a question, or is the voice note the only
   case that matters?

3. **`DD-474` — the Discard column never appears on the dashboard.**
   Raised by the owner; awaiting nothing, just unbuilt.

4. **`DD-476` — the SQLite search index.** Raised by the owner.
   **Blocked on his decision**: an index is a second copy of the truth,
   so it can only ever be a rebuildable cache and never what a read
   trusts when the two disagree. That premise is the whole basis of
   the tool, so it is his call rather than mine.

## Standing rules I am working to

- Every response an agent gets should say what the thing still owes,
  terse and machine-readable, with the fewest commands that settle it.
  If a fix needs two commands, that is the command surface telling on
  itself.
- Reminders are read by an LLM, not a person. Tira exists to spend
  fewer tokens than Jira; prose in a reminder is the cost it exists to
  avoid.
- Every guard is verified in the failing direction before its green is
  trusted.
