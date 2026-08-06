# Tira Agent Skill Manual

Tira is a filesystem-native Jira-style Kanban system exposed through Developer
Dashboard. It manages projects, SOWs, epics, tickets, columns, relationships,
people, comments, evidence, gates, and content-addressed attachments without a
server or hidden database. Never edit Tira-managed YAML or JSON directly.

## Availability legend

- **Implemented (0.01):** shipped, executable, and covered by tests.
- **Implemented (0.02):** shipped, executable, and covered by tests.
- **Implemented (0.03):** shipped, executable, and covered by tests.
- **Implemented (0.04):** shipped, executable, and covered by tests.
- **Implemented (0.05):** shipped, executable, and covered by tests.
- **Implemented (0.06):** shipped, executable, and covered by tests.
- **Implemented (0.07):** shipped, executable, and covered by tests.
- **Implemented (0.08):** shipped, executable, and covered by tests.
- **Implemented (0.09):** shipped, executable, and covered by tests.
- **Implemented (0.10):** shipped, executable, and covered by tests.
- **Implemented (0.11):** shipped, executable, and covered by tests.
- **Implemented (0.12):** shipped, executable, and covered by tests.
- **Implemented (0.13):** shipped, executable, and covered by tests.
- **Implemented (0.14):** shipped, executable, and covered by tests.
- **Implemented (0.16):** shipped, executable, and covered by tests.
- **Implemented (0.17):** shipped, executable, and covered by tests.
- **Implemented (0.18):** shipped, executable, and covered by tests.
- **Implemented (0.19):** shipped, executable, and covered by tests.
- **Implemented (0.20):** shipped, executable, and covered by tests.
- **Implemented (0.21):** shipped, executable, and covered by tests.
- **Implemented (0.22):** shipped, executable, and covered by tests.
- **Implemented (0.23):** shipped, executable, and covered by tests.
- **Implemented (0.24):** shipped, executable, and covered by tests.
- **Implemented (0.25):** shipped, executable, and covered by tests.
- **Implemented (0.26):** shipped, executable, and covered by tests.
- **Implemented (0.27):** shipped, executable, and covered by tests.
- **Implemented (0.28):** shipped, executable, and covered by tests.
- `dashboard tira.skills` is implemented and prints this file as raw Markdown.

All commands and use cases in this manual ship in release 0.28.

## Global invocation grammar

```text
dashboard tira.<resource>.<action> [arguments] [-o FORMAT]
dashboard tira.skills

FORMAT := toon | json | human
DASHBOARD_FORMAT := toon | json | human | table
TYPE   := sow | epic | ticket
```

References are immutable, case-sensitive values such as `SOW-001`, `EPC-001`,
and `TKT-001`. Quote whitespace, Markdown, glob characters, and empty strings.
Repeat an option only where its table marks it repeatable. `--help` is exclusive
and performs no mutation.

All command-line text, text files, YAML, JSON, and structured output use UTF-8.
Invalid UTF-8 input is rejected. Non-ASCII text, including `£`, is preserved in
titles, fields, comments, evidence, and gate details. Attachment content remains
raw bytes. When a legacy record contains an isolated non-UTF-8 byte, Tira
repairs it during reading and persists canonical UTF-8 on the next mutation.

## Argument precedence

Project location is intentionally opaque and is never disclosed to agents.
Use Tira commands exclusively; do not locate, inspect, or edit managed storage.
For ordinary fields, explicit update values win, omitted fields stay unchanged,
and `--field ""` clears nullable text. Supply `-o` at most once. Append options
and `--set-*` for the same field are mutually exclusive.

## Output contract

- Default and `-o toon`: `Data::TOON` output.
- `-o json`: canonical pretty JSON with the full result.
- `-o human`: Markdown summary.
- Errors use the selected structured format on stderr, never success stdout.
- Mutations return the affected record or operation receipt.
- `attachment.get` emits raw bytes and never exposes managed storage paths.
- `tira.skills` emits raw Markdown and accepts no options.

## Exit status contract

| Status | Meaning |
| --- | --- |
| `0` | Completed. |
| `1` | Content-specific negative result, such as deleted attachment content. |
| `2` | Usage, validation, lookup, conflict, or output failure. |

Validation failure creates no mutation. A failed multi-record operation leaves
both sides unchanged. Always check status before consuming output.

## Project database

Tira owns a private filesystem-backed database. Its location and discovery
mechanism are deliberately absent from this agent manual. Access it only
through documented commands. There is no supported manual-edit workflow.

## Concurrency and transaction semantics

Mutations take the project lock, write a validated same-directory temporary
file, and atomically rename it. Multi-record links validate both ends first and
roll back partial writes. Board counters only increase; refs are never reused.
Column sync compares YAML order with real directories. Attachments are keyed by
SHA-256 bytes, so identical content deduplicates while refs retain original
filenames.

## Record schema

