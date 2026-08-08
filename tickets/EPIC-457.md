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

## Open, asked or to ask

- **Q4 (asked):** with no collector state, is the escalation level
  derived from dwell time, or is a count stored somewhere after all?
  Those two cannot both be true as stated.
- Attribution: a browser drag records the move but leaves *who* blank,
  because the board does not know who is using it. Flagged to the owner;
  needs its own decision.
- Threshold value and whether it differs per column; relationship
  between threshold and beat interval.
- Delivery when the session is busy or the id is stale; what the
  collector does on failure.
- Whether the eye state lives in the project config (shared) or per
  browser (local).

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

Design in progress. No implementation until the open questions close.
