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