Every SOW, epic, and ticket JSON contains `ref`, `type`, `title`, `description`,
`key_details`, `problem_or_feature`, `solution_needed`, `deliverables`,
`scope.included`, `scope.excluded`, `source`, `acceptance_criteria`,
`test_steps`, `bdd`, `atdd`, `gate_passing_log`, `evidence`, `attachments`, `checklist`,
`subtasks`, `linkage`, `assignee`, `reporter`, `labels`, `due_date`,
`start_date`, `sdlc_gate`, `lifecycle`, `priority`, `fix_version`,
`affects_versions`, `parent`, `comments`, `created_at`, and `last_updated`.

Comments have an ID, author, `markdown|text` format, body, attachments, creation
time, and last update. Evidence and gate entries are append-only observations.
Assignees and reporters must be active people defined in `project.yml`.
Checklist entries have an immutable `CHK-NNN` ID, `item`, free-text `status`,
creation time, and last update. Status is descriptive; Tira never infers record
completion or moves a record from it.
Checklist entries are retained, not deleted; there is no remove command. Word
an entry as though it will outlive the work, and change its item or status only
with `tira.checklist.update`.

## Record metadata contract

The following implemented contract applies symmetrically to SOWs, epics, and
tickets.

- `assignee`: one active project-person ID or `null`. Human output renders the
  current person name. One record has at most one assignee.
- `reporter`: one project-person ID or `null`. It is optional and human output
  renders the current person name.
- `labels`: an array of case-insensitive free-text values. Preserve the first
  spelling supplied and reject later case-insensitive duplicates.
- `due_date` and `start_date`: nullable ISO 8601 date-times with a mandatory
  timezone, such as `2026-08-05T14:30:00+01:00` or
  `2026-08-05T13:30:00Z`.
- `sdlc_gate` and `lifecycle`: nullable free-text values. `sdlc_gate` is
  independent of append-only structured gate log entries.
- `priority`: nullable JSON integer from `1` through `5`. Human output renders
  `Low`, `Medium Low`, `Medium`, `High`, or `Very High`, respectively.
- `fix_version`: one nullable free-text value.
- `affects_versions`: an array of free-text values, empty by default.
- `parent`: one generated parent ref or `null`; it is never directly editable.

Parent is the immediate structural parent only. A sub-ticket's parent is its
master ticket, not its epic; a sub-epic's parent is its master epic, not its
SOW. Otherwise, an epic's parent may be its SOW and a ticket's parent may be
its epic. A sub-SOW may have one parent SOW. More distant ancestry remains
discoverable by following parent linkage.

Implemented create/update arguments are:

```text
--assignee ID|"" --reporter ID|""
--label TEXT ... --set-labels FILE
--due-date DATETIME|"" --start-date DATETIME|""
--sdlc-gate TEXT|"" --lifecycle TEXT|"" --priority 1..5|""
--fix-version TEXT|""
--affects-version TEXT ... --set-affects-versions FILE
```

Repeated `--label` and `--affects-version` values append on update. Their
`--set-*` forms replace the complete array from a UTF-8 JSON-array file; `-`
reads stdin. Append and replacement forms for the same field conflict. Empty
strings clear nullable scalar fields. Parent changes only through hierarchy or
sub-item link commands.

The same append rule applies to repeated `--key-detail`, `--deliverable`,
`--acceptance`, `--test-step`, `--bdd`, `--atdd`, `--scope-in`, and
`--scope-out` values. Existing values remain first and new values retain CLI
order. `--set-key-details`, `--set-deliverables`, `--set-acceptance`,
`--set-test-steps`, `--set-bdd`, and `--set-atdd` are the explicit full-array
replacement controls. Scope has no wholesale replacement command.

Project people gain an `active` Boolean, defaulting to true. Inactive people
remain rendered on historical records but cannot become a new assignee or
reporter. Reactivation restores eligibility. Person removal is rejected while
any historical assignee, reporter, author, or other person reference remains.
The implemented commands are:

```text
tira.project.people.deactivate --id ID [-o FORMAT]
tira.project.people.activate --id ID [-o FORMAT]
```

## Record field arguments

| Argument | Repeatable | Create | Update | Meaning |
| --- | ---: | ---: | ---: | --- |
| `--title TEXT` | no | required | optional | Summary. |
| `--description TEXT` | no | optional | optional | Markdown body. |
| `--key-detail TEXT` | yes | optional | append | Key fact. |
| `--problem TEXT` | no | optional | optional | Problem/feature. |
| `--solution-needed TEXT` | no | optional | optional | Requested outcome. |
| `--deliverable TEXT` | yes | optional | append | Delivery. |
| `--scope-in TEXT` | yes | optional | append | Included scope. |
| `--scope-out TEXT` | yes | optional | append | Excluded scope. |
| `--source TEXT` | no | optional | optional | Origin. |
| `--acceptance TEXT` | yes | optional | append | Acceptance criterion. |
| `--test-step TEXT` | yes | optional | append | Verification step. |
| `--bdd TEXT` | yes | optional | append | BDD scenario. |
| `--atdd TEXT` | yes | optional | append | ATDD scenario. |
| `--assignee ID|""` | no | optional | replace/clear | Active project person. |
| `--reporter ID|""` | no | optional | replace/clear | Active project person. |
| `--label TEXT` | yes | optional | append | Case-insensitive unique label. |
| `--due-date DATETIME|""` | no | optional | replace/clear | Zoned ISO 8601 date-time. |
| `--start-date DATETIME|""` | no | optional | replace/clear | Zoned ISO 8601 date-time. |
| `--sdlc-gate TEXT|""` | no | optional | replace/clear | Free-text SDLC state. |
| `--lifecycle TEXT|""` | no | optional | replace/clear | Free-text lifecycle. |
| `--priority 1..5|""` | no | optional | replace/clear | Numeric priority. |
| `--fix-version TEXT|""` | no | optional | replace/clear | One target version. |
| `--affects-version TEXT` | yes | optional | append | Affected version. |

