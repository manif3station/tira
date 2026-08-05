# Tira Agent Skill Manual

Tira is a filesystem-native Jira-style Kanban system exposed through Developer
Dashboard. It manages projects, SOWs, epics, tickets, columns, relationships,
people, comments, evidence, gates, and content-addressed attachments without a
server or hidden database. Never edit Tira-managed YAML or JSON directly.

## Availability legend

- **Implemented (0.01):** shipped, executable, and covered by tests.
- **Specified:** normative interface for a later governed ticket. Do not invoke
  or simulate it by editing files.
- `dashboard tira.skills` is implemented and prints this file as raw Markdown.

Unknown and not-yet-shipped commands fail at Developer Dashboard dispatch.
Check availability before selecting a command.

## Global invocation grammar

```text
dashboard tira.<resource>.<action> [arguments] [--project DIR] [-o FORMAT]
dashboard tira.skills

FORMAT := toon | json | human
TYPE   := sow | epic | ticket
```

References are immutable, case-sensitive values such as `SOW-001`, `EPC-001`,
and `TKT-001`. Quote whitespace, Markdown, glob characters, and empty strings.
Repeat an option only where its table marks it repeatable. `--help` is exclusive
and performs no mutation.

## Argument precedence

1. Explicit `--project DIR` wins.
2. Otherwise non-empty `TIRA_HOME` selects the project root.
3. Otherwise Tira walks upward from the current directory for
   `.tira/project.yml`.

Selectors point to the project root, not `.tira/`. Explicit update values win;
omitted fields stay unchanged, while `--field ""` clears nullable text. Supply
`-o` at most once. Append options and `--set-*` for the same field are mutually
exclusive.

## Output contract

- Default and `-o toon`: `Data::TOON` output.
- `-o json`: canonical pretty JSON with the full result.
- `-o human`: Markdown summary.
- Errors use the selected structured format on stderr, never success stdout.
- Mutations return the affected record or operation receipt.
- `attachment.get` defaults to raw bytes and uniquely supports `-o path`.
- `tira.skills` emits raw Markdown and accepts no options.

## Exit status contract

| Status | Meaning |
| --- | --- |
| `0` | Completed. |
| `1` | Content-specific negative result, such as deleted attachment content. |
| `2` | Usage, validation, lookup, conflict, or output failure. |
| `3` | Persistence failure; rollback was attempted. |

Validation failure creates no mutation. A failed multi-record operation leaves
both sides unchanged. Always check status before consuming output.

## Project database

```text
<project>/.tira/
├── project.yml
├── .lock
├── sow/{config.yml,<column>/*.json}
├── epic/{config.yml,<column>/*.json}
├── ticket/{config.yml,<column>/*.json}
└── attachments/{<sha256>.<extension>,delete.log.yml}
```

The filesystem is the database: column folders are state and JSON files are
records. There is no registry or index. Config files are YAML. Backlog and
Discard are protected on all boards. Searches enumerate files.

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
`test_steps`, `bdd`, `atdd`, `gate_passing_log`, `evidence`, `attachments`,
`subtasks`, `linkage`, `assignees`, `comments`, `created_at`, and
`last_updated`.

Comments have an ID, author, `markdown|text` format, body, attachments, creation
time, and last update. Evidence and gate entries are append-only observations.
Assignees must exist in `project.yml`.

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
| `--assignee ID` | yes | optional | replace | Project person. |

Only title and description are implemented on create in 0.01. Other fields are
specified. Updates may replace arrays with `--set-<field> FILE`; `-` reads a
UTF-8 JSON array from stdin.

## Command catalogue

### Manual and project

- `tira.skills` — **Implemented.** No arguments; raw manual.
- `tira.project.create --name TEXT [--dir DIR] [-o FORMAT]` — **Implemented.**
  Name required; directory defaults to `.`; existing projects are preserved.
- `tira.project.show [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.update [--name TEXT] [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.people.list [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.people.add --id ID --name TEXT [--email EMAIL] [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.people.update --id ID [--name TEXT] [--email EMAIL|""] [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.people.remove --id ID [--project DIR] [-o FORMAT]` — **Specified.** Fails while assigned.
- `tira.project.link-types.list [--project DIR] [-o FORMAT]` — **Specified.**
- `tira.project.link-types.add --outward NAME --inward NAME [--project DIR] [-o FORMAT]` — **Specified.** Names unique.
- `tira.project.link-types.remove --outward NAME [--project DIR] [-o FORMAT]` — **Specified.** Protected types remain.
- `tira.project.validate [--repair-columns] [--project DIR] [-o FORMAT]` — **Specified.** Read-only without repair.

