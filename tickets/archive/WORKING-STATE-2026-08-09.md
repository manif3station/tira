# Working state, last updated 2026-08-10

Everything shipped, everything queued, and the one thing that is
blocked and why. Written at the owner's instruction so nothing depends
on my memory.

## Where it stands

Tira is at **1.01**. 73 test files, 2803 tests, 100% statement and
subroutine coverage on all three modules, taint clean, working tree
clean, everything pushed.

## Shipped in this stretch: 0.65 to 1.01

**EPIC-457, stale-card reminders** — complete. Dwell derived from the
existing history journal, per-column limits and a watched flag, an
escalation level counted rather than stored, ten tones, sticky warnings
for failures nobody would otherwise see, settings, and the collector
itself.

**EPIC-469, questions on cards** — complete. Ask, list, answer, update,
mark, discard, attach, voice. Project-wide `Q` references. Reason and
choices. Voice notes the agent records and Tira only stores. Evidence
on a question and on its answer. Terse machine-readable reminders of
what a question or a new record still owes. The card dialog panel with
click-to-answer choices, drag-and-drop, a growing answer box, and
judged questions collapsed to a verdict. Two board toggles, yellow for
the owner's move and greyed for the agent's, and blocked cards exempt
from chasing.

**Defects, mostly found by use rather than by tests** — the reentrant
lock, nesting refusal, wrapping boards, mojibake icons, the human
question view, the vanishing yellow, the erased panel, self-restarting
dashboards, the attachment count that read as zero, a manual example
that could not work, and the Discard column nobody could see.

## Queued and unblocked

Nothing. Everything raised has either shipped or been superseded.

## Blocked on the owner

**`DD-476`, the SQLite search index.** He asked for it; I will not
build it until he agrees one thing. An index is a second copy of the
truth, so it can only ever be a cache rebuilt from the files and never
what a read trusts when the two disagree. The filesystem being the
database is the premise the whole tool rests on, so that is his call
and not mine.

## Standing rules learned here, in priority order

1. **Verify every guard in the failing direction before trusting its
   green.** Three guards this stretch passed against deliberately
   broken builds before I caught them.
2. **Look at anything visual.** Two real defects passed every
   assertion and were obvious on screen.
3. **Never trust a coverage figure taken while another run is alive** —
   and check the previous container is actually dead, not merely
   finished.
4. **Reminders are read by an LLM.** Terse, mechanical, one line, and
   the fix in as few commands as possible. If a fix needs two commands,
   the command surface is telling on itself.
5. **The suite is the last thing before committing**, not the last
   thing before the documentation edits.
6. **Answer on the channel the owner used.**