All listed create and update fields are implemented. Updates may replace arrays
with `--set-<field> FILE`; `-` reads a UTF-8 JSON array from stdin.
`--problem-or-feature` aliases `--problem`; `--acceptance-criteria` aliases
`--acceptance`; and `--set-acceptance-criteria` aliases `--set-acceptance`.

## Command catalogue

### Manual and project

- `tira.skills` — **Implemented.** No arguments; raw manual.
- `tira.project.create --name TEXT [--dir DIR] [-o FORMAT]` — **Implemented.**
  Name required; directory defaults to `.`; existing projects are preserved.
- `tira.project.show [-o FORMAT]` — **Implemented.**
- `tira.project.update [--name TEXT] [-o FORMAT]` — **Implemented.**
- `tira.project.people.list [-o FORMAT]` — **Implemented.**
- `tira.project.people.add --id ID --name TEXT [--email EMAIL] [-o FORMAT]` — **Implemented.**
- `tira.project.people.update --id ID [--name TEXT] [--email EMAIL|""] [-o FORMAT]` — **Implemented.**
- `tira.project.people.activate --id ID [-o FORMAT]` — **Implemented.**
- `tira.project.people.deactivate --id ID [-o FORMAT]` — **Implemented.**
- `tira.project.people.remove --id ID [-o FORMAT]` — **Implemented.** Fails while historically referenced.
- `tira.project.link-types.list [-o FORMAT]` — **Implemented.**
- `tira.project.link-types.add --outward NAME --inward NAME [-o FORMAT]` — **Implemented.** Names unique.
- `tira.project.link-types.remove --outward NAME [-o FORMAT]` — **Implemented.** Protected types remain.
- `tira.project.validate [--repair-columns] [-o FORMAT]` — **Implemented.** Read-only without repair.

### Boards and columns

All are **Implemented (DD-389)** and require `--type sow|epic|ticket`:

```text
tira.board.show --type TYPE [-o FORMAT]
tira.column.list --type TYPE [-o FORMAT]
tira.column.add --type TYPE --name SLUG [--label TEXT] [--after SLUG|--before SLUG] [-o FORMAT]
tira.column.rename --type TYPE --name SLUG --new-name SLUG [--label TEXT] [-o FORMAT]
tira.column.reorder --type TYPE --name SLUG (--after SLUG|--before SLUG) [-o FORMAT]
tira.column.remove --type TYPE --name SLUG [-o FORMAT]
tira.column.sync --type TYPE [--apply] [-o FORMAT]
tira.board.refs --type TYPE [--prefix PREFIX] [--digits N] [-o FORMAT]
```

`--after` and `--before` conflict. Slugs use lowercase letters, digits, and
hyphens. Backlog/Discard cannot be renamed, reordered, or removed. Removing a
custom column moves records to Discard. Sync reports drift unless `--apply`.
Prefix/digit changes affect future refs and never lower `next_number`.

### Records

These create commands are **Implemented**:

```text
tira.sow.create --title TEXT [record field arguments] [-o FORMAT]
tira.epic.create --title TEXT [record field arguments] [-o FORMAT]
tira.ticket.create --title TEXT [record field arguments] [-o FORMAT]
```

They create independent Backlog records with empty linkage. These symmetric
forms are **Implemented (DD-389)** for each `TYPE`:

```text
tira.TYPE.show --ref REF [-o FORMAT]
tira.TYPE.list [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [-o FORMAT]
tira.TYPE.update --ref REF [record field arguments] [-o FORMAT]
tira.TYPE.move --ref REF --column SLUG [-o FORMAT]
tira.TYPE.discard --ref REF [-o FORMAT]
tira.TYPE.restore --ref REF [--column SLUG] [-o FORMAT]
tira.TYPE.clone --ref REF --title TEXT [-o FORMAT]
```

List filters use AND. Parent means the generated immediate parent ref. Discard
is movement, not deletion; restore defaults to Backlog.
Clone creates a Backlog record, shares attachment refs, clears hierarchy, and
adds reciprocal clone links.

### Hierarchy and typed links

All are **Implemented (DD-389)**, with immediate-parent projection updated by
DD-390:

```text
tira.hierarchy.link --parent REF --child REF [-o FORMAT]
tira.hierarchy.unlink --parent REF --child REF [-o FORMAT]
tira.hierarchy.show --ref REF [--recursive] [-o FORMAT]
tira.subitem.link --parent REF --child REF [-o FORMAT]
tira.subitem.unlink --parent REF --child REF [-o FORMAT]
tira.link.add --from REF --type NAME --to REF [-o FORMAT]
tira.link.remove --from REF --type NAME --to REF [-o FORMAT]
tira.link.list --ref REF [--type NAME] [-o FORMAT]
```

Hierarchy permits only SOW→epic and epic→ticket. Reparenting removes the old
reciprocal relationship. Sub-items are same-type, one-to-many, and cycle-free.
Hierarchy show returns the complete direct-read record plus `children`; human
output adds a Children section. An empty children array means the record was
read successfully and has no children. An unresolved ref exits `2`. Recursive
children are complete records; immediate children are ref-only summaries.
Typed links may cross types. Built-ins are `blocks`/`is-blocked-by`,
`clones`/`is-cloned-by`, `duplicates`/`is-duplicated-by`, and symmetric
`relates-to`. Link add is idempotent. Tira never infers completion.

### Assignments and comments

All are **Implemented (DD-389)**, with singular assignment semantics updated
by DD-390:

```text
tira.assign.list --ref REF [-o FORMAT]
tira.assign.add --ref REF --person ID [-o FORMAT]
tira.assign.remove --ref REF --person ID [-o FORMAT]
tira.assign.set --ref REF [--person ID] [-o FORMAT]
tira.comment.list --ref REF [-o FORMAT]
tira.comment.add --ref REF --author ID (--text TEXT|--file FILE) [--format markdown|text] [--attach PATH ...] [-o FORMAT]
tira.comment.update --ref REF --comment ID (--text TEXT|--file FILE) [--format markdown|text] [-o FORMAT]
tira.comment.remove --ref REF --comment ID [-o FORMAT]
tira.comment.attach --ref REF --comment ID --file PATH [-o FORMAT]
```

People must exist and be active for new assignments. Assignment add replaces
the singular assignee; set accepts at most one person and clears with no
`--person`. Remove clears only a matching assignee. Comment `--text`/`--file`
conflict; `--file -` reads stdin.
Markdown is default. Updates preserve creation time. Repeated `--attach`
imports files before writing the comment. `tira.comment.remove` permanently
deletes one comment by id and reports the removed comment; an unknown id
fails with exit 2 and no change. Removal updates the record's last-updated
timestamp; comment ids keep increasing and are never reused.

### Attachments

All are **Implemented (DD-389)**:

```text
tira.attachment.add --ref REF --file PATH [--comment ID] [-o FORMAT]
tira.attachment.list [--ref REF] [--include-deleted] [-o FORMAT]
tira.attachment.get --sha SHA256 [--extension EXT]
tira.attachment.remove --sha SHA256 [--extension EXT] [-o FORMAT]
tira.attachment.detach --ref REF --sha SHA256 [--extension EXT] [--comment ID] [-o FORMAT]
```

Add hashes bytes, stores `sha256.extension`, and records the original filename.
Many refs may share content. Remove deletes content, appends to
`delete.log.yml`, and preserves JSON refs. Re-adding identical bytes restores
the object. Deleted get emits `Deleted at <timestamp>` raw and exits `1`.
Managed storage paths are never returned; redirect raw bytes to a destination.
Attachment deduplication is scoped to the target record or comment list. Add
returns `original_filename` from the reference actually retained,
`supplied_filename` from the current request, and Boolean `deduped`. Thus a
same-target duplicate with a different name reports the retained first name,
the rejected supplied name, and `deduped: true`. A different record may retain
another filename for the same SHA. These response fields do not alter stored
references.

### Checklists, evidence, gates, migration, search, and dashboard

All are **Implemented (DD-389)**:

```text
tira.checklist.list --ref REF [-o FORMAT]
tira.checklist.add --ref REF --item TEXT --status TEXT [-o FORMAT]
tira.checklist.update --ref REF --id CHK-NNN [--item TEXT] [--status TEXT] [-o FORMAT]
tira.evidence.list --ref REF [-o FORMAT]
tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [-o FORMAT]
tira.evidence.annotate --ref REF --id EVD-NNN --note TEXT [--author ID] [-o FORMAT]
tira.gate.list --ref REF [-o FORMAT]
tira.gate.add --ref REF --gate TEXT --result pass|fail|blocked --details TEXT [--author ID] [-o FORMAT]
tira.gate.annotate --ref REF --id GATE-NNN --note TEXT [--author ID] [-o FORMAT]
tira.export [-o FORMAT]
tira.<type>.list [--full] [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [-o FORMAT]
tira.import --file FILE [--dry-run] [-o FORMAT]
tira.search --text QUERY [--field FIELD ...] [--type TYPE] [--column SLUG] [--assignee ID] [-o FORMAT]
tira.replace --pattern REGEX --with TEXT [--field FIELD ...] [--type TYPE] [--dry-run] [-o FORMAT]
tira.dashboard [--type TYPE|all] [--include-discard] [--title] [-o DASHBOARD_FORMAT]
tira.dashboard.sow [--include-discard] [--title] [-o DASHBOARD_FORMAT]
tira.dashboard.epic [--include-discard] [--title] [-o DASHBOARD_FORMAT]
tira.dashboard.ticket [--include-discard] [--title] [-o DASHBOARD_FORMAT]
```