### Boards and columns

All are **Specified** and require `--type sow|epic|ticket`:

```text
tira.board.show --type TYPE [--project DIR] [-o FORMAT]
tira.column.list --type TYPE [--project DIR] [-o FORMAT]
tira.column.add --type TYPE --name SLUG [--label TEXT] [--after SLUG|--before SLUG] [--project DIR] [-o FORMAT]
tira.column.rename --type TYPE --name SLUG --new-name SLUG [--label TEXT] [--project DIR] [-o FORMAT]
tira.column.reorder --type TYPE --name SLUG (--after SLUG|--before SLUG) [--project DIR] [-o FORMAT]
tira.column.remove --type TYPE --name SLUG [--project DIR] [-o FORMAT]
tira.column.sync --type TYPE [--apply] [--project DIR] [-o FORMAT]
tira.board.refs --type TYPE [--prefix PREFIX] [--digits N] [--project DIR] [-o FORMAT]
```

`--after` and `--before` conflict. Slugs use lowercase letters, digits, and
hyphens. Backlog/Discard cannot be renamed, reordered, or removed. Removing a
custom column moves records to Discard. Sync reports drift unless `--apply`.
Prefix/digit changes affect future refs and never lower `next_number`.

### Records

These create commands are **Implemented**:

```text
tira.sow.create --title TEXT [--description TEXT] [--project DIR] [-o FORMAT]
tira.epic.create --title TEXT [--description TEXT] [--project DIR] [-o FORMAT]
tira.ticket.create --title TEXT [--description TEXT] [--project DIR] [-o FORMAT]
```

They create independent Backlog records with empty linkage. These symmetric
forms are **Specified** for each `TYPE`:

```text
tira.TYPE.show --ref REF [--project DIR] [-o FORMAT]
tira.TYPE.list [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [--project DIR] [-o FORMAT]
tira.TYPE.update --ref REF [record field arguments] [--project DIR] [-o FORMAT]
tira.TYPE.move --ref REF --column SLUG [--project DIR] [-o FORMAT]
tira.TYPE.discard --ref REF [--project DIR] [-o FORMAT]
tira.TYPE.restore --ref REF [--column SLUG] [--project DIR] [-o FORMAT]
tira.TYPE.clone --ref REF --title TEXT [--project DIR] [-o FORMAT]
```

List filters use AND. Parent means SOW for epic, epic for ticket, and same-type
parent for SOW. Discard is movement, not deletion; restore defaults to Backlog.
Clone creates a Backlog record, shares attachment refs, clears hierarchy, and
adds reciprocal clone links.

### Hierarchy and typed links

All are **Specified**:

```text
tira.hierarchy.link --parent REF --child REF [--project DIR] [-o FORMAT]
tira.hierarchy.unlink --parent REF --child REF [--project DIR] [-o FORMAT]
tira.hierarchy.show --ref REF [--recursive] [--project DIR] [-o FORMAT]
tira.subitem.link --parent REF --child REF [--project DIR] [-o FORMAT]
tira.subitem.unlink --parent REF --child REF [--project DIR] [-o FORMAT]
tira.link.add --from REF --type NAME --to REF [--project DIR] [-o FORMAT]
tira.link.remove --from REF --type NAME --to REF [--project DIR] [-o FORMAT]
tira.link.list --ref REF [--type NAME] [--project DIR] [-o FORMAT]
```

Hierarchy permits only SOW→epic and epic→ticket. Reparenting removes the old
reciprocal relationship. Sub-items are same-type, one-to-many, and cycle-free.
Typed links may cross types. Built-ins are `blocks`/`is-blocked-by`,
`clones`/`is-cloned-by`, `duplicates`/`is-duplicated-by`, and symmetric
`relates-to`. Link add is idempotent. Tira never infers completion.

### Assignments and comments

All are **Specified**:

```text
tira.assign.list --ref REF [--project DIR] [-o FORMAT]
tira.assign.add --ref REF --person ID [--project DIR] [-o FORMAT]
tira.assign.remove --ref REF --person ID [--project DIR] [-o FORMAT]
tira.assign.set --ref REF [--person ID ...] [--project DIR] [-o FORMAT]
tira.comment.list --ref REF [--project DIR] [-o FORMAT]
tira.comment.add --ref REF --author ID (--text TEXT|--file FILE) [--format markdown|text] [--attach PATH ...] [--project DIR] [-o FORMAT]
tira.comment.update --ref REF --comment ID (--text TEXT|--file FILE) [--format markdown|text] [--project DIR] [-o FORMAT]
tira.comment.attach --ref REF --comment ID --file PATH [--project DIR] [-o FORMAT]
```

