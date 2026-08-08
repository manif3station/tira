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
- **Implemented (0.29):** shipped, executable, and covered by tests.
- **Implemented (0.30):** shipped, executable, and covered by tests.
- **Implemented (0.31):** shipped, executable, and covered by tests.
- **Implemented (0.77):** shipped, executable, and covered by tests.
- `dashboard tira.skills` is implemented and prints this file as raw Markdown.

All commands and use cases in this manual ship in release 0.77.

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
- `-o json`: canonical compact JSON — stable key order, raw UTF-8, one
  line. **Implemented (DD-435)**; identical information to every other
  format.
- `-o json-pretty`: the indented JSON shape, for human reading.
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
- `tira.project.new --name TEXT [--dir DIR] [--members LIST] [--columns LIST]
  [--sow-prefix PREFIX] [--epic-prefix PREFIX] [--ticket-prefix PREFIX]
  [--digits N] [-o FORMAT]` — **Implemented (DD-446).** Creates a project, its
  people, each board's reference prefix, and one shared column set in a single
  call. `--members` and `--columns` take comma-separated human text and repeat, and
  `--sow-columns`, `--epic-columns`, and `--ticket-columns` give one board its
  own set instead of the shared one.
  Column names are written as they read — `--columns "Backlog, In Progress,
  Done / Release"` — and each becomes a lowercase hyphenated column keeping the
  original text as its label. Columns that already exist, including the
  protected Backlog and Discard, are left alone, so the full list works
  verbatim and re-running the command changes nothing. Every input is checked
  before the first write, so a rejected call creates nothing. Prefixes are
  applied before any record can exist, which matters because a board counter
  never goes backwards: set a prefix after the first record and the next
  reference is `002`.
- `tira.onboard [-o FORMAT]` — **Implemented (DD-448).** The guided version of
  `tira.project.new`: it asks for the name, the directory, the people, each
  board's reference prefix, whether all three boards share one column set, and
  the columns, then shows a summary and creates everything once confirmed. Any
  flag given becomes that question's default. Answers that cannot be used are
  re-asked with the reason. Declining the confirmation exits 1 and creates
  nothing; reaching the end of input aborts and creates nothing.
  `tira.project.new` itself never asks anything, so scripts and agents calling
  it can never be left waiting. At a terminal every answer is editable: Ctrl-A
  and Ctrl-E jump to the start and end of the line, Ctrl-U clears it, Ctrl-K
  cuts to the end, the arrows and Home/End move the cursor, and Ctrl-C or
  Ctrl-D abandons the prompt. Away from a terminal the prompt is a plain read,
  so piping answers in behaves exactly as before.