Checklist commands apply symmetrically to SOWs, epics, and tickets. Add
requires both non-empty values. Update requires at least one of `--item` or
`--status`; omitted values remain unchanged. Entries retain order and IDs.
Evidence may have both URI and file. Gates record observations but never move
work. Search scans files without an index and combines filters with AND.
Dashboard follows configured column order and excludes Discard by default.
Gate/evidence entries have stable IDs and `annotations`; annotate appends an
attributed correction while preserving the original entry. There is no general
gate/evidence update command.

Export returns `{records, count}` for every type and column. List continues to
return its compatible full-record array; `--full` explicitly requests that
existing shape. Search always returns `{hits, count}`. Without field scoping,
hits are complete records. With repeated `--field`, hits contain dotted field
paths and matched values from every named field in supplied order.

Repeated search/replace fields accumulate. Omit replace fields to scan every
mutable field. Name fields when historical content must be excluded: a legacy
string in a description is an instruction to fix; the same string in a comment
is a record to preserve. Scoped replacement never visits an unnamed field.

Import reads a UTF-8 JSON object keyed by ref and treats supplied fields as
exact replacements. It validates the whole set, returns field-level diffs, and
writes transactionally unless `--dry-run` is present. Replace scans mutable
content only, accepts a Perl regular expression, returns before/after diffs,
and performs no write with `--dry-run`. Neither command rewrites gate or
evidence observations.

Dashboard scans each selected board once and groups records by configured
column in memory. Column count therefore does not multiply JSON file reads;
configured order and optional Discard inclusion remain unchanged.
Default TOON and human dashboards contain only refs and use filename/stat data,
without decoding records. `--title` decodes each card once to add its title.
`-o json` returns complete records. All modes sort cards by filesystem
modification time, newest first, then by ref when timestamps tie.
For these four dashboard commands only, `-o table` prints a complete raw HTML
document. The combined command stacks SOW, epic, and ticket boards; specific
commands print one board. Columns run left-to-right. Embedded CSS provides the
responsive visual design, while embedded JavaScript lets the viewer select
cards and reorder each board by last modified or card ref. Table output remains
ref-only unless `--title` is supplied and uses no external resources.
The page reloads every five seconds by default and shows the active interval;
`?refresh=30` selects 30 seconds, invalid values fall back to five, and zero is
clamped to one. `-o browser` serves this same live HTML at `0.0.0.0:7899`.
Use `-o browser=localhost:4567`, `127.0.0.1`, or `0.0.0.0:1234` to choose an
approved bind. The optional port defaults to 7899, and every request rebuilds
lightweight card placement payload from current filesystem state. Browser
JavaScript applies that payload in place, moving cards without reloading the
page. Drag/drop calls the real JSON-file move operation through a pointer-events
engine that serves mouse and touch alike: mouse drags start after a small
movement threshold, touch drags start after a short hold so page scrolling
stays native (once a drag arms, the page blocks native touch scrolling so
iOS keeps delivering movement to the ghost), a floating ghost tracks the pointer, the destination column
highlights, and the release click never reopens the dragged card. The drop zone is the
whole column stripe within the card's own board — releasing on, between,
or below the column's existing cards all land the move; releasing outside
the board cancels. Clicking a card makes
one detail request for its complete record and opens a Jira-style dialog that
renders the record section by section — a details grid (assignee, reporter,
priority label, labels, dates, versions, SDLC gate, lifecycle, parent,
source), long-text sections, list sections (key details, deliverables, scope,
acceptance criteria, test steps, BDD, ATDD, checklist, subtasks, linkage,
gate log, evidence, attachments), and threaded comments — never as raw JSON.
Empty values render as an em-dash. Single-value fields carry an inline edit
control; saving routes the change through the same validated update engine as
the CLI, and validation failures (bad priority, inactive person, malformed
date) appear inside the dialog without closing it. The comment section adds
comments with an author picker limited to active people, edits any comment in
place, and deletes a comment permanently; every successful change re-reads
the record so the dialog always shows filesystem truth.
Attachments render as chips: images and PDFs open inline in an overlay
viewer; text-like files render in the viewer's own themed panel — fetched
and set as plain text with deterministic dark-theme contrast in every
color scheme, so nothing can execute and nothing can vanish into a
same-color background; other types offer a named download.
Files upload from the dialog with a 16 MB cap through the same hash-dedup
store as the CLI, and each comment carries and manages its own attachment
chips. Attachment references record their added time and render as a vertical
one-per-row list, full date-and-time stamps right-aligned, sorted newest
first at full timestamp precision. References
stored before timestamps existed recover their real added time on read
from the deduplicated store file's own modification time (persisted on
the record's next mutation, like the legacy UTF-8 repair); only a
reference whose stored file was physically removed shows an em-dash. Comments render newest first below
a collapsed composer that expands on demand with a formatting bar; comment
text is stored as markdown and rendered through a DOM-building formatter
(bold, italic, inline code, bullet lists) that never injects raw HTML. Dialog deletion detaches the reference; the stored file is physically
removed, with logging, only when no record or comment still references it —
the same semantics as `tira.attachment.detach`.
List fields edit per item in the dialog: each row offers edit and remove, and
each list section (plus labels and affects versions in the details grid) has
an add box; saves send the whole replacement list through the engine's
replace semantics, so ordering and case-insensitive label dedup still apply.
Checklist entries add and edit in place through the checklist commands'
semantics — ids are immutable, entries are never deleted from the dialog,
and item and status stay free text.
Linkage edits in the dialog reuse the hierarchy, sub-item, and typed-link
commands transactionally: parent rows link and unlink, children rows unlink
per entry and link new refs, and typed links offer the project's configured
outward and inward names with reciprocals kept consistent on both records.
Engine validation errors (wrong type pairing, unknown ref or link type)
render inside the dialog. Long-text sections carry their edit pencil in the
section heading, and a small-screen layout keeps the board and dialog fully
usable at phone width.
The visible last-updated time advances only after fresh data is applied. Stop
the foreground server with Ctrl-C.