People must exist. Assignment add is idempotent; set replaces all and clears
with no `--person`. Comment `--text`/`--file` conflict; `--file -` reads stdin.
Markdown is default. Comments are retained, not deleted. Updates preserve
creation time. Repeated `--attach` imports files before writing the comment.

### Attachments

All are **Specified**:

```text
tira.attachment.add --ref REF --file PATH [--comment ID] [--project DIR] [-o FORMAT]
tira.attachment.list [--ref REF] [--include-deleted] [--project DIR] [-o FORMAT]
tira.attachment.get --sha SHA256 [--extension EXT] [--project DIR] [-o raw|path]
tira.attachment.remove --sha SHA256 [--extension EXT] [--project DIR] [-o FORMAT]
```

Add hashes bytes, stores `sha256.extension`, and records the original filename.
Many refs may share content. Remove deletes content, appends to
`delete.log.yml`, and preserves JSON refs. Re-adding identical bytes restores
the object. Deleted get emits `Deleted at <timestamp>` raw and exits `1`. Only
explicit `-o path` reveals storage location.

### Evidence, gates, search, and dashboard

All are **Specified**:

```text
tira.evidence.list --ref REF [--project DIR] [-o FORMAT]
tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [--project DIR] [-o FORMAT]
tira.gate.list --ref REF [--project DIR] [-o FORMAT]
tira.gate.add --ref REF --gate TEXT --result pass|fail|blocked --details TEXT [--author ID] [--project DIR] [-o FORMAT]
tira.search --text QUERY [--type TYPE] [--column SLUG] [--assignee ID] [--project DIR] [-o FORMAT]
tira.dashboard [--type TYPE|all] [--include-discard] [--project DIR] [-o FORMAT]
```

Evidence may have both URI and file. Gates record observations but never move
work. Search scans files without an index and combines filters with AND.
Dashboard follows configured column order and excludes Discard by default.

## 100 use cases

Each case states availability; agents must not execute specified-only commands.

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
**Implemented.** `dashboard tira.sow.create --title "Ship v1" --project ./delivery`.

### UC-007: Create an epic
**Implemented.** `dashboard tira.epic.create --title "Identity" --project ./delivery`.

### UC-008: Create a ticket
**Implemented.** `dashboard tira.ticket.create --title "Login" --project ./delivery`.

### UC-009: Add a description
**Implemented.** `dashboard tira.ticket.create --title "Docs" --description "## Goal"`.

### UC-010: Use TIRA_HOME
**Implemented.** `TIRA_HOME=~/work/api dashboard tira.ticket.create --title "Test"`.

### UC-011: Override TIRA_HOME
**Implemented.** `TIRA_HOME=~/work/a dashboard tira.epic.create --project ~/work/b --title "B"` writes to B.

### UC-012: Discover upward
**Implemented.** Run create from a nested project directory without a selector.

### UC-013: Human output
**Implemented.** `dashboard tira.sow.create --title "Migration" -o human`.

### UC-014: Explicit TOON
**Implemented.** `dashboard tira.epic.create --title "Cache" -o toon`.

### UC-015: Reject missing title
**Implemented.** `dashboard tira.ticket.create -o json` exits `2` without a ref.

### UC-016: Show project
**Specified.** `dashboard tira.project.show -o human`.

### UC-017: Rename project
**Specified.** `dashboard tira.project.update --name "Platform 2"`.

### UC-018: Add person
**Specified.** `dashboard tira.project.people.add --id ada --name "Ada Lovelace" --email ada@example.test`.

### UC-019: List people
**Specified.** `dashboard tira.project.people.list -o json`.

### UC-020: Update email
**Specified.** `dashboard tira.project.people.update --id ada --email new@example.test`.

### UC-021: Clear email
**Specified.** `dashboard tira.project.people.update --id ada --email ""`.

### UC-022: Remove person
**Specified.** `dashboard tira.project.people.remove --id former` fails if assigned.

### UC-023: List link types
**Specified.** `dashboard tira.project.link-types.list`.

### UC-024: Add link type
**Specified.** `dashboard tira.project.link-types.add --outward implements --inward is-implemented-by`.

### UC-025: Remove link type
**Specified.** `dashboard tira.project.link-types.remove --outward implements`.

### UC-026: Validate project
**Specified.** `dashboard tira.project.validate -o json`.

### UC-027: Repair columns
**Specified.** `dashboard tira.project.validate --repair-columns`.

### UC-028: Show board
**Specified.** `dashboard tira.board.show --type ticket -o human`.

