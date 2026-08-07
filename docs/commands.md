# Complete Command Ecosystem

Release 0.16 implements every workflow in `SKILLS.md` through 83 Developer
Dashboard entrypoints. The shared `Tira::CLI` parser applies TOON-first output,
pretty JSON, Markdown, repeatable options, JSON-array replacement, raw
attachment output, and consistent structured failures.

## Capability groups

- Project metadata, people, custom reciprocal link types, and validation.
- SOW, epic, and ticket boards with protected Backlog/Discard, ordered custom
  columns, drift synchronization, and future-reference configuration.
- Full work-record creation and update, filtered filesystem listing, movement,
  discard, restoration, and cloning.
- Atomic SOW→epic and epic→ticket hierarchy, cycle-free same-type subitems, and
  typed cross-entity links.
- Singular assignee, optional reporter, person activation controls, immutable attributed comments, comment attachments,
  evidence, and gate observations.
- Ordered SOW, epic, and ticket checklists with immutable entry IDs and
  user-controlled item/status values.
- Case-insensitive labels, zoned planning dates, lifecycle/SDLC text, numeric
  priorities, fix/affected versions, and a generated immediate parent.
- SHA-256 attachment deduplication, path-private raw retrieval, append-only deletion
  logging, and identical-content restoration.
- Filesystem search and an ordered Markdown/structured Kanban dashboard.
- Self-contained table dashboards with query-controlled refresh and optional
  live Dancer2 PSGI serving on a validated local bind. Browser mode polls the
  lightweight placement projection, updates card placement in place, performs
  real JSON-file moves on drag/drop, lazy-loads complete card details in a
  Jira-style sectioned dialog, and reports when displayed data was last
  refreshed. The dialog edits single-value fields through the validated
  engine, and adds, edits, and permanently deletes comments with an
  active-people author picker (`tira.comment.remove` is the CLI twin).
- Strict UTF-8 CLI/text boundaries, canonical UTF-8 persistence and output,
  and lossless recovery of isolated legacy bytes.
- One-call export, full lists, field-aware search, previewable bulk correction,
  and append-only gate/evidence annotations for migrations.
- Single-scan dashboard grouping per selected board, independent of column
  count, while preserving configured order and Discard filtering.
- Metadata-free default dashboard cards, optional `--title` reads, and complete
  `-o json` records, all ordered newest-first by file modification time.
- Self-contained `-o table` HTML for combined and type-specific dashboards,
  with polished offline CSS, selectable cards, and client-side mtime/ref sorts.

## Transaction boundaries

Every mutation takes the private project lock. Reciprocal record changes first
snapshot all affected JSON and restore every snapshot if a later write fails.
Column add, rename, and removal similarly roll back their filesystem changes
when configuration persistence fails. Reference counters only increase and
failed counter persistence removes the uncommitted record.

## Private project aliases

Project-directory selectors accept either an existing relative/absolute
directory or an alias registered with `d2 path add`. Existing directories take
precedence over an alias of the same spelling. Alias lookup uses Developer
Dashboard's registry and layered config directly; it does not spawn a command,
parse human output, or disclose the resolved target in Tira output and errors.

## Accumulating record fields

On record update, repeated `--key-detail`, `--deliverable`, `--acceptance`,
`--test-step`, `--bdd`, `--atdd`, `--scope-in`, and `--scope-out` values append
in supplied order. Existing values are retained. The corresponding `--set-*`
JSON-array options remain the explicit wholesale-replacement controls for the
six content arrays; scope has no replacement option.

## Attachment response truth

Attachment content remains globally deduplicated by SHA-256, while filenames
belong to a specific record or comment attachment list. `attachment.add`
returns `original_filename` from the reference actually retained,
`supplied_filename` from the current call, and `deduped` as a Boolean. A true
value therefore makes filename collapse explicit. Removing content never
removes record references, so re-adding bytes reports the still-retained name.

## Agent boundary

Managed project location is intentionally omitted. Agents use Tira commands for
all reads and mutations and must not attempt direct filesystem access. Run
`dashboard tira.skills` for the full argument matrix and UC-001 through UC-100.

## Migration-scale commands

`tira.export` returns `{records, count}` for every type and column in one call.
Existing record-list commands retain their compatible array result; `--full`
is an explicit assertion that the full records already returned are required.

The read cache is opt-in per call: `--cache-ttl N` on read commands serves
repeated identical calls locally while both the ttl and a board fingerprint
hold — any write invalidates immediately (read-your-own-writes), hits are
reported on stderr, corrupt entries warn and fall back to a live read, and
entries live under the project workspace, never a shared temp path.
`--no-cache` bypasses explicitly; mutations and zero ttls exit 2.

`-o json` is compact by default — canonical key order, raw UTF-8, one line
— and `-o json-pretty` keeps the previous indented shape. The two carry
identical information; whitespace was pure cost for machine callers.

Gate and evidence logs read indexed: `--last`/`--first` windows over the
newest-last order, `--id` for one entry (loud when missing), `--meta-only`
with text lengths and annotation counts, `--where` entry filters such as
`result=fail`, and `--count`. Annotations stay with their parent entry;
reading an append-only log never mutates it.

A project remembers the address its live dashboard should listen on:
`tira.project.update --dashboard-host localhost --dashboard-port 8080` stores it,
`project.show` reports it, and `-o browser` uses it. Precedence is stated rather
than incidental — an address on the command line beats the remembered one, which
beats the `0.0.0.0:7899` default — and both values are validated where they are
set, not where they are used.

`tira.onboard` is the guided form of the same thing: it asks for the name,
directory, people, each board's reference prefix, whether the boards share one
column set, and the columns, then confirms before writing. Flags pre-fill the
answers, unusable answers are re-asked, and both declining and running out of
input leave nothing behind. Only `tira.onboard` ever prompts — `project.new`
is purely argument-driven so nothing automated can be left waiting on input.