- `tira.project.show [-o FORMAT]` — **Implemented.**
- `tira.project.update [--name TEXT] [--dashboard-host HOST] [--dashboard-port PORT]
  [-o FORMAT]` — **Implemented.** Renames a project, and **Implemented
  (DD-449)** remembers the address its live board should listen on:
  `--dashboard-host` takes `localhost`, `127.0.0.1`, `0.0.0.0`, or `any` as the
  plain-language form of every interface, and `--dashboard-port` takes 1-65535.
  Both are checked where they are set, so a bad value is refused then rather
  than the next time someone serves the board. `tira.dashboard -o browser`
  uses the remembered address; an address written on the command line, such as
  `-o browser=localhost:8080`, still wins; a project that has never set one
  serves `0.0.0.0:7899` as always. `tira.project.show` reports it.
  `--listen HOST` or `--listen HOST:PORT` is the compact form of the two.
  A path beginning with `~` means the user's home directory wherever it is
  accepted — typed at a prompt, or written as `--dir "~/work"`, which a shell
  does not expand.
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
tira.TYPE.show (--ref REF ...|--refs LIST) [--fields LIST] [--exclude-fields LIST] [--include-empty] [--since TIMESTAMP] [--if-changed HASH] [--brief] [--truncate N|--full] [-o FORMAT]
tira.TYPE.list [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [--fields LIST] [--exclude-fields LIST] [--include-empty] [--since TIMESTAMP] [--count] [--refs-only] [--brief] [--truncate N|--full] [--where CLAUSE ...] [-o FORMAT]
tira.TYPE.update --ref REF [record field arguments] [-o FORMAT]
tira.TYPE.move --ref REF --column SLUG [-o FORMAT]
tira.TYPE.discard --ref REF [-o FORMAT]
tira.TYPE.restore --ref REF [--column SLUG] [-o FORMAT]
tira.TYPE.clone --ref REF --title TEXT [-o FORMAT]
```

List filters use AND. Parent means the generated immediate parent ref. Discard
is movement, not deletion; restore defaults to Backlog.
Field projection is **Implemented (DD-424)** on show, list, and export:
`--fields` and `--exclude-fields` take comma-separated lists, repeat and
accumulate, and never alter stored data. Selection always keeps `ref`;
exclusion applies after selection. An unknown or empty field name exits 2
naming the offender — a typo can never quietly return an empty object.
Selected fields that are null stay visibly null. On any other command
either flag exits 2.
Empty omission is **Implemented (DD-425)** on the same three commands: by
default a returned record omits keys whose value is null, an empty
string, an empty array, or a hash of only such values; `--include-empty`
restores every key. An omitted key therefore always means "empty or
unset" — `false` and `0` are values and are never omitted, and a field
named in `--fields` is always present even when empty. The record schema
section above lists every possible key, so omission costs no
discoverability.
Changed-since filtering is **Implemented (DD-426)** on the same three
commands: `--since` takes an ISO 8601 timestamp (`Z`, `±HH:MM`, or
`±HHMM`; a missing offset reads as UTC) and returns only records whose
`last_updated` is at or after that instant — compared as instants, never
as strings. With `--since`, the export envelope adds `now`, the server
clock at scan start; pass it back as the next `--since` for gap-free
polling (a record touched in the boundary second may repeat, but none
can be missed). A future timestamp returns empty with exit 0; a
malformed one exits 2; `show` returns `{}` for an unchanged record; a
record whose stored stamp is unreadable is always returned, never
hidden.
Content hashes and conditional reads are **Implemented (DD-427)**.
Selecting the computed `content_hash` field returns an opaque stable
token covering every meaningful field including placement and excluding
only `last_updated`, so a no-op write keeps its hash; only equality is
contractual. `tira.export --fields ref,content_hash` also returns a
`board_hash` over the whole result. `--if-changed HASH` on show and
export returns `{"unchanged": true}` with exit 1 when nothing differs
(exit 0 with the payload otherwise — the exit status alone answers the
question), exits 2 on a malformed hash rather than treating it as
changed, composes with `--fields`, and when combined with `--since` the
stricter suppression wins. Conditional reads never write.
Count and refs-only are **Implemented (DD-428)**: `--count` (list,
export, search) returns `{"count": N}` alone — zero is an answer, not an
error — and `--refs-only` (list, search) returns a flat ref array in
stable ref order, deduplicated for field-scoped search hits. Count wins
over refs-only wins over `--fields`, documented rather than guessed, and
field names are still validated loudly even when projection is moot.
With `-o human`, count prints a bare number and refs-only prints one ref
per line, so both pipe straight into a shell.
Brief and truncation are **Implemented (DD-429)** on show, list, and
export. `--brief` is exactly `ref,title,column,sdlc_gate,assignee` — a
shorthand for the equivalent `--fields` list, never a special case — with
the title cut at a stable 72 characters plus an ellipsis and a null
assignee kept visible; combining it with `--fields` exits 2. Long text
(`description`, `problem_or_feature`, `solution_needed`, and each gate
`details` / evidence `summary`) truncates at 2000 characters by default,
always visibly: the cut value ends with an ellipsis and gains
`<field>_truncated` and `<field>_length` markers. `--truncate N` chooses
the limit, `--truncate 0` omits the text while still marking it present,
`--full` restores everything (combining `--full` with `--truncate` exits
2), short fields carry no markers, and structural fields are never cut.
Truncation is presentation only: `content_hash` is computed from the
full record. The board dashboard is already a summary view and takes no
brief flag.
Comment and attachment reads are **Implemented (DD-430)**. Comments are
stored newest-last, so `--last N` is the recent thread and `--first N`
the original framing (contradictory together, exit 2; a zero window or
`--count` returns `{"count": N}` alone; an oversize window returns
everything). `--meta-only` returns id, author, format, both stamps,
`body_length`, and `attachment_count` — selecting `body` with it exits
2. Comment `--fields` selects comment keys with `id` always kept;
`--since` filters by the comment's own stamps. On show, list, and
export, `--meta-only` strips embedded comment bodies board-wide.
`tira.attachment.list --ref REF --meta-only` returns newest-first
entries with `filename`, real byte `size`, `content_type`, `added_at`,
and `sha`, in an envelope with `count` and `total_size`; attachment
`--fields` keeps `sha`; `--since` filters by `added_at`; these options
require `--ref`. The computed record field `attachment_count` is
selectable via `--fields` for board-wide evidence coverage.
Server-side filtering is **Implemented (DD-431)** on list and export:
`--where` is repeatable and clauses combine with AND. `FIELD=VALUE` is
string equality; `FIELD=` (empty value) matches a field that is empty or
unset by the same emptiness rule as omission; `FIELD!=VALUE` excludes;
`FIELD!=` means the field has a value; `FIELD~VALUE` matches an element
of an array field case-insensitively, and on a non-array field matches
nothing rather than erroring. Computed fields (`content_hash`,
`attachment_count`, `column`, `parent`) are filterable. An unknown field
or an operatorless clause exits 2 — a typo can never read as "none
exist". Composes with `--fields`, `--count`, and `--since`.
Batch reads are **Implemented (DD-432)** on show: repeat `--ref` or pass
`--refs A,B,C` (both compose) and the response is
`{records, order, count}` — records keyed by ref, `order` preserving the
request, duplicates collapsed. A missing ref is an explicit
`{"not_found": true}` marker and never loses the rest of the call; a
validation error fails the whole call with exit 2 before any lookup.
Batches cross record types freely, accept at most 100 refs (a clear
error beyond, never silent truncation), compose with every read option
except `--if-changed`, which is refused with exit 2 in favor of the
cheaper `export --fields ref,content_hash` poll. Multiple refs on any
other command exit 2.
A first-class diff is **Implemented (DD-433)**: `tira.diff --since T`
reports every record changed at or after that instant with its kind
(`added`/`changed`), current column, gate, and title, plus new-comment
ids — enough to act without a further read — and `now` for chaining.
`tira.diff --snapshot FILE` compares a stored full export (save one with
`tira.export --include-empty -o json`): scalar fields carry `before` and
`after`, new comments are named, structural changes carry an explicit
`changed` marker, and additions, changes, and removals are distinguished
— a deletion never looks like an absence of change. `--fields` scopes a
snapshot comparison; `--count` answers whether to look; an empty diff is
an explicit empty result. Exactly one baseline is required; diff never
writes, and storing a snapshot is the separate export call.
Column dwell is **Implemented (DD-458)**: `tira.stale` reports every card
with the column it is in now, when it entered that column, and how long it has
been there, across all three boards in one call. Entry time comes from the
card's most recent recorded column move. A card whose entry was never recorded
is listed with `basis: none` and **no duration** rather than a guessed one, and
`--older-than MINUTES` never returns it — an unmeasured card is unknown, not
old. An unreadable stamp yields `basis: unknown` instead of failing the board,
and a column renamed underneath a card does not disturb its measurement.
Wrapping wide boards is **Implemented (DD-453)**: each column now owns
its own heading rather than sitting in a table row, so **Fit all wraps
the columns onto as many rows as it takes** at a readable width instead
of squeezing every one of them onto a single line. Standard is
unchanged: one row, full-width columns, scrolling sideways. Drag and
drop, paging, filtering, counts and the column editor are unaffected.

Nesting refusal is **Implemented (DD-447)**: creating a project in a
directory that sits inside an existing project is refused, naming the
project that is in the way and where it is. Project discovery walks
upward, so a buried project means later commands may address either
one, and nothing would ever say so. Pass `--nested` to do it
deliberately.

Serialised mutations are **Implemented (DD-444)**: comments,
checklists, gates, evidence and attachment references used to read a
record, change it and write it back with no lock held, so two changes
made at the same moment could silently lose one — while this manual
already promised every mutation was serialised. The project lock is now
reentrant, and each of those methods holds it across the read as well
as the write. The guarantee stated here is now true rather than
aspirational.

The column editor is **Implemented (DD-466)**: each board control has a
Columns button opening a modal that shows that board's own columns —
drag a row by its grip to reorder, edit its label, set how many minutes
a card may sit there, turn its eye off to stop it being chased, remove
it, or add a new one before Discard. Saving sends the whole layout at
once. Reordering uses pointer events like the rest of the board, so the
grip works on a phone.

Whole-layout column edits are **Implemented (DD-465)**:
`tira.column.apply` takes the column list a board should have — order,
labels, per-column thresholds and watched flags — and works out the
difference itself, adding what is missing and removing what is gone.
Cards in a removed column land in Discard exactly as removing one at a
time puts them there. A protected column left out is refused and
nothing changes. The call reports what it added, removed and
reordered, because removals happen one at a time and a run that fails
partway will already have made some of them.

The reminder job is **Implemented (DD-463)**: `tira.collector.show`
computes the background job for this project and
`tira.collector.install` registers it, merging into the machine's own
configuration without disturbing anything else already there and
refusing to take over a name another project registered. No heartbeat
means no job. The sending itself lives outside the command surface, so
Tira still runs no shell and no external process; it delivers one
message covering every stale card, records them only once the message
has actually arrived, retries a failed delivery once, and then leaves a
warning rather than failing silently. Nothing stale, no agent installed
and no session configured are all quiet no-ops rather than errors.

Onboarding registers the job itself **(DD-467)**: filling in the
reminder details now creates the background job as well as recording
them, and reports the name it will really answer to along with the
command that starts it. It asks for a number of minutes once — how long
a card may sit still — and the heartbeat follows that answer, since
looking more often than the shortest staleness window finds nothing
new; `--heartbeat` still tunes it. The directory question offers
whatever project is already resolvable rather than making you type it.

Reminder settings are **Implemented (DD-464)**: the project records how
long a card may sit still by default, which coding agent to remind, its
session, how often to check, and the name of the job that does it.
`tira.onboard` collects them and can be **run again on an existing
project** with every answer pre-filled, so an older project gains them
by pressing enter through it; naming a different directory reloads that
project's own settings rather than carrying the first one's across. With
no coding agent installed those questions never appear. An empty value
clears a setting, and no heartbeat means no reminders at all.

Escalating reminders are **Implemented (DD-462)**: one message covers
every card that is past its column's limit, and its tone rises with how
often those cards have already been chased where they stand — plain,
tense, angry, shouting, then a final tone that keeps counting rather
than running out of words, across ten levels. The most-chased card sets the tone for the
message, so a long-stuck card is never softened by newer company, while
every line still states its own count, its column and how long it has
sat there. Nothing stale composes nothing at all.
`tira.notify.compose` returns the level, the tone, the text and the
cards it covers in one call.

Unattended failures are **Implemented (DD-461)**: background work has
nobody in the room to tell when it breaks, so a failure it cannot
resolve is recorded once and then shown underneath the output of
whatever command anybody runs next, naming the exact command that
clears it. The same failure recurring leaves the standing warning
alone rather than piling up copies, and it keeps appearing until it is
cleared. Human output carries it on standard output; every machine
format carries it on standard error so the payload stays parseable.

Notification history is **Implemented (DD-460)**: every reminder that is
actually delivered writes one row recording the card, the column it was
sitting in, and the time. How urgent a reminder is comes from counting
those rows, so **moving a card resets its escalation** — later rows
carry a different column name and the count starts again. The card
itself is never rewritten, so reminders never touch its stamp, its hash
or its history. `tira.stale --stale --with-level` reports each stale
card with the level it has already reached, which is enough to compose
a whole reminder in one call. Reading history creates nothing.

Staleness limits are **Implemented (DD-459)**: every column carries its own
limit in minutes and its own watched flag, both set by `tira.column.update` and
reported by `tira.column.list`. A column is watched unless switched off, so
existing boards need no configuring. `tira.stale --stale` judges each card by
its own column's limit, falls back to the project default set with
`tira.project.update --notify-after`, skips unwatched columns however old their
cards are, and — with no limit anywhere — reports nothing.
Indexed log reads are **Implemented (DD-434)** on the gate and evidence
lists, whose entries are append-only and stored newest-last: `--last N`
is the recent history (`--last 1` answers "what did it last pass?" at
constant cost), `--first N` the origins, a zero window or `--count`
returns `{"count": N}`, and `--id` returns one entry with a loud miss.
`--meta-only` keeps ids, results, uris, authors, and stamps while
replacing the unbounded text with `details_length`/`summary_length` and
`annotation_count`. `--where` filters entries (`result=fail` is the one
that matters) with the same loud unknown-field rule. Annotations always
ride with their parent entry; reads never mutate the logs.
Per-field history is **Implemented (DD-443)**. Every record write is
journaled field by field, whichever command performed it: creation seeds
one entry per set field so a field's timeline starts at its birth value,
edits record `before` and `after`, moves record the column change, and
structural fields (comments, attachments, linkage and the like) record
that they changed without inlining their whole value. Entries carry the
change time, the record ref, the operation, and an author when the
command supplied one — an unattributed change is recorded as such rather
than guessed. A rolled-back operation records nothing, so history never
claims a change that did not happen. `tira.history.list` reads it with
the same window, `--since`, `--where`, `--count`, and truncation
semantics as the other logs; `--field` narrows to one field's timeline
and an unknown name exits 2. History lives outside the boards, so it
never alters a record, a `content_hash`, or a board read, and reading it
never writes.
Compact JSON is **Implemented (DD-435)**: `-o json` emits canonical
one-line JSON with stable key order and unescaped UTF-8 — measurably
smaller, identical information — while `-o json-pretty` keeps the
indented shape. Formats are presentation only, and errors always go to
stderr in the selected structured format, so stdout can never carry a
corrupted payload.
An opt-in read-through cache is **Implemented (DD-436)** and disabled by
default: `--cache-ttl N` (seconds, at least 1) enables it per call on
read commands only, `--no-cache` is the explicit bypass. Entries key on
the full argument set and are valid only while both the ttl holds and a
board fingerprint is unchanged — any write invalidates immediately, so
a caller can never read its own stale data. A hit is always reported on
stderr (`served from cache`), never invisible; a corrupt entry warns and
falls back to a live read; a cached conditional read replays its exit
status. `--since` and `--if-changed` are part of the key, so they can
never silently defeat each other. Caching a mutation or a zero ttl
exits 2.
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
tira.comment.list --ref REF [--last N|--first N] [--meta-only] [--fields LIST] [--since TIMESTAMP] [--count] [-o FORMAT]
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
tira.attachment.list [--ref REF] [--include-deleted] [--meta-only] [--fields LIST] [--since TIMESTAMP] [--count] [-o FORMAT]
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
tira.evidence.list --ref REF [--last N|--first N] [--id EVD-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]
tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [-o FORMAT]
tira.evidence.annotate --ref REF --id EVD-NNN --note TEXT [--author ID] [-o FORMAT]
tira.gate.list --ref REF [--last N|--first N] [--id GATE-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]
tira.history.list --ref REF [--field NAME] [--last N|--first N] [--since TIMESTAMP] [--where CLAUSE ...] [--count] [--truncate N|--full] [-o FORMAT]
tira.gate.add --ref REF --gate TEXT --result pass|fail|blocked --details TEXT [--author ID] [-o FORMAT]
tira.gate.annotate --ref REF --id GATE-NNN --note TEXT [--author ID] [-o FORMAT]
tira.export [--fields LIST] [--exclude-fields LIST] [--include-empty] [--since TIMESTAMP] [--if-changed HASH] [--count] [--brief] [--truncate N|--full] [--where CLAUSE ...] [-o FORMAT]
tira.diff (--since TIMESTAMP|--snapshot FILE) [--type TYPE] [--fields LIST] [--count] [-o FORMAT]
tira.stale [--type TYPE] [--stale] [--with-level] [--older-than MINUTES] [-o FORMAT]
tira.notify.compose [-o FORMAT]
tira.column.apply --type TYPE --columns-json JSON [-o FORMAT]
tira.collector.show [-o FORMAT]
tira.collector.install [-o FORMAT]
tira.collector.remove [-o FORMAT]
tira.project.update [--notify-after MINUTES] [--collector NAME] [--agent NAME]
                    [--session ID] [--heartbeat MINUTES] [-o FORMAT]
tira.warning.list [-o FORMAT]
tira.warning.add --message TEXT [-o FORMAT]
tira.warning.clear {--id ID | --all} [-o FORMAT]
tira.notify.record --ref REF [--ref REF ...] --column SLUG [-o FORMAT]
tira.notify.list [--ref REF ...] [-o FORMAT]
tira.column.update --type TYPE --name SLUG [--notify-after MINUTES] [--watch|--no-watch] [-o FORMAT]
tira.<type>.list [--full] [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [-o FORMAT]
tira.import --file FILE [--dry-run] [-o FORMAT]
tira.search --text QUERY [--field FIELD ...] [--type TYPE] [--column SLUG] [--assignee ID] [--count] [--refs-only] [-o FORMAT]
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
A column shows its first ten cards and offers to reveal ten more at a time,
saying how many remain; the count beside the column name stays the real total.
The board control also carries a keyword filter that asks the server, so a word
appearing only in a card's description still finds it; an empty box clears the
filter and filtering restarts the paging at the first ten matches.
Cards can be worked in bulk: shift-click selects and deselects without
opening anything, dragging any selected card carries the whole selection to
the target column — one ordinary move per card, so the same validation
applies — and the ghost shows how many are travelling. A plain click clears
the selection and opens that card. A selection survives the live refresh.
Each column header shows its card count, and only when it has cards — an
empty column shows no zero. Counts are derived from the board itself, so
they stay correct after a refresh, a drag, or a creation. Every column
also offers an add-card control (live boards only, since a static file
has no server to post to): it opens the same dialog in new-card mode
with an empty form and no reference, because the reference is assigned
on save. Only the title is required; description, priority, and assignee
are optional there and every remaining field is editable on the card
once it exists. Creating posts to the same validated engine path as the
CLI, so an unknown column or assignee is refused, and the dialog then
switches to the created card. **Implemented (DD-441).**

Each board header carries a column-width toggle: Standard (the default) keeps
fixed-width scrollable columns, Fit all shrinks every column so a wide board
fits without sideways scrolling. The choice applies to every board, is
remembered in browser storage across reloads, and falls back to Standard when
storage is unavailable; screens under 720px keep scrollable columns while the
saved preference is preserved for the desktop.
The page reloads every sixty seconds by default and shows the active interval;
`?refresh=30` selects 30 seconds, invalid values fall back to sixty, and zero is
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
same-color background; video and audio attachments open in a native player backed by byte-range
streaming on the attachment route (so iOS plays and seeking works); PDFs
preview in the frame; TIFF previews where the browser can decode it and
otherwise shows a clear not-supported panel with the download; office
documents and other binaries offer a named download. Escape closes
the open preview first and the dialog second, and closing the dialog by
any route resets the preview layer. While the dialog is open it refreshes
on the board's cycle so edits from other terminals appear — but never
while a field editor, comment editor, or the composer is active, so
in-progress typing is never destroyed.
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

### UC-001: Create a project, or a whole board setup, in one call
**Implemented.** `dashboard tira.project.create --name "MT5"` creates an empty project in the current directory. `dashboard tira.project.new --name "MT5" --members "K-Bot, Michael" --columns "Backlog, Planning, In Progress, Done / Release" --sow-prefix M5S --epic-prefix M5E --ticket-prefix M5T` does the whole onboarding at once — people, per-board reference prefixes, and the same columns on all three boards, named as they read. `dashboard tira.onboard` asks the same questions one at a time and creates it from the answers.

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
**Implemented.** `dashboard tira.ticket.create --title "Login"`. The live board offers the same thing without the CLI: an add-card control on every column opens the dialog with an empty form, assigns the reference on save, and requires only a title.

### UC-009: Add a description
**Implemented.** `dashboard tira.ticket.create --title "Docs" --description "## Goal"`.

### UC-010: Allocate the next immutable ticket reference
**Implemented.** Repeated ticket creation advances the configured sequence.

### UC-011: Keep entity counters independent
**Implemented.** Creating a SOW does not consume an epic or ticket number.

### UC-012: Reject unavailable managed storage
**Implemented.** A command with no available managed project exits nonzero
without revealing or creating a storage location.

### UC-013: Choose the output weight
**Implemented.** `dashboard tira.project.show -o human` reads as Markdown; `-o json` is compact machine JSON (stable key order, raw UTF-8); `-o json-pretty` restores the indented shape when a person is reading.

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

### UC-040: Show a SOW, briefly when that is enough
**Implemented.** `dashboard tira.sow.show --ref SOW-001 -o json` (long text arrives truncated with visible markers; `--full` restores it); `dashboard tira.sow.show --ref SOW-001 --brief -o human` is the one-line look.

### UC-041: Show one record or a named set
**Implemented.** `dashboard tira.epic.show --ref EPC-001 -o human`; `dashboard tira.ticket.show --refs TKT-001,TKT-002,TKT-003 --fields column -o json` answers the columns of a named set in one call, keyed by ref with explicit not-found markers.

### UC-042: Show a ticket, whole or projected
**Implemented.** `dashboard tira.ticket.show --ref TKT-001` returns the record's populated keys (empty values are omitted by default; `--include-empty` restores them); `dashboard tira.ticket.show --ref TKT-001 --fields column -o json` returns only `ref` and `column` — the cheapest way to answer the board's commonest question.

### UC-043: Read boards in one call, at chosen weight
**Implemented.** `dashboard tira.export -o json` returns every SOW, epic, and ticket in one `{records, count}` object; `dashboard tira.export --fields ref,column -o json` returns the same board as two-key records, and `--exclude-fields description,comments` keeps structure while dropping the prose. Count is unaffected by projection. `dashboard tira.export --since 2026-08-07T02:30:00Z --fields ref,column -o json` returns only records changed at or after that instant plus `now` for the next poll; `dashboard tira.export --fields ref,content_hash -o json` adds a `board_hash`, and `dashboard tira.export --if-changed BOARD_HASH` collapses a quiet board to `{"unchanged": true}` with exit 1 — the cheapest possible sweep. Repeated sweeps within one task can add `--cache-ttl 60`: identical calls serve locally, any write reads fresh, and a hit always announces itself on stderr.

### UC-044: Filter by column, or just count it
**Implemented.** `dashboard tira.ticket.list --column backlog` lists the column; `dashboard tira.ticket.list --column backlog --count -o json` answers `{"count":47}` for a few bytes, and `--refs-only` returns just the refs — the input to a batch read.

### UC-045: Filter server-side on any field
**Implemented.** `dashboard tira.ticket.list --assignee ada` remains; `dashboard tira.ticket.list --where column=backlog --where sdlc_gate= -o json` returns parked tickets with no gate in one cheap call, and `--where labels~Zenandi-Developer` checks label coverage without an export.

### UC-046: Watch the board with a first-class diff
**Implemented.** `dashboard tira.ticket.list --parent EPC-001` still filters by parent; `dashboard tira.diff --since 2026-08-07T10:30:00Z -o json` replaces a hand-written watcher — kinds, current column and gate, and new-comment ids in one small call, with `now` to chain the next poll.

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
**Implemented.** `dashboard tira.ticket.move --ref TKT-001 --column in-progress`. Every move, like every field edit, is journaled: `dashboard tira.history.list --ref TKT-001 --field column -o json` returns that card's column timeline, and `--field title` or any other field returns its own, with the value before and after each change.

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

### UC-090: Read comments at chosen weight
**Implemented.** `dashboard tira.comment.list --ref TKT-001 -o json` lists everything; `--last 1` is the newest comment alone, `--meta-only` returns ids, authors, stamps, body lengths, and attachment counts without a single body — exactly what a watcher needs before deciding to read.

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

### UC-098: Record, annotate, and cheaply re-read gates, evidence, and checklists
**Implemented.** Add a gate, then append a correction with `dashboard tira.gate.annotate --ref TKT-001 --id GATE-001 --note "Use local docs" --author ada`; evidence uses `tira.evidence.annotate` with `EVD-NNN`. Manage retained checklists with add, list, and update; there is no remove command. `dashboard tira.gate.list --ref TKT-001 --last 1 -o json` reads the newest gate entry at constant cost, and `--where result=fail --meta-only` lists every failure without the details text.

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
