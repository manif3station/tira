# Complete Command Ecosystem

This is the reference: every command and argument, what it is for and when to
use it. For the use cases — the workflows these commands serve, and which one
to reach for — run `dashboard tira.skills`.

Release 0.16 implements every workflow in `SKILLS.md` through 83 Developer
Dashboard entrypoints. The shared `Tira::CLI` parser applies TOON-first output,
pretty JSON, Markdown, repeatable options, JSON-array replacement, raw
attachment output, and consistent structured failures.

## Questions on cards

An agent working a card often cannot move it but can ask about a procedure or
a detail. These commands replace the open-decision file each agent used to keep
in its own format.

**References.** Every question reference is project-wide with a `Q` prefix, on
one sequence across all three boards, so `Q-007` reaches a question without
naming the card it was asked on. Cards are addressed by their own reference
alone (`--ref TKT-001`) — the reference names the board through its prefix, and
prefixes cannot collide inside a project, so there is never a board argument.

**Statuses.** `new` (no answer), `answered` (has one), `discarded` (set aside).
Derived from the facts rather than stored, so a status cannot drift from what
is actually there. There is no follow-up status: pressing further is a new
question.

### `tira.question.ask`

Ask about a card.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The card to ask about, e.g. `TKT-001`. No board argument. |
| `--text TEXT` | yes | The question itself. Keep it to the question. |
| `--reason TEXT` | no | Why you are asking: what you are blocked on, what you already tried. |
| `--option TEXT` | no | One choice you can see. **Repeat it** for each. On the dashboard these become buttons the owner clicks. |
| `--author WHO` | no | Who is asking. |
| `-o FORMAT` | no | `toon` (default), `json`, `json-pretty`, `human`. |

Both `--reason` and `--option` are optional, but an owner answering a question
with neither is composing an answer from nothing. With them he can pick a
choice in one click.

### `tira.question.list`

List the questions on a card, with their answers underneath. **Reading is what
marks the answers read** — you do nothing extra, and the owner can see they
were seen. Writes only when there is something to mark. Every list carries an
`instruction` naming your next step.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The card whose questions to list. |
| `--status STATUS` | no | Only `new`, only `answered`, or only `discarded`. |
| `--since STAMP` | no | Only what has changed since then. Reads the **answer's** stamp when there is an answer and the question's when there is not, so a newly answered question shows as newly changed. |
| `-o FORMAT` | no | As above. `human` renders each question, its reason, its numbered choices and its answer. |

### `tira.question.answer`

Answer a question, or reword an answer already given.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. Project-wide, so the card need not be named. |
| `--text TEXT` | yes | The answer, in your own words. |
| `--author WHO` | no | Who answered. |
| `-o FORMAT` | no | As above. |

Answering the first time stamps `answered_at`; answering again stamps
`updated_at` and leaves the first stamp alone. The question keeps the time it
was asked, always.

### `tira.question.update`

Reword a question, or **take a crammed one apart**. Questions asked before
`--reason` and `--option` existed have all three in the text; give all three
here to split them in one command, or one at a time as you work them out.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. |
| `--text TEXT` | one of these four | The question itself. |
| `--reason TEXT` | one of these four | Why it is being asked. |
| `--option TEXT` | one of these four | A choice; repeat for each. |
| `--voice FILE` | one of these four | A recording, replacing any the change just made stale. Everything a question owes can therefore be settled in one command. |
| `-o FORMAT` | no | As above. |

**Only what you name changes.** A reason on its own leaves the text and the
choices alone. An explicitly empty `--reason` clears it; `--option ""` alone
clears the choices. The question keeps its reference and its original time, so
anybody quoting it is not stranded. Naming none of the three is refused.

### `tira.question.attach`

Hang evidence on a question, or on its answer: a screenshot, a log, whatever
makes the question answerable.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. |
| `--file FILE` | to attach | A local path. Any kind of file. |
| `--to answer` | no | Attach to the answer rather than the question. Refused before there is an answer. |
| `--filename NAME` with `--remove` | to remove | Take one off by its name. |
| `-o FORMAT` | no | As above. |

`tira.question.answer --file FILE` attaches while answering, so answering and
showing your working are one action. The same file attached twice is one
reference, not two rows saying the same thing.