## 100 use cases

Every case below is implemented and executable.

### UC-001: Create locally
**Implemented.** `dashboard tira.project.create --name "Website"`.

### UC-002: Create elsewhere
**Implemented.** `dashboard tira.project.create --name "API" --dir ~/work/api`.

### UC-003: Create with JSON
**Implemented.** `dashboard tira.project.create --name "Data" --dir ./data -o json`.

### UC-004: Prevent overwrite
**Implemented.** Repeating create at one root exits `2` unchanged.

### UC-005: Print the manual
**Implemented.** `dashboard tira.skills` emits raw Markdown.

### UC-006: Create a SOW
**Implemented.** `dashboard tira.sow.create --title "Ship v1"`.

### UC-007: Create an epic
**Implemented.** `dashboard tira.epic.create --title "Identity"`.

### UC-008: Create a ticket
**Implemented.** `dashboard tira.ticket.create --title "Login"`.

### UC-009: Add a description
**Implemented.** `dashboard tira.ticket.create --title "Docs" --description "## Goal"`.

### UC-010: Allocate the next immutable ticket reference
**Implemented.** Repeated ticket creation advances the configured sequence.

### UC-011: Keep entity counters independent
**Implemented.** Creating a SOW does not consume an epic or ticket number.

### UC-012: Reject unavailable managed storage
**Implemented.** A command with no available managed project exits nonzero
without revealing or creating a storage location.

### UC-013: Human output
**Implemented.** `dashboard tira.sow.create --title "Migration" -o human`.

### UC-014: Explicit TOON
**Implemented.** `dashboard tira.epic.create --title "Cache" -o toon`.

### UC-015: Reject missing title
**Implemented.** `dashboard tira.ticket.create -o json` exits `2` without a ref.

### UC-016: Show project
**Implemented.** `dashboard tira.project.show -o human`.

### UC-017: Rename project
**Implemented.** `dashboard tira.project.update --name "Platform 2"`.

### UC-018: Add person
**Implemented.** `dashboard tira.project.people.add --id ada --name "Ada Lovelace" --email ada@example.test`.

### UC-019: List people
**Implemented.** `dashboard tira.project.people.list -o json`.

### UC-020: Update email
**Implemented.** `dashboard tira.project.people.update --id ada --email new@example.test`.

### UC-021: Clear email
**Implemented.** `dashboard tira.project.people.update --id ada --email ""`.

### UC-022: Remove person
**Implemented.** `dashboard tira.project.people.remove --id former` fails if assigned.

### UC-023: List link types
**Implemented.** `dashboard tira.project.link-types.list`.

### UC-024: Add link type
**Implemented.** `dashboard tira.project.link-types.add --outward implements --inward is-implemented-by`.

### UC-025: Remove link type
**Implemented.** `dashboard tira.project.link-types.remove --outward implements`.

### UC-026: Validate project
**Implemented.** `dashboard tira.project.validate -o json`.

### UC-027: Repair columns
**Implemented.** `dashboard tira.project.validate --repair-columns`.

### UC-028: Show board
**Implemented.** `dashboard tira.board.show --type ticket -o human`.

### UC-029: List columns
**Implemented.** `dashboard tira.column.list --type epic`.

### UC-030: Add after Backlog
**Implemented.** `dashboard tira.column.add --type ticket --name in-progress --label "In Progress" --after backlog`.

### UC-031: Add before Discard
**Implemented.** `dashboard tira.column.add --type ticket --name review --before discard`.

### UC-032: Rename column
**Implemented.** `dashboard tira.column.rename --type epic --name doing --new-name in-progress`.

### UC-033: Reorder after
**Implemented.** `dashboard tira.column.reorder --type ticket --name review --after in-progress`.

