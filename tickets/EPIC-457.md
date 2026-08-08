# EPIC-457

## Title

Stale-card reminders: a collector that nags the agent session.

## Source

Owner voice messages 3014, 3017, 3020, 3023, 3026 (2026-08-08), through
his one-question-at-a-time protocol. **Design in progress — questions 4
onward are still open. Nothing is implemented.**

## Goal

A card that sits too long in a working column should produce an
escalating reminder in the coding-agent session that manages the
project, so work does not quietly stall.

## Settled by the owner

1. **The collector does the sending.** It scans, builds one list, and
   sends a single message to the Claude session — not one message per
   card. Because a DD collector is itself a command, the `claude`
   invocation lives there, so Tira's own code still spawns nothing and
   its documented no-external-process guarantee stands.
2. **All three boards** are scanned every beat — SOWs, epics, tickets.
3. **Age is measured from the moment the card entered its current
   column**, not from when the collector first noticed it. (Owner
   corrected an earlier reading of mine.)
4. **The collector holds no state.** Everything is computed from each
   card's own movement log.
5. **The movement log already exists** — the DD-443 per-field history
   records column moves with from, to, who, and when. It will be used
   rather than duplicated.
6. **Cards with no movement entry are skipped silently.** On the
   owner's real boards that is 89% of one and 99% of another, because
   history only began in 0.53; each joins the report naturally the
   first time it moves. No backfill, no invented history.
7. **Watching is per column**, toggled by an eye control on each column
   in the browser dashboard and by an equivalent command; unwatched
   columns are never reported. Column size is irrelevant — 100 or 1000
   cards are all scanned.
8. **Tone escalates** with how many times a card has been reported in
   its current column — plain, tense, angry, shouting, and onward from
   templates — and resets when the card moves.
9. **Onboarding gains three answers**: heartbeat interval in minutes,
   which coding agent (Claude only for now, still offered as a choice),
   and the session id. No interval means no collector.
10. **Onboarding must be re-runnable**, pre-filling every answer from
    what the project already stores, so a project onboarded earlier can
    gain the new settings by pressing enter through it.

## Settled since (questions 4 to 7)

11. **The escalation count lives in SQLite.** A `notification.db`
    beside `project.yml`, one row per notification holding the card
    reference, the time, and the column, indexed on reference and
    column. The level is `SELECT COUNT(*)` for that reference in its
    current column, so a move resets it for free — new rows carry a
    different column name. The owner chose this over writing the count
    onto the card, which also removes the whole question of
    notifications polluting the card's hash, stamp and history: the
    card is never rewritten at all.
12. **SQLite becomes a real dependency** (`DBD::SQLite`), declared in
    the cpanfile and added to the test container, which does not have
    it today. When it is missing, Tira must say plainly that SQLite
    needs installing rather than dying on a missing module. Noted for
    the record: this is the first thing in Tira that is not the
    filesystem, and the owner accepted that trade knowingly after being
    shown the alternative (an append-only text file, no dependency).
13. **Onboarding asks four things**, not three: the collector's own
    name (defaulted from the workspace reference, editable — note DD
    prefixes it, so the stored name becomes `tira.<name>`), the coding
    agent, the session id, and the heartbeat. It also asks once for a
    **default staleness threshold**.
14. **The threshold is per column**, falling back to that project
    default. Storage correction made to the owner and accepted unless
    he objects: column folders have no config file of their own, so the
    threshold goes on the column's existing entry in the board config
    rather than in a new per-folder file.
15. **A column editor** is wanted: a button on each board control
    opening a modal shaped like the card modal but showing the board's
    structure — add, remove, reorder by dragging, and set each column's
    notification time. Scoped out as **its own ticket**: it is a board
    structure editor, not notification work. The notification ships
    first with the setting storable; the editor then becomes its UI.
16. **Attribution proposal** (stated, not yet confirmed): the board
    remembers which of the project's people you are, chosen once and
    kept locally like the width setting, and stamps that on moves made
    from the board. Blank stays blank when nobody is chosen, so nothing
    is invented.

## Open, asked or to ask

- **Q8 (asked, last):** when delivery fails — stale session id, missing
  `claude`, busy agent — is the notification still recorded? It decides
  whether escalation is honest: a row written for an undelivered
  message escalates a card to shouting while the owner has heard
  nothing, and the first message he ever sees is a furious one about a
  card nobody told him about. Recommended: record only on success, and
  have the collector report its own failure once rather than going
  silent.
- Whether the eye (watched) state lives in the board config (shared) or
  per browser (local). Not yet asked.
- Escalation template wording for each level.

## Research already done (2026-08-08)

- DD collectors are declared in `<skill>/config/config.json`, run as
  forked daemon loops, interval in **seconds** (default 30), with a
  hidden 30-second floor for commands starting `dashboard`/`d2` unless
  `allow_fast_poll` is set. Tira has no `config/` directory yet.
- The workspace's DD reference copy is stale (3.92) against the runtime
  that actually executes (4.16); read the runtime, not the reference.
- Dwell for a whole board costs ~10ms measured on the owner's real
  boards, reading journals backwards with a string prefilter before
  decoding. Per-card CLI calls would cost ~145ms each — unusable.
- `--since` cannot see moves (a move does not touch `last_updated`);
  `--if-changed` can, because the content hash covers the column.
- `column_remove` and `column_rename` relocate cards without journaling,
  so the reader must not require the last move's target to equal the
  card's current column. Arguably its own defect ticket.

## Status

Design in progress; questions 1 to 7 answered, question 8 outstanding.
No implementation until it closes.
