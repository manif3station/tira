# Tira Agent Skill Manual

Tira is a filesystem-native Jira-style Kanban system exposed through Developer
Dashboard. It manages projects, SOWs, epics, tickets, columns, relationships,
people, comments, evidence, gates, and content-addressed attachments without a
server or hidden database. Never edit Tira-managed YAML or JSON directly.

This manual is the use cases: what to do, and which command does it. For the
command reference — every command, every argument, what it is for and when to
use it — run `dashboard tira.usage`.

## Before anything else: install Developer Dashboard

Tira is a Developer Dashboard (DD) skill and every command in this manual
runs through `dashboard`/`d2`, which DD provides. Install DD first, then
install this skill:

```bash
curl https://raw.githubusercontent.com/manif3station/developer-dashboard/refs/heads/master/install.sh | sh
dashboard skills install tira
```

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
- **Implemented (1.04):** shipped, executable, and covered by tests.
- `dashboard tira.skills` is implemented and prints this file as raw Markdown.
- `dashboard tira.changes` is implemented and prints the changelog as raw text.

All commands and use cases in this manual ship in release 1.04.

## Global invocation grammar

```text
dashboard tira.<resource>.<action> [arguments] [-o FORMAT]
dashboard tira.skills
dashboard tira.changes

FORMAT := toon | json | human
DASHBOARD_FORMAT := toon | json | human | table
TYPE   := sow | epic | ticket
```

References are immutable, case-sensitive values such as `SOW-001`, `EPC-001`,
and `TKT-001`. Quote whitespace, Markdown, glob characters, and empty strings.
Repeat an option only where its table marks it repeatable. `--help` is exclusive
and performs no mutation. Repeating a single-valued option anyway is refused,
naming the flag and both competing values, rather than silently keeping the
last and discarding the rest - `--priority 5 --priority 1` no longer creates a
P1 card with exit 0. Genuinely repeatable options are entirely unaffected.
TKT-389.

An unknown option is refused naming the nearest declared option name(s) by
edit distance - `Unknown option: key-details` followed by `Did you mean:
--key-detail` - the same help an unknown command already gets, rather than
only "Invalid command-line options" with nothing suggested. Nothing is
guessed when no declared name is close, and nothing is written before the
refusal either way. TKT-298.

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
  line. **Implemented.**; identical information to every other
  format.
- `-o json-pretty`: the indented JSON shape, for human reading.
- `-o human`: Markdown summary. With `--fields` it shows the fields asked for
  and nothing else — it does not draw the card summary against a narrowed
  record, which used to print a fully populated card as an empty one and leave
  out the field that had been requested.
- Errors use the selected structured format on stderr, never success stdout.
- Mutations return the affected record or operation receipt.
- `attachment.get` emits raw bytes and never exposes managed storage paths.
- `tira.skills` emits raw Markdown and accepts no options.
- `tira.changes` emits the raw changelog by default, or entries newer than `--since VERSION` (that version itself excluded). It never exits zero having printed nothing — an empty changelog means a broken copy of the skill, and it says so rather than reading as a release with no changes. An unknown or malformed `--since` version is refused. TKT-404.

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

The enforcement ledger (the violation store a `d2 tira.police` pass reads and
writes) takes its own exclusive lock, scoped to the store directory rather than
the project root, across the whole read-modify-write of one pass - not just the
final write. TKT-486: two `d2 tira.police` daemons left running against the
same board at once used to race this cycle with no lock at all, and a daemon
whose read landed before another daemon's write could silently lose that
daemon's already-recorded violation. The lock stops that write-corruption race.
It does not by itself stop two daemons from ever running at the same time -
only one police daemon is meant to watch a given board, matching
`_enforcement_write`'s own invariant ("Police writes here and nobody else
does"). TKT-487: the same file has two more writers besides `violation_record`
- the move-notification stamp and the agent-still throttle stamp - each doing
their own read-modify-write of it. Both now share the same lock, factored into
one `_with_enforcement_lock` helper, so all three serialise against each other
rather than only against themselves.

`d2 tira.police` is meant to be a singleton per board - his own words, asked
directly after the duplicate-daemon investigation above: "Whoever the last run
it is the winner and the loser process will be killed." The persistent daemon
now claims a pid file in the violation store before its first round, killing
whatever still-alive daemon held the claim before it, and releases the claim
on a clean exit - `--once` and `policy.bridge` (a read-only tail, never a
writer) do not participate, since neither is "a process" in the sense that
answer means. TKT-492.

## Record schema

Every SOW, epic, and ticket JSON contains `ref`, `type`, `title`, `description`,
`key_details`, `problem_or_feature`, `solution_needed`, `deliverables`,
`scope.included`, `scope.excluded`, `source`, `acceptance_criteria`,
`test_steps`, `bdd`, `atdd`, `gate_passing_log`, `evidence`, `attachments`, `checklist`,
`required_items`, `subtasks`, `linkage`, `assignee`, `reporter`, `labels`, `due_date`,
`start_date`, `sdlc_gate`, `lifecycle`, `priority`, `fix_version`,
`affects_versions`, `parent`, `comments`, `created_at`, and `last_updated`.

Comments have an ID, author, `markdown|text` format, body, attachments, creation
time, and last update. Evidence and gate entries are append-only observations.
Assignees and reporters must be active people defined in `project.yml`.
Checklist entries have an immutable `CHK-NNN` ID, `item`, free-text `status`,
creation time, and last update. Status is descriptive; Tira never infers record
completion or moves a record from it. Where a rule does read a status against
the word "done" - the `card-stalled` and `checklist-unmoved` police rules, and
the required-action move-out and backward-reset checks below - the comparison
is case-insensitive, so `--status Done` or `--status DONE` reads exactly like
`--status done`; every other value, such as `todo`, is unaffected. TKT-434.

That rule is the whole contract, and since 4.63 the browser dashboard keeps it
too. It had compared against the literal `"done"` in three places - the
done/total count, the tick-or-empty-box icon, and whether an actionable
checkbox is drawn - so an item stored as `Done` was finished to the gate and
outstanding to the page. Measured on a real board: 534 items stored that way
against 2068 lowercase, mis-rendering across 21 cards, two of which showed all
97 of their required actions as empty boxes while being provably complete. The
third comparison was the harmful one, because it did not merely mislead - it
offered a live checkbox to redo finished work, and taking it up can meet the
duplicate-proof refusal. All three now go through one predicate rather than
three copies, since three copies is how one of them came to disagree. Only the
comparison against `done` is defined: status stays free text, nothing
normalises what is stored, and the checklist renderer still prints whatever
value it holds verbatim. TKT-601.
Checklist entries are retained, not deleted; there is no remove command. Word
an entry as though it will outlive the work, and change its item or status only
with `tira.checklist.update`.
`checklist-unmoved` addresses its finding to the card's reporter, not its
assignee, since 3.47 - the assignee is often the reviewer for a card sitting
in review, who cannot tick an item only the card's own author left unticked,
while the reporter is who raised the card and is who a checklist item
usually belongs to. TKT-286.
`required_items` is a genuinely separate list, never written to by anything
that touches `checklist`. Entries have an immutable `REQ-NNN` ID, `item`,
free-text `status`, the `column` the item applies to, creation time, and last
update - managed with `tira.required-action.add/list/update`, which move-in,
creation-time population, and the move-out gate also use internally. TKT-445.

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
  timezone, in any of the three forms `--since` already took (TKT-572):
  `2026-08-05T14:30:00+01:00`, `2026-08-05T14:30:00+0100`, or
  `2026-08-05T13:30:00Z`. The basic `±HHMM` form matters because it is the
  one Tira itself prints on every card — `created_at` and `last_updated` read
  `2026-08-19T09:00:00+0100` — and until TKT-572 these two fields refused it,
  so a timestamp copied out of a card could not be pasted back in. An offset
  of some kind is still required: a stamp without one is ambiguous, which is
  what the mandatory timezone exists to prevent.
- `sdlc_gate` and `lifecycle`: nullable free-text values. `sdlc_gate` is
  independent of append-only structured gate log entries. `sdlc_gate` is
  free text only until a project declares its own gate vocabulary with
  `tira.project.gates --gate-name` (TKT-292) — once declared, a name outside
  it is refused, the same list `tira.gate.add`'s `--gate` is validated
  against, so the two can no longer silently drift apart.
- `priority`: nullable JSON integer from `1` through `5`, where **5 is the most
  urgent** and 1 the least. This is the opposite of the P1 convention most
  trackers use, so it is worth reading twice before setting one. Human output
  renders `Low`, `Medium Low`, `Medium`, `High`, or `Very High`, respectively,
  and a board ordered by priority puts 5 at the top. A card with no priority is
  unassessed rather than lowest, and sorts last saying so.
- `fix_version`: one nullable value - a released version number (e.g. `3.45`), `none`, or an `n/a - ...` explanation for work outside a release; anything else is refused. `tira.changelog.check [--file FILE]` cross-references every card's claimed fix_version against a changelog's own version headings, naming any card whose version was never actually released. Until 3.45 the field took any word at all, and a real gap - four tickets shipped in 1.07 with no changelog entry - went unnoticed until a reader cross-checked the two by hand. TKT-347.
- `affects_versions`: an array of free-text values, empty by default.
- `parent`: one generated parent ref or `null`; it is never directly editable. `tira.card.required` names `parent` among the fields a complete card needs, but the definition it returns carries the exception alongside the field list: a SOW is exempt (it sits at the top of the tree) and so is any card carrying the `standalone` label (saying somebody meant it to have none). Read `exempt.parent` off that command's own JSON rather than assuming the field list applies to every card unconditionally - `orphan-card` and the push gate both honour the same exception. TKT-285.

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
--scope-in TEXT ... --set-scope-in FILE
--scope-out TEXT ... --set-scope-out FILE
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
`--set-test-steps`, `--set-bdd`, `--set-atdd`, `--set-scope-in`, and
`--set-scope-out` are the explicit full-array replacement controls, same
file-or-stdin shape as the others; an empty array clears the field rather
than leaving it unchanged. TKT-293.

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

**Create and Update say what the command needs, not what a card needs.** A card
can be made with a title alone; it cannot be finished with one. Everything a
complete card carries is listed by `tira.card.required`, and the push gate and
police both read that same list - as they both read `tira.column.endings` for
which columns this board says work ends in, because a card that has ended is
not asked what a card still being worked is asked - so a field marked optional here is optional
to type and required before the card can claim to be done. An agent that fills
in only what says required will make cards that are refused later, which is
what happened on 2026-08-15: five cards raised from this table blocked a push
that had already passed its suite.

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
| `--priority 1..5|""` | no | optional | replace/clear | Numeric priority, 5 being the most urgent. |
| `--fix-version TEXT|""` | no | optional | replace/clear | One target version. |
| `--affects-version TEXT` | yes | optional | append | Affected version. |
| `--exempt-required TEXT` | yes | optional | append | A column-required-action item this specific card is exempt from. Paired positionally with `--exempt-reason`; refused without a matching one. |
| `--exempt-reason TEXT` | yes | optional | append | Why the paired `--exempt-required` item does not apply to this card. |

All listed create and update fields are implemented. Updates may replace arrays
with `--set-<field> FILE`; `-` reads a UTF-8 JSON array from stdin.
`--problem-or-feature` aliases `--problem`; `--acceptance-criteria` aliases
`--acceptance`; and `--set-acceptance-criteria` aliases `--set-acceptance`.

## Command catalogue

### Manual and project

- `tira.skills` — **Implemented.** No arguments; raw manual.
- `tira.changes [--since VERSION]` — **Implemented.** The raw changelog, or
  entries newer than `VERSION` (excluding that version's own entry). The
  fourth documentation command, beside `tira.skills`, `tira.usage` and
  `tira.policies`, so an agent wanting one of them need not print several
  thousand words of the others to reach it. Every entry names the card it
  came from, so a project that reported something through
  `tira.dev.found.bug_or_improvement` can find that card's number here and
  see what happened to it. `--since` bounds by exactly the two version
  numbers an upgrade notice already states in one sentence, rather than
  requiring the whole history to reach the newest entry. TKT-404.
- `tira.project.create --name TEXT [--dir DIR] [-o FORMAT]` — **Implemented.**
  Name required; directory defaults to `.`; existing projects are preserved.
- `tira.project.new --name TEXT [--dir DIR] [--members LIST] [--columns LIST]
  [--sow-prefix PREFIX] [--epic-prefix PREFIX] [--ticket-prefix PREFIX]
  [--digits N] [--notify-after MINUTES] [--collector NAME] [--agent NAME]
  [--session ID] [--heartbeat MINUTES] [--repo PATH] [-o FORMAT]` —
  **Implemented.** Creates a project, its
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
- `tira.onboard [-o FORMAT]` — **Implemented.** The guided version of
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

  TKT-555: `_wizard_defaults` now carries a project's existing mode
  (single vs chain) into its returned defaults, so re-running onboarding
  against a project already set to a mode shows it as that question's
  default - previously the mode question always showed no default at
  all, contradicting "press enter to keep each answer" for that one
  question specifically (every other field's stored value was already
  shown correctly). Not data-loss - an unanswered mode question was
  always a no-op, never a silent reset - just a broken pre-fill promise.
  Found during a standing 1-hourly bug hunt.

  TKT-556: the "Do all three boards use the same columns?" question now
  defaults to whatever an existing project's boards actually have -
  identical or not - instead of always defaulting to yes regardless of
  project state. `_wizard_defaults` already computed this (the same
  `@distinct` check deciding the shared `columns` key) but never
  surfaced it as this question's default. Not destructive - column_add
  only ever adds columns, never removes any - the same broken-pre-fill-
  promise class as TKT-555. Found during a standing 1-hourly bug hunt.

  TKT-560: the wizard's "Which coding agent should be reminded" question
  no longer refuses anything but the literal string `claude` -
  `project_update`'s own agent handling was already generalized by
  TKT-459 to accept any registered, active person (its own example:
  `zenbot`), but this interactive question was never updated to match.
  Found during a standing 1-hourly bug hunt.

  `tira.onboard -o browser` — **Implemented, TKT-517.** Michael, via TODOYET:
  "Add a browser mode for tira.onboard, so there user either to answer
  questions from the CLI or they do that on the browser... No login needed
  because this is not a long term thing. Once the questions are all
  answered. The onboard starman or dancer2 will be stopped and the project
  folder should be setup." A disposable, no-login server (its own package,
  `Tira::OnboardWeb`, not layered onto the dashboard) serves every field the
  CLI wizard collects as one form rather than replaying its turn-by-turn
  prompts over HTTP; submitting it validates and creates through the exact
  same dispatch (`_invoke` for the `onboard` command) the interactive
  wizard's own answers reach, so nothing forks into a second creation path.
  Confirmed via Q-078: the address convention matches `tira.dashboard -o
  browser`, defaulting to `127.0.0.1` on a dynamically-picked free port
  rather than the dashboard's fixed 7899 (two onboarding sessions must
  never collide) - `-o browser=127.0.0.1:PORT` still wins when given. On
  success it renders a thank-you page reminding the person their role from
  here is viewing/managing cards (`tira.dashboard -o browser`) and that
  every `tira.<command>` is agent-facing but open to them too, then stops
  itself: a forked watchdog gives the response a moment to leave the
  socket, then sends the parent SIGTERM - any request after that gets a
  503, not a second form.

  TKT-527: `-o browser=0.0.0.0:PORT` is refused for `onboard`, naming why
  - this server has no login at all, so making it reachable from the
  whole network would be a genuinely unauthenticated project-creation
  endpoint. `127.0.0.1`/`localhost`/the plain default are unaffected;
  `tira.dashboard`'s own `0.0.0.0` mode stays login-gated and untouched.

  TKT-543: `GET /` now pre-fills name/members/columns/prefixes from an
  existing project at the directory it was pointed at, reusing the exact
  same `_wizard_defaults` the CLI wizard already relies on rather than
  duplicating the lookup - previously the browser form always started
  blank except for hardcoded `SOW`/`EPC`/`TKT` prefix defaults, so editing
  an existing project meant guessing its current values correctly or
  having the submission fail with "A different project already exists
  there."

  TKT-553: the form now also offers `notify_after` (stuck-card minutes),
  `agent`/`session`/`collector` for card-reminder setup, and one field
  per `Tira->onboarding_questions()` entry (today, project mode - single
  vs chain), naming its options the same way the terminal wizard does -
  previously these four things had no equivalent in the browser form at
  all, despite its own POD claiming full field parity with the CLI
  wizard. Found during a standing 2-hourly improvement hunt.

  TKT-559: `GET /` now pre-fills `notify_after`/`agent`/`session`/
  `collector` and every onboarding question (today, `mode`) from an
  existing project too, the same way name/members/prefixes/columns
  already did - `_fields_from_defaults` (introduced by TKT-543) was
  never updated when TKT-553 added these five fields to the form, so
  they silently stayed blank on re-open even though `_wizard_defaults`
  already had the data. Found during a standing 1-hourly bug hunt.
- `tira.project.show [-o FORMAT]` — **Implemented.**
- `tira.doctor [--repair] [-o FORMAT]` — **Implemented.** Finds board files
  holding bytes that are not valid UTF-8, and says which file, which byte and at
  what offset. It looks for bytes rather than for the replacement character:
  U+FFFD is what a lenient read *produces*, not what is on disk, so a check
  looking for it would report every damaged file clean.
  Reports only, until `--repair` is given. A bad byte is repaired by reading it
  as latin-1 and writing it back as UTF-8, so `0xD7` becomes the multiplication
  sign somebody meant rather than a replacement mark — substituting one would
  make the damage permanent. Nothing else in the file moves, and attachments are
  never touched, being bytes that were never meant to decode.