### UC-034: Reorder before
**Implemented.** `dashboard tira.column.reorder --type sow --name approval --before discard`.

### UC-035: Remove column
**Implemented.** `dashboard tira.column.remove --type ticket --name obsolete` moves records to Discard.

### UC-036: Protect Backlog
**Implemented.** Removing Backlog exits `2` unchanged.

### UC-037: Preview drift
**Implemented.** `dashboard tira.column.sync --type epic`.

### UC-038: Apply drift
**Implemented.** `dashboard tira.column.sync --type epic --apply`.

### UC-039: Change future refs
**Implemented.** `dashboard tira.board.refs --type ticket --prefix DEV --digits 5`.

### UC-040: Show SOW
**Implemented.** `dashboard tira.sow.show --ref SOW-001 -o json`.

### UC-041: Show epic
**Implemented.** `dashboard tira.epic.show --ref EPC-001 -o human`.

### UC-042: Show ticket
**Implemented.** `dashboard tira.ticket.show --ref TKT-001`.

### UC-043: Read full boards in one call
**Implemented.** `dashboard tira.ticket.list --full -o json` returns full ticket records across columns; `dashboard tira.export -o json` returns every SOW, epic, and ticket in one `{records, count}` object.

### UC-044: Filter by column
**Implemented.** `dashboard tira.ticket.list --column backlog`.

### UC-045: Filter by assignee
**Implemented.** `dashboard tira.ticket.list --assignee ada`.

### UC-046: Filter by parent
**Implemented.** `dashboard tira.ticket.list --parent EPC-001`.

### UC-047: Combine filters
**Implemented.** `dashboard tira.ticket.list --column review --assignee ada --text security` uses AND.

### UC-048: Update title
**Implemented.** `dashboard tira.ticket.update --ref TKT-001 --title "New title"`.

### UC-049: Clear description
**Implemented.** `dashboard tira.epic.update --ref EPC-001 --description ""`.

### UC-050: Append criteria
**Implemented.** Repeat `--acceptance` on `tira.ticket.update`.

### UC-051: Append BDD and ATDD
**Implemented.** Use `--bdd "Given..." --atdd "When..."`.

### UC-052: Replace array from file
**Implemented.** `dashboard tira.ticket.update --ref TKT-001 --set-acceptance criteria.json`.

### UC-053: Replace array from stdin
**Implemented.** Pipe JSON to `--set-key-details -`.

### UC-054: Move ticket
**Implemented.** `dashboard tira.ticket.move --ref TKT-001 --column in-progress`.

### UC-055: Move epic independently
**Implemented.** Moving an epic does not move its tickets.

### UC-056: Discard SOW
**Implemented.** `dashboard tira.sow.discard --ref SOW-001` keeps links.

### UC-057: Restore to Backlog
**Implemented.** `dashboard tira.ticket.restore --ref TKT-001`.

### UC-058: Restore to a column
**Implemented.** `dashboard tira.epic.restore --ref EPC-001 --column in-progress`.

### UC-059: Move out of Discard
**Implemented.** `dashboard tira.sow.move --ref SOW-001 --column approval`.

### UC-060: Clone ticket
**Implemented.** `dashboard tira.ticket.clone --ref TKT-001 --title "Follow-up"`.

### UC-061: Link SOW and epic
**Implemented.** `dashboard tira.hierarchy.link --parent SOW-001 --child EPC-001`.

### UC-062: Link epic and ticket
**Implemented.** `dashboard tira.hierarchy.link --parent EPC-001 --child TKT-001`.

### UC-063: Reparent epic
**Implemented.** Linking to SOW-002 removes the reciprocal SOW-001 link atomically.

### UC-064: Unlink hierarchy
**Implemented.** `dashboard tira.hierarchy.unlink --parent SOW-002 --child EPC-001`.

### UC-065: Reject SOW-to-ticket
**Implemented.** Direct SOW→ticket hierarchy exits `2` unchanged.

### UC-066: Show hierarchy
**Implemented.** `dashboard tira.hierarchy.show --ref EPC-001` returns the complete epic plus immediate child refs; `-o human` prints its metadata and Children section.

### UC-067: Recurse hierarchy
**Implemented.** `dashboard tira.hierarchy.show --ref SOW-001 --recursive -o json`.

### UC-068: Link sub-ticket
**Implemented.** `dashboard tira.subitem.link --parent TKT-001 --child TKT-002`.

### UC-069: Link sub-epic
**Implemented.** `dashboard tira.subitem.link --parent EPC-001 --child EPC-002`.

### UC-070: Link sub-SOW
**Implemented.** `dashboard tira.subitem.link --parent SOW-001 --child SOW-002`.

### UC-071: Reject sub-item cycle
**Implemented.** Making a parent its descendant exits `2` unchanged.

### UC-072: Unlink sub-item
**Implemented.** `dashboard tira.subitem.unlink --parent TKT-001 --child TKT-002`.

### UC-073: Add blocks link
**Implemented.** `dashboard tira.link.add --from TKT-001 --type blocks --to TKT-002`.