### UC-029: List columns
**Specified.** `dashboard tira.column.list --type epic`.

### UC-030: Add after Backlog
**Specified.** `dashboard tira.column.add --type ticket --name in-progress --label "In Progress" --after backlog`.

### UC-031: Add before Discard
**Specified.** `dashboard tira.column.add --type ticket --name review --before discard`.

### UC-032: Rename column
**Specified.** `dashboard tira.column.rename --type epic --name doing --new-name in-progress`.

### UC-033: Reorder after
**Specified.** `dashboard tira.column.reorder --type ticket --name review --after in-progress`.

### UC-034: Reorder before
**Specified.** `dashboard tira.column.reorder --type sow --name approval --before discard`.

### UC-035: Remove column
**Specified.** `dashboard tira.column.remove --type ticket --name obsolete` moves records to Discard.

### UC-036: Protect Backlog
**Specified.** Removing Backlog exits `2` unchanged.

### UC-037: Preview drift
**Specified.** `dashboard tira.column.sync --type epic`.

### UC-038: Apply drift
**Specified.** `dashboard tira.column.sync --type epic --apply`.

### UC-039: Change future refs
**Specified.** `dashboard tira.board.refs --type ticket --prefix DEV --digits 5`.

### UC-040: Show SOW
**Specified.** `dashboard tira.sow.show --ref SOW-001 -o json`.

### UC-041: Show epic
**Specified.** `dashboard tira.epic.show --ref EPC-001 -o human`.

### UC-042: Show ticket
**Specified.** `dashboard tira.ticket.show --ref TKT-001`.

### UC-043: List tickets
**Specified.** `dashboard tira.ticket.list` scans all columns.

### UC-044: Filter by column
**Specified.** `dashboard tira.ticket.list --column backlog`.

### UC-045: Filter by assignee
**Specified.** `dashboard tira.ticket.list --assignee ada`.

### UC-046: Filter by parent
**Specified.** `dashboard tira.ticket.list --parent EPC-001`.

### UC-047: Combine filters
**Specified.** `dashboard tira.ticket.list --column review --assignee ada --text security` uses AND.

### UC-048: Update title
**Specified.** `dashboard tira.ticket.update --ref TKT-001 --title "New title"`.

### UC-049: Clear description
**Specified.** `dashboard tira.epic.update --ref EPC-001 --description ""`.

### UC-050: Append criteria
**Specified.** Repeat `--acceptance` on `tira.ticket.update`.

### UC-051: Append BDD and ATDD
**Specified.** Use `--bdd "Given..." --atdd "When..."`.

### UC-052: Replace array from file
**Specified.** `dashboard tira.ticket.update --ref TKT-001 --set-acceptance criteria.json`.

### UC-053: Replace array from stdin
**Specified.** Pipe JSON to `--set-key-details -`.

### UC-054: Move ticket
**Specified.** `dashboard tira.ticket.move --ref TKT-001 --column in-progress`.

### UC-055: Move epic independently
**Specified.** Moving an epic does not move its tickets.

### UC-056: Discard SOW
**Specified.** `dashboard tira.sow.discard --ref SOW-001` keeps links.

### UC-057: Restore to Backlog
**Specified.** `dashboard tira.ticket.restore --ref TKT-001`.

### UC-058: Restore to a column
**Specified.** `dashboard tira.epic.restore --ref EPC-001 --column in-progress`.

### UC-059: Move out of Discard
**Specified.** `dashboard tira.sow.move --ref SOW-001 --column approval`.

### UC-060: Clone ticket
**Specified.** `dashboard tira.ticket.clone --ref TKT-001 --title "Follow-up"`.

### UC-061: Link SOW and epic
**Specified.** `dashboard tira.hierarchy.link --parent SOW-001 --child EPC-001`.

### UC-062: Link epic and ticket
**Specified.** `dashboard tira.hierarchy.link --parent EPC-001 --child TKT-001`.

### UC-063: Reparent epic
**Specified.** Linking to SOW-002 removes the reciprocal SOW-001 link atomically.

### UC-064: Unlink hierarchy
**Specified.** `dashboard tira.hierarchy.unlink --parent SOW-002 --child EPC-001`.

### UC-065: Reject SOW-to-ticket
**Specified.** Direct SOW→ticket hierarchy exits `2` unchanged.

### UC-066: Show hierarchy
**Specified.** `dashboard tira.hierarchy.show --ref EPC-001`.

### UC-067: Recurse hierarchy
**Specified.** `dashboard tira.hierarchy.show --ref SOW-001 --recursive -o json`.

