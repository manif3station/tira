# EPIC-424

## Title

Token-efficiency read paths: CA01–CA20.

## Source

Owner document `20-enhancement.md` (Telegram message 2941, caption
"CA01-CA20"), stored verbatim as `tickets/SOW-CA-token-efficiency.md`;
directive "Work on these enhancements and gate them all" (message 2938).

## Goal

Stop an agent paying for bytes it did not ask for. Four compounding
groups: ask for less (field selection, presets, truncation), do not send
what has not changed (since, hashes, conditional reads, diff, cache),
send it more densely (compact format, omit empty), ask once instead of
many times (server-side filtering, batch reads).

## Standing principle (owner's caution, binding on every ticket)

Every saving is opt-in or provably lossless; the full payload stays
reachable; where a saving and a correctness guarantee conflict, the
correctness guarantee wins. Failures are loud: unknown fields, malformed
timestamps, and bad hashes exit 2 rather than silently matching
everything or nothing.

## Ticket map (each a gated release)

- DD-424 (0.35) — CA01+CA02+CA03: `--fields` / `--exclude-fields` on
  show, list, and export through one shared projection layer.
- DD-425 (0.36) — CA15: omit null/empty values by default with
  `--include-empty`; `false`/`0` never treated as empty.
- DD-426 (0.37) — CA04: `--since TIMESTAMP` filtering with a `now`
  stamp in the envelope.
- DD-427 (0.38) — CA05+CA06: stable per-record `content_hash`, board
  hash on export, `--if-changed HASH` conditional reads.
- DD-428 (0.39) — CA07+CA17: `--count` and `--refs-only`.
- DD-429 (0.40) — CA08+CA09: `--brief` preset; default truncation of
  long text with markers, `--truncate N`, `--full`.
- DD-430 (0.41) — CA10+CA11+CA12: `--last/--first` comment windows,
  `--meta-only` for comments and attachments.
- DD-431 (0.42) — CA16: repeatable `--where FIELD=VALUE` (equality,
  inequality, absence, array containment) ANDed server-side.
- DD-432 (0.43) — CA19: batch reads (`--ref` repeatable / `--refs`),
  explicit not-found markers, documented maximum.
- DD-433 (0.44) — CA13: `tira.diff` (`--since` or `--snapshot`),
  added/changed/removed with previous and new scalar values.
- DD-434 (0.45) — CA20: indexed reads on gate log and evidence
  (`--last/--first/--id/--meta-only`, `--where result=`).
- DD-435 (0.46) — CA14: compact `-o json` default, `-o json-pretty`
  preserving today's shape, stable key order.
- DD-436 (0.47) — CA18: opt-in read-through cache, disabled by default,
  write-invalidated, never able to break the tool.

Priority order follows the document's closing note: field selection
first, then change detection, with the near-free densification early.

## Status

In progress — DD-424 started 2026-08-06.