### UC-074: Cross-type block
**Implemented.** `dashboard tira.link.add --from EPC-001 --type blocks --to TKT-009`.

### UC-075: Relate SOW to ticket
**Implemented.** `dashboard tira.link.add --from SOW-001 --type relates-to --to TKT-001`.

### UC-076: Mark duplicate
**Implemented.** `dashboard tira.link.add --from EPC-002 --type duplicates --to EPC-001`.

### UC-077: List links
**Implemented.** `dashboard tira.link.list --ref TKT-001`.

### UC-078: Filter links
**Implemented.** `dashboard tira.link.list --ref TKT-001 --type is-blocked-by`.

### UC-079: Remove link
**Implemented.** `dashboard tira.link.remove --from TKT-001 --type blocks --to TKT-002` updates both sides.

### UC-080: Assign person
**Implemented.** `dashboard tira.assign.add --ref TKT-001 --person ada`.

### UC-081: Replace the singular assignee
**Implemented.** `dashboard tira.assign.set --ref TKT-001 --person grace` replaces any prior assignee.

### UC-082: Clear the assignee
**Implemented.** `dashboard tira.assign.set --ref TKT-001`.

### UC-083: Deactivate and reactivate a person
**Implemented.** `dashboard tira.project.people.deactivate --id grace` blocks new ownership; `dashboard tira.project.people.activate --id grace` restores eligibility.

### UC-084: List or remove the assignee
**Implemented.** `dashboard tira.assign.list --ref TKT-001 -o json`; `dashboard tira.assign.remove --ref TKT-001 --person grace` clears a match.

### UC-085: Add Markdown comment
**Implemented.** `dashboard tira.comment.add --ref TKT-001 --author ada --text "## Review"`.

### UC-086: Add text comment from file
**Implemented.** `dashboard tira.comment.add --ref EPC-001 --author ada --file note.txt --format text`.

### UC-087: Read comment from stdin
**Implemented.** Use `--file -` with `tira.comment.add`.

### UC-088: Update comment
**Implemented.** `dashboard tira.comment.update --ref TKT-001 --comment CMT-001 --text "Corrected"`.

### UC-089: Attach to comment
**Implemented.** `dashboard tira.comment.attach --ref TKT-001 --comment CMT-001 --file screenshot.png`.

### UC-090: List comments
**Implemented.** `dashboard tira.comment.list --ref TKT-001 -o human`.

### UC-091: Add attachment
**Implemented.** `dashboard tira.attachment.add --ref TKT-001 --file ./build.zip`.

### UC-092: Deduplicate content
**Implemented.** Adding identical bytes to another record reuses the SHA object.

### UC-093: Stream attachment
**Implemented.** `dashboard tira.attachment.get --sha <64-hex> --extension zip > copy.zip`.

### UC-094: Retrieve by an unambiguous SHA
**Implemented.** `dashboard tira.attachment.get --sha <64-hex> > recovered.bin` works without an extension when the SHA resolves uniquely.

### UC-095: Remove content
**Implemented.** `dashboard tira.attachment.remove --sha <64-hex> --extension zip` logs deletion.

### UC-096: Restore content
**Implemented.** Re-adding identical bytes restores the shared SHA object.

### UC-097: Add evidence
**Implemented.** `dashboard tira.evidence.add --ref TKT-001 --summary "CI" --uri https://ci.example.test/1 --file result.xml --author ada`.

### UC-098: Record and annotate gates, evidence, and checklists
**Implemented.** Add a gate, then append a correction with `dashboard tira.gate.annotate --ref TKT-001 --id GATE-001 --note "Use local docs" --author ada`; evidence uses `tira.evidence.annotate` with `EVD-NNN`. Manage retained checklists with add, list, and update; there is no remove command.

### UC-099: Search and correct migrations in bulk
**Implemented.** Repeat fields in one reviewable pass: `dashboard tira.search --text Jira --field description --field atdd -o json` and `dashboard tira.replace --pattern Jira --with Local --field description --field atdd --dry-run -o json`. Import preview `dashboard tira.import --file changes.json --dry-run -o json` returns `changes[]` entries containing `ref`, `field`, `before`, and `after`; omit dry-run only after reviewing every diff.

### UC-100: Render dashboard
**Implemented.** `dashboard tira.dashboard --type all` is the ref-only fast path; add `--title` for titles, `--include-discard` for archived cards, `-o json` for complete records, `-o table` for self-contained interactive HTML, or `-o browser` for the live Dancer2 view. Type-specific table/browser commands are `tira.dashboard.sow`, `.epic`, and `.ticket`.

## Safety contract

Tira validates and untaints canonical paths, references, prefixes, digits,
column slugs, link names, and hashes before filesystem use. It invokes no shell.
Records are discarded, never deleted. Attachment removal is the sole physical
deletion workflow and is permanently logged. Raw attachment output may disrupt
a terminal by design; redirect it.

This catalogue is the normative implemented interface. Use commands exclusively
and never emulate them through manual managed-storage edits.