### UC-068: Link sub-ticket
**Specified.** `dashboard tira.subitem.link --parent TKT-001 --child TKT-002`.

### UC-069: Link sub-epic
**Specified.** `dashboard tira.subitem.link --parent EPC-001 --child EPC-002`.

### UC-070: Link sub-SOW
**Specified.** `dashboard tira.subitem.link --parent SOW-001 --child SOW-002`.

### UC-071: Reject sub-item cycle
**Specified.** Making a parent its descendant exits `2` unchanged.

### UC-072: Unlink sub-item
**Specified.** `dashboard tira.subitem.unlink --parent TKT-001 --child TKT-002`.

### UC-073: Add blocks link
**Specified.** `dashboard tira.link.add --from TKT-001 --type blocks --to TKT-002`.

### UC-074: Cross-type block
**Specified.** `dashboard tira.link.add --from EPC-001 --type blocks --to TKT-009`.

### UC-075: Relate SOW to ticket
**Specified.** `dashboard tira.link.add --from SOW-001 --type relates-to --to TKT-001`.

### UC-076: Mark duplicate
**Specified.** `dashboard tira.link.add --from EPC-002 --type duplicates --to EPC-001`.

### UC-077: List links
**Specified.** `dashboard tira.link.list --ref TKT-001`.

### UC-078: Filter links
**Specified.** `dashboard tira.link.list --ref TKT-001 --type is-blocked-by`.

### UC-079: Remove link
**Specified.** `dashboard tira.link.remove --from TKT-001 --type blocks --to TKT-002` updates both sides.

### UC-080: Assign person
**Specified.** `dashboard tira.assign.add --ref TKT-001 --person ada`.

### UC-081: Set assignees
**Specified.** `dashboard tira.assign.set --ref TKT-001 --person ada --person grace`.

### UC-082: Clear assignees
**Specified.** `dashboard tira.assign.set --ref TKT-001`.

### UC-083: Remove assignee
**Specified.** `dashboard tira.assign.remove --ref TKT-001 --person grace`.

### UC-084: List assignees
**Specified.** `dashboard tira.assign.list --ref TKT-001 -o json`.

### UC-085: Add Markdown comment
**Specified.** `dashboard tira.comment.add --ref TKT-001 --author ada --text "## Review"`.

### UC-086: Add text comment from file
**Specified.** `dashboard tira.comment.add --ref EPC-001 --author ada --file note.txt --format text`.

### UC-087: Read comment from stdin
**Specified.** Use `--file -` with `tira.comment.add`.

### UC-088: Update comment
**Specified.** `dashboard tira.comment.update --ref TKT-001 --comment CMT-001 --text "Corrected"`.

### UC-089: Attach to comment
**Specified.** `dashboard tira.comment.attach --ref TKT-001 --comment CMT-001 --file screenshot.png`.

### UC-090: List comments
**Specified.** `dashboard tira.comment.list --ref TKT-001 -o human`.

### UC-091: Add attachment
**Specified.** `dashboard tira.attachment.add --ref TKT-001 --file ./build.zip`.

### UC-092: Deduplicate content
**Specified.** Adding identical bytes to another record reuses the SHA object.

### UC-093: Stream attachment
**Specified.** `dashboard tira.attachment.get --sha <64-hex> --extension zip > copy.zip`.

### UC-094: Reveal path explicitly
**Specified.** `dashboard tira.attachment.get --sha <64-hex> --extension png -o path`.

### UC-095: Remove content
**Specified.** `dashboard tira.attachment.remove --sha <64-hex> --extension zip` logs deletion.

### UC-096: Restore content
**Specified.** Re-adding identical bytes restores the shared SHA object.

### UC-097: Add evidence
**Specified.** `dashboard tira.evidence.add --ref TKT-001 --summary "CI" --uri https://ci.example.test/1 --file result.xml --author ada`.

### UC-098: Record gate
**Specified.** `dashboard tira.gate.add --ref TKT-001 --gate Security --result pass --details "122 tests" --author ada`.

### UC-099: Search files
**Specified.** `dashboard tira.search --text authentication --type ticket --column backlog`.

### UC-100: Render dashboard
**Specified.** `dashboard tira.dashboard --type all --include-discard -o human`.

## Safety contract

Tira validates and untaints canonical paths, references, prefixes, digits,
column slugs, link names, and hashes before filesystem use. It invokes no shell.
Records are discarded, never deleted. Attachment removal is the sole physical
deletion workflow and is permanently logged. Raw attachment output may disrupt
a terminal by design; redirect it.

This catalogue is normative. Until a command is marked Implemented here, in the
README, tests, and Changes, do not call it or emulate it through manual edits.