### `tira.question.voice`

Attach a recording of the question, so it can be played from the board rather
than read. **Tira does not make the recording** — it runs no external process,
which is the rule that lets it be trusted inside another tool. You record it,
Tira keeps it and serves it.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. |
| `--file FILE` | one of these two | A local path to the recording. `mp3`, `wav`, `m4a`, `ogg`, `oga`, `opus` or `flac`. `--voice` is accepted as well. |
| `--remove` | one of these two | Take the recording off, for when it is simply wrong. |
| `-o FORMAT` | no | As above. |

`tira.question.ask --voice FILE` attaches one in the same breath as asking. The
recording is copied into the project's ordinary attachment store and
deduplicated there, so the same recording on ten questions is one file. A
recording is never deleted when it is replaced, because another question may be
pointing at it.

### `tira.question.mark`

Say whether an answer settles the matter. Separate from having read it: reading
is not agreeing.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. |
| `--mark MARK` | yes | `ok` or `not-ok`, and nothing else. |
| `-o FORMAT` | no | As above. |

**A cross settles nothing on its own.** If an answer does not do it, mark it
`not-ok` *and* ask a new question. An unanswered question cannot be marked.

### `tira.question.discard`

Set a question aside.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id Q-NNN` | yes | The question. |
| `-o FORMAT` | no | As above. |

Nothing in Tira is ever really deleted: the question stays, its answer stays
underneath it, its status becomes `discarded`, and the board draws it struck
through. Discarding twice is refused, and a discarded question cannot be
answered.

### Reminders you will be given

A question that still owes something carries a `reminder` in the response to
whatever you just did — asking, updating, answering, marking or listing. It is
one terse line, written for the agent reading it rather than for a person:

    missing: reason,options,voice | fix: tira.question.update --id Q-007 --reason TEXT --option TEXT --option TEXT --voice FILE

`missing` names the gaps: `reason` (whoever answers has to guess what you are
blocked on), `options` (without them the owner composes an answer instead of
picking one), `voice` or `voice(stale)` (no recording, or one made before the
question last changed and so reading an older wording). `fix` is **one
command**, references filled in, that settles all of them — `question.update`
takes the recording too, precisely so this never needs to be two.

A question that owes nothing carries no reminder at all. One that is always
there is furniture, and gets ignored like furniture.

### The Discard column

Every board is created with a Backlog and a Discard. A board rendered for a
person — `-o table` or `-o browser` — shows Discard among the columns, faded
and marked as set aside, so discarded work is visible as an archive rather than
disappearing. The ref-only listing an agent queries leaves it out by default,
since that path exists to be cheap. `--include-discard` forces it on any
format, and the machine formats are otherwise unchanged.

### Where a card's files actually live

`tira.attachment.list --ref TKT-001` counts every file on the card, wherever it
is attached: to the card, to a comment, to a question, or to a question's
answer. Each entry carries `attached_to` saying which. A count of zero
therefore means there is genuinely nothing, rather than nothing in the first of
several places.

Add `--question Q-007` to narrow it to one question — its own evidence and the
evidence that came back with its answer, together, because somebody reading a
question wants everything bearing on it. Repeat the flag for several. Naming
none shows the lot.

Fetching needs only the reference: `tira.attachment.get --sha SHA --extension
EXT` takes no card and no question, because a reference already identifies the
file.

### Reminders on a new record

Creating a record returns a `reminder` in the same terse form, naming what it
still owes and the commands that settle it:

    missing: description,reporter,gate,questions(if unclear) | fix: tira.ticket.update --ref TKT-001 --description TEXT --reporter NAME; tira.gate.add --ref TKT-001 --gate NAME --result pass --details TEXT; tira.question.ask --ref TKT-001 --text TEXT --reason TEXT --option TEXT

- **description** — a title alone is not a ticket.
- **reporter** — whoever asked for it. If the owner did, name the owner; if you
  found the bug, the gap or the enhancement yourself, name yourself.
- **gate** — a ticket with no gate has recorded nothing about how it will be
  judged.
- **questions(if unclear)** — not a defect, and most tickets need none. It is
  there because guessing at something unclear is the expensive mistake, and an
  agent never told it may ask will not ask.

Fields that share a command share one, and the fix names the board the record
actually lives on. A record that owes nothing carries no reminder.

### What questions do to the rest of Tira

- **A card with an unanswered question is not chased.** While it waits it is in
  the owner's hands, not the agent's, so the stale-card reminder leaves it
  alone however long it sits.
- **Answering the last one restarts the clock from that answer**, not from the
  move that put the card in its column, and escalation restarts at level one —
  the agent was blocked, not idle.
- **An all-clear** then tells the agent every question is answered and the card
  is back with it, once per round of questions.
- **The card's appearance says whose move it is.** Yellow: a question nobody
  has answered, so the owner owes the next move. Greyed out: everything
  answered and something not yet ticked or crossed, so it is with the agent and
  off the owner's plate. Never both at once, and ordinary once every question
  is settled.
- **Search matches** question text, answer text and question references, so
  `tira.search --text Q-007` finds the card it lives on.

### Finding the work that is yours

A board control carries two toggles, one for each side of a question:

- **Questions to answer** — the cards nobody has answered yet. The owner's
  queue: these are the yellow ones.
- **Answers to review** — every question answered, at least one not yet ticked
  or crossed. The agent's queue: these are the greyed-out ones.

Both start off, so a board shows all the work until somebody narrows it. They
are independent, so turning one on never silently turns the other off: with
both on you get every card that still has something open, which is the third
useful view rather than an accident.

These are exactly the **greyed-out** cards: everything answered, something
still unjudged. Yellow cards — questions the owner has not answered — are his
move, not yours, so the toggle leaves them out rather than making you scroll
past work you cannot act on. A mark of either kind clears a card from the list,
since a cross is a judgement too, and a discarded question needs none.

### Leaving a board open across an update

A live dashboard (`-o browser`) keeps working when Tira is updated underneath
it. The running server notices that the installed version no longer matches the
one it started with, re-executes itself into the new code with the same
arguments and on the same port, and the page reloads once it sees a version it
was not built by. Nothing has to be restarted by hand, however many boards are
open.

The page reloads only after the new code is genuinely serving, so it can never
fetch the old page again; the cost is one skipped refresh cycle. A version that
cannot be read is treated as no change, so an unreadable install never puts a
board into a restart loop.

The restart works out its own entrypoint from the command it is running, and
passes the project explicitly, so it does not depend on how the board was
launched or on what the new process inherits. If it cannot find a valid
entrypoint it does not restart at all: running slightly old code is better than
not running.

### On the dashboard

A card's dialog carries a **Questions** section, placed directly after the
card's details rather than at the bottom: it is the part that needs an answer,
so it should not be the part you scroll furthest to reach.

They are ordered by what still needs doing — unanswered first, then answered
but not yet judged, then judged, then set aside. A question that has been
marked collapses to its question, its answer and a tick or a cross, since
everything else is only in the way once it is settled.

An open question shows five
things: the question, its choices, why it was asked, its status, and its
answer. A choice is a button — clicking one answers with it, and the text box
stays hidden until **Other…** is chosen. An answer already given can be edited
and saved there, and marked as settling the matter or not.

Everything done on the dashboard runs the same engine subroutine as the
matching command. The interface differs; the behaviour does not, so no
consequence of an action is skipped by taking one route rather than the other.

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

Prompted answers are editable at a terminal — Ctrl-A, Ctrl-E, Ctrl-U, Ctrl-K,
arrows, Home and End — written directly against core POSIX termios, because no
`Term::ReadLine` editing implementation is installed on the host or in the test
image and depending on one would have delivered nothing. Away from a terminal
the prompt falls back to a plain read. A leading `~` expands to the user's home
directory wherever a path is accepted, including at a prompt and inside a
quoted `--dir`, where a shell would not have expanded it.

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

`tira.stale` answers how long each card has sat in the column it is in now,
reading each card's history backwards and stopping at its most recent column
move. Cards whose entry predates the history are reported without a duration
rather than with an invented one, so they never appear in an `--older-than`
result. One pass over the boards costs a few milliseconds; asking per card
through the API or the CLI costs a hundred to a thousand times more.

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