- `tira.project.update [--name TEXT] [--dashboard-host HOST] [--dashboard-port PORT]
  [--listen HOST[:PORT]] [--notify-after MINUTES] [--collector NAME]
  [--agent NAME] [--session ID] [--heartbeat MINUTES] [--repo PATH]
  [-o FORMAT]` —
  **Implemented.** Renames a project, and **Implemented.** remembers the address its live board should listen on:
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

All are **Implemented.** and require `--type sow|epic|ticket`:

```text
tira.board.show --type TYPE [-o FORMAT]
tira.column.list [--type TYPE] [-o FORMAT]
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

These create commands are **Implemented.**

```text
tira.sow.create --title TEXT [--column SLUG] [record field arguments] [-o FORMAT]
tira.epic.create --title TEXT [--column SLUG] [record field arguments] [-o FORMAT]
tira.ticket.create --title TEXT [--column SLUG] [record field arguments] [-o FORMAT]
```

They create independent records with empty linkage. A card lands in Backlog
unless `--column` names another one, which lets a card be claimed into the
column the work is in rather than created and then moved. A column that does not
exist is refused, and so is creating a card directly into Discard: that column
is where work is set aside, and a card put there before it exists was never
work. The answer names the column the card is in. These symmetric forms are
**Implemented.** for each `TYPE`:

```text
tira.TYPE.show (--ref REF ...|--refs LIST) [--fields LIST] [--exclude-fields LIST] [--include-empty] [--since TIMESTAMP] [--if-changed HASH] [--brief] [--truncate N|--full] [-o FORMAT]
tira.TYPE.list [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [--fields LIST] [--exclude-fields LIST] [--include-empty] [--since TIMESTAMP] [--count] [--refs-only] [--brief] [--truncate N|--full] [--where CLAUSE ...] [-o FORMAT]
tira.TYPE.update --ref REF [record field arguments] [-o FORMAT]
tira.TYPE.move --ref REF --column SLUG [-o FORMAT]
tira.TYPE.discard --ref REF [-o FORMAT]
tira.TYPE.restore --ref REF [--column SLUG] [-o FORMAT]
tira.TYPE.clone --ref REF --title TEXT [-o FORMAT]
tira.TYPE.missing --ref REF [-o FORMAT]
```

List filters use AND. Parent means the generated immediate parent ref. Discard
is movement, not deletion; restore defaults to Backlog. `missing` answers the
same field list `card-full-details` already computes to fire a violation -
which of a complete card's fields are still empty - for the named card in any
column, on demand, rather than waiting for the card to reach its declared
entry column and for police to notice. Owner, in Cantonese, watching an agent
drop a field: "I want a command that shows immediately which parts are
missing." TKT-498.
Field projection is **Implemented.** on show, list, and export:
`--fields` and `--exclude-fields` take comma-separated lists, repeat and
accumulate, and never alter stored data. Selection always keeps `ref`;
exclusion applies after selection. An unknown or empty field name exits 2
naming the offender — a typo can never quietly return an empty object.
Selected fields that are null stay visibly null. On any other command
either flag exits 2.
Empty omission is **Implemented.** on the same three commands: by
default a returned record omits keys whose value is null, an empty
string, an empty array, or a hash of only such values; `--include-empty`
restores every key. An omitted key therefore always means "empty or
unset" — `false` and `0` are values and are never omitted, and a field
named in `--fields` is always present even when empty. The record schema
section above lists every possible key, so omission costs no
discoverability.
Changed-since filtering is **Implemented.** on the same three
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
Content hashes and conditional reads are **Implemented.**
Selecting the computed `content_hash` field returns an opaque stable
token covering every meaningful field including placement and excluding
`last_updated` and the read-time-only `checklist_done`/`checklist_total`
counts, so a no-op write keeps its hash regardless of which fields were
requested alongside it; only equality is contractual. `tira.export --fields ref,content_hash` also returns a
`board_hash` over the whole result. `--if-changed HASH` on show and
export returns `{"unchanged": true}` with exit 1 when nothing differs
(exit 0 with the payload otherwise — the exit status alone answers the
question), exits 2 on a malformed hash rather than treating it as
changed, composes with `--fields`, and when combined with `--since` the
stricter suppression wins. Conditional reads never write.
Count and refs-only are **Implemented.** `--count` (list,
export, search) returns `{"count": N}` alone — zero is an answer, not an
error — and `--refs-only` (list, search) returns a flat ref array in
stable ref order, deduplicated for field-scoped search hits. Count wins
over refs-only wins over `--fields`, documented rather than guessed, and
field names are still validated loudly even when projection is moot.
With `-o human`, count prints a bare number and refs-only prints one ref
per line, so both pipe straight into a shell.
Brief and truncation are **Implemented.** on show, list, and
export. `--brief` is exactly `ref,title,column,sdlc_gate,assignee` — a
shorthand for the equivalent `--fields` list, never a special case — with
the title cut at a stable 72 characters plus an ellipsis and a null
assignee kept visible; combining it with `--fields` exits 2. Long text
(`description`, `problem_or_feature`, `solution_needed`, and each gate
`details` / evidence `summary`) truncates at 2000 characters by default,
always visibly: the cut value ends with an ellipsis and gains
`<field>_truncated`, `<field>_length`, and `<field>_hint` ("use --full to
read it whole") markers, so a truncated read names its own fix in the same
output rather than requiring the reader to already know `--full` exists -
`TKT-402`. `--truncate N` chooses
the limit, `--truncate 0` omits the text while still marking it present,
`--full` restores everything (combining `--full` with `--truncate` exits
2), short fields carry no markers, and structural fields are never cut.
Truncation is presentation only: `content_hash` is computed from the
full record. Writing a truncated read straight back through `update` is
refused, naming `--full` - before TKT-400 a read-modify-write on
`description`, `problem_or_feature`, or `solution_needed` done without
`--full` silently destroyed everything past character 2000, because the
truncated flag never travelled from the read into the write. Only an
exact match against a truncated read of the field's *current* value
refuses; a genuinely shorter rewrite is unaffected. The board dashboard is already a summary view and takes no
brief flag.
Checklist completion is **Implemented.** `checklist_done`/
`checklist_total` ride alongside the existing `checklist` array on every
show and list response, by default rather than opt-in like
`content_hash` - a checklist's completion used to be computed by hand on
every read, though `checklist[N]{...}`'s own array header already named
the total. Computed at read time only, from the array a read is already
walking to render it: never stored, so a mutation that round-trips a
read (`comment.add`, `checklist.add`, and the rest) never persists a
stale copy or journals a spurious change for either field. A
checklist-less card reads `0`/`0`, not an error. `TKT-407`.
Comment and attachment reads are **Implemented.** Comments are
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
Since 4.69 `content_type` is the one answer to "can this be read": a
named list decides the extensions where guessing would be worse than
knowing — a `.pl` file is Perl whatever its first bytes look like, and a
`.zip` whose bytes happen to read as printable must not be shown as
text — and everything else is decided by reading the first 8KB, where a
NUL byte or more than a tenth of the bytes outside the printable range
means binary. Nothing to examine means refusal rather than a guess. The
browser viewer holds no extension list of its own; it reads this field,
and the twelve languages named on TKT-645 are highlighted in the page by
an embedded 4.5KB tokeniser, since the board loads nothing over the
network.
Server-side filtering is **Implemented.** on list and export:
`--where` is repeatable and clauses combine with AND. `FIELD=VALUE` is
string equality; `FIELD=` (empty value) matches a field that is empty or
unset by the same emptiness rule as omission; `FIELD!=VALUE` excludes;
`FIELD!=` means the field has a value; `FIELD~VALUE` matches an element
of an array field case-insensitively, and on a non-array field matches
nothing rather than erroring. Computed fields (`content_hash`,
`attachment_count`, `column`, `parent`) are filterable. An unknown field
or an operatorless clause exits 2 — a typo can never read as "none
exist". Composes with `--fields`, `--count`, and `--since`.
Batch reads are **Implemented.** on show: repeat `--ref` or pass
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
A first-class diff is **Implemented.** `tira.diff --since T`
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
Which columns work waits in is **Implemented.** `tira.column.update --queue`
lets a board say so. Until 2.50 waiting meant protected-and-not-an-ending, and
`protected` says *Tira owns this column* rather than what it means — so a board
queueing work in columns it created had every waiting card invisible, `tira.next`
answering empty and `priority-skipped` unable to fire at all. A board that marks
nothing keeps the old assumption exactly.

What to work next is **Implemented.** `tira.next` answers it: the cards
waiting in a protected column with a priority, most urgent first and then the
one that has waited longest, as `{next, then}` — the answer, and what it was
chosen over, so a caller can check it rather than take it. A board with nothing
waiting answers with `{next: null, then: []}` - the same shape, never a card
there is no reason to work. Until 3.48 the empty case answered with a bare
`[]`, a different type than the busy-board hash, so a caller doing
`result.next` crashed the moment the board went quiet - exactly when an
unattended scheduled caller runs with nobody watching. TKT-354.
A card carrying an unanswered question is never offered — a question is a hold
the board reads, naming the condition, released when the answer arrives. A
card whose `start_date` is in the future is never offered either, the other
machine-readable hold this board already validates — a maintenance window, an
embargo, a market close — released the moment the date passes; a past or
absent `start_date` is unchanged, and the card stays visible on the board and
in lists, held rather than hidden. Until 3.40 only the question was read.
TKT-309.
Discarded cards are never offered — `discard` is protected and is not an
ending, so it counted as waiting until 2.44.
The ordering belongs to `priority-skipped`, which has enforced it since it was
written and asks the same method, so **the rule and the command cannot disagree
about the same board**. Without it a caller read every card and sorted by hand.
An owner edit is **Implemented.** `card-changed-by-owner` says on the bridge
that somebody other than the agent changed a card, so an instruction left on a
card in the browser is not invisible to an agent working from the command line.
It compares rather than remembers — the newest change was somebody else's — so
it settles the moment the agent touches the card.
A terminal column is **Implemented.** `done` is where work ends unless the
board says otherwise — and marking a *different* column terminal is not saying
otherwise. Until 2.46 it switched the assumption off for every column at once,
turning every finished card into live work in one pass (**171 findings** on the
board that reported it). The flag has three values, so a board that means it can
still mark `done` as not terminal.
Column dwell is **Implemented.** `tira.stale` reports every card
with the column it is in now, when it entered that column, and how long it has
been there, across all three boards in one call. Entry time comes from the
card's most recent recorded column move. A card whose entry was never recorded
is listed with `basis: none` and **no duration** rather than a guessed one, and
`--older-than MINUTES` never returns it — an unmeasured card is unknown, not
old. An unreadable stamp yields `basis: unknown` instead of failing the board,
and a column renamed underneath a card does not disturb its measurement.
Column dwell history is **Implemented.** `tira.dwell.report` is
`tira.stale`'s historical sibling — median, p90, max and count seconds per
column, per type, computed from every card's own recorded column moves,
rather than how long the card sitting there now has been there.
`--type TYPE` scopes to one board; with none, all three. Only completed
passes count: a card's current column is not one and never appears in its
own report until it moves again, and a column nothing has completed a
pass through yet is absent rather than shown at zero. Every
`card-duration` threshold on a board was otherwise a guess, picked by hand
and never checked against what the board itself records — this turns it
into a reading. TKT-366.

A column that holds containers needs its own reading, separately from the
columns that hold work items. A SOW or an epic legitimately sits in a working
column for as long as its children take, so a threshold set for tickets
reports it forever and nothing an agent does settles it — the only settling
move is finishing every child. On this board, `in-progress` holds the SOW and
the epic and no tickets at all: median dwell 4h31m, p90 57h09m, max 5d08h,
against a policy of 8h. The result was two CRITICAL reminders that fired 63
and 69 times over three days with no action available, which is worse than
silence — a signal nobody can act on teaches the reader to skip the channel
it arrives on. Re-thresholded from the p90 to 58h and both settled on the
first pass. Re-thresholded rather than exempted, so a genuinely stuck epic is
still caught. When diagnosing one of these, note the distinction from
`card-still`: `card-duration` measures time in a column, so folding a child's
work back into its parent — a comment, key details, a scope change — never
settles it, and only moving the card does. TKT-573.
Wrapping wide boards is **Implemented.** each column now owns
its own heading rather than sitting in a table row, so **Fit all wraps
the columns onto as many rows as it takes** at a readable width instead
of squeezing every one of them onto a single line. Standard is
unchanged: one row, full-width columns, scrolling sideways. Drag and
drop, paging, filtering, counts and the column editor are unaffected.

Nesting refusal is **Implemented.** creating a project in a
directory that sits inside an existing project is refused, naming the
project that is in the way and where it is. Project discovery walks
upward, so a buried project means later commands may address either
one, and nothing would ever say so. Pass `--nested` to do it
deliberately.

Serialised mutations are **Implemented.** comments,
checklists, gates, evidence and attachment references used to read a
record, change it and write it back with no lock held, so two changes
made at the same moment could silently lose one — while this manual
already promised every mutation was serialised. The project lock is now
reentrant, and each of those methods holds it across the read as well
as the write. The guarantee stated here is now true rather than
aspirational.

The column editor is **Implemented.** each board control has a
Columns button opening a modal that shows that board's own columns —
drag a row by its grip to reorder, edit its label, set how many minutes
a card may sit there, turn its eye off to stop it being chased, remove
it, or add a new one before Discard. Saving sends the whole layout at
once. Reordering uses pointer events like the rest of the board, so the
grip works on a phone. Each row also shows its chain (`--next`) as one
checkbox per other column, so checking more than one to declare a fork
is a visible, tappable action rather than something hidden behind a
native multi-select — TKT-468 shipped that as a `<select multiple>`,
which on a phone renders as little more than a single value with a
"…" affordance, no visible way to see or make a fork; TKT-472 replaced
it. Its required-action template shows one row per item — a text input
holding that item plus a cross to remove it — and a blank trailing row
with a checkmark that adds a new item and leaves a fresh blank row
behind it, instead of TKT-468's one big multi-line text box, which
crammed every item onto its own line in a single field ("if I have 10,
that's 10 lines" — owner, live). Both fields are already round-tripped
by `/columns/apply` (above). A column with neither declared shows both
empty rather than forcing a value in on save. Emptying a column's
existing chain or required-action list down to nothing sends an
explicit empty list back, not an omitted field — until TKT-481, the
payload dropped the key entirely when a list was cleared, which reads
as "leave whatever was there" server-side, so a removed item came back
after the very next page load; a column that never had a value still
omits the key, which is the only case that means "nothing to save."
Owner's live question,
2026-08-22: "Where to view and edit the column chain? Also, where to
view and edit the required items of each column?" — nowhere, until
TKT-468, and not usably until TKT-472. Each required-action row also
carries its own drag handle, matching the column row's own grip, so
existing items can be reordered the same way columns themselves are —
dragging never crosses between two different columns' own lists, and
the blank add-row always stays last. TKT-476.

Choosing where new cards start is **Implemented,** from the same
dialog. Each column row carries an Entry checkbox — "New cards can
start here" — reflecting whatever `tira.column.roles --role entry=X`
already declared, and more than one may be checked at once: "It can be
multiple entries" (owner, live). Saving sends the whole checked set to
`column_roles_set` in one call, replacing the declared entry columns
exactly the way repeating `--role entry=X` on the command line already
does — not an add-only merge, so unchecking one and saving again
actually removes it rather than only ever growing the set. A save that
never touches the checkboxes at all — every other layout edit this
dialog already makes — sends no `entry` field and leaves the declared
entry columns untouched. TKT-494, building on the engine support
TKT-496 shipped for it (`entry` may now name more than one column).

Whole-layout column edits are **Implemented.**
`tira.column.apply` takes the column list a board should have — order,
labels, per-column thresholds and watched flags — and works out the
difference itself, adding what is missing and removing what is gone.
Cards in a removed column land in Discard exactly as removing one at a
time puts them there. A protected column left out is refused and
nothing changes. The call reports what it added, removed and
reordered, because removals happen one at a time and a run that fails
partway will already have made some of them.

The police policy dialog is **Implemented.** each board control
also has a Policies button, separate from Columns, opening a modal for
the board-wide police policy engine — the 36 rules police itself
watches (`card-duration`, `wip-limit`, `conversation-not-folded`, and
the rest), which was CLI-only until TKT-493 and is a different thing
entirely from a column's own required-action template above. The
modal shows the same three-way split `tira.policy.review` already
returns — declared, declined, undeclared — with a form to declare a
new policy, edit or remove a declared one, or decline a rule with a
reason. The rule picker's parameter fields (`--enter`, `--column`,
`--age`, `--max`, and the rest of `tira.policy.add`'s own options,
plus the `--type`/`--on-column`/`--ref` scope) show or hide themselves
per selected rule from a new engine method, `policy_rule_specs`, which
returns the exact needs/forbids `policy_add` already validates
against — so the form cannot drift from what the CLI actually accepts
without both changing together. Editing a declared policy removes and
re-declares it under the hood, since `policy_add` itself refuses to
update a declaration in place (TKT-339's rule against silently
replacing a stricter policy with a looser one); the modal keeps that
guarantee rather than working around it. Requested directly: "create a
new modal on the html dashboard, the user can view and edit and add
the policies not just column policies." TKT-493.

A declared/declined/undeclared policy row's text renders in its own span (min-width:0, overflow-wrap:anywhere) rather than as a bare text node beside Edit/Remove - a comma-joined value with no spaces (what --require/--pattern produce) is one long unbreakable run, and without that span it overflowed the row on a narrow viewport, pushing Edit/Remove out of reach. A plain long sentence wrapped correctly on its own; only an unbroken run reproduced it. Michael, live, with screenshots: "all these edit button no one works." TKT-501.

A declared row's id, rule, and action render as a bold header line, with every parameter listed below as a labeled "name: value" pair on its own secondary line, rather than packed into one dense "POL-002 · rule → action (param=val, param=val)" parenthetical. Michael, live: "can you make each of them more easy to understand and read." One line per parameter was considered and rejected - it would roughly triple the list's scroll length on a board carrying 60+ declared policies. TKT-502.

The message field carries a (?) badge that opens a popover listing every `{token}` it can substitute and what each means - ref, rule, policy, detail, column, title, assignee, reporter, age, max, matching docs/POLICIES.md's own table. Michael, live: "how does the user know which {token} is avaliable to use in the messsage? and can the same set of {token} be used in other field?" Answered directly and in the UI: tokens are message-only, so no other field carries the badge. `GET /policies` now sends the token list and its descriptions (`Tira::policy_message_fields`/`policy_message_field_help`) rather than the dialog hardcoding a second copy that could drift. TKT-519.

Declining a rule for one card is **Implemented.** `tira.policy.decline`
takes an optional `--ref CARD`, scoping the decision to one card
instead of the whole board — a different question than declining
board-wide ("should this rule exist at all"), so it does not conflict
with the rule staying declared for every other card. This is the
answer to a card whose work genuinely breaks a rule's assumption with
no other honest way to clear it: `card-sandbox-missing` assumes one
project maps to one repository, and "both halves are correct about
the DECLARED repo and wrong about the work" when a card's work
legitimately lives in a second one — the only prior options were
declining the whole rule (losing the check for every other card) or a
permanent violation nobody could act on, and this project's own
standing instruction is that every outstanding violation is followed
up until cleared. Requires a reason exactly like board-wide decline,
reads back through `tira.policy.declined --ref CARD`, and is reusable
by any rule. TKT-303.

`checklist-idle`'s message is **Fixed.** on a checklist that is
100% complete it now says "checklist complete since TIMESTAMP - move
the card, there is nothing left to tick" instead of "no checklist
movement since TIMESTAMP" — the old wording was true and useless
there, naming the one action that cannot be taken (there is no
unticked item) and never the one that works. "ZEPG-6 has a checklist
of ELEVEN ITEMS, ALL DONE... There is nothing left to tick - not
'nothing worth ticking', literally nothing." The rule's own
behaviour — when it fires, and that moving the card settles it — is
unchanged; a checklist with anything still unticked keeps the
existing wording. TKT-357.

The reminder job is **Implemented.** `tira.collector.show`
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

Onboarding registers the job itself ****: filling in the
reminder details now creates the background job as well as recording
them, and reports the name it will really answer to along with the
command that starts it. It asks for a number of minutes once — how long
a card may sit still — and the heartbeat follows that answer, since
looking more often than the shortest staleness window finds nothing
new; `--heartbeat` still tunes it. The directory question offers
whatever project is already resolvable rather than making you type it.

Reminder settings are **Implemented.** the project records how
long a card may sit still by default, which coding agent to remind, its
session, how often to check, and the name of the job that does it.
`tira.onboard` collects them and can be **run again on an existing
project** with every answer pre-filled, so an older project gains them
by pressing enter through it; naming a different directory reloads that
project's own settings rather than carrying the first one's across. With
no coding agent installed those questions never appear. An empty value
clears a setting, and no heartbeat means no reminders at all.

Escalating reminders are **Implemented.** one message covers
every card that is past its column's limit, and its tone rises with how
often those cards have already been chased where they stand — plain,
tense, angry, shouting, then a final tone that keeps counting rather
than running out of words, across ten levels. The most-chased card sets the tone for the
message, so a long-stuck card is never softened by newer company, while
every line still states its own count, its column and how long it has
sat there. Nothing stale composes nothing at all.
`tira.notify.compose` returns the level, the tone, the text and the
cards it covers in one call.

Unattended failures are **Implemented.** background work has
nobody in the room to tell when it breaks, so a failure it cannot
resolve is recorded once and then shown underneath the output of
whatever command anybody runs next, naming the exact command that
clears it. The same failure recurring leaves the standing warning
alone rather than piling up copies, and it keeps appearing until it is
cleared. Human output carries it on standard output; every machine
format carries it on standard error so the payload stays parseable.

Notification history is **Implemented.** every reminder that is
actually delivered writes one row recording the card, the column it was
sitting in, and the time. How urgent a reminder is comes from counting
those rows, so **moving a card resets its escalation** — later rows
carry a different column name and the count starts again. The card
itself is never rewritten, so reminders never touch its stamp, its hash
or its history. `tira.stale --stale --with-level` reports each stale
card with the level it has already reached, which is enough to compose
a whole reminder in one call. Reading history creates nothing.

Staleness limits are **Implemented.** every column carries its own
limit in minutes and its own watched flag, both set by `tira.column.update` and
reported by `tira.column.list`. A column is watched unless switched off, so
existing boards need no configuring. `tira.stale --stale` judges each card by
its own column's limit, falls back to the project default set with
`tira.project.update --notify-after`, skips unwatched columns however old their
cards are, and — with no limit anywhere — reports nothing.
Indexed log reads are **Implemented.** on the gate and evidence
lists, whose entries are append-only and stored newest-last: `--last N`
is the recent history (`--last 1` answers "what did it last pass?" at
constant cost), `--first N` the origins, a zero window or `--count`
returns `{"count": N}`, and `--id` returns one entry with a loud miss.
`--meta-only` keeps ids, results, uris, authors, and stamps while
replacing the unbounded text with `details_length`/`summary_length` and
`annotation_count`. `--where` filters entries (`result=fail` is the one
that matters) with the same loud unknown-field rule. Annotations always
ride with their parent entry; reads never mutate the logs.
Per-field history is **Implemented.** Every record write is
journaled field by field, whichever command performed it: creation seeds
one entry per set field so a field's timeline starts at its birth value,
edits record `before` and `after`, moves record the column change, and
structural fields (comments, attachments, linkage and the like) record
that they changed without inlining their whole value. Entries carry the
change time, the record ref, the operation, and who made the change —
taken from the author the command was given, or from the identity said
once in the environment rather than on every command, so anything running
unattended is attributable as long as it says who it is. A name the board
does not know is not written down, and neither is a guess: an
unattributed change is recorded as unattributed, because a log that
accepts any name reads as accounted for. A rolled-back operation records nothing, so history never
claims a change that did not happen. `tira.history.list` reads it with
the same window, `--since`, `--where`, `--count`, and truncation
semantics as the other logs; `--field` narrows to one field's timeline
and an unknown name exits 2. History lives outside the boards, so it
never alters a record, a `content_hash`, or a board read, and reading it
never writes.
Compact JSON is **Implemented.** `-o json` emits canonical
one-line JSON with stable key order and unescaped UTF-8 — measurably
smaller, identical information — while `-o json-pretty` keeps the
indented shape. Formats are presentation only, and errors always go to
stderr in the selected structured format, so stdout can never carry a
corrupted payload.
An opt-in read-through cache is **Implemented.** and disabled by
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

All are **Implemented.**, with immediate-parent projection updated by
```text
tira.hierarchy.link --parent REF --child REF [--priority N] [--assignee ID] [-o FORMAT]
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

All are **Implemented.**, with singular assignment semantics updated
by ```text
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

All are **Implemented.**

```text
tira.attachment.add --ref REF --file PATH [--comment ID] [-o FORMAT]
tira.attachment.list [--ref REF] [--include-deleted] [--meta-only] [--fields LIST] [--since TIMESTAMP] [--count] [-o FORMAT]
tira.attachment.get --sha SHA256 [--extension EXT]
tira.attachment.remove --sha SHA256 [--extension EXT] [-o FORMAT]
tira.attachment.discard --ref REF --sha SHA256 [--extension EXT] [--comment ID] [--author NAME] [-o FORMAT]
tira.attachment.detach --ref REF --sha SHA256 [--extension EXT] [--comment ID] [-o FORMAT]
```

Add hashes bytes, stores `sha256.extension`, and records the original filename.
Many refs may share content. Remove deletes content, appends to
`delete.log.yml`, and preserves JSON refs. Re-adding identical bytes restores
the object after a remove. Discard is not the same thing: it sets a card-scoped
stamp that outlives the bytes, so re-adding the identical content to that card
is refused rather than reported as done — attach different content, or say on
the card that it stands. A project read the restore sentence as general, lost
ten screenshots to adds that returned success and created nothing, and could
only repair them by re-rendering until the hash moved. Deleted get emits `Deleted at <timestamp>` raw and exits `1`.
Managed storage paths are never returned; redirect raw bytes to a destination.
Attachment deduplication is scoped to the target record or comment list. Add
returns `original_filename` from the reference actually retained,
`supplied_filename` from the current request, and Boolean `deduped`. Thus a
same-target duplicate with a different name reports the retained first name,
the rejected supplied name, and `deduped: true`. A different record may retain
another filename for the same SHA. These response fields do not alter stored
references.

### Checklists, evidence, gates, migration, search, and dashboard

All are **Implemented.**

```text
tira.checklist.list --ref REF [-o FORMAT]
tira.checklist.add --ref REF --item TEXT --status TEXT [-o FORMAT]
tira.checklist.update --ref REF --id CHK-NNN [--item TEXT] [--status TEXT] [--command TEXT ... [--proof TEXT ...]] [-o FORMAT]
tira.required-action.list --ref REF [--blocking] [-o FORMAT]
tira.required-action.add --ref REF --item TEXT --status TEXT [--column SLUG] [-o FORMAT]
tira.required-action.update --ref REF --id REQ-NNN [--item TEXT] [--status TEXT] [--command TEXT ... [--proof TEXT ...]] [--repeated-reason TEXT] [--repeated-confirm CODE] [-o FORMAT]
tira.question.ask --ref REF --text TEXT [--reason TEXT] [--option TEXT ...] [--voice FILE] [--author ID] [-o FORMAT]
tira.question.answer --ref REF --id Q-NNN --text TEXT [--file FILE] [--author ID] [-o FORMAT]
tira.question.mark --ref REF --id Q-NNN --mark ok|not-ok [-o FORMAT]
tira.evidence.list --ref REF [--last N|--first N] [--id EVD-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]
tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [-o FORMAT]
tira.evidence.annotate --ref REF --id EVD-NNN --note TEXT [--author ID] [-o FORMAT]
tira.gate.list --ref REF [--last N|--first N] [--id GATE-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]
tira.history.list --ref REF [--field NAME] [--last N|--first N] [--since TIMESTAMP] [--where CLAUSE ...] [--count] [--truncate N|--full] [-o FORMAT]
tira.gate.add --ref REF --gate TEXT --result pass|fail|blocked --details TEXT [--author ID] [-o FORMAT]
tira.gate.annotate --ref REF --id GATE-NNN --note TEXT [--author ID] [-o FORMAT]
tira.release.record --ref REF --gate TEXT --result pass|fail|blocked --details TEXT --evidence TEXT --fix-version VERSION [-o FORMAT]
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
tira.column.update --type TYPE --name SLUG [--notify-after MINUTES] [--watch|--no-watch] [--terminal|--no-terminal] [--queue|--no-queue] [--required-action TEXT ...] [--entry-required-action TEXT ...] [--next SLUG ...] [-o FORMAT]
tira.column.endings [--type TYPE] [-o FORMAT]
tira.<type>.list [--full] [--column SLUG] [--assignee ID] [--parent REF] [--text QUERY] [-o FORMAT]
tira.import --file FILE [--dry-run] [-o FORMAT]
tira.changelog.check [--file FILE] [-o FORMAT]
tira.search --text QUERY [--field FIELD ...] [--type TYPE] [--column SLUG] [--assignee ID] [--count] [--refs-only] [-o FORMAT]
tira.search.index [-o FORMAT]
tira.replace --pattern REGEX --with TEXT [--field FIELD ...] [--type TYPE] [--dry-run] [-o FORMAT]
tira.dashboard [--type TYPE|all] [--include-discard] [--title] [--with-questions] [--no-session-expire] [--ssl] [-o DASHBOARD_FORMAT]
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

`tira.import` and `tira.replace` are the only two commands that read
`--dry-run`, and every other command now refuses it by name rather than
accepting it and writing anyway. One global option spec parses every flag for
every command, so `--dry-run` was accepted everywhere and honoured in two
places; `tira.ticket.create --dry-run` created the card and printed it back as
though nothing unusual had been asked. It cost eight junk cards on this board -
TKT-617 through TKT-624, every one discarded afterwards - written by probes that
all carried the flag believing it prevented a write. The refusal names the command, says the change is made
rather than previewed, and points at the two commands that do honour it.

It is written as an allow-list naming `import` and `replace`, not as a list of
the commands that swallowed the flag, so a verb nobody thought to test is
refused too - `tira.comment.add --dry-run` is refused by the same line that
refuses `tira.ticket.create --dry-run`. That shape is available because
`--dry-run` has exactly two readers and they can be named; it is not a general
per-command option list, which the neighbouring `%MISLEADING_OPTIONS` guard
explains it deliberately is not, because deriving one would refuse things that
work today. TKT-625.

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
switches to the created card. **Implemented.**

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
comments, edits any comment in place, and deletes a comment permanently;
every successful change re-reads the record so the dialog always shows
filesystem truth. A comment carries no author picker - it is always
attributed to whoever is signed in, with no choice offered, unlike every
other mutation the board makes (assignee, move, create), where an explicit
author still wins over the session. A comment is personal in a way those are
not: his own words, "if I make a mistake and pick someone else, it becomes
their comment - that's not acceptable." TKT-458.
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
(bold, italic, inline code, bullet lists) that never injects raw HTML.

Since 4.66 the push gate does not decide for itself whether a card's checklist
is finished - it reads the engine's `checklist_done`/`checklist_total`. It
still picks out which individual items to name in its message, and does that
case-insensitively so the two agree. A card
whose items were ticked as `Done` rather than `done` used to be complete to the
card and incomplete to the gate, which refused the push of 4.57, 4.58 and 4.59
over items that were all marked done. The two places in `tools/card-holes` that
compared statuses failed in opposite directions: one refused a good push, and
the other - the check for a finished checklist under an unfinished column - was
silently blind to `Done` and never fired. The unfinished-item message also says
how many items it did not name, where before it listed three of four and marked
the gap in no way at all. TKT-671.

Since 4.62 the push gate does not run the test suite. It ran the full suite
with coverage in a container before every push - 138 of the hook's 266
lines and roughly twenty minutes - over a tree the `verify` column had already
proved. Measured on the release of 4.60 and 4.61: the suite ran at 08:41 in
verify and again at 11:47 in the hook, and that push took 21 minutes 19 seconds.
The gate-cache built to prevent exactly that double-run (TKT-351) could not,
because it keys on the tree `HEAD` carries and the verify run happens before the
documentation and version commits exist - 93 records and not one matching. The
owner's rule is about where readiness is decided rather than about speed:
*"anything landed on push column is ready to pushed"*. A card reaches that column
because verify proved it and recorded the evidence on the card, so re-deriving
it at push time was the hook contradicting the board. Seven checks stay and
their ORDER stays with them - the version against what is shipping, the board
backup, live-card completeness and `tools/card-holes` before; `tools/docs-match-code`,
`tools/docs-examples-run` and `tools/browser-tests` after, last on purpose,
because documentation edited after a gate has shipped a broken build here twice.
That ordering is what still defends the property the suite step was really for,
which was never "the tests pass" but "nothing was edited between the proof and
the push". `tools/gate-run` is unchanged and still proves a committed tree by
hand; nothing reads its cache records automatically any more. A *new, separate* step reading `fix_version` and `evidence`
off each card was proposed and declined - *"only trim away the full test run.
keep other checks"* - and is recorded in the card's excluded scope so it is not
reintroduced. It would have been redundant as well as unwanted: `tools/card-holes`,
which stays, already refuses a card carrying no recorded gate, no evidence or no
fix version. TKT-680.

Since 4.61 the card dialog's three text editors share their behaviour rather
than reimplementing it. All three grow through one handler and all three build
their formatting bar from one builder - the comment composer's own bar, which is
now the shared one rather than a fourth copy. Image paste is on the long fields
only, which is where it was asked for. A long field -
description, problem or feature, solution needed - edits full width, grows with
its content to a 420px ceiling and then scrolls, carries the same formatting bar
the comment composer has, and takes a pasted image: the file goes to the record's
attachments and an `[image: name]` marker lands at the caret. A long field is
also DISPLAYED formatted, through the same renderer comments use, while what is
stored stays markdown. The new-comment textarea and the edit-comment editor grow
the same way, and the edit-comment editor gained the bar the composer beside it
always had.

The ceiling is the point rather than an implementation detail. Two grow handlers
already existed - the tasklist card input grows without limit, the question
answer box stops at 420 - and a description runs to paragraphs, so unbounded
growth pushes the dialog's own Save and Cancel off the screen. The answer box's
ceiling is the one worth copying. Reported by the owner, who called the old
fixed five-row box "un-usable" at roughly half the modal's width; measured at
44% before and 100% of its container after. TKT-586. Dialog deletion detaches the reference; the stored file is physically
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

## 139 use cases

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

A board can declare which column is the valid starting point for new cards - `d2 tira.column.roles --type ticket --role entry=planning` - reusing the existing column-roles vocabulary rather than a new setting. Once declared, `--column` other than the entry column refuses (naming the entry column and a command to run instead), and omitting `--column` lands the card there instead of the fixed `backlog` default. A board that has named no entry role is unaffected. This closes the bypass TKT-426's chain check leaves open: a card created directly into `implement` or `done` never needs the move the chain check would otherwise refuse. Checked only on the CLI/agent command path - the browser dashboard's own create flow, and any direct engine call, is unrestricted. TKT-428. `--role entry=X` may be repeated to declare more than one entry column - a board can start new cards in more than one place; each repetition accumulates rather than the last one silently winning. With more than one declared, omitting `--column` lands the card in the first one declared, and `--column` naming any of the declared entries succeeds. Every other role stays single-valued, and a board with zero or one entry column is completely unaffected. TKT-496.

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

Creation seeds the same column timeline, not just a card's fields: a card created directly into a column - the board's default entry point, or an explicit `--column` - gets one history entry the moment it exists, tagged `op: create` rather than `op: move` (`before: null`, `after:` the starting column), so it stays distinguishable from a real move made afterward. Without this, a card created straight into a non-default column had no history entry recording it ever arrived there, and any rule reading history to see which columns a card had visited (`column-skipped`) read it as having arrived from nowhere - flagging a card that never actually skipped anything. TKT-433.

`column-skipped`'s only remedy on a finished card used to be walking it backward and forward through the column it missed, which writes moves into its history that never happened - the same falsified-history shape 2.35 already fixed for `orphan-card`, unfixed here. Any comment on the card now settles the finding instead, the same shape `discard-unexplained` already has: the comment is the acknowledgement, and nothing is rewritten. A card with the same shortcut and no comment is still reported, exactly as before. TKT-284.

A move that skips ahead of the board's declared column order refuses - `d2 tira.ticket.move --ref TKT-001 --column done` from `backlog` on a board declaring `backlog, planning, doc, code, done` exits non-zero naming the correct next column (`planning`) and a command to run instead. Backward moves (redoing work after a step back) and moves to `discard` are always exempt. This check runs only on the CLI/agent command path - a move made from the browser dashboard is unrestricted, since a human there is not an agent skipping a gate. TKT-426.

`record_move` itself - not only the CLI dispatch layer - now refuses a caller that supplies no author at all, or one naming somebody the project has never registered: found investigating a production incident where two moves with no author recorded skipped nine columns with neither the chain check nor the required-action check ever running, because a caller reaching the engine some other way than the CLI never had either check to skip. The CLI already resolved `--author` or the `TIRA_AUTHOR` environment variable before this; what changes is that reaching `record_move` with neither is now refused with a corrective message (`--author`) rather than silently recorded against nobody. A signed-in browser move is unaffected - the dashboard already threads the signed-in person through as author on every mutating route. `record_discard` and `record_restore` inherit the same refusal, since both call `record_move` underneath. Scoped to `record_move` alone at the time; other mutating commands followed later. TKT-457.

`record_update`, `comment_update`, `checklist_add`/`checklist_update`, `required_item_add`/`required_item_update`, `gate_add`, `evidence_add` (and so `release_record`, `assignment_add`/`assignment_set`/`assignment_remove`, and `record_clone`, all built on the above) now carry the same refusal - none of them required an author before, so a caller reaching any of them with neither `--author` nor `TIRA_AUTHOR` wrote a journal or history entry attributed to nobody. Caught live: an entire session's worth of `ticket.update`/`required-action.update`/`checklist.update`/`release.record` calls landed anonymous, because `--author` was easy to forget on those four command families and nothing refused it. The same sweep found the browser dashboard's `update`, `comment_update`, `checklist_add`, `checklist_update`, and `required_action_update` providers never forwarded the signed-in person to the engine at all - a real gap, not merely a test gap, since editing a comment, a checklist item, or a required action from the actual dashboard would have failed outright once the engine-level refusal shipped. Fixed alongside: each provider now passes the client-sent `author` through when the caller deliberately named one, falling back to the signed-in session otherwise - except `comment_add`/`comment_update`, where the session always wins over a client-sent author (TKT-458's "personal" exemption). TKT-466.

A skip is allowed anyway when every column being skipped already carries a passing gate named exactly like it - `d2 tira.gate.add --ref TKT-001 --gate planning --result pass --details "..."` followed by the same for `doc`, then `d2 tira.ticket.move --ref TKT-001 --column code` succeeds directly from `backlog`. No new mapping from a column to a gate exists or is needed - the column's own name is the gate's name, so a card whose intermediate stages already passed does not need a mechanical walk through columns it never substantively occupied. A missing gate, a wrongly-named one, or one recorded `fail` still refuses. TKT-429.

A column is identified with `--name`, never `--column` - `--column` is the reflex flag on `record.move`, `record.list`, `notify.record` and `search`, and `column.add`/`column.update`/`column.rename`/`column.remove` refuse it with a usage error naming `--name` rather than silently accepting and ignoring it. Until 3.39 it was accepted and did nothing, and with `--name` absent entirely the resulting `Column '' not found` read as a claim about the board rather than the actual mistake, a mistyped flag. TKT-305.

A column can declare more than one valid next column, for a chain with a genuine fork - work that ends there and work that continues down a different path: `d2 tira.column.update --type ticket --name e2e-testing --next done --next deploying` (repeatable, replaces the column's whole set each call). A forward move from that column succeeds to either one; a third destination still refuses, naming both valid options. A column with no explicit `--next` set keeps deriving its single next column from the board's declared order, exactly as before - every existing linear board is unaffected. Backward moves stay unconditional regardless. TKT-430.

`--next` refuses a column name that does not exist, rather than accepting it silently. And removing a column - via `tira.column.remove` directly, or via the Columns dialog's Save button (`column_apply`) - now strips that column's name out of every OTHER column's stored `next` too, and `column_apply` strips any `next` entry naming a column absent from the layout being saved regardless of what the caller sent, since the dialog's own Next checkboxes are a snapshot taken when it opened and are not refreshed if another row removes the column they point at in the same editing session. Before this, a removed column stayed a dangling fork target: the chain check kept refusing any forward move that wasn't in the now-partly-nonexistent fork list, and its own suggested remedy ("move there first") failed too, since the named column no longer existed to move to - every card in the affected column had no valid forward move at all. Found by the hourly-hunt agent's first real run. TKT-475.

A column can also name what must be done before a card leaves it: `d2 tira.column.update --type ticket --name planning --required-action "left a note"` (repeatable, replaces the column's whole template each call). Required items live on their own list, `required_items` - never a card's `checklist`, which stays purely manual regardless of anything below. Moving a card into that column adds its required-action items to that list as `pending`, tagged with the column, skipping any it already carries for that column so re-entering never duplicates. A forward departure refuses while any of the current column's required items are still unmarked, naming which ones and the `tira.required-action.update` command to mark them done. A backward move stays unconditional regardless - the unmet item may be exactly what the card is retreating to fix - but resets to `pending` every required item tagged with a column from the new position through the old one, inclusive on both ends, since redoing that work means satisfying the check again on the way back through - including the column landed on itself, not only the ones passed through to get there. Until 3.13 the destination was excluded, so an item already done there stayed done even though the card was landing back on that exact column; the owner asked for it included, moving 4 to 2 resets 4, 3 AND 2. TKT-455. A backward move-in also populates the destination column's own template, exactly as a forward move-in does, for any item the card has no snapshot of yet - until 3.22 population only ever happened on the forward branch, so a card that first crossed a column before that column had a template got nothing on a later backward move into it; only reset ran. `discard` is exempt on both sides. The move-out *refusal* stays CLI/agent-only, same as the chain check above - a human on the dashboard is not an agent skipping a gate. The population and reset are not enforcement, though, and until 3.10 the dashboard's own move UI skipped them entirely: a card dragged into a column with required actions never received its template, and dragging one backward left a required item marked `done` exactly as it was. Both now happen on a browser move the same as a CLI/agent one - only the refusal stays CLI-only. TKT-452. "Unmarked" and the reset both read a required item's status against "done" case-insensitively, so `--status Done` or `--status DONE` satisfies the move-out check and resets on a backward move exactly like `--status done`; only genuinely unfinished values, such as `todo`, still refuse. TKT-427, TKT-434, TKT-445.

A move out is also gated on questions whose answers nobody has judged. Reading an answer is automatic - `question_list` stamps `read_at` on the way past, and the code says so: "Reading is what marks an answer read - the agent does nothing extra". Judging is a deliberate `tira.question.mark` that nothing asked for until `answer-unjudged` fired hours later, by which time the card was finished and the answer had already been acted on. So the prompt now lands at the moment it belongs to: a card does not leave the column an answer was given in while that answer carries no mark, and the refusal names the question and the command that settles it. The check reads the question's own `mark` rather than raising a required-action item to stand in for it - an item is marked done with a command and a proof like any other, so it could be satisfied in the same sweep as everything else without anybody forming a view, which is the acknowledgement-clicked-through this exists to prevent. Four things stay ungated deliberately: an unanswered question, because waiting on the owner is its normal state; a discarded one, which nobody owes a judgement on; an answer marked `not-ok`, because the gate wants an assessment rather than agreement; and reading, because a check consulting `read_at` would release itself on the way past. Forward moves only - a backward move stays unconditional for the same reason it does for required actions, and an unjudged answer is a particularly good reason to retreat, since the person who would judge it may be why. `answer-unjudged` is unchanged and remains the backstop for whatever escapes the gate. TKT-584.

A column can also say what a card must ALREADY have done before it may be worked there. `tira.column.update --type TYPE --name SLUG --entry-required-action TEXT` declares that list, separately from the `--required-action` list that gates the way OUT, and replacing the whole entry list per call the same way. A move INTO the column is refused while any of its entry items are unmarked, and the card stays exactly where it was rather than landing anywhere new. The worked case is work belonging to neither column: between `backlog` and `tests-red`, "verify all details in the card" is not backlog's business and cannot be tests-red's exit action, because the card is not allowed in yet. TKT-591. In the browser column editor since 4.71 the entry list renders ABOVE the exit list - the order a card meets them - and both name themselves, `Entry required actions` and `Exit required actions`, each add field naming the list it adds to. The two lists have always been separate on the column and separate on the CLI; until 4.71 the editor was the one place that did not say so. TKT-651.

The list is put on the card BEFORE the refusal, which is what makes an entry gate satisfiable at all: the work happens outside the column that demands it, so items appearing only once the card was inside would leave nothing to mark and no way in. The first attempt therefore brings the list and refuses, naming each item with its id and a command that runs; the second, once they carry evidence, goes through. Forward moves only - a card sent back is not asked to qualify for where it is retreating to, since the unmet thing may be what it is going back to fix.

Entry items are required items, so everything that already applies to marking one done applies unchanged: a `--command`/`--proof` pair, the duplicate-proof refusal and its two-step confirmation, and a card-specific exemption (`--exempt-required`) releasing this card from an item that does not apply to it. There is one evidence mechanism, not two. The browser dashboard's column editor declares entry actions beside exit ones; dragging a card is still not refused by them, because a human on the dashboard is not an agent skipping a gate (TKT-426), but the dragged card now arrives carrying what that column asks rather than only its exit items.

A column's required action can ask for a code review, and one asking for it must say how to run it. The verify column's does: the review goes through `tools/review-worktree`, which runs the reviewing agent in a throwaway clone of the repository carrying the uncommitted work - tracked changes, staged state and untracked files - so it reads and runs everything, while an ordinary relative write or git command reaches the throwaway rather than the checkout. It is not a sandbox and does not claim to be: what it takes away is the checkout as the reviewer's working directory, and the shared git metadata a linked worktree would have left reachable. Pointing a reviewer at the checkout directly once cost two paragraphs of documentation, reverted by a `git checkout --` while they were being written, and the loss was silent because `git status` afterwards showed the files unmodified. The instruction lives in the required action's own text rather than in a document somebody has to already know about, which is the same reason a usage line names the flags it demands. TKT-626.

TKT-681: a card created straight into a column THROUGH THE CLI now receives
that column's entry required actions too, and is never refused for them. The
browser's own create flow calls `create_record` directly rather than going
through the command, so it seeds neither template and is unchanged by this -
excluded deliberately rather than overlooked. The create path
seeded only the exit template - it mirrored `_populate_column_required_actions`,
which is the exit seeder, while entry actions on a move come from
`_populate_entry_required_actions`, which creation never called - so a card
created into a gated column was born past the gate: no items recorded, nothing
checking it, skipped rather than failed. It calls the same function now.
Creation is not blocked, and cannot be: a required action's proof is a command
and its output, and before the card exists there is nothing to run a command
against. The items are recorded pending and the caller is told on STDERR,
naming entry and exit separately - owed now, against owed before it leaves the
column - and ending with the command to work them. That warning also covers the
exit items, which have been seeded on create since TKT-439 and printed by
nothing, so an agent met them only at a refused move.

TKT-657: the four places in `lib/Tira/CLI.pm` that ask whether a required item
is finished now ask one named predicate, `_item_is_done`. Three of them
lowercased the status first and `_remind_one_at_a_time` did not, so an item
marked `Done` was finished to every gate and outstanding to the move-in
reminder, which announced already-completed items as work to do. Nothing is
normalised on write - `Done` stays `Done`, which TKT-434 decided - and the
predicate is the one place that reads it. It replaces the one-word fix because
this was the third instance of the same fault in a day (the dashboard, and
`tools/card-holes` twice), and a predicate can be grepped for where four inline
comparisons cannot.

None of the four move guards - chain order, exit required actions, unjudged answers, and entry required actions - can be evaded by omitting the board type. `column_list` needs a concrete type to say which columns exist, while `record_show` and `record_move` resolve a card by ref alone, so a guard that asked for columns with the caller's arguments got nothing back and returned "nothing to refuse" - failing silent and open rather than closed. Reproduced on a copy of a real board: a card walked from backlog to in-review through nine gated columns with all 75 of its required actions pending. The browser move provider had already solved this for its own bookkeeping under the principle recorded there - "a caller is never required to say what the engine can already tell for itself" (TKT-532) - and the recovery is now a shared helper with five call sites - all four move guards and the post-move required-action bookkeeping. It said three guards and four sites until TKT-662, written when there were three: TKT-591 added the entry guard afterwards and the count was never revisited, the same drift that left CLI.pm's POD documenting one guard of four. The browser move provider keeps its own recovery, which is where the principle came from and which predates this. The recovered type is written back into the caller's own arguments, not kept to the lookup: the chain guard's refusal ends by naming the move to make instead, and that line is formatted from those arguments, so recovering the type for the lookup alone left the gate correctly closed and the caller told to run a move command with an empty type in it - `tira` then two dots then `move` - which is not a command at all. It matters to two refusals in four - the chain guard names the move to make, and the entry guard ends with `d2 tira.column.update --type TYPE ...`, so both format the recovered type into their own advice. The required-action and unjudged-answer refusals name a command of their own and never print it. This said 'one refusal in three' until TKT-662: the entry guard both raised the count and joined the half of it that prints the type. A guard that refuses correctly and then misdirects has moved the failure rather than fixed it. TKT-597.

A refusal names the items blocking a card WITH THE IDS it tells you to use. It states how many there are, prints one per line with its `REQ-NNN` id beside its own text, and ends with a `tira.required-action.update` carrying a real id from that list rather than a placeholder. Before 4.57 it joined the item texts with semicolons onto one line and suggested the literal `REQ-NNN`, so acting on it meant running `tira.required-action.list`, matching each item by text and reading off the id - on a card with 75 items across a dozen columns, by eye. That cross-reference had already put proofs against the wrong ids twice. Only the wording changed; the same moves are refused. TKT-598.

`tira.required-action.list --blocking` answers the same question without attempting a move: what does the column this card is in still owe. Without it the command returns every item on the card across every column, which is why being refused was the only way to find out. The flag sits on the existing command rather than a new verb because `tira.card.required` already answers a different question - which FIELDS a complete card needs - and a third similarly-named command would mislead. Giving `--blocking` to any other command is refused by name. The refusal and this answer share one selection, so a card cannot be told one thing and refused for another; an item this card is exempt from (`--exempt-required`) drops out of both.

One thing it does not yet do: the items are separate lines in the message and not in what you see. A refusal is serialised as a single error string and every format escapes the newlines, `-o human` included. TKT-658 covers that for all three multi-line refusals.

A command's usage line names the arguments it refuses without. `_usage()` answers from this manual's own usage catalogue and falls back to a bare `[options]` for any command with no line here, so `tira.required-action.add`, `.list` and `.update` and `tira.question.ask`, `.answer` and `.mark` - the ones an agent touches at every gate - described themselves as taking nothing in particular. `tira.checklist.update` was the worse shape: it had a line, and that line listed three optional flags while omitting the two mandatory ones, so it read as exhaustive. Another board reported the cost independently - four `checklist.update` calls composed from `--help`, their output suppressed, and the author walked away believing four entries were ticked while the checklist still read 0/9. The enforcement is unchanged and was never the problem; `--help` now says what it demands, with `[--command TEXT ... [--proof TEXT ...]]`, the proofs nested inside the commands rather than paired off one bracket at a time. Until 4.64 it read `[--command TEXT --proof TEXT ...]` as a single unit, because the pair was required together and repeatable; TKT-628 made a `--command` usable alone to record what is being run before it can be proved, so the pair is now required together only for a `done` claim. The nesting is a summary rather than a grammar - the parser takes both as independent repeatable options and the engine pairs them by count afterwards - but it is the summary that misleads least: a proof cannot arrive without a command, and once any proof is given the counts must match. Forty-nine commands still print a bare `[options]` - `tira.police`, `tira.next`, the `policy.*`, `backup.*` and `project.*` families among them - and that set is written down as a ledger a test holds: a new command cannot join it silently, and one that gains a usage line cannot be left in it. `--help` naming nothing at least admits it is withholding something; a list that omits the required half does not. TKT-575.

A backward move to `backlog` also resets the tasklist items that say somebody is working the card. The board already understood that retreating undoes claims of progress; tasks were never part of it, so a card could sit in the queue while its task list went on reading `working` until an agent ran a second command nobody prompted for. Anchored to `backlog` because it is the default builtin column - a fix point every board has, needing no per-board configuration. A task already `done` is left alone, because it records work that happened and a card retreating does not unmake it. The reset crosses the session boundary deliberately: tasklist items are session-scoped (TKT-537), and on a multi-agent board the tasks most needing reset belong to somebody else's session, so a boundary-respecting reset would do nothing in exactly the case it exists for. A task naming more than one card is **not** reset and **is** named in the output - there is no status true about two cards at once, and a silent skip is indistinguishable from the feature being broken, so the person moving the card is told which task to judge by hand. TKT-596.

The "skipping any it already carries" dedup above is now atomic against two near-simultaneous moves of the same card, not only a sequential re-entry. Two browser moves fired close together - a double-click on the status dropdown, or any other double-fire of the same request - used to both read the card's `required_items` before either had written its own addition, both decide the template item was missing, and both add it, leaving two identical `REQ-NNN` entries for the same text and column. `required_item_add`'s auto-populate path now makes that check-and-add one atomic step inside the lock it already holds, so the second of two concurrent calls sees the first's addition and skips it. A manual `tira.required-action.add` is unaffected - only the template-population source is deduplicated, so asking for the same text twice on purpose still adds it twice. Reported live: "When card being move along on the html dashboard. The population of the required action items will be duplicated." TKT-497.

Marking either kind of item done now costs proof: `tira.checklist.update` and `tira.required-action.update` refuse `--status done` (case-insensitively) without at least one `--command`/`--proof` pair - repeatable, since one item may take several commands to satisfy - and refuse it again if either half of a pair is empty or whitespace-only, naming the half that is missing. Counting the pair was never the point; the pair is what says the work happened, and until 4.60 `--command '' --proof ''` marked any item done, which was cheaper than doing the work and cheaper than reusing somebody else's proof. Whitespace counts as empty: a space is not a smaller piece of evidence than none. TKT-585. `--proof` is the literal output of the paired `--command`, trusted as given rather than re-executed. Every pair is stored on the item and logged to the card's `gate_passing_log`, so what proved an item done survives independently of the item itself. Proof over 2000 characters (the same truncation threshold already used elsewhere on this board) is stored as an attachment instead of inlined onto the card, referenced by filename in both places. Every other status change is unaffected - including the move mechanism's own backward reset to `pending`, which needs no proof either, since "done" is the only claim being gated.

Since 4.64 a `--command` may arrive ahead of its proof, on a call that is also changing the item's status or its text - `required-action.update` still refuses a call that changes nothing, so the command travels with the `--status pending` that says the work has started. `tira.required-action.update --status pending --command "prove -lr t"` records what is being run, leaves the item exactly where it is, and the card dialog marks it with a clock - distinct from an untouched item and from a done one. The proof follows when the command has actually produced something, repeating its command. What marks the item done is still `--status done`, which refuses without that pair - a full pair supplied with `--status pending` is accepted and stored and leaves the item pending, because evidence is recorded and status is asserted, and they are two different things. Before this the same call was parsed, accepted and silently discarded: `_proof_entries_for` returned nothing unless the status was already `done`, so the caller was told nothing and the card recorded nothing. The owner asked for the state because a list of pending items cannot say which one is being worked right now. This adds a state BEFORE done and does not weaken the gate - marking done still costs a matching pair, an empty half is still refused, and an announcement writes no `gate_passing_log` entry, because that log records what was proved and an announcement proves nothing. The engine half reaches checklist items too, since both families share that function; only required actions get the clock. An announcement that is never proved stays visible, which is the point - an item that says it started and never finished is something somebody should see. Announcing a command on an item that is already done is only allowed as a deliberate re-open - pass `--status` with it, and the item's `proof` field carries the new announcement while what proved it before survives in `gate_passing_log`, which is where evidence is kept precisely so it outlives the item field. Announcing without a status, so the item would stay `done`, is refused: `That item is done and its proof is what says so - re-open it with --status before announcing a new command over it`. Otherwise renaming a finished item while announcing would leave it claiming done with an announcement where its evidence used to be. A status change carrying no command - the move mechanism's own backward reset among them - leaves a stored proof untouched, as it always did. TKT-628. Caught on ZSD-246: an agent created 9 checklist items and marked all 9 Done inside a 5-second window, a narrative written after the work supposedly finished rather than a live record of progress. TKT-453.

Proof that costs nothing to copy proves nothing, so one piece of evidence can no longer prove two different instructions. `tira.required-action.update --status done` is refused when another item **in the same column** already carries that exact `--command`/`--proof` pair, trimmed before comparison so a trailing newline cannot slip a duplicate through, and attachment-backed proofs compared by content hash rather than filename. Reported by the owner from his own board - "the agent will use the same command and message to fill in and mark all done. Like TKT-555 Install column" - and measured across its done column before anything was written: 422 reuses on 73 cards, one `prove` run standing as the proof for eleven separate items, among them "add the start date". A suite run genuinely does prove several items at once, so the door is priced rather than locked, but paying for it takes two calls instead of one argument, because a gate that accepts any argument is exactly the hole TKT-585 records. `--repeated-reason TEXT` is refused too, and answers by reading **this item's own instruction** back beside the reason just given, with a six-character code to sign; repeating the call with `--repeated-confirm CODE` marks it done and stores the reason for later reading. The failure being caught is inattention rather than dishonesty - nobody re-read what item eight asked for - so being made to look at the instruction *is* the check, and the code is what makes looking unskippable. It is bound to the claim it was issued for: stashed against card and item, invalidated and reissued if the command, proof or reason changes between the two calls, and returned unchanged when the same claim is re-asked, so a typo costs a retry rather than locking the item. The reason is stored only on an item that genuinely duplicated something, never on one that did not. The board shows the outcome rather than hiding it - such an item is highlighted, not merely ticked, and its proof modal opens with the reason above the evidence. Moving a card into a column carrying required actions prints how many arrived and to work them one at a time, to STDERR and only when there are any: the reuse happens at the end of a column's work holding a list nobody read item by item, so the reminder belongs at the moment the list arrives. TKT-583, TSK-168.

`tira.checklist.update`'s refusal on an unknown `--id` names the card's real `CHK-NNN` ids, or the shape itself on a card with none yet, rather than only "not found": an ordinal like `--id 1` used to fail that way with no hint that ids are not positions, and entries print as a numbered list, which makes an ordinal the obvious wrong guess. Reported live: a loop over ordinals believing `--id` took the position failed silently on every call, and three cards' checklists were reported ticked when none of them were. TKT-280. `tira.required-action.update` had the identical gap on its own `REQ-NNN` ids and got the same fix. TKT-488. So did `tira.gate.list`/`tira.gate.annotate` and `tira.evidence.list`/`tira.evidence.annotate`, on their own `GATE-NNN`/`EVD-NNN` ids - fixed together, since both pairs share one underlying lookup. TKT-490. `tira.comment.update` and `tira.comment.remove` were the last two lookups with the identical gap on their own `CMT-NNN` ids, found during a documentation-gap hunt that grepped every remaining "not found" die site in `lib/Tira.pm`; both now name the card's real ids or the `CMT-NNN` shape the same way. TKT-491.

Creation is not a move, so a card created directly into a column carrying required actions - its declared entry point, or any `--column` matching one - gets those items on its `required_items` list immediately, the same way a move-in would, rather than only after its first real move away and back. `tira.ticket.create --title "..." --column planning` on the board above already carries `left a note` as `pending` the moment it returns. A direct engine call, the dashboard's own create flow, is unaffected. TKT-439, TKT-445. Populating those items requires an author the same way any other write does, and until 3.72 that requirement was discovered too late: the record was already written by the time the required-items population needed one, so a create with no `--author` and no `TIRA_AUTHOR` failed *after* creating an orphaned, unattributed card - a retry with `--author` then created a second, duplicate ticket for the same work rather than completing the first. Refused up front now, before anything is written, whenever the landing column carries required actions and no author is available; a create landing in a column with none is unaffected either way. TKT-485.

A column's required-action template is a baseline, not an absolute, in both directions. An agent can remove one specific card's obligation to a column-declared item: `d2 tira.ticket.update --ref TKT-001 --exempt-required "the item text" --exempt-reason "said why"` (both repeatable, paired positionally, accumulating) lets that card diverge from the baseline when its own situation does not need everything the column normally requires. `--exempt-required` is refused without a matching `--exempt-reason` - a card in `done` with an item still showing an empty checkbox is indistinguishable, on screen, from work that was simply skipped, so the reason is required rather than merely permitted, and both are stored (`{item, reason, exempted_at, author}`) rather than the item text alone. The move-out check skips anything on a card's own exemption list, so an exempted item never has to be marked done to leave. The exemption is per card - a sibling card sitting in the same column still needs its own copy of every item the column requires, unaffected by another card's exemption. An exempted item renders struck-through in the dashboard's Required actions section, with no checkbox, and its click-popup shows the reason where a done item would show command/proof - before this it rendered identically to a genuinely pending item. An exemption recorded before this reads and gates the same as a new one. TKT-439, TKT-473.

An agent can also add a required item that exists only on one card: `d2 tira.required-action.add --ref TKT-001 --item "card-specific extra check" --status pending`, tagged with whichever column the card currently sits in. Unlike a plain `tira.checklist.add` extra (still available, still never gates a move - that list is purely manual), an item added this way DOES gate the card's departure from that column exactly like a template-derived one. `d2 tira.required-action.list --ref TKT-001` reads the whole list back, and `d2 tira.required-action.update --ref TKT-001 --id REQ-NNN --status done` marks one done. TKT-445.

Required items get their own labeled section in the browser dashboard's card dialog, separate from the general checklist - opening a card shows a "Required actions (done/total)" section, grouped by column, the moment it opens. A card with none renders exactly as before, no new section. Marking one done from the dialog updates the count in place, with no page reload. TKT-440. A done item's command/proof pairs open in a popup on click, rather than an inline row - the inline form (TKT-462) could not cope with a long command on a narrow screen, wrapping the proof text one character per line until it was unreadable; the popup wraps at word boundaries and stays within the viewport at any width. TKT-467.

The card dialog's **Gate Passing Log** section paginates rather than rendering the whole log at once: it shows the first ten entries and, when more remain, a "Load more (N more)" button reveals the rest and disappears once every entry is shown. A card with ten or fewer entries never shows the button at all, and a card with none renders no section, exactly as before. Every other list section on the dialog (Evidence included) is unaffected - only Gate Passing Log paginates. Owner, live, after watching a long-running ticket's log grow: "If the Gate Passing Log length more then 10 start pagination... if there are 1000 logs. That will kill the browser performance. So do not load all gate log at once." TKT-495.

A linked sub-ticket/epic row in the card dialog's hierarchy/linkage list is clickable - clicking it navigates the dialog to that card, and a back control (top-left of the header, hidden until there is somewhere to go back to) returns to the card that was open before, one step at a time. Clicking the unlink (x) on a linkage row, or the remove (x) on a typed link, does not navigate - only the row itself does. The navigation trail resets when the dialog closes or a fresh card is opened from the board, so it never carries stale state into an unrelated card. Owner, live: "Add a click to the list. When user click on it. Will open that card. And when click on the back button will be back to parent card." TKT-470.

The attachment preview overlay has left/right arrow buttons that step to the previous/next attachment in the same list the opened one belongs to - a card's own attachments, or one comment's - without closing and reopening the overlay. An arrow disables itself at the end of its list rather than wrapping, and a lone attachment (nothing to step to) shows both disabled. Michael, via Telegram: "can we add a left arrow and right arrow to scroll through the attachment list? ... click the right arrow in a badge and the next attachment just show up." TKT-500.

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
`--priority`/`--assignee` optionally set the child in the same write as the
link - an untriaged card reaching the board (from a bug hunt or the external
bridge) usually needs a home, a priority, and an assignee in the same
breath, and before this it always cost a second round trip: measured four
times in one session. Omitting both leaves the command exactly as before. An
invalid priority or unknown assignee refuses the whole call, the link
included, rather than linking and silently dropping the bad value. TKT-432.

### UC-137: Create a record already parented
**Implemented.** `dashboard tira.ticket.create --title "Login" --parent EPC-001` creates the ticket and links it under EPC-001 in one command, applying the same hierarchy validation `hierarchy.link` applies - the record was created parentless and given a parent by a second command before this, which meant it was an orphan in between and this project's own board had 1361 findings to show for it. An invalid hierarchy (a ticket parented straight to a SOW, or a parent that does not exist) fails the whole creation: nothing is left behind for `--parent` to have half-worked on. `--parent` is still refused on `tira.<type>.update` with the same message as before - naming `hierarchy.link` and the ref to run it with - because accepting it there and silently doing nothing is a worse failure than a refusal. TKT-362.

### UC-138: Record a passed gate in one command
**Implemented.** `dashboard tira.release.record --ref TKT-001 --gate "Release gate" --result pass --details "Suite green, 100% coverage" --evidence "Full suite run, 6540 tests" --fix-version 2.88` writes a gate entry, an evidence entry and the fix version together - the three separate calls (`gate.add`, `evidence.add`, `<type>.update --fix-version`) this project's own releases ran on every one of them, and forgot part of three times, each caught only by a later refusal. Anything it is not told is refused rather than defaulted: omit `--fix-version` and nothing is written, not even the gate the same call also carried. Column moves are deliberately untouched - walking the gates a card passes through stays manual, because that is the discipline the push gate enforces rather than paperwork a verb should shortcut. `gate.add`, `evidence.add` and `<type>.update --fix-version` keep working exactly as they always have. TKT-345.

### UC-139: Keep a running list of steps, without opening a ticket for each one
**Implemented.** `dashboard tira.tasklist.add --text "read the README"` adds a free-text item to a small, separate list - three fixed states (pending, working, done), no gates, no checklist, none of the ticket system's release discipline. `dashboard tira.tasklist.list` shows what is there; `dashboard tira.tasklist.update --id TSK-001 --status working` moves one along. Every call is scoped by `--session`: two different session ids never see each other's items, so a subagent that declares its own gets a private list, and an orchestrating agent can still read one by naming that session; call with no `--session` at all and everything shares the one list, which is what a single agent working alone wants. `--ref` optionally ties an item to an existing ticket, epic, or sow. Michael, live: "since TaskList not working, Create this simple task list feature to Tira, d2 tira.tasklist.add." TKT-504. `tasklist.add`/`tasklist.list` fall back to the `TIRA_AGENT_SESSION` environment variable when `--session` is not given explicitly, so multi-agent mode does not have to type it on every call; an explicit `--session` still overrides it. TKT-505. Ids are `TSK-NNN`, matching the short prefix every other record type uses. TKT-506.

A task sits below the SOW → epic → ticket hierarchy, for anything smaller than a ticket - a chore, a sub-step, a note-to-self mid-task. Sticky-note style: `--ref` can name one thing, several (repeat the flag), or nothing at all, and nothing checks that a named ref actually exists - a task can point at a real ticket, a URL, a filename, or free text equally. Use it when the ticket system's own weight (gates, required-actions, 100% coverage) would be overkill for the step itself.

Michael, live, treating it as an array list: "all the array functions you can think of could apply to it - like next, pop, shift, unshift, slice to insert item in between, etc... And push, update, remove etc..." `push` is `tasklist.add`; `update` already existed. TKT-507 adds the rest: `next` peeks the front of the pending queue without removing it; `shift` returns and removes the front (FIFO); `pop` returns and removes the back (LIFO, the most recently added); `unshift` inserts a new item at the very front, jumping the queue; `slice` inserts a new item at an arbitrary `--position`; `remove` deletes an item entirely by id, distinct from marking it `done`. Each item carries an explicit `order` field, independent of `created_at`, so `next`/`shift`/`pop` can always find queue position without timestamp games. His other follow-up - "you can add the required actions items or checklist items to the tasklist, so you can focus on a task at a time" - is `tasklist.import --ref TKT-XXX`: copies a card's still-pending required-actions and checklist entries into linked tasklist items, one per entry, skipping any already imported, so an agent can work a card's outstanding gate items one at a time through the same queue instead of the raw ticket view.

A further screenshot, TKT-508: status became a stored integer enum (0 = pending, 1 = working, 2 = done) - `tasklist.update --status` still accepts the word too, but every command now returns the number; a task list written with string statuses before this shipped reads back correctly and upgrades itself on its next write, no separate migration step. `tasklist.prune` deletes every `done` item. `tasklist.list --sort FIELD:DIR[,FIELD:DIR...]` defaults to `last_updated:desc,status:asc` - a purely-display ordering, independent of the `order` field `next`/`shift`/`pop` use for actual queue position. `tasklist.add --attach FILE` (repeatable) attaches files at creation, content-addressed the same way record attachments already are; `tasklist.task.attach.add/discard --id ID --file FILE...` and `tasklist.task.ref.link/unlink --id ID --ref REF...` manage an existing item's attachments and refs after the fact.

```text
tira.tasklist.add --text TEXT [--session ID] [--ref REF ...] [--attach FILE ...] [-o FORMAT]
tira.tasklist.list [--session ID] [--sort FIELD:DIR[,FIELD:DIR...]] [-o FORMAT]
tira.tasklist.update --id ID [--status pending|working|done|0|1|2] [--text TEXT] [-o FORMAT]
tira.tasklist.next [--session ID] [-o FORMAT]
tira.tasklist.shift [--session ID] [-o FORMAT]
tira.tasklist.pop [--session ID] [-o FORMAT]
tira.tasklist.unshift --text TEXT [--session ID] [--ref REF ...] [-o FORMAT]
tira.tasklist.slice --text TEXT --position N [--session ID] [--ref REF ...] [-o FORMAT]
tira.tasklist.remove --id ID [-o FORMAT]
tira.tasklist.import --ref REF [--session ID] [-o FORMAT]
tira.tasklist.prune [--session ID] [-o FORMAT]
tira.tasklist.task.attach.add --id ID --file FILE [--file FILE ...] [-o FORMAT]
tira.tasklist.task.attach.discard --id ID --file FILE [--file FILE ...] [-o FORMAT]
tira.tasklist.task.ref.link --id ID --ref REF [--ref REF ...] [-o FORMAT]
tira.tasklist.task.ref.unlink --id ID --ref REF [--ref REF ...] [-o FORMAT]
```

TKT-516: full CLI parity in the browser dashboard (`-o browser`). Michael,
live: "add a new section under the ticket bboard in html dashboard for
tasklist. it should be fully functional like on the cli. the ui make it like
a yellow momo paper for pending, green for done and purple blue is
in-progress." A `board--tasklist` section renders below the ticket board:
every item as a colored sticky-note card (`data-status` drives the color via
new `--task-pending`/`--task-working`/`--task-done` CSS custom properties,
themed for both light and dark), list-level controls (add box, session
switcher, next/shift/pop/unshift/slice/prune buttons, import-from-card), and
per-card controls (a status dropdown that recolors the card live, remove, and
- once TKT-510 shipped the sub-verb dispatch fix - per-card attach/ref chips
with their own add/discard/link/unlink buttons). Backed by new `GET
/tasklist` and 14 `POST /tasklist/*` routes in `Tira::DashboardWeb.pm`, wired
to matching provider closures in `Tira::CLI::browser_providers`, the same
shape the Policies dialog's own providers already use.

TKT-523: a card's own text is editable in place - click it, type, Enter or
blur saves, Escape discards - and the section auto-refreshes every second
(matching the ticket board's own cadence) without a tick ever clobbering an
edit already in progress. `tira.tasklist.update` gained `--text` alongside
its existing `--status`; either can be given alone, and each leaves the
other field untouched.

TKT-524: a tasklist card also accepts an attachment by drag-and-drop
(highlighting while a file is dragged over it) or paste (when the card
has focus), alongside the existing file-picker button - all three reach
the same attach path. Michael, live: "the user can also drag and drog
attachment to any existing task... Also the user can paste if that is a
file or picture, also convert that to attachment."

TKT-528: clicking a linked ref chip's text (not its remove button) on a
tasklist card now opens that card's own dialog - the same
`navigateToCard(ref)` opener the card dialog's own linkage table already
uses, rather than a second dialog mechanism. Michael, via TSK-022: "when
i click on the card ref on the task card. It will open the card modal."
The chip's remove (x) button is unaffected - it still just unlinks.

TKT-529: the dashboard's own search box now also filters the Task List
section - typing hides non-matching tasklist cards (by text, id, or a
linked ref) and clearing the box shows every card again, matching how
the search box already filters the SOW/Epic/Ticket boards. Michael, via
TSK-023: "The search also filter the task cards too." Implemented
client-side rather than a server round-trip, since tasklist items are
already loaded locally.

TKT-531: a tasklist card's ref field now suggests matches as you type,
instead of being a blind text box - typing a bare number shows every ref
containing it, and typing a prefix (or a partial prefix) filters the same
way, both via one substring match against the refs the dashboard already
knows client-side. Clicking a suggestion links it exactly like the
existing Link button. Michael, via TSK-021: "if i just type the number
will show me any card with that number and i just click the one at the
dropdown and linked."

TKT-530: 3 of the Task List section's native blocking dialogs now use
inline styled UI instead - the "Next" peek result shows in the section's
own notice element rather than alert(), and the slice-position/
import-ref prompts became a small inline capture (input + Go, Enter
submits, Escape cancels) next to the triggering button. The section's 5
confirm() dialogs (remove policy/task/attachment, prune) were judged
individually and kept as native, since each gates a genuinely
irreversible action and a blocking native confirm is harder to mis-click
through than any in-place replacement.

TKT-532: the browser dashboard's `/record` and `/move` providers no
longer require a `type` field - the engine methods behind them resolve
a record by its ref alone, and never actually read the caller's type
for lookup, confirmed by direct code reading. `type` is still accepted
when supplied; the move provider's own required-action bookkeeping now
recovers the real type from the moved record itself rather than
requiring it from the caller.

TKT-533: `tira.search --tasklist` also matches a tasklist item's text,
id, or a linked ref - opt-in only, so a plain `tira.search` is
unaffected. Previously `search()` only ever walked the sow/epic/ticket
boards, leaving a tasklist item invisible to it regardless of how
distinctive its text was.

TKT-537: `--tasklist` matching is scoped to the caller's own `--session`
now, the same way `tasklist.list` already is - self-found and fixed
immediately after TKT-533 shipped: a search run under one session could
otherwise surface another session's private tasklist item just by
matching its text, id, or a linked ref, defeating the per-agent privacy
`--session` exists for.

TKT-538: every tasklist mutation command (`tasklist.update`,
`tasklist.remove`, `tasklist.task.attach.add`/`.discard`,
`tasklist.task.ref.link`/`.unlink`) now refuses to act on an item
belonging to a different `--session`, with the same "No task" error an
unknown id gets. Previously these looked an item up by id alone - since
TSK ids are sequential and project-wide, a different session could
silently edit or permanently delete another session's private item just
by guessing its id, a materially worse version of TKT-537's read-only
gap. Self-found and reproduced directly while fixing TKT-537.

TKT-539: `tasklist.list --all-sessions` is a new, explicit opt-in that
returns every item across every session, each still labeled with its
own session field - the default (no flag) behavior is unchanged.
Restores the one legitimate use TKT-537/538 otherwise closed off
entirely: a supervising agent checking on several subagents' tasklists
without already knowing each one's session id.

TKT-547: a new `task-unlinked` police rule reports a pending or working
tasklist item with an empty `refs` array, once it has aged past the
rule's `--age` grace, instructing the reading agent to link it to an
existing ticket or file a new one and link the two - the police engine
only detects and instructs, it never creates or links a ticket itself.
Whole-board like `board-still`/`agent-still` (a `--ref` scope is
refused), swept across every session.

TKT-639: a new `task-card-mismatch` police rule reports a tasklist item
whose status contradicts the column its linked card sits in, and a card
carrying the same note twice. Three directions from one comparison: a
task saying working about a card in a column nobody called work; a task
saying pending about a card being worked; and a task not yet done about
a card that has gone past the work columns entirely. Which columns mean
work is declared with `--column` and never inferred - the hand-run
check this replaces counted `next-to-work-on` as work and seven of its
eight findings were false for that one reason, since a card waiting to
be picked up has not been started. The columns are one set however they
are spelled: a comma-separated list in one policy, several policies,
`--column-role` naming a role the board has assigned, or any mixture -
they all compose, and the pass reports from the first. Roles are read
because policy.add already accepts a `--column-role` wherever a
`--column` is required, so a rule ignoring them would compute an empty
working set from a declaration the engine accepted, and an empty set
inverts the rule rather than silencing it; nothing resolving means the
rule stays quiet and `policy-unfollowable` reports the declaration. That is
deliberately unlike every other rule, where `--column` is a scope and a
second policy is a second intention - read that way, each policy
reported the other's honest tasks. "Past the work" is read from the
board's own column order, per record type, so the third direction needs
no second option. Duplicates match on the first sixty characters,
lowercased and trimmed - multiplicity alone is not a fault, and a pair
that is entirely done is left alone. No `--age`, whole-board like
`task-unlinked`, and swept across every session. At most one finding
per task per pass: the violation ledger keys an entry by rule, policy
and reference, so two findings about one task would share a number, a
`first_seen` and a `seen` count - the status mismatch is said first and
the duplicate on the pass after it is put right. It reports only;
closing the gap stays the agent's job.

TKT-554: a Task List card's own 1-second poll no longer wipes a
half-typed ref in its ref-link input, or a file chosen but not yet
attached in its file input - `reconcileTasklist`'s rebuild guard
previously only protected an open text-edit textarea (`tlEditingIds`),
so any other in-progress input on a row got silently replaced by the
next poll tick's fresh row. Root-caused from Michael's own bug report
(TSK-072); TKT-551 first investigated the wrong UI (the regular
ticket/epic/sow card dialog, whose own `dialogEditingActive()` guard was
confirmed already correct) before this ticket found the real gap in the
Task List section's own live JS.

TKT-590: the same guard, one clause short. TKT-554 protected a ref that
already had characters in it, and left the moment before the first one
landed unprotected - a box that is focused but still empty is not busy by
any content test. With `setInterval(loadTasklist, 1000)` that window
recurs every second, so pausing to read the ref you are about to type is
enough to lose the box, which is exactly what the owner reported
(TSK-169): "if i typed to type in a card-ref on it. It will wipe it out.
But the card text edit is fine." The text edit was fine because
`tlEditingIds` registers *intent* when the editor opens, while the ref box
was judged on *content*. The guard now reads both: the ref box counts as busy when it holds a value
**or when it is the focused element**. Scoped to that box rather than to any
focused input in the row - the wider form was written first and regressed the
text editor, which stayed on screen forever because focus was still inside the
row it was trying to leave. The whole test is extracted into one named
predicate, `tlRowBusy`, rather than appended as another inline clause - a
growing conjunction is how TKT-554 came to fix one case and miss its
neighbour. The browser test proving it passed on its first
run against unfixed code, because it reused a row that still had a file
chosen and that clause kept the row alive regardless; rewritten against an
untouched row, it fails on the old code and passes on the new.

TKT-548: a new `task-changed` police rule reports a tasklist item whose
text, attachments, or linked refs changed since the last police pass
saw it, firing for any actor (not owner-only, per Michael's own live
answer) since a tasklist item has no change journal to compare a
newest author against - what it looked like last time is kept in the
same store-backed ledger `agent-still`'s own notified-stamp already
uses. No age (a change is a change the moment it happens); whole-board
like `task-unlinked`; a freshly-added item is not reported and settles
the instant it has been seen once.

TKT-549: the Task List section's header has a Prune button again, next
to Add - removed entirely by TKT-535, brought back with new behavior
per Michael's own tasklist note: a manual click asks for confirmation
before pruning every done item, and a standing 5-minute interval
prunes automatically with no confirmation.

TKT-557: the Task List section now offers a known-sessions dropdown
next to the free-text session box, listing every session
`tira.tasklist.sessions` already knows about with its item count -
closing the same discovery gap TKT-541 closed for the CLI/agent side.
Sourced from a new `GET /tasklist/sessions` route (and matching
`browser_providers` closure); the free-text box still accepts an
arbitrary typed session id. Found during a standing 2-hourly
improvement hunt.

TKT-558: `Tira::DashboardWeb`'s own `build_psgi_app` POD now names
every one of the module's 58 provider arguments, grouped by the routes
they answer - previously it named only the original 12 from long
before tasklist/login/policy/checklist/hierarchy support existed, so
entire feature areas were invisible to anyone reading the POD alone. A
new test (t/402) source-scans the module's own `@PROVIDERS` table
against the POD text so this cannot silently go stale again.
Documentation-only, no behavior changed. Found during a standing
documentation-gap hunt.

TKT-552: `tasklist.list --unlinked` returns only the items with an
empty `refs` array. `task-unlinked` (TKT-547) already watches for those,
but reports one only once it has aged past its grace - so an agent
wanting to find and fix them before the police nags, which is what the
standing hunts on this board do, had to fetch every item and filter
`refs` itself. The same shape TKT-545 found for `--status`, applied to
linkage. It filters linkage only: the rule watches pending and working
items, but an audit that silently dropped done ones would answer a
narrower question than the one asked. Composes with `--status` rather
than replacing it, since the two read different fields.

TKT-580: `tira.search --tasklist --session NAME` is accepted at last.
Both this file and `docs/commands.md` have described search's tasklist
matching as scoped to the caller's own `--session` "the same way
`tasklist.list` already is" since TKT-537 - but the CLI refused the
flag. `--session` was grouped with `--collector`, `--agent` and
`--heartbeat` in the reminder-settings guard, whose whitelist covers
`project.update`, `project.new`, `onboard` and `tasklist.*` and never
included `search`, so the documented scoping was reachable only through
`TIRA_AGENT_SESSION` and typing the flag produced "Reminder settings
belong to the project.update, project.new and onboard commands" - three
commands, none of them the one typed. A session scopes; it does not
configure a reminder, and it now has its own guard rather than another
name appended to that one. The guard's own comment already recorded
being patched once for this same class of miss, which is why the fix
separates rather than extends.

TKT-550: `tira.search --tasklist --all-sessions` searches every
session's tasklist items rather than only the caller's own - the same
opt-in `tasklist.list` got in TKT-539, for the same supervising agent,
who until now could not find a subagent's item by text at all. Strictly
opt-in: the session filter it crosses is TKT-537's deliberate privacy
boundary, not an oversight, so without the flag nothing changes and the
existing cross-session assertion in `t/396` keeps passing untouched.
Every tasklist hit now carries a `session` field, with or without the
flag, because a cross-session answer that cannot say whose item matched
reproduces the gap the flag exists to close.

TKT-545: `tasklist.list --status` narrows the list to one status,
taking the same `pending|working|done|0|1|2` values `tasklist.update`
does and through the same parser, so the two cannot drift on what a
status is called. `next`, `shift` and `pop` already filtered to pending
internally for their own single-item use, so the vocabulary existed and
only `list` could not be asked - which left "what is still on my plate"
to be answered by pulling every item as JSON and filtering the `status`
field by hand, the aggregation a list command is for. Omitting it is
unchanged. An unknown status is refused rather than returning nothing,
because an empty list reads as "no such work" when it means "no such
status". Filtering runs before sorting, so `--sort` orders what
survived rather than being applied to a set nobody asked for.

TKT-568: `t/344` now sees the engine methods the CLI reaches through
its string dispatch table. That guard exists to stop `lib/Tira.pm`'s
METHODS section going stale, and scoped itself to what `Tira::CLI`
actually calls on `$tira` - which it found by matching `$tira->method(`
call sites. But a command name maps onto a method name as a string,
`'release.record' => 'release_record'`, and the method is then called
through a variable, so no literal call site exists for the guard to
find. Every method reached that way sat outside the scope the guard
believed it was enforcing, and the test passed while a fifth of the
documented surface was missing - precisely the drift it was written to
stop. Widening it surfaced 23 undocumented methods, one more than the
count the ticket had enumerated by hand: `required_item_list` was the
extra, undocumented while its own siblings `required_item_add` and
`required_item_update` both had entries, so the family read as complete
until each member was checked. All 23 are now documented.

TKT-562: onboarding refuses an invalid `--mode` before it creates
anything. The check used to happen after `project_new` had written the
project, its people, its boards and every column, so an invalid value
left the caller with a nonzero exit, an error, and a complete project on
disk that nothing mentioned. "It failed" and "it half worked" are
different facts, and only one of them tells the reader to go and look at
the directory; the next attempt then meets a project that should not be
there. Reachable through the `--mode` flag and through the browser
onboarding form, whose mode field renders its options as a hint and
validates nothing before calling back into the same dispatch - the
interactive wizard was always safe, because its own loop re-asks. The
refusal names the option and both values, and reads them from
`onboarding_questions()` rather than a hard-coded pair, so a third mode
added there cannot be silently refused here.

TKT-571: an UNASSIGNED card counts against the agent again. TKT-570's
filter (below) kept a card only when its assignee equalled the declared
agent, which dropped cards nobody had claimed alongside cards belonging
to somebody else. Since assignee is optional, a board that never sets
one then had nothing left for the rule to report, and it went silent
for good - and a rule that silently never fires is worse than one that
over-fires, because nothing announces the loss. It was also stricter
than TKT-570's own acceptance criterion, which asked for cards
"assigned to someone OTHER than the agent"; unassigned is not assigned
to someone else. A card is now dropped only when it is assigned to a
named person who is not the agent. `card-unassigned` still complains
about the missing assignee, but its remedy is a different one and it
says nothing about elapsed time. Found by the standing bug hunt an hour
after 4.39 was committed and before it was pushed, so no board ever ran
the silent rule.

TKT-570: `agent-still` now asks whose card it is before deciding the
agent has stopped. Its waiting list was built from columns alone, so a
card parked at `in-review` awaiting the owner's answer counted as the
agent stalling on it - while the rule's own text claimed it "reports
only when something is actually waiting on the agent". Reported from
another project using this skill, with a measurement rather than a
description: 59 firings in a single session, every one true about
elapsed time and wrong about what it implied. None of the existing
escapes reached it, which is what made it a defect rather than a
preference - this rule is whole-board so a `--ref` scope is refused,
and the idle-queue exemption only helps when working columns are empty
rather than holding somebody else's card. What was left was touching a
card every 45 minutes to reset the clock: progress claimed by dragging
rather than by working, which is the anti-pattern the rulebook names
elsewhere, so the rule was training the behaviour it exists to catch.
A board that has declared no agent behaves exactly as before.

TKT-546: the `agent-still` policy rule's bridge-visible text now prompts
the agent to diagnose why progress stopped before instructing it
through the ask-the-owner/resolve-directly/file-a-resolver-ticket
procedure, instead of only naming elapsed time and waiting cards. The
rule's separate off-channel owner notification is now opt-in
(`--notify` on the policy declaration) rather than automatic - the
violation already reaches the bridge like every other rule, so the
off-channel page duplicated it by default.

TKT-541: `tasklist.sessions` is a new, read-only command listing every
distinct session present in the task list, with an item count and a
pending/working/done breakdown each, sorted by count descending -
closing the gap `--all-sessions` left open: it proved cross-session
visibility, but a supervisor still had to hand-dedupe the dump to find
out which sessions existed at all.

TKT-563: `tasklist.next --ref REF` (repeatable) narrows to the next
pending item linked to any of the given cards, instead of always
answering the session's globally-next pending item - Michael's own
words, given live: "Get the next task specific from a single or
multiple card." Omitted, behavior is unchanged. The pre-existing
"Multiple refs are only available on show" guard now names
`tasklist.next` alongside `record.show` as the two commands allowed
more than one `--ref`.

TKT-544: `lib/Tira.pm`'s own POD for `tasklist_list`, `tasklist_update`,
`tasklist_remove`, and the four `tasklist_task_*` sub-verbs now describes
their actual session behavior - TKT-538's session enforcement and TKT-539's
`--all-sessions` opt-in were already documented correctly in
docs/commands.md and SKILLS.md, but the module's own POD had been left
behind. Documentation-only, found during a standing documentation-gap hunt.

TKT-540: six of the browser dashboard's Task List mutation routes
(`tasklist_update`, `tasklist_remove`, and the four
`tasklist_task_attach_add`/`_discard`/`_ref_link`/`_ref_unlink`
providers) now forward the `session` field the frontend already sends
on every request - previously only the other eight tasklist providers
did. Since TKT-538 made a session mismatch a hard refusal, switching to
another session's view in the dashboard and editing/removing/
attaching/linking there silently failed with "No task". Found during a
standing bug hunt, widened from an initial two-provider finding to all
six after a follow-up pass found the same gap in the remaining four.

TKT-542: docs/commands.md's tasklist intro paragraph no longer claims
`tasklist.update` ignores session - that sentence was accurate before
TKT-538 but was left behind when TKT-538 made `tasklist.update` one of
the six commands enforcing session ownership, leaving the file directly
self-contradicting a few paragraphs later. Documentation-only fix,
found during a standing documentation-gap hunt.

TKT-534: a tasklist card's inline text edit is a dynamic-sizing textarea
now, not a single-line input - it grows as multi-line text is typed
(Shift+Enter for a newline; plain Enter still saves, unchanged).
Pasting an image while editing attaches it through the same mechanism
drag-and-drop already uses (TKT-524) and inserts a `[image: filename]`
reference inline at the cursor. Michael, via screenshot: "Change it to
dynamic sizing textarea that support richtext and allow user copy and
paste images..." - Q-080 answered: embed inline, but the actual file is
an attachment, not raw base64 in the text field.

TKT-535: the Task List section's header now shows only Add and the
new-task text input - Unshift, Insert at position, Next, Shift, Pop,
Prune done, and Import from card were removed from the browser
entirely, per Michael's Q-081 answer ("We only need the add button and
a text input for new task"). Full CLI parity is unaffected: every
tasklist CLI command still works, only the browser buttons that
triggered them are gone. Found and fixed a genuine pre-existing bug
this exposed: the reconciliation that keeps an actively-edited card's
own DOM node stable across the section's 1-second auto-refresh could
still reposition (and blur) it whenever an earlier card was rebuilt in
the same tick, because a stale replaced node was never removed before
the reinsert pass ran.

TKT-536: the Policies dialog's "decline a rule" reason field uses an
inline capture now (input + Go, Enter submits, Escape cancels), reusing
the pattern TKT-530 built for the Task List section - this was the last
native `prompt()`/`alert()` left anywhere in the embedded dashboard JS.
The 5 `confirm()` calls TKT-530 judged and kept native are unaffected.

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
**Implemented.** `dashboard tira.comment.list --ref TKT-001 -o json` lists everything; `--last 1` is the newest comment alone, `--meta-only` returns ids, authors, stamps, body lengths, and attachment counts without a single body — exactly what a watcher needs before deciding to read. Each comment carries `body` alongside `text` since 3.81 — `comment.add` writes `--text`, and until then that was the one write/read field pair of four (gate, evidence, checklist, comment) where the names disagreed, so a caller reading a comment back with the name it was written under got a silent `None`. TKT-353.

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
**Implemented.** Re-adding identical bytes restores the shared SHA object after
a remove, which deleted the content. It does not undo a discard, which is
card-scoped and beats deduplication: re-adding content discarded on that card is
refused and says so, because an add that cannot take must not report success.

### UC-097: Add evidence
**Implemented.** `dashboard tira.evidence.add --ref TKT-001 --summary "CI" --uri https://ci.example.test/1 --file result.xml --author ada`.

### UC-098: Record, annotate, and cheaply re-read gates, evidence, and checklists
**Implemented.** Add a gate, then append a correction with `dashboard tira.gate.annotate --ref TKT-001 --id GATE-001 --note "Use local docs" --author ada`; evidence uses `tira.evidence.annotate` with `EVD-NNN`. Manage retained checklists with add, list, and update; there is no remove command. `dashboard tira.gate.list --ref TKT-001 --last 1 -o json` reads the newest gate entry at constant cost, and `--where result=fail --meta-only` lists every failure without the details text.

### UC-099: Search and correct migrations in bulk
**Implemented.** Repeat fields in one reviewable pass: `dashboard tira.search --text Jira --field description --field atdd -o json` and `dashboard tira.replace --pattern Jira --with Local --field description --field atdd --dry-run -o json`. Import preview `dashboard tira.import --file changes.json --dry-run -o json` returns `changes[]` entries containing `ref`, `field`, `before`, and `after`; omit dry-run only after reviewing every diff. An import change is keyed by its own record reference (`{"TKT-001": {...}}`), not a `--ref` flag - an empty or malformed key is refused naming the import's own key structure rather than the generic `--ref`-flag wording every other command shares, since `tira.import` has no such flag to point at. TKT-346.

### UC-100: Render dashboard
**Since 4.70 the dashboard renders through a View.** Dancer2 has a Template Toolkit engine configured and the page, the sign-in page and the card and column dialogs are templates under `lib/Tira/views`, alongside the stylesheet and seven scripts; `lib/Tira.pm` carries no page markup and no line in it exceeds 2,000 characters. The assets are read from disk and inlined at render, never linked, so the board still loads nothing from another host - the live page talks only to itself (polling its own data, fetching a record on demand, posting a move on a drag) and a table-mode board saved to a file makes no request at all. The distinction that matters is between where the bytes live and how they reach the browser. `INCLUDE_PATH` and the asset directory both resolve from the module's own location rather than the working directory, so an installed skill finds its templates wherever it is run from. The move was made in five slices, each proved byte-identical against the previous render.

**Implemented.** `dashboard tira.dashboard --type all` is the ref-only fast path; add `--title` for titles, `--include-discard` for archived cards, `-o json` for complete records, `-o table` for self-contained interactive HTML, or `-o browser` for the live Dancer2 view. Type-specific table/browser commands are `tira.dashboard.sow`, `.epic`, and `.ticket`.

### UC-101: Ask about a card without moving it
**Implemented.** An agent that cannot move a card can still ask about it: `dashboard tira.question.ask --ref TKT-001 --text "Which credentials should this use?"`. The reference alone names the board, so no board argument is needed. The question is answered by whoever owns the decision, and until it is, the card is waiting on them rather than on you. Replaces keeping open decisions in a file of your own.

### UC-106: Ask a question the owner can answer quickly
**Implemented.** Give the reason and the options with the question, not just the question: `dashboard tira.question.ask --ref TKT-001 --text "Which store should the importer write to?" --reason "Both are configured and the runbook names neither." --option "The staging bucket" --option "The live bucket" --option "Neither, block until told"`. Both are optional and a bare question still works, but an owner answering without them is composing an answer from nothing; with them he can reply "the staging one" in seconds. They render under the question in the human view and in the card's Questions section on the dashboard, where he can answer and mark without leaving the board.

### UC-130: Back the board up
**Implemented.** `dashboard tira.backup` **is the backup** - the one to run often, and the one `board-unbacked` is about. `dashboard tira.backup.export` and `dashboard tira.backup.import` are not: they move a board to another machine and receive it there, and day-to-day operation uses neither. Another project read export as the way to back a board up, which is the reading that loses work, because an export is a file somebody has to remember to make and a board with exports and no backups has nothing to restore from. `dashboard tira.backup` makes a commit in a git repository Tira manages inside the board's own storage, beside the project file. The board lives outside git by design, which is why one was destroyed on 11 August with nothing to restore from — every board has that hole until it is backed up. The repository is made the first time you back up, so nobody has to set anything up to obey a rule, and a board that never backs up has none: reading never makes one. It has no remote, because a board that lives on a filesystem should not need somebody else's machine to be backed up. Attachments are in it — a backup is everything or it is not a backup — and two things are left out: the lock file, because a restored lock is somebody else's half-finished write, and the sessions, because a session is the server side of somebody's sign-in and a restored one hands over an identity. Leaving the sessions out is also what makes `changed: 0` mean something: a session is rewritten whenever anybody uses the board, so while they were kept there was always something pending and two backups seconds apart both reported a change. What a board committed before 1.97 stays in its history — rewriting the history of a backup is a worse thing to own than the tidiness it would buy. Backing up an unchanged board is not an error: it says nothing had changed and names the backup that still stands, since a command that failed on a quiet afternoon would teach whoever reads the bridge to ignore it. The commit carries an identity given on the command rather than written into the repository, so it neither depends on your git being configured nor changes what it would do. Git is run from the command layer; the engine still invokes no shell or external process.

### UC-131: Get a board back after losing it
**Implemented.** `dashboard tira.backup.restore --yes` puts the board back to its last backup: the cards, the attachments and the reference counters as they were, with anything done since removed rather than merged. It is the only command in Tira that can lose work, so without `--yes` it does nothing but print what would be discarded, by name — counting them would tell nobody whether it matters. A board that has never been backed up is refused rather than reported as restored, and a restored board is still a working board: it can be added to and backed up again. This exists because a backup nobody has restored from is a directory, and the board destroyed on 11 August was in exactly that position the day before.

### UC-132: Keep a backup somewhere the board is not
**Implemented.** `dashboard tira.backup.export --file board.bundle` writes the board's whole history and every attachment into one file, and `dashboard tira.backup.import --file board.bundle` lays it out again where you tell it to. The repository a backup lives in sits inside the board's own storage, so it survives a bad edit and not a lost disk; a bundle is what leaves the machine. Import is how a board arrives somewhere, so it takes the folder you name rather than looking for one, and an imported board is a working board — it issues its own references and can be backed up again where it landed. Importing over a board that already exists replaces it, so without `--yes` it says what is there and does nothing. A bundle from a newer Tira is refused rather than half-restored, and nothing is written when it is: Tira has no migrations, an older board reads correctly because defaults are applied on read, and a newer one holds shapes these readers have never seen.

### UC-133: Report a fault in Tira from whatever you are working on
**Implemented.** `dashboard tira.dev.found.bug_or_improvement --from <your project> --title "<what you found>" --text "<what happened>"` raises the report where Tira is maintained. You do not say where that is and you are not told: the command carries it, so an agent that hits a fault while working on something else reports it in one command and gets back to work. Your own board is untouched. `--from` is required and becomes a label on the card, because a report nobody can go back to is one nobody can answer — and a question asked on that card reaches you through it. The card is raised in the backlog under the maintainer's name, since an agent in another project is not a member of that board, and where it goes from there is that board's decision. It arrives as an incomplete card on purpose: that board refuses a release while any live card is incomplete, so a report has to be triaged before the next one ships and cannot sit unread.

```text
tira.dev.found.bug_or_improvement --from PROJECT --title TEXT [--text TEXT] [-o toon|json|human]
```

### UC-134: See what police has said about a card, on the card
**Implemented.** Open a card on the live dashboard and a **What police has said** section shows its enforcement log: when, what kind of thing it was, and what was said — with the number of entries in the heading. It is read for the card the dialog is open on, and it offers nothing to change, because police writes that log and nobody else may; there is no command to add an entry either, and a button here would have been the way around that. A card police has never mentioned shows no section at all rather than an empty heading, since a heading on every card is how a section teaches people to skip past it. This exists because the log was kept and never surfaced: it is there precisely so what police said survives the bridge scrolling past, and until now the surviving copy was readable only by an agent running a command.

Both this section and the work log are a fixed-width-columns-plus-detail grid, and until TKT-469 a narrow-screen override meant to collapse them to one readable column was declared *before* the unconditional base rule that set the wide desktop widths - same specificity, later source wins, so the override never actually applied at any viewport width. The detail column stayed squeezed to a sliver (or, for the work log's extra "who" column, near zero) on a phone regardless of screen size. Fixed by moving the override after both base rules so it wins when its media query matches. TKT-469.

### UC-135: Order a column by what matters most
**Implemented.** Every column can be ordered three ways, and the third is priority: highest first, because the question a column answers is what to pick up next. A card nobody has prioritised goes last and says so rather than pretending to a number — an unprioritised card is unassessed, not lowest. The priority travels in the refresh payload as well as the first render, so the ordering still holds after the board rebuilds itself a minute later. Each board has its own sorter and sorts itself; the mode is shared, so the next refresh brings the others into line.

### UC-136: Quiet one rule without going deaf
**Implemented.** `dashboard tira.rule.suspend --rule card-full-details --seconds 300 --reason "rewriting this card"` puts one rule down for a period; adding `--ref TKT-001` puts it down for that card alone. Every other rule keeps watching, and the same rule keeps watching every other card — which is the grain that matters, because a card being worked hard collects comments faster than anybody can fold them and silencing the whole bridge to get through that afternoon would make the escape hatch worse than the noise. A reason is required and a length is required: it comes back by itself, so there is nothing to remember to switch on again, and every putting-down is in the enforcement log with its rule, its card, its length and its reason - as structured fields since 3.46, not only inside the prose sentence, so suspensions can be counted and grouped by rule without a regex; an entry written before 3.46 carries no fields key and still reads back. TKT-348. A silence nobody can account for is worse than the noise it replaces. Adding `--pid 12345` ties the suspension to a running process instead of only the clock: it lifts the moment that process is gone, before `--seconds` would have said so, with a higher 1800s ceiling as a backstop rather than the clock-only form's 600s — long enough to cover this repo's own gates (coverage 846s, and the push gate at 15m+ before 4.62 took the suite out of it), which the clock-only ceiling was not. TKT-361.

### UC-129: Serve the board over HTTPS
**Implemented.** `dashboard tira.dashboard -o browser --ssl` serves the board over HTTPS with its own certificate, made the first time and reused afterwards. Over plain HTTP a password typed into the login page and the session cookie that follows it both travel in clear — and if sessions never expire, that cookie is a credential with no end date. The certificate is made by a library rather than by running `openssl`, because Tira invokes no shell or external process; it lives beside the project rather than inside a board, and its key is readable by nobody else. It is self-signed, so a browser warns the first time and you accept it once: that stops somebody reading your password off the wire, and does not stop somebody who can already stand between you and the machine. The board says both of those on the terminal it starts from.

### UC-128: Take an attachment off a card without losing it
**Implemented.** `dashboard tira.attachment.discard --ref TKT-001 --sha SHA256` sets an attachment aside rather than deleting it. The reference stays on the card stamped with when and by whom, the browser draws it struck through and greyed like every other discarded thing, and the work log carries the event — read off the card by the engine, so it cannot be forgotten and cannot be written by hand. The stored file is untouched even when that was the last reference to it: the bytes are shared by content hash and are not one card's to destroy. Discarding one twice is refused rather than restamped, because the first stamp is the record somebody is relying on. `tira.attachment.remove` still deletes, for when the file itself has to go.

### UC-127: Leave the board open all day without signing in again
**Implemented.** `dashboard tira.dashboard -o browser --no-session-expire` serves a board whose sign-in lasts until somebody signs out. By default a session ends after ten minutes of inactivity, and the board's own refresh does not count as activity — it reads a session without extending it — so a board you are watching expires exactly as fast as one nobody is looking at, and every refresh after that is refused. That default is right on a shared machine and wrong for a board you read from a phone instead of asking for progress, so it is a choice you make rather than a behaviour that changes. The board tells you on the terminal it starts from that sessions never expire, and what that costs: over plain HTTP the cookie is a credential with no end date.

### UC-126: Make search faster without letting it lie
**Implemented.** `dashboard tira.search.index` builds a search index for the project, and searching gets faster because a card whose text cannot match is skipped without being parsed — parsing is what reading a board actually costs. The index is keyed by the content of the file it describes, so a row can only ever describe the exact bytes on disk: edit a card behind Tira's back and search follows the file, not the index. Corrupt it, delete it, or restore an old copy over it and search reads the files, which is what it did before any index existed. Ordinary work keeps it current — a card you create or edit updates its own row — and rebuilding it is throwing it away and running the command again, because nothing is in it that did not come from the files. A project that never runs the command has no index, and pays nothing for it.

### UC-125: Say which column is which, so a rule survives a rename
**Implemented.** `dashboard tira.column.roles --type ticket --role in-progress=implement --role done=archived` says what each column means, and `dashboard tira.column.roles` on its own reads back what every board says, because the question has an answer for each of them and there is no reason to make you name one to ask it. A policy written against a role follows the meaning rather than the name, so renaming the column does not quietly stop the rule protecting anything. The vocabulary is yours — Tira matches a role without needing to understand it — and every role is optional, because most projects have a column for very few of them. A role naming a column that does not exist is refused, since a role pointing at nothing makes every rule written against it match nothing at all, silently. A role declared by mistake can be taken back with `--remove-role`, which needs a reason and writes down who removed it and why — unless a policy names the role, in which case the refusal says which policy, because the same silence would follow from the other direction.

### UC-124: Let the agent be told when it stops keeping the board honest
**Implemented.** The agent runs `dashboard tira.policy.bridge` and leaves it running. Police writes one line per violation, carrying the issue number, how loudly it is being said, the card, what is wrong, and the command that fixes it. When it starts, one line introduces whatever is outstanding — how many there are and the span they were raised over — so a pile of old lines about cards that have moved on cannot be read as a storm of new ones; the lines themselves are unchanged, because an agent parses them. When a violation stops being true, one more line says so — marked `SETTLED`, carrying the same issue number, addressed to the same reader, and said once — so a reader replaying a backlog after a restart sees the demand and its end together rather than being sent after work that is already done. The line that raised it stays where it is: the log is a record, and rewriting it would be worse than leaving it. Nothing else arrives when nothing is wrong — silence is the signal, because a channel that announces all-clear every thirty seconds is one you stop reading. A policy set without the bridge running is worse than none at all, because it looks like cover.

### UC-123: Watch a project without ever touching it
**Implemented.** The owner runs `dashboard tira.police` in a terminal he leaves open. It reads the board and reports; it never writes to it. With no policies set it exits and prints what to paste to the agent rather than running and guarding nothing. Every violation keeps one issue number and climbs four tones as it persists, so one lasting problem reads as one problem getting louder rather than as noise repeating; past five tellings it appears in his own terminal, naming who to hand it to - the agent holding that card, or the core agent when nobody holds it - and the command to hand them. A problem is said once when it is found and then not again until there has been time to act on it - five minutes, then fifteen, then thirty, then an hour - so the channel stays worth reading; a fixed cause silences it on the very next pass, with nothing to acknowledge and nothing to clear by hand.

`dashboard tira.police.outstanding` answers what is still true as of the last pass - one line per finding, not the comma-joined single row a plain array of prose used to render as until 3.79. `--by-rule` groups the same findings by rule instead of by chased/log-only, each card listed once per rule even when two policies for the same rule both matched it, with the rules worth acting on sorting before the ones the board only logs. `-o json` stays the bare list the clear-violations loop pipes either way. TKT-291.

### UC-122: Declare what this project actually cares about
**Implemented.** `dashboard tira.policy.add --rule card-full-details --enter implement --action bridge-reminder` tells police what to watch for. 40 rules cover a card that left the backlog as a title, a card being worked with no agent_session recorded - a different question from an unassigned card: assignee says who owns the work, agent_session says whether the worker can be reached again, and an agent whose spawn handle was never written down is silently re-forked on resume rather than continued, discarding everything it had already learned - TKT-332, an agent that has stopped while the board stays busy with other projects' reports, a card the owner changed in the browser while the agent worked from the command line, a card nothing has happened to for too long wherever it is sitting - each column setting its own limit with `tira.column.update --notify-after`, or none at all, with the finding naming which of the two set the limit that fired ("this column allows 2h (unit-test notify_after)" versus "the policy allows 6h (no column limit set)"), since elapsed time alone read as though it were the threshold too - TKT-290, a rule this board has neither declared nor declined after an upgrade, a column work happens in that no column-scoped policy mentions at all - which is what adding a column does to policies that were complete when they were written, a bridge police has been writing to that nobody has read, a whole board where nothing has moved for as long as the agent said, a card set aside while it still carries a question nobody answered, a card worked while a higher-priority card of the same kind waits untouched, a card that arrived somewhere without passing through the steps the board defines, a checklist finished while the column says otherwise, a card talked about since it was last written down, too many things being worked at once - counted per record kind (sow/epic/ticket) since 3.42, so an epic sitting In Progress as the permission state for its children does not consume a ticket's budget by existing, and the finding names which kind is over - TKT-333, work in progress with nobody on it - a board with more than one finished column marks each of them with `--terminal` and the rule asks, because protected says Tira owns a column rather than that work stops there, an answer the agent waiting on it has not read yet, a question answered and never acted on, a parent in done above a child that is not, a commit naming no card, a card moved on with nothing ticked since its last move, a task whose status contradicts the column its linked card sits in - three directions from one comparison, plus a card carrying the same note twice, with the columns that mean work declared by `--column` - a name or a comma-separated list, and several policies compose into one set - rather than inferred, because the hand-run check this replaced counted the queue column as work and seven of its eight findings were false for that one line - TKT-639, and a test container nobody stopped. Six of them read the machine rather than the board - leftover processes and containers, commits, unpushed work, a tree changing with nothing on the board, and how long since the last backup. Tira still invokes no shell: the police command gathers those facts and hands them over, every pass, and a program that is not installed simply contributes nothing. Anything a rule cannot work without is refused when the policy is set, rather than discovered later - naming every missing option in one refusal, not the first alone, and pointing at `tira.policies` for the complete catalogue: declaring `card-metrics` (needs `--enter` and `--require`) with neither used to cost three attempts to discover fully, one option named per refusal. TKT-289. Declaring it on a card beats declaring it on the column, which beats the board, which beats the project — per rule, so one exception cannot switch the rest off. `dashboard tira.policies` prints the whole guide with a hundred worked examples. `dashboard tira.policy.review` prints the whole set in one place - every rule either declared with the columns it covers, declined with the reason, or unanswered - for the review somebody does behind the agent, where the question is what the set adds up to rather than what one policy says. `dashboard tira.policy.undeclared` answers the narrower question of which rules this project has neither declared nor declined — the agent is the only party that can declare one, and police prints that list for the owner rather than for it, once, when it starts. A rule that was declined is answered and does not appear; a project that has decided all of them gets an empty list.

`dashboard tira.card.holes` asks a related but different question: not what police is watching for, but which live cards on the board right now are missing required fields — a title moving between columns with nothing behind it. `tools/card-holes` already answered this from the pre-push hook, but only against the cards a push happened to be about, so a card left untouched in the backlog stayed unblocked indefinitely; measured live, 26 of 300 cards were missing both `problem_or_feature` and `solution_needed`, 24 of them still open with no push ever having named them. `tira.card.holes` reads the exact same definition `card_missing`/the push gate uses, so the two can never disagree, excludes discarded cards, and exempts an untriaged `tira.dev.found.bug_or_improvement` report still sitting in the entry column — filing a quick report stays as easy as it always was. It reports and refuses nothing. TKT-374.

### UC-121: Know who is looking at the board
**Implemented.** The browser dashboard is behind a login. A person claims a password the first time they use it — whatever they type becomes theirs — and must match it afterwards. Only a salted, iterated digest is stored, never the password. Anybody whose name or id contains "bot" cannot sign in at all, because machines drive the board through the command line. Every route is behind the gate: an unknown visitor gets the login page and nothing else.

### UC-120: Stay signed in while you are working, and not a minute after
**Implemented.** A session lives in a cookie for ten minutes from the last thing you did, not from when you signed in, so an afternoon of work is never interrupted. The board's own background refresh reads your session without extending it — a tab left open overnight does not keep itself signed in. Sessions survive Tira being upgraded, so shipping a new version does not sign everybody out.

### UC-119: Get back in when you have forgotten your password
**Implemented.** There is no reset command, deliberately: anything that resets a password from outside is a way in. Delete that person's `password` block from the project file by hand and they are unregistered again, so the next sign-in claims a new one. Over plain HTTP the password and the cookie travel in clear — this login is good against somebody wandering past an open board, not against somebody watching the network, and there is no lockout on repeated guesses.

### UC-118: See where discarded work went
**Implemented.** A board somebody is looking at — `-o table` or `-o browser` — shows the Discard column alongside the live ones, faded and marked as set aside so it reads as an archive rather than as more work outstanding. Discarding a card no longer makes it vanish from the only view most people use. The ref-only listing an agent queries still leaves it out, because that path exists to be cheap; `--include-discard` forces it either way, and machine formats are unchanged unless asked.

### UC-117: Show your working when you ask, and when you answer
**Implemented.** Hang evidence on a question with `dashboard tira.question.attach --id Q-007 --file /tmp/screen.png`, and answer with evidence in one action using `dashboard tira.question.answer --id Q-007 --text "That one." --file /tmp/proof.pdf`. Both belong to the question: `dashboard tira.attachment.list --ref TKT-001 --question Q-007 -o json` returns what you asked with and what came back together, because somebody reading a question wants everything bearing on it. Naming no question lists every file on the card, each saying where it hangs. Fetching needs only the reference — no card, no question, nothing to choose.

### UC-116: Read a card's questions in the order they need you
**Implemented.** The Questions panel puts what still needs doing first: unanswered, then answered but not yet judged, then judged, then set aside. A question you have already marked collapses to its question, its answer and a tick or a cross — everything else is only in the way once it is settled — so a card with a long history stays readable.

### UC-115: Find every file on a card, wherever it is attached
**Implemented.** `dashboard tira.attachment.list --ref TKT-001 -o json` counts and lists every file belonging to the card: attached to the card itself, to one of its comments, or recorded as a voice note on one of its questions. Each entry says which in `attached_to`. A zero means there is genuinely nothing there — it used to mean nothing on the card itself, which read as failure when the files were one level down.

### UC-114: Be told what a new ticket still owes
**Implemented.** Creating a record hands back a `reminder` in the same terse line: `missing: description,reporter,gate,questions(if unclear) | fix: tira.ticket.update --ref TKT-001 --description TEXT --reporter NAME; …`. A title alone is not a ticket. The reporter is whoever asked for it — name the owner if he did, name yourself if you found the bug or the enhancement. A gate records how the work will be judged. And a question is offered because guessing at something unclear is the expensive mistake, not because every ticket needs one. Fields that share a command share one, the fix names the board the record lives on, and a record that owes nothing says nothing.

### UC-112: Let the owner hear the question instead of reading it
**Implemented.** Record the question, its reason and its choices, and attach the audio: `dashboard tira.question.ask --ref TKT-001 --text "..." --reason "..." --option A --option B --voice /tmp/question.ogg`, or `dashboard tira.question.voice --id Q-007 --file /tmp/question.ogg` afterwards. `--remove` takes a wrong recording off. **Tira does not make the recording** — it runs no external process, so you record it and Tira keeps it, in the ordinary attachment store where the same recording on ten questions is one file. The board shows a play control on the question.

### UC-113: Be told what a question still owes
**Implemented.** You will not be left to remember any of this. A question missing its reason, its choices or its recording carries a `reminder` in the response to whatever you just did — one terse line naming every gap at once and the commands that close them, references filled in: `missing: reason,options,voice | fix: tira.question.update --id Q-007 --reason TEXT --option TEXT --option TEXT --voice FILE`. It is written for you to act on, not for a person to read, so it is short, and the fix is always **one** command — `question.update` takes the recording too, so settling three gaps never costs three commands. Change the wording, the reason or the choices and it reports `voice(stale)` until you re-record. A question that owes nothing says nothing: a reminder that is always there is furniture.

### UC-111: Leave a board open across an update
**Implemented.** A live dashboard picks up a new Tira without anyone restarting it by hand - but the shipped board never does so by restarting itself. `tira.dashboard -o browser` always runs under Starman with a worker pool, so the process that notices a new version is always a worker, and a worker can never replace the board. Nor can the master do it on its own account: it owns the listening socket and never serves a request, so nothing inside the board is both able to notice a new version and able to act on it - the signal has to come from outside. What actually picks a release up is **police** (TKT-565), which runs on a schedule, is not a worker, and owns no socket: it finds the process holding the board's port - asked of the kernel rather than of a pidfile, which goes stale and can name a reused pid - and sends that master a `HUP` once the code on disk has genuinely moved. Starman re-forks its workers, and because Tira serves a `.psgi` file path rather than an in-memory coderef, each new worker re-reads the modules from disk and comes up on the installed version, finishing any request it is holding first. It signals once per release, not once per pass, and every uncertainty refuses and names itself - no board on the port, a process it cannot confirm is a Starman (TKT-566: `SIGHUP` defaults to Term, so signalling a process with no handler kills it; police reads the command line first, and checks for a Starman rather than for this board because Starman rewrites `$0` so a live master reads only `starman master`), an unreadable installed version, no known port, a version already signalled about - because a board on slightly old code still works. The in-process self-restart below remains correct for a server that owns its own socket, just not for the shipped one: the server notices the code on disk is no longer the code it is running, re-executes itself into it with the same arguments and the same port, and the page reloads once it sees a version it was not built by. The reload waits until the new code is actually serving, so it never just fetches the old page again; a version it cannot read is treated as no change, and so is one that differs only in a label, because re-executing into the same code and disagreeing again is a loop rather than an upgrade. **Only the process that launched a board may replace it.** A board answering requests in a worker cannot: the master owns the listening socket, so a worker that re-executed would fail to bind the port and die, losing that request and every later one. Such a board keeps working and says what it cannot do - the page shows the installed version and asks for a restart, beside where it says when it last updated.

### UC-110: See only the questions waiting on you
**Implemented.** The **Questions to answer** toggle on a board control narrows it to the cards nobody has answered yet — the yellow ones, the owner's own queue. It sits beside **Answers to review**, which is the agent's. Both start off and are independent: turning one on never switches the other off, and with both on you see every card that still has something open. Switch both off to get the whole board back.

### UC-109: Find the answers you have not judged yet
**Implemented.** On the live dashboard, the **Answers to review** toggle in a board control narrows it to exactly the **greyed-out** cards: every question answered, at least one answer not yet ticked or crossed. It starts off, so the board shows all the work until you narrow it, and switching it off restores everything. Yellow cards are left out on purpose — those are questions the owner has not answered, so they are his move, not yours. Marking an answer either way clears the card, because a cross is a judgement too.

### UC-108: Take an old crammed question apart
**Implemented.** A question asked before reason and choices existed has all three squeezed into its text, and those are exactly the ones that most need splitting. Revisit it and decompose it: `dashboard tira.question.update --id Q-007 --text "Which store should this write to?" --reason "Both are configured and the runbook names neither." --option Staging --option Live` does it in one command, or set one piece at a time as you work it out — **only what you name changes**, so a reason on its own leaves the question and the choices untouched. An explicitly empty value clears that piece if you decide it was wrong. The question keeps its reference and its original time, so anybody who quoted it is not stranded.

### UC-107: Answer a question from the board in one click
**Implemented.** Open the card on the live dashboard and its **Questions** section shows each question, its choices, why it was asked, its status (`new`, `answered` or `discarded`) and its answer. Click a choice and that is the answer — no typing. Use **Other…** to write something else, or edit an answer already given and save it. Mark it as settling the matter or not from the same place. A discarded question stays visible, struck through, because it still happened. Every action there runs the same engine subroutine as the matching command, so answering from the board has exactly the consequences answering from a terminal does: the card stops waiting, the reminder clock restarts from your answer, and the agent is told the card is back with it.

### UC-102: Read the answers, and say whether they settle it
**Implemented.** `dashboard tira.question.list --ref TKT-001 -o json` returns every question with its answer underneath, and reading them is what marks them read — you do nothing extra. Each list carries an `instruction` naming your next step. If an answer settles the matter, `dashboard tira.question.mark --id Q-007 --mark ok`. If it does not, mark it `not-ok` **and** ask a new one: a cross on its own settles nothing, and there are no follow-up threads. A card's own `tira.<type>.show` embeds the same questions, and since 3.41 each carries the same `status` (`new`, `answered` or `discarded`) this command reports — until then the embedded shape had no `status` key at all, so a discarded question and a live one were distinguishable only by `discarded_at`. TKT-322.

Reading is what marks an answer read, which used to make checking whether an answer had been read the same act as reading it — a manager routing work down a chain who opened a question to route it consumed the one detector whose entire job was to send that particular agent there, and could never fire for that question again. `--peek` (3.43) inspects without reading: `dashboard tira.question.list --ref TKT-001 --peek -o json` returns metadata only — `id`, `status`, `answered_at`, `read_at`, `mark` — never the answer text, reason, or options, and does not itself mark anything read. Refused on every other `question.*` command. TKT-336.

### UC-105: See at a glance whose move a card is waiting on
**Implemented.** On the HTML and live dashboards a card's appearance says **whose turn it is**, not merely that somebody is waiting. **Yellow** means a question nobody has answered: the owner owes the next move, and it is the only thing on the board competing for his attention. **Greyed out** means every question has been answered and at least one has not been ticked or crossed: it is off his plate and with the agent. A card is never both, so the board never says two people owe the same thing at once, and it returns to its ordinary appearance when every question is settled — discarded, or answered and marked. Knowing this means reading the card, so the colour appears wherever a person is looking at a board (`-o table`, `-o browser`, `-o json`, or with `--title`); the ref-only fast path still opens no files and stays as cheap as it was.

`tira.question.mark/answer/update/discard` take the question's own id via
`--id` - never `--ref`, which is optional and only narrows which card the id
is expected to belong to. Omitting `--id` refuses with "A question id is
required", naming `--id` specifically rather than the generic word
"reference" this project uses for both a question's own id and a card's -
that overlap once produced the identical refusal for "nothing was given" and
"a question id was given as `--ref` by mistake", which could not be told
apart from the message alone. The second case is now named distinctly:
`--ref Q-007` (a question id, not a card reference) with `--id` left out says
so directly, naming what was given and pointing at `--id` instead. A `--ref`
that genuinely names a different real card than the question's own is
unaffected - the existing "Question X is on Y, not on Z" message already
told the two apart. TKT-412.

### UC-104: Find the card a question was asked on
**Implemented.** A question reference belongs to the project, not to a board, so quoting it is enough: `dashboard tira.search --text Q-007 -o json` returns the card it lives on whichever board that is. `--text` searches the whole card, not the front of it: the title and description, the problem statement, what a solution needs, the key details, deliverables, acceptance criteria, test steps, behaviour and scope, the labels, the checklist, the required items and the column each is tagged with, the comments, the gate records, the evidence, the conversation and the names of attached files. The gates and the evidence matter most on a finished card - they are append-only observations, so they carry what was measured rather than what was believed at planning, which is exactly when somebody comes looking. A project once published that a figure appeared nowhere on a card when it had been in that card's gate records the whole time; an absence proven by an instrument that cannot see most of the record is not an absence. Search also matches the words in a question and the words in its answer, so `--text credentials` finds the card somebody asked about credentials on. A discarded question is still found, because it still happened. On the dashboard the keyword box does the same thing across all three boards at once — typing a question reference on one board empties it and shows the card on the board that owns it.

### UC-103: Catch up on what changed without re-reading everything
**Implemented.** Set a question aside with `dashboard tira.question.discard --id Q-007` when it stops mattering — nothing is deleted, it keeps its answer and shows struck through. `dashboard tira.question.list --ref TKT-001 --status new -o json` shows only what is still unanswered; `--status answered` only what has been answered, and `--status discarded` what was set aside. `--since 2026-08-09T09:00:00Z` reads the answer's stamp when there is an answer and the question's when there is not, so a newly answered question shows up as newly changed. A question reference is project-wide, so `--id Q-007` reaches it from anywhere without naming the card.

## Safety contract

Tira validates and untaints canonical paths, references, prefixes, digits,
column slugs, link names, and hashes before filesystem use. It invokes no shell.
Records are discarded, never deleted. Attachment removal is the sole physical
deletion workflow and is permanently logged. Raw attachment output may disrupt
a terminal by design; redirect it.

This catalogue is the normative implemented interface. Use commands exclusively
and never emulate them through manual managed-storage edits.
