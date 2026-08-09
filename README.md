# Tira

Tira is a filesystem-native Kanban project manager for Developer Dashboard. It
provides Jira-style projects, SOWs, epics, and tickets over a transparent local
filesystem engine accessed exclusively through Tira commands.

Release 0.95 implements the complete command ecosystem: projects, independent
boards, columns, records, links, people, comments, attachments, evidence,
gates, search, dashboards, agent-efficient TOON output, singular record
ownership, planning metadata, immediate parents, and inactive-person controls.
Attachment retrieval streams content without exposing its managed location.
Text is strict UTF-8 end to end, including long comments and currency symbols;
legacy isolated-byte records are repaired when next updated.
Every SOW, epic, and ticket also has an ordered checklist of item/status pairs.
Repeatable content and scope options append safely on update; explicit
`--set-*` options are the only wholesale replacement route.
Attachment-add responses distinguish the supplied filename from the filename
actually retained when identical content is deduplicated.
Migration-scale tools provide one-call export, field-aware search, previewed
bulk import/replacement, and append-only gate/evidence corrections.
Hierarchy views retain the complete direct-read record at every node and add
children, so human and recursive JSON views cannot silently lose metadata.
Dashboard reads scan each selected board once and group records by configured
column in memory, keeping multi-column boards responsive without an index.
The default dashboard reads only filenames and modification times; `--title`
adds titles with one JSON read per card, while `-o json` returns full records.
Every mode orders cards newest-first by filesystem modification time.
`-o table` emits a self-contained, responsive dark Kanban document with
left-to-right columns, stacked type boards, embedded styling, card selection,
and local last-modified/reference sorting. It makes no network requests.
Project selection also accepts aliases registered with `d2 path`; Tira resolves
them through Developer Dashboard without printing the private target directory.
The live browser board opens every card in a Jira-style sectioned dialog with
in-place field editing and full comment management, including permanent
comment deletion through the `tira.comment.remove` command.
Attachments are first-class in the dialog: chips open images, PDFs, and text
inline in an overlay viewer with no download step (HTML is forced to plain
text so nothing executes), files upload from the dialog with a 16 MB cap,
deletion is reference-safe under content-hash dedup via the new
`tira.attachment.detach` command, and every comment shows and manages its
own attachments separately from the record strip.
Every list field is editable per item from the dialog — labels, affects
versions, key details, deliverables, scope, acceptance criteria, test steps,
BDD, and ATDD — and checklist entries can be added and edited in place while
remaining retained-not-deleted.
Linkage is editable from the dialog too: set or unlink hierarchy and
sub-item parents, link and unlink children, and add or remove typed links
with reciprocals through the same transactional engine commands as the CLI.
Long-text sections carry their edit pencil in the section heading, and the
whole dashboard is responsive down to phone width with a near-fullscreen
dialog and a stacked details grid. Card drag-and-drop runs on pointer
events, so it works identically with a mouse and with touch: hold a card
briefly on a phone, drag its floating ghost to the highlighted column, and
the same real JSON-file move applies.
Attachments render as a one-per-row list with right-aligned full timestamps, sorted
newest first — legacy references recover their real timestamp from the
stored file's own modification time; comments list
newest first under a collapsed top composer that expands into an author
picker, a bold/italic/code/list formatting bar, and markdown storage with
safe formatted rendering in the dialog. Text attachments render in the
viewer's own themed panel with deterministic contrast in every color
scheme, instead of the browser's default plain-text document.

## Value

Tira gives people and AI agents a shared project-management model without a
server or opaque database. Folders represent Kanban columns, JSON files
represent work records, and YAML files hold project and board configuration.

### Why mirror Jira locally?

Tira keeps Jira's familiar project, epic, ticket, and Kanban concepts while
removing payload overhead that quickly consumes an LLM agent's context and
usage allowance. In measured migration examples, Jira responses averaged
about 3.3 times the size of equivalent Tira records, with the gap increasing
on comment-heavy work:

- Jira ADF expands each paragraph into a nested `type`/`content` tree.
- Every Jira comment repeats its author's account, timezone, and avatar block,
  including five image URLs.
- Jira needs separate issue and comment requests; one Tira `show` includes the
  record and its comments.

For example, Ticket at Jira occupied 1.04 MB across two requests and 301 KB in one
Tira read. If ticket was only 1.29 times larger in Jira because it had no comments,
supporting the conclusion that repeated author metadata drives much of the
growth. A heavy ticket can therefore use roughly one-third of an agent's
context with Tira, in one operation instead of two.

Tira deliberately has no HTTP transaction layer. Commands operate directly on
validated local files and column folders, keeping the system simple,
inspectable, and efficient.

## Installation

```bash
dashboard skills install tira
```

## Commands

Create a project:

```bash
dashboard tira.project.create --name "Delivery" --dir ./delivery
```

Create free-ranging records and link them later:

```bash
dashboard tira.sow.create --title "Ship v1"
dashboard tira.epic.create --title "Authentication"
dashboard tira.ticket.create --title "Implement login"
```

Operate the board, relationships, and collaboration data:

```bash
dashboard tira.column.add --type ticket --name in-progress --after backlog
dashboard tira.hierarchy.link --parent SOW-001 --child EPC-001
dashboard tira.link.add --from TKT-001 --type blocks --to TKT-002
dashboard tira.comment.add --ref TKT-001 --author ada --text "Ready for review"
dashboard tira.checklist.add --ref TKT-001 --item "Run regression" --status "To Do"
dashboard tira.checklist.update --ref TKT-001 --id CHK-001 --status Done
dashboard tira.attachment.add --ref TKT-001 --file ./evidence.png -o json
dashboard tira.project.people.deactivate --id ada
dashboard tira.dashboard --type all
dashboard tira.dashboard --type all --title -o human
dashboard tira.dashboard -o table > kanban.html
dashboard tira.dashboard.ticket --title -o table > tickets.html
dashboard tira.dashboard -o browser
dashboard tira.dashboard.ticket --title -o browser=localhost:4567
```

`dashboard tira.onboard` asks for everything a new project needs and creates
it from the answers. The same thing non-interactively, for scripts: `dashboard tira.project.new
--name "MT5" --members "K-Bot, Michael" --columns "Backlog, Planning, In
Progress, Done / Release" --sow-prefix M5S --epic-prefix M5E --ticket-prefix
M5T` creates the project, its people, each board's reference prefix, and the
same columns on all three boards, with column names written as they read.

Tira uses `Cpanel::JSON::XS` when it is installed and core `JSON::PP`
otherwise. The accelerator is optional and needs no configuration; on a
138-record board it takes a titled dashboard from about two seconds to
twelve milliseconds. Both backends emit identical bytes, so installing or
removing it never rewrites a record or changes a content hash.

HTML dashboards reload every sixty seconds and display the active interval.
Each board header offers a column-width choice: Standard keeps fixed-width
scrollable columns, Fit all shrinks every column to fit the container so no
sideways scrolling is needed. The choice is remembered in browser storage;
narrow screens keep scrollable columns regardless.
Append `?refresh=30` to the browser URL to select a positive interval in
seconds; zero is safely clamped to one second. Browser output serves the same
board shell through Dancer2, defaults to `0.0.0.0:7899`, and accepts `0.0.0.0`,
`127.0.0.1`, or `localhost` with an optional port. Each request rescans the
filesystem. The page polls lightweight card placement data and moves cards in
place without reloading. Dragging a card calls the real record-move operation,
which moves its JSON file into the target column folder. Click a card to load
its complete record on demand in a Jira-style dialog that renders section by
section — a details grid, description and solution texts, planning lists,
checklist, linkage, evidence, attachments, and threaded comments — never as a
raw JSON dump. Single-value fields are editable in place through the same
validated engine as the CLI, and the comment section adds, edits, and
permanently deletes comments with an author picker limited to active project
people. Validation failures appear inside the dialog. “Last updated” changes
only after fresh data is applied. Stop the foreground command with
Ctrl-C when the dashboard is no longer needed.

The default all-interface bind is reachable from permitted network peers. Use
`localhost` or `127.0.0.1` when the complete ticket payload must remain local
to one machine.

Read or correct many records without spawning one process per ticket:

```bash
dashboard tira.export -o json
dashboard tira.ticket.list --full -o json
dashboard tira.search --text Jira --field description -o json
dashboard tira.import --file changes.json --dry-run -o json
dashboard tira.replace --pattern Jira --with Local --field description --dry-run -o json
dashboard tira.gate.annotate --ref TKT-001 --id GATE-001 \
  --note "Use local documentation" --author ada
```

Repeat `--field` to review or change several fields while preserving historical
comments:

```bash
dashboard tira.search --text 'dashboard doc.' \
  --field description --field bdd --field atdd -o json
dashboard tira.replace --pattern 'dashboard doc\.' --with 'the docs vault' \
  --field description --field bdd --field atdd --dry-run -o json
```

Search always returns `{hits, count}`. Unnamed fields are not inspected by a
scoped replacement.

Remove `--dry-run` only after reviewing the returned field-level changes.
Import applies the complete ref-keyed change set transactionally. Gate and
evidence corrections append annotations; their original observations remain
unchanged.

SOWs, epics, and tickets share planning metadata. For example:

```bash
dashboard tira.ticket.create --title "Security review" --assignee ada \
  --reporter grace --label Security --priority 5 \
  --start-date 2026-08-06T09:00:00Z \
  --due-date 2026-08-08T17:00:00+01:00 --fix-version 3.0.0
```

Assignee and reporter values are person IDs in JSON and names in human output.
Inactive people remain visible on historical work but cannot receive new
ownership.

## Output

TOON is the default and is also selected explicitly with `-o toon`.
`-o json` returns canonical pretty JSON. `-o human` returns Markdown:

```bash
dashboard tira.ticket.create --title "Add tests" -o json
dashboard tira.epic.create --title "Release gate" -o human
```

Print the complete agent manual as raw Markdown:

```bash
dashboard tira.skills
```

The manual is the complete technical contract. It records every command
signature, argument interaction, output and exit contract, transaction
invariant, and 100 implemented use cases while intentionally keeping managed
project location opaque.

## Managed-storage model

Tira owns a local filesystem-backed database, but its location is intentionally
not part of the agent interface. Backlog and Discard are always present and
protected. Use the CLI for every read and mutation; manual managed-file editing
is unsupported.

See [the foundation guide](docs/foundation.md) and [SKILLS.md](SKILLS.md) for
the complete implemented Tira ecosystem.

## Verification

Run tests only through the workspace Docker environment:

```bash
docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test \
  bash -lc 'cd /workspace/skills/tira && cpanm --quiet --notest --installdeps . && prove -lr t'
```

The release gate requires 100% statement and subroutine coverage plus the
post-coverage `perlsec` and taint-mode audit recorded in `tickets/TESTING.md`.

## License

Tira is released under the MIT License. See [LICENSE](LICENSE).