`tira.project.new` bootstraps in one call what `project.create`, `project.people.add`,
`board.refs`, and `column.add` otherwise do across dozens: it creates the project,
adds each member, sets each board's reference prefix, and applies one shared column
set to all three boards. Column names are given as human text and slugified
automatically with the original kept as the label, columns that already exist are
skipped so re-running is safe, and everything is validated before the first write so
a rejected call leaves nothing behind. Prefixes are applied before any record can be
created, because board counters never rewind.

`tira.diff` is the watcher: `--since T` lists added/changed records with
their current column, gate, title, and new-comment ids plus `now` for the
next poll; `--snapshot FILE` (a saved `tira.export --include-empty -o json`)
adds per-field before/after for scalars and distinguishes added, changed,
and removed — a deletion is never mistaken for quiet. Field scoping and
`--count` compose; exactly one baseline is required; diff never writes.

Batch reads collapse N invocations into one: repeat `--ref` or pass
`--refs A,B,C` to show, and the response is keyed by ref with the request
order preserved, explicit not-found markers for missing refs, a 100-ref
documented maximum, and full composition with projection and brief. A bad
ref never loses the call; a bad option never half-succeeds.

`--where` on list and export filters server-side: repeatable ANDed clauses
with `=` equality, `=` against an empty value meaning empty-or-unset, `!=`
inequality (and `!=` empty meaning has-a-value), and `~` case-insensitive
array containment that never crashes on scalars. Unknown fields and
operatorless clauses exit 2. A query returning three records now costs three
records, not the board.

Comment reads window and slim down: `--last N`/`--first N` (newest-last
storage order), `--meta-only` (id, author, stamps, body length, attachment
count), comment-level `--fields` with `id` always kept, `--since` against the
comment's own stamps, and `--count`. Attachment lists enrich under
`--meta-only` with the stored filename, real byte size, content type, and
added time, newest first, in an envelope carrying `count` and `total_size`.
Record reads accept `--meta-only` to strip embedded comment bodies, and the
computed `attachment_count` field joins `--fields` for evidence coverage.

`--brief` on show, list, and export is the documented five-field preset
(`ref,title,column,sdlc_gate,assignee`, title cut at a stable 72 characters);
long text fields and gate/evidence entry text truncate at 2000 characters by
default with an ellipsis plus `_truncated`/`_length` markers — never
silently. `--truncate N` picks the limit, `--truncate 0` omits but marks,
`--full` restores the complete values, and contradictory combinations exit 2.
Hashes are computed before truncation, so a truncated read and a full read
agree about change.

`--count` on list, export, and search suppresses the records and returns the
count alone; `--refs-only` on list and search returns a flat, stably ordered,
deduplicated ref array. Count wins over refs-only wins over field selection —
documented precedence, and misspelled field names still fail loudly. Human
output prints a bare number or one ref per line for direct shell use.

Records expose a computed `content_hash` through field selection: an opaque
stable token over every meaningful field including placement, excluding only
`last_updated`, so a touched-but-identical record keeps its hash. Export adds
a `board_hash` whenever hashes are requested. `--if-changed HASH` on show and
export answers with `{"unchanged": true}` and exit 1 when nothing differs,
the full (projectable) payload with exit 0 when something does, and exit 2 on
a malformed hash — a bad token must never quietly mean "changed". Combined
with `--since`, the stricter suppression wins; conditional reads never write.

Show, list, and export accept `--since TIMESTAMP` to return only records
whose `last_updated` is at or after that instant (timezone-aware, never a
string comparison). Export's envelope then carries `now` — the server clock
captured before the scan — so a poller passes it back as its next `--since`
and can never miss a change; a record touched in the boundary second may
appear twice, which is the safe side. Future timestamps return empty with
exit 0, malformed ones exit 2, and a record whose stored stamp is
unreadable is always returned.

Show, list, and export omit empty values by default — null, empty string,
empty array, or a hash containing only such values — and `--include-empty`
restores the previous fixed-key shape. `false` and `0` are never treated as
empty, and a field named in `--fields` is returned even when empty, so an
explicit question always gets an explicit answer.

Show, list, and export accept `--fields` and `--exclude-fields`
(comma-separated, repeatable, accumulating) to project each returned record.
Selection always keeps `ref`, exclusion applies after selection, stored data
is never altered, and an unknown or empty field name fails with exit 2 naming
the field. The full record remains the default — asking for everything is a
choice, not a tax.

Field-aware search returns `{hits, count}` and each hit includes ref, type,
column, dotted field path, and matched value. Search uses the same envelope
without field scoping, where each hit is a complete matching record. Repeated
`--field` options accumulate in supplied order. `tira.replace` operates only on
mutable content fields and returns field-level before/after changes. `--dry-run`
performs no write.

Scope corrections to instruction-bearing fields when comments must remain
historical: a legacy string in a description is an instruction to fix; the
same string in a comment is a record to preserve. Omitting `--field` from
replace selects every mutable field.

`tira.import --file changes.json` accepts a JSON object keyed by record ref.
Values are exact replacement fields. It validates every record and field before
writing the complete set transactionally; `--dry-run` returns the same diff
without mutation. Gate and evidence logs remain append-only: annotate commands
append attributed correction notes to stable entry IDs.

An import dry-run returns one object per changed field:

```json
{
  "changes": [
    {"ref":"TKT-001","field":"description","before":"old","after":"new"},
    {"ref":"TKT-001","field":"atdd","before":[],"after":["one","two"]}
  ],
  "changed_records": 1,
  "dry_run": true
}
```
