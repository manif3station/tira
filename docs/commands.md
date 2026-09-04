# Complete Command Ecosystem

This is the reference: every command and argument, what it is for and when to
use it. For the use cases — the workflows these commands serve, and which one
to reach for — run `dashboard tira.skills`.

Every workflow in `SKILLS.md` is implemented through the entrypoints this
document names, and a command that ships without being named here fails the
suite - a reader who captured only this file was missing whole families before
that check existed. The shared `Tira::CLI` parser applies TOON-first output,
pretty JSON, Markdown, repeatable options, JSON-array replacement, raw
attachment output, and consistent structured failures - including, since
3.80, a "Did you mean" suggestion on an unknown option, naming the nearest
declared option name(s) by edit distance rather than only "Invalid
command-line options". TKT-298.

That suggestion has one exception, since 4.82: when the "unknown option" is
exactly a name the command declares, it is not a typo - a bare declared option
would have parsed - so it is a VALUE beginning with two dashes that the parser
consumed as the next flag. Suggesting the option back in that case would name
the exact string the caller just typed, reading as a correct flag being
rejected. Instead the refusal says the value looks like an option and names the
`--option=VALUE` form, which joins the value to its flag rather than leaving it
as a separate argument. TKT-742.

That parser is one array declared once, shared by every command - an option
declared twice in it, `'attach=s@'` for years until 4.90 (TKT-775), is silent
noise rather than a per-command bug: parsing still worked (both entries pointed
at the same destination), but Getopt::Long's own duplicate-specification
warning prints straight to STDERR, bypassing the `$SIG{__WARN__}` capture the
unknown-option suggestion above depends on, on every single invocation of the
raw entrypoint script.

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
| `--caller-kind agent\|human` | no | Defaults to `human`. See below. |
| `-o FORMAT` | no | `toon` (default), `json`, `json-pretty`, `human`. |

Both `--reason` and `--option` are optional, but an owner answering a question
with neither is composing an answer from nothing. With them he can pick a
choice in one click.

`--caller-kind` (TKT-787) tells the question who is asking: a human, who can
record a voice note on a phone, or an agent, who cannot. Every question
defaults to `human`, so nothing already relying on the voice reminder changes.
An agent-filed question that passes `--caller-kind agent` is not reminded to
attach `--voice` - the reminder's reason/options half still fires the same as
for anyone else, since that costs nothing an agent cannot produce. Refused on
every other `question.*` command, the same restriction `--voice` already has
on `question.update`/`question.voice`. A question asked before this shipped
carries no `caller_kind` field at all and still reads as `human`.

### `tira.question.list`

List the questions on a card, with their answers underneath. **Reading is what
marks the answers read** — you do nothing extra, and the owner can see they
were seen. Writes only when there is something to mark. Every list carries an
`instruction` naming your next step.

Every question here carries `status` (`new`, `answered` or `discarded`).
Until 3.41, `tira.<type>.show`'s embedded `questions` did not - the stored
entry came back as-is, so a discarded question and a live one were
distinguishable only by `discarded_at`, invisible to a caller filtering on
`status` the way this command's own output invites. `record.show` and
`record.show --refs` now compute `status` on their embedded questions the
same way this command does, so the two agree. TKT-322.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The card whose questions to list. |
| `--status STATUS` | no | Only `new`, only `answered`, or only `discarded`. |
| `--since STAMP` | no | Only what has changed since then. Reads the **answer's** stamp when there is an answer and the question's when there is not, so a newly answered question shows as newly changed. |
| `--peek` | no | Inspect without reading. Returns metadata only per question - `id`, `status`, `answered_at`, `read_at`, `mark` - never the answer text, reason, or options, and does not itself mark anything read. Refused on every other `question.*` command. |
| `-o FORMAT` | no | As above. `human` renders each question, its reason, its numbered choices and its answer. |

Reading is what marks an answer read, which made checking whether an answer
had been read the same act as reading it - a manager routing work down a
chain who opened a question to route it consumed the one detector whose
entire job was to send that agent there, permanently, since nobody else
could act on a finding only the main session could see. `--peek` is the
inspection route: same command, metadata only, no mark. TKT-336.

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

**Answering again keeps what it replaced, and re-attributes the answer.** Since
5.42 the previous answer moves to a `superseded` list on the answer itself,
carrying its text, its author, when it was given, when it was replaced and by
whom. The answer's `author` becomes whoever wrote the new text — before that it
kept pointing at whoever answered first, so a card could show one person's name
above another person's words, with nothing anywhere to recover the original
from. It happened on Tira's own board: an agent ran this command to record that
it had *read* an answer, and replaced it.

`--author` is optional here as elsewhere, and leaving it out on a second answer
does **not** blank the name already recorded — a missing author is not a claim
that nobody wrote it.

**If you only meant to record that you had read an answer, you have already
done it.** Reading marks it: `tira.question.list` sets `read_at` as a side
effect of showing you the answer, and `--peek` is the way to look without that
counting as reading. `tira.question.mark` is a different thing again - it
records `ok` or `not-ok`, a judgement, and its own section says so: "Separate
from having read it: reading is not agreeing." Marking an answer leaves
`read_at` untouched.

What to use for "I have acted on this" is `tira.comment.add`, or a card field if
the decision belongs on the card - which is what the `answer-ok-not-folded` rule
asks for. Neither overwrites the answer. TKT-879.

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

### Naming a card on a question command

Every question command takes `--id`, and the ids are unique across a board, so
the card is optional — the question is found on its own.

**If you do name a card and the question is somewhere else, the command is
refused**, naming both:

```
Question 'Q-001' is on TKT-001, not on TKT-002. Name that card, or leave the
card out and the question will be found on its own.
```

Until 2026-08-13 the card you named was looked up by id and then overwritten,
so answering with one card's reference and another card's question changed the
other card and reported success. The card you named stayed waiting, and nothing
said the answer had landed anywhere else — the board afterwards looked
perfectly consistent, because the answer really was on a card.

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
through. It offers no place to attach anything, since nothing more will happen
to it; files already on it still show, because they still happened. Discarding twice is refused, and a discarded question cannot be
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
disappearing. It offers no add-card control, because nobody creates work
straight into the discard pile. The ref-only listing an agent queries leaves it out by default,
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
file. It writes the file's raw content to stdout - `--output`/`-o` is the
same response-FORMAT flag every command shares (`toon`, `json` or `human`),
never a destination, so save it with shell redirection:
`tira.attachment.get --sha SHA --extension EXT > FILE`. Passing a path to
`--output` is refused with `Unsupported output format`, and the refusal now
says both of these things - until 3.57 it only quoted the path back,
leaving a caller who reached for the obvious spelling to learn nothing
from being refused. TKT-371.

Taking one off again needs both: `tira.attachment.detach --ref TKT-001 --sha
SHA256` removes the file from that card, and `--comment CMT-001` takes it off a
comment instead. The card is named because the same file can be attached in
several places at once - deduplication stores it once and records each
attachment - so detaching without saying where would be a guess about which one
was meant.

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
it, and picks the new version up without anyone restarting it by hand — but
not by restarting itself. **The shipped board never can.** `tira.dashboard -o
browser` always runs under Starman with a worker pool, so the process that
notices a new version is always a worker, and a worker can never replace the
board (see below). Nor can the master do it on its own account: it owns the
listening socket and never serves a request, so nothing inside the board is
both able to notice a new version and able to act on it. The signal has to
come from outside.

What actually picks up a release is **police** (TKT-565). It runs on a
schedule, is not a worker, and owns no listening socket, so it can do the one
thing that works: send the master a `HUP`. Starman re-forks its workers on
`HUP`, and because Tira serves a `.psgi` **file path** rather than an
in-memory coderef, each new worker re-reads the modules from disk and comes
up on the installed version. Nothing is dropped - a worker finishes the
request it is holding before it is replaced.

Police finds the master by asking which process holds the board's port, not
by reading a pidfile: a pidfile goes stale, survives a crash and can name a
pid the machine has since reused, while a listening socket is the truth at
The master is picked out by parentage, not by pid order (TKT-567): a
pre-forked server's master and all of its workers share the one listening
socket, so the master is identified as the holder that no other holder
fathered. Pid order would work only until pids wrap past `pid_max` -
smaller in a container than on a host - after which a worker can be
numbered below its own master. Where that cannot be resolved to exactly
one process the lookup refuses, since signalling a worker would reload
only that worker and leave the rest of the board on the old code.

It signals **once per release**, remembering which
version it last signalled about, because signalling every pass is the loop
this whole mechanism exists to avoid.

**It refuses far more readily than it acts**, and every refusal names itself
- no board holding the port, a process on that port it cannot confirm is the
dashboard, an unreadable installed version, no known port, or a version it
has already signalled about. The identity check matters more than it looks
(TKT-566): `SIGHUP`'s default disposition is Term, so signalling a process
that installs no handler kills it, and the board port is a stable configured
number that another program can take while the board is down. Police reads
the process's own command line and signals only a Starman. It checks for a
Starman rather than for this board specifically because Starman rewrites
`$0` - a live master's command line reads `starman master`, naming neither
`dashboard.psgi` nor the command that started it - and that is enough, since
every Starman handles `HUP` and merely reloads, while a process without a
handler dies.

Proved end to end rather than reasoned about: `tools/hup-integration` runs a
real board inside the `developer-dashboard:latest` image, installs a newer
Tira underneath it, runs one police pass, and asserts the master pid is
unchanged while every worker pid has been replaced and the board is still
serving. Those three together can only mean a reload in place - a restart
would change the master, and doing nothing would leave the workers alone.
It needs Docker and a real image, so it is run by hand like
`tools/browser-tests` rather than from the test suite. A board running slightly old
code is a working board. With police not running, the board stays on its old
version and shows the banner below until somebody restarts it.

The rest of this section describes the dashboard's own in-process self-restart,
which is still correct for a server that owns its own socket — just not for
the shipped one.

**Only the process that launched the board may replace it.** A board served by a
pre-forked server answers each request in a worker, and a worker is not the
board: the master owns the listening socket, so a worker that re-executes cannot
bind the port, dies, and takes the request with it. That is not a restart, it is
a lost request every time the page refreshes, for ever. So a worker does not try.

A served board therefore does not replace itself, and says so rather than
failing quietly: when a different version is installed under it, the page shows
`Tira <version> is installed - restart this board to run it` beside the last
update time. Restart it when it suits you; the board keeps working meanwhile.

The page reloads only after the new code is genuinely serving, so it can never
fetch the old page again; the cost is one skipped refresh cycle. A version that
cannot be read is treated as no change. So is a version that differs only in
`.env`: what decides is the module a restart would actually load, because
re-executing into the same code and disagreeing again is a loop rather than an
upgrade.

The restart works out its own entrypoint from the command it is running, and
passes the project explicitly, so it does not depend on how the board was
launched or on what the new process inherits. If it cannot find a valid
entrypoint it does not restart at all: running slightly old code is better than
not running.

### What a command loads

Since 4.74 a command loads only the code it needs. `Tira::CLI` is an index -
argument handling, the one shared option table, the dispatch, and the four move
guards - and the command bodies live in `lib/Tira/CLI/<Concern>.pm`, each pulled
in with `require` at the point one of its verbs actually runs.

Measured rather than inferred - each row below is what `%INC` held after that
command ran, one command per process so nothing accumulated. The two rows marked
*not measured* say so rather than guessing, because an earlier version of this
table was written by reading the code and was wrong in three places.

| running this | loads beyond the index |
|---|---|
| `tira.ticket.list`, `tira.project.show`, `tira.column.list` | nothing |
| `tira.ticket.create` | `Records` |
| `tira.question.list` (and the other question verbs, which share one body) | `Records` |
| `tira.next`, `tira.column.roles` | `Board` |
| `tira.login.status`, `tira.policy.list` (and their siblings) | `Board`, `Police` |
| `tira.police.outstanding` | `Police` |
| `tira.backup` and its three siblings | `Backup`, `Police`, `Serve` |
| `tira.project.new` | `Wizard` |
| `tira.dashboard.ticket -o browser` | `Browser`, `Police`, `Serve` |
| `--help`, and any refusal that prints a usage line | `Usage` |
| `tira.onboard` | *not measured* - it prompts, and a probe that hands it an exhausted input handle produces no reading |
| `tira.police`, `tira.policy.bridge` | *not measured* - the probe's run errored, and an errored run measures the error path rather than the command |

Two things in that table are worth reading twice. `tira.backup` loads `Police`
because the backup readers and the police store sit either side of one another,
not because backing up polices anything. And a command that ERRORS loads `Usage`
on the way to printing its refusal, so any measurement of a failed run reports
the error path rather than the command - which is how the first version of this
table came to claim that every command loads four modules.

The dependencies between modules are loaded the same way. `Police`'s world scan
reads the machine through `Serve` and the last backup through `Backup`, but it
asks for each inside the sub that needs it rather than at the top of the file -
otherwise running `tira.next` would pull in the whole chain for the sake of one
helper, which is what it did for the first hour after the split.

**No command's arguments changed, and no command moved.** The dispatch table is
the same one, and it still resolves a command name to a `Tira` method; what
moved is where the bodies of the larger ones are written. `--help` answers for
every command exactly as before, and a command that never serves a board still
never compiles Dancer2 - which was already true of `Tira::DashboardWeb` and is
now true of eight more modules.

This is worth knowing in one situation: a long-running board holds whichever
modules it has already needed, so it picks up a change to one of them only when
a command first reaches it *after* a restart. `docs/POLICIES.md` covers the
consequence for diagnosing a board that looks like it is running two versions
at once.

### Which required actions are yours

The card dialog renders one required-action group per column. On a card with a
history that is a column of headings, exactly one of which is the work actually
owed, and until 4.75 nothing said which.

The group for the column the card is in now carries an accent border, and its
heading reads `<column> - N owed here`. `N` is what is unmet in that column -
this column, minus exemptions, minus anything already done - and it is the same
number `tira.required-action.list --ref REF --blocking` prints. Both read one
selection in Perl; the dialog is handed the answer and renders it rather than
deciding which items count.

The section's own heading is unchanged and still reads `Required actions
(18/75)`. That answers a different question - how much of the card's whole life
is finished - and the two numbers are stated separately because they are not the
same question.

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
  Since 5.40 the page begins closer to the top: the shell had 3.5rem of padding
  above a header that is `position: sticky; top: 0`, which is empty background
  on first paint, gone at the first scroll, and until then delaying how far you
  must scroll before the header pins. That is 1rem now, and
  the gap below the header halved, returning roughly one card row per screen
  (TKT-855). The header keeps its own padding — what went was clearance above a
  sticky element, not breathing room around content.

Since 5.25 the code behind `-o human` and `-o table` lives in
`lib/Tira/Render.pm` rather than `lib/Tira.pm`, loaded by `format_output`
only when one of those two formats is asked for - so a command answering in
`json` or `toon` never compiles the renderers (TKT-834, the third lift under
TKT-746). Nothing about either format changed: the same markdown, the same
self-contained HTML, the same escaping, and the same two refusals - `-o table`
handed data that is not a board still says `Table output requires dashboard
data`, and an unrecognised format is still refused by `format_output` itself.

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

### `tira.dashboard`

Render the board. `tira.dashboard.sow`, `.epic` and `.ticket` render one board
rather than all three.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `toon` (default), `json`, `table` for a page, `browser` to serve it live. |
| `--title` | no | Show card titles as well as references. |
| `--include-discard` | no | Force the Discard column in or out; shown by default in the formats a person looks at. |
| `--with-questions` | no | Mark cards that are waiting on somebody; on by default in the formats a person looks at. |
| `--no-session-expire` | no | With `-o browser`: a sign-in lasts until somebody signs out. |
| `--show-logs` | no | With `-o browser`: keep the last 200 requests the board answered, and serve them at `/logs` for the page to show. |
| `--with-police` | no | With `-o browser`: run the police bridge beside the served board, so one terminal carries both. Refused in any other output format — there is nothing to run alongside. While the dashboard holds the watch, a later `tira.police` says so and exits 0 rather than taking it over. |

Until 4.93, `--title` with `-o browser` had no effect - the live dashboard
never showed titles regardless, because the serve path read a key
(`with_title`) that nothing ever set, rather than the one `--title` actually
populates. `-o table`/`json`/`toon` were unaffected; only the served browser
dashboard silently ignored the flag. TKT-779.

Since 4.94 the page's top header (title, board subtitle, Refresh control,
Last-updated timestamp) stays pinned to the top of the viewport while the
board scrolls, rather than scrolling away with the rest of the page - the
Refresh button and freshness indicator stay reachable no matter how far down
a long board you have scrolled. Owner request. TKT-780.

The default output is deliberately cheap: references only, because that is the
path an agent queries. The formats a person looks at carry titles, the Discard
column and the waiting marks, since somebody reading a board wants to see where
things are rather than the smallest possible answer.

In the browser, a card worked recently is tinted green and the tint fades as it
ages, so progress is visible without reading a timestamp. He asked for it after
looking at the board and asking whether the agent had stopped, while two cards
were being actively gated — a card being worked and a card abandoned for six
hours looked identical.

The ranking is **relative to the other cards in the same column**, read from the
same `data-mtime` the default sort already orders by, and recomputed on every
refresh so it cannot go stale. The tint is proportional to age rather than to
position: two cards a minute apart do not look as far apart as two cards a week
apart merely because they sit next to each other. The newest card in a column is
fully tinted, the oldest carries none.

Three cases are deliberately not painted. A column with fewer than two visible
cards is not a ranking. A column whose cards all share one timestamp is not a
ranking either — there is no difference to show, and inventing one would say
something the board does not know. And a card waiting on an unanswered question
keeps its own yellow and takes no green, because a card waiting on somebody is
not a card that has gone stale.

`--ssl` serves the board over HTTPS. The certificate is the board's own, made
the first time and reused afterwards — a certificate that changed on every
restart would make a browser warn every time, which teaches somebody to click
through warnings. It is made by a library rather than by running `openssl`,
because Tira invokes no shell or external process and that guarantee is not
worth spending on a convenience. It lives beside the project rather than inside
a board, with the key readable by nobody else.

What it gives you and what it does not: it stops somebody reading your password
and your session cookie off the wire, which over plain HTTP they can. It does
not stop somebody who can already stand between you and the machine, because
nothing has vouched for the certificate except the board that made it. Your
browser will say so the first time and you accept it once.

`--with-police` runs the police bridge in the same terminal as the board, which
is what it is for: watching a board otherwise takes two terminals, one serving
and one listening. The pass is a child of the serving command, so interrupting
the command stops both and the singleton claim is released rather than left
naming a process that has gone. It writes to the same handles as the server —
which is the point of the flag, and also keeps its findings out of a pipe nobody
is reading. A `--store` given to the dashboard is handed to the pass as well, so
both are claiming in the same place; without that they would derive stores
separately and the standing-down rule would never fire.

**While the dashboard holds police, a later `tira.police` stands down.** It says
which process holds the watch and exits 0, because standing aside is the correct
outcome rather than a failure — a non-zero status there would make every wrapper
read a working board as a broken one. This is the one exception to TKT-486's
rule, which is otherwise unchanged: between two ordinary police daemons the
newest still wins and the previous one is killed. The owner's words, answering
Q-117 on TKT-897: *"The dashboard is a special case - while it holds police, a
later tira.police says so and exits 0. TKT-486 still applies everywhere else."*

`--show-logs` makes the board keep a record of the requests it answers — path
and status — and serve it at `/logs`. It is **refused** with any other output
format, naming what it needs: the record is read through the page the board
serves, and there is no page in `-o json`. Accepted-and-ignored would be worse
than refused, because a flag that parses reads as confirmation. Without the flag there is no record and
`/logs` answers 404 saying so, rather than an empty list: an empty list would
tell a reader the board had answered nothing, which is a different claim from
not keeping a record at all.

It exists because a board that will not load says nothing about why. Starting
one and watching it answer is the difference between a request being refused
and a request never arriving — and only the first of those leaves a trace here,
which is the honest limit of it: a page that never reaches the server produces
no entries.

The record is a fixed ring of 200 entries rather than a time window. A window
bounds memory only if a request rate is assumed, and this is read precisely when
the rate is unusual.

The panel does not record its own polling. It reads `/logs` every five seconds,
which is more traffic than the four board routes produce between them, so
recording it would fill the ring with the act of looking and push out the
requests you opened the panel to see.

Nothing is written to disk — the entries are held in memory and served to the
page that shows them, and the board says as much on the terminal it starts
from.

`--no-session-expire` turns off the idle timeout for the board it serves. A
session normally ends after ten minutes of inactivity, and the board's own
refresh does not count as activity — it reads a session without extending it,
so a tab left open overnight does not keep itself signed in. That is the right
default on a shared machine and the wrong one for a board somebody watches all
day from a phone, which is why it is a choice rather than a change.

What it costs: over plain HTTP the session cookie is a credential with no end
date, and anything on the path between the browser and the board can read it.
The board says so on the terminal it is started from, so nobody turns it on
without seeing that.

`-o browser` serves it and keeps working when Tira is upgraded underneath it -
the server notices and restarts into the new code. **The browser dashboard is
behind a login**; see the sign-in section below.

**Where the dashboard's markup lives, since 4.70.** Not in `lib/Tira.pm`. The
page, the sign-in page and the card and column dialogs are Template Toolkit
templates under `lib/Tira/views`, beside the stylesheet and seven scripts. The
module holds no markup at all and no line in it exceeds 2,000 characters; before
this, eight lines held 113,884 bytes between them and the longest was 54,419.

Two properties of that arrangement are load-bearing rather than incidental.
The assets are read and **inlined at render, never linked** - a `<link>` or a
`<script src>` pointing at them would reach outside the page, and nothing the
board serves does. This is narrower than "makes no requests": the live board
talks to itself constantly, polling its own card data, fetching a record when a
card is opened and posting a move when one is dragged. What it never does is
load anything from another host, which is why a table-mode board saved to a file
still works with no server at all. And the template directory is resolved from the module's own location
rather than from the working directory, so an installed skill finds it wherever
it is run from; a relative path would work only when the board was served out of
the source tree.

Editing the dashboard now means editing a `.css`, `.js` or `.tt` file and
reading the change as an ordinary diff. It also removes an escaping layer: a
script built inside a Perl `q{}` has its backslash pairs halved on the way to
the browser, which shipped a dead board on TKT-645; a file read verbatim cannot.

### `tira.usage`

Prints this document. One command, so an agent can read the whole reference
without knowing where the file lives or that it is a file at all.

`tira.policies` does the same for the policy guide.

## Signing in to the browser dashboard

The board is behind a login. A person claims a password the first time they
use it and must match it afterwards. Only a salted, iterated digest is ever
stored - never the password.

**Over plain HTTP the password and the session cookie travel in clear.** This
login is good against somebody wandering past an open board; it is not good
against somebody watching the network. There is no lockout on repeated wrong
guesses, and the first person to claim an unregistered name gets it - so it
assumes a trusted network.

### `tira.login.register`

Claim a password for a person who has never signed in.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id PERSON` | yes | Who is claiming it. |
| `--password TEXT` | yes | What they are claiming. Stored only as a salted, iterated digest. |
| `-o FORMAT` | no | `toon` (default), `json`, `json-pretty`, `human`. |

Refused for an unknown person, an inactive person, an empty password, a person
who already has one, and **anybody whose id or name contains "bot"** - machines
drive the board through the command line, not a browser.

**Forgotten a password?** There is no reset command by design. Delete the
`password` block from that person in the project file by hand; they are
unregistered again and the next sign-in claims a new one.

**Every field of the stored record is validated, including the work factor**
(TKT-686). `algorithm`, `salt` and `hash` were always checked before a
password was accepted; `iterations` was not, and `for ( 2 .. $iterations )`
silently does nothing when it is undef, `0` or `1` - all three verified
against a single HMAC round instead of the real cost, with no error. A
record's `iterations` must now be a positive integer at or above
`$Tira::PASSWORD_ITERATIONS_FLOOR` (210,000) and at or below
`$Tira::PASSWORD_ITERATIONS_CEILING` (2,000,000), checked before any hashing
runs - so a record nobody could have written honestly is refused instead of
verified cheaply or made to hash for minutes. The floor is a separate
constant from the write-time `$Tira::PASSWORD_ITERATIONS`, deliberately:
raising the write-time cost later must not lock out a password already on
file.

### `tira.login.check`

Ask whether a password is right. Exits clean either way, because being wrong is
an answer. A wrong password and a person who does not exist are answered
identically, so this cannot be used to find out who is on a project.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id PERSON` | yes | Who to check. |
| `--password TEXT` | yes | What to check. |

### `tira.login.status`

Who is signed in. Says the person, when they signed in and when they were last
active - never the token, because a token is the credential itself.

### `tira.login.logout`

End sessions.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--id PERSON` | one of | End every session that person holds. |
| `--all` | one of | End everybody's. |

A session lasts ten minutes from the last deliberate action, not from signing
in, so an afternoon of work is never interrupted. The board's own background
polls - `/data`, since TKT-807 also `/tasklist` and `/tasklist/sessions`
(the Task List section's own 1-second and 5-second refresh timers), and since
TKT-839 `/jobs` (the Repeated Jobs section's 30-second one) - read a
session without extending it, so a tab left open overnight does not keep
itself signed in. Before TKT-807, only `/data` was exempted: a dashboard tab
with the Task List section visible polled far more often than `/data` ever
did and never let its own session actually expire, defeating the mechanism
this exemption exists to provide. A test (TKT-694) now scans every view file
for a timer-driven poll and fails if its route is not exempted, so a future
one cannot silently repeat the same gap.

## Policies, and the police that follow them

The agent declares what a project cares about; the owner runs police in a
terminal of their own; the agent tails a bridge and acts on what arrives.
Police never writes to the board - it watches read-only and writes only to a
log it owns.

`d2 tira.policies` prints the whole guide, including a hundred worked use
cases. Read that before setting anything.

### `tira.policy.add`

Declare a policy.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--rule NAME` | yes | What to watch for. `tira.policies` lists them all. |
| `--action NAME` | yes | `bridge-reminder` to the agent, `print-reminder` to the owner's terminal, `log-only` while tuning. |
| `--enter COLUMN` | per rule | The column a card must have its detail by. |
| `--enter-role ROLE` | per rule | The same, said as a role rather than a column name. |
| `--before-column COLUMN` | per rule | The column that means the work has moved on. |
| `--before-role ROLE` | per rule | The same, as a role. |
| `--column COLUMN` | per rule | The column a rule watches. For `task-card-mismatch` it says which columns mean *work* rather than which column to act on, so it takes a name or a comma-separated list and several policies compose into one set. |
| `--column-role ROLE` | per rule | The same, said as a role rather than a column name - the counterpart to `--enter-role` and `--before-role`, and accepted anywhere a rule needs a `--column`. |
| `--age DURATION` | per rule | That rule's grace: `30s`, `10m`, `2h`, `7d`. |
| `--max N` | per rule | A limit, for `wip-limit`. |
| `--pattern TEXT` | per rule | What to match, for `leftover-process`. |
| `--sandbox PATH` | per rule | Where worktrees live, for `card-sandbox-missing`. |
| `--require FIELDS` | per rule | Comma-separated fields, for `card-metrics`. |
| `--require-link TYPE` | per rule | The link a card must carry, for `card-unlinked`. |
| `--link-to CARD` | no | Narrows `card-unlinked` to a link pointing at one card. |
| `--notify` | no | An additional off-channel page (through the same address `tira.notify.moves` uses) on top of the bridge, for `agent-still` - off by default since the bridge already carries the same finding for a standing session with its own live reader. |
| `--message TEXT` | no | What to say instead of Tira's own wording. |
| `--type TYPE` | no | Declare it for one board only. |
| `--on-column COLUMN` | no | Declare it for one column only. |
| `--ref CARD` | no | Declare it for one card only. |

Anything a rule cannot work without is refused when the policy is set, rather
than discovered later by police - a policy police cannot follow is worse than
no policy, because it reads as cover.

**`task-card-mismatch` reads its siblings.** Its `--column` values name the
columns that mean somebody is working, and a set is not several independent
opinions - so every policy of that rule on the board is unioned and the pass
reports from the first. Declared the ordinary way, one policy per working
column, each policy would call the other columns' honest tasks mismatches. A
`--column-role` naming a role the board has assigned counts toward the same
set; if nothing resolves, the rule stays silent rather than reporting every
task on the board, and `policy-unfollowable` reports the declaration it cannot
read. It also says at most one thing per task per pass, because the violation
ledger keys an entry by rule, policy and reference and two findings about one
task would share a number, a `first_seen` and a `seen` count.

**Some rules read more than the policy tells them.** `agent-still` is the
clearest: `--age` sets its grace, but whether a card counts at all depends on
the board's declared agent. A card in a working column stops being held
against the agent once it is assigned to a named person who is not the agent,
because an agent cannot be stalling on work it has no power to move. An
unassigned card still counts: nobody has claimed it, so the agent is the only
party who could be moving it. Declare an agent
with `tira.project.update --agent NAME`; a board that has declared none is
measured on columns alone, exactly as before TKT-570.

**Where a policy is declared decides how narrow it is.** A policy on a card
beats one on its column, which beats one on its board, which beats one on the
project. Resolution is per rule, so a card that overrides one rule keeps every
other rule the project set.

### `tira.policy.list` / `tira.policy.remove`

See them, or remove one by `--id POL-nnn`. Numbers are never reused.

**The dashboard's Policies button is Implemented,** as a modal
alongside the Columns dialog, since TKT-493. It reads and writes the
same declared/declined/undeclared policies as the commands on this
page, through `GET /policies` and `POST /policy/add` / `/policy/remove`
/ `/policy/decline`, rather than a separate mechanism - a policy
declared from the browser is a policy `tira.policy.list` shows, and one
declared with `tira.policy.add` shows up in the browser on next open.
Its rule picker's parameter fields match `--enter`/`--column`/`--age`
and the rest of this section exactly, driven by the same needs/forbids
data `policy_add` validates against.

TKT-519: `GET /policies` also carries `token_fields` and `token_help` -
the same `{token}` list and one-line descriptions "Saying it in your own
words" documents above, from `Tira::policy_message_fields` /
`policy_message_field_help`. The dialog's message field shows this behind
a (?) badge, since nothing else in the UI told a person which tokens
existed or that they are message-only.

### `tira.police`

**The owner runs this**, in a terminal they can leave open.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--once` | no | One pass, then exit. |
| `--interval SECONDS` | no | How often to look. Thirty by default. |
| `--rounds N` | no | Stop after this many passes. |
| `--store PATH` | no | Where police keeps its own state. |

With no policies set it exits and prints what to paste to the agent, rather
than running and guarding nothing.

**The persistent daemon (no `--once`) is a singleton per board.** Starting one
claims a pid file in its own store, killing whatever daemon was already
running there - "whoever the last run it is the winner and the loser process
will be killed", his own words after two live daemons were found racing the
same board's enforcement ledger. `--once` and `tira.policy.bridge` (a
read-only tail) do not participate in the claim. TKT-492.

Every violation carries a `VIO-nnnn`. The same problem keeps its number, counts
the times it has been said and climbs four tones - note, warning, urgent,
critical.

**The number belongs to one board.** Every board's store counts its own
violations from one, so `VIO-0453` on one board and `VIO-0453` on another are
unrelated problems - and two people looked that number up on the same morning,
got different answers, and had no way to notice. So every line ends with the
board it came from:

    ... | fix: d2 tira.ticket.show --ref DD-532 | board: developer-dashboard

and the line that introduces a replay names it too. It goes last because a
reader splitting the first fields sees exactly what it saw before. Making the
numbers unique across boards was rejected: a board's store is its own, and
coordinating them is what this design avoids.

**Match the field, not the word.** A line now carries a name somebody chose, so
a board called `Settled`, `Done` or `Urgent` will match a grep for that word
anywhere in the line. Matchers should key on the field - ` | SETTLED | `, ` |
for ada | ` - which is what the line has always been shaped for. This is not
hypothetical: a test whose board is named `Settled` had three assertions match
every line on it the moment the board's name arrived. Past five tellings it also appears in this terminal with a message the
owner can paste straight to the agent. Fixing the cause silences it on the next
pass, with nothing to acknowledge.

A problem is written to the bridge once when it is found and then not again
until there has been time to act on it - five minutes, then fifteen, then
thirty, then an hour - so one that persists gets quieter rather than repeating
every thirty seconds for ever. A violation waiting out its quiet is still
reported by the pass, a fixed one goes silent immediately, and a new one is
said at once whatever else is waiting.

### `tira.worklog.show`

What has actually happened to a card: raised, moved, edited, commented, asked,
answered, marked - in order, with who did it where the board knows.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | Which card. |

**There is no command to write an entry, and there never will be.** The log is
derived from what the engine already records, so adding a comment *is* the
entry and changing a title logs itself. An agent that has to remember to log
keeps a log worth nothing.

On the browser dashboard it is a collapsed section in the card dialog, fetched
only when somebody expands it - a card has a great deal happen to it, and
loading all of it whenever a card opens would bury everything else.

## Which of the three you want

Three commands sound alike and are not interchangeable. Another project read
`tira.backup.export` as the way to back a board up, which is the one reading
that loses work: an export is a file somebody has to remember to make, and a
board with exports and no backups has nothing to restore from.

**`tira.backup` is the backup.** It makes a commit in a git repository Tira
manages inside the board's own storage. It is the one to run often, and the one
`board-unbacked` is about. If you are reaching for a backup, this is it.

**`tira.backup.restore` is the undo.** It puts the board back to its last
backup.

**`tira.backup.export` and `tira.backup.import` move a board between machines.**
Export writes the whole history and every attachment into one file; import lays
that file out as a board on a machine that has not got one. In his words:
export when you move a Tira project to another machine, import when the other
machine receives it, and day-to-day operation uses neither.

The two answer different losses. The repository a backup lives in sits inside
the board's own storage, so it survives a bad edit and not a lost disk. A bundle
is what leaves the machine, which is why it is worth keeping one somewhere the
board is not - but making one is not backing up, and neither replaces the other.

### `tira.backup`

Back the board up. A backup is a commit in a git repository Tira manages inside
the board's own storage, beside the project file.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `toon` (default), `json`. |

**The repository is created the first time you back up**, so nobody has to run
`git init` to obey a rule, and a board that never backs up has none — reading
never makes one.

**Two things are left out.** The lock file, because a restored lock is somebody
else's half-finished write, and the sessions, because a session is the server
side of somebody's sign-in and a restored one hands over an identity. That
exclusion is checked on every backup rather than written once when the store is
made, so a board created before 1.97 picks it up on its next backup and stops
carrying sessions from that point.

**What was already committed stays committed.** Only the tracking changes.
Rewriting the history of a backup is a worse thing to own than the tidiness it
would buy — a record somebody's tooling quietly rewrites is not evidence any
more.

**This is what makes `changed: 0` mean something.** A session file is rewritten
whenever anybody uses the board, so while sessions were kept there was always
something pending, and two backups seconds apart both reported a change. "Is
this board already backed up" now has an answer.

It has **no remote**, deliberately. A board that lives on a filesystem should
not need somebody else's machine to be backed up, and a backup that can fail
because a server is down is one that stops being made.

Attachments are in it. A backup is everything or it is not a backup.

**Backing up an unchanged board is not an error.** It says nothing had changed
and names the backup that still stands, because `board-unbacked` asks for one on
a schedule and a command that failed on a quiet afternoon would teach whoever
reads the bridge to ignore it.

The lock file is the one thing left out. A restored lock is somebody else's
half-finished write, restored.

The commit is made with an identity given on the command rather than written
into the repository, so backing up neither depends on your git being configured
nor changes what it would do — and signing is switched off for that commit,
because a signing prompt would hang a command police asks for on a schedule.

Git is run from the command layer. **The engine still invokes no shell or
external process**, which is what lets Tira be trusted inside another tool.

### `tira.backup.restore`

Put the board back to its last backup.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--yes` | to do it | Agree to lose what has happened since the backup. |
| `-o FORMAT` | no | `toon` (default), `json`. |

**This is the only command in Tira that can lose work**, so without `--yes` it
does nothing: it prints what would be discarded, by name, and stops. Named
rather than counted — "3 files would be discarded" tells nobody whether it
matters.

A restore is a restore. The cards, the attachments and the reference counters
come back as they were, and anything done since the backup is gone: a card
raised afterwards is removed, not merged. A board with no backup is refused
rather than reported as restored.

The board is still a working board afterwards. It can be added to, and backed
up again.

### `tira.backup.export` and `tira.backup.import`

Get a backup off the machine, and bring one back.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--file FILE` | yes | The bundle to write, or to read. |
| `--dir DIR` | on import | Where the board should go. Import is how a board arrives somewhere, so the folder is taken as given rather than searched for - a destination, not a way of selecting a board that already exists. |
| `--yes` | to replace | Agree to replace a board that is already there. |
| `--claiming-schema N` | no | What schema the bundle says it holds. A newer one is refused. |
| `-o FORMAT` | no | `toon` (default), `json`. |

The repository `tira.backup` keeps lives inside the board's own storage, so it
survives a bad edit and **not a lost disk**. A bundle is one file holding the
whole history and every attachment — keep it somewhere the board is not.

Import lays a board out in a folder that was not one. Importing over a board
that already exists replaces it, so without `--yes` it says what is there and
does nothing.

**A bundle from a newer Tira is refused rather than half-restored.** Tira has no
migrations: an older board reads correctly because defaults are applied on read,
and a newer one holds shapes these readers have never seen. Nothing is written
when it is refused.

### `tira.dev.found.bug_or_improvement`

Report a fault or an improvement in Tira itself, from whatever project you are
working on.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--from PROJECT` | yes | Which project this is coming from. |
| `--title TEXT` | yes | What you found, in one line. |
| `--text TEXT` | no | What happened, in as much detail as you have. |
| `-o FORMAT` | no | `toon` (default), `json`. |

**You do not say where the report goes and you are not told.** The command
carries that itself, so an agent working on something else can report a fault in
one command and get back to what it was doing. Your own board is untouched.

`--from` is required, because a report nobody can go back to is one nobody can
answer. It becomes a label on the card, which is how the report is found again
and how a question asked on it reaches you.

The card is raised in the backlog under the maintainer's name, because an agent
in another project is not a member of that board. Where it goes from the backlog
is that board's decision, the same courtesy any bug report gets.

**A report arrives as an incomplete card, and that is deliberate.** Tira's own
board refuses a release while any live card is incomplete, so an incoming report
has to be triaged before the next one goes out. It cannot sit unread.

### `tira.gates.install`

Install Tira's gates into this project's repository.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `toon` (default), `json`. |

Two hooks. `commit-msg` refuses a commit that names no card on this board, or
names one that is sitting in backlog, discard or done - if the work is real
enough to commit, the card is real enough to have been moved. `pre-push` asks
police about the board and refuses the push if it has anything to say.

Since 5.41 the commit gate also refuses the opposite drift: a commit that
changes **code** while its card sits in a column claiming the code is settled -
anything other than `tests-red` or `implement`. The two refusals are the same
rule read in both directions, because a card's column must match its real state
whichever way they have come apart. It decides by what the commit actually
touches (`git diff --cached --name-only`), so a documentation commit in a
documentation column is not refused as code - a gate that blocked the stage
after `implement` would stop the process it exists to protect.

That direction was added because the first one could not see it. A card sat in
`verify` - not idle, so nothing objected - while its implementation was being
rewritten after the verify walkthrough found a defect. A verify that finds a
code defect is not a check that failed; it is the card returning to `implement`,
and this is what says so at the moment it matters.

Both fail closed: if `d2` is not on the path, or police cannot read the board,
the gate refuses rather than skipping. A gate that disappears when something is
missing is not a gate.

The commit gate asks the board which references are cards rather than assuming
what a reference looks like, so it works on a project whose boards are named
anything at all. Installing twice is safe.

### `tira.police.suspend`

Ask police to look away for a set number of seconds, so the agent can
concentrate on one thing without the bridge interrupting.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--seconds N` | yes | How long. There is no open-ended form; enforcement resumes by itself. |
| `--reason TEXT` | yes | Why. At most 500 characters, refused rather than trimmed. |
| `--store PATH` | no | Police's own state, if it is not in the usual place. |

Ten minutes is the ceiling. A second suspension within the hour is reported to
the owner's terminal as a renewal, with the day's running quiet time beside it -
because a ceiling on its own is defeated by asking again the moment each one
expires.

Every suspension appears in the owner's terminal as it happens, and the reason
is written into the enforcement log **by police**, on the agent's behalf.

### `tira.rule.suspend`

Put one rule down for a while, without going deaf to everything else.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--rule RULE` | yes | Which rule. A rule nobody has heard of is refused. |
| `--seconds N` | yes | How long. There is no open-ended form; it comes back by itself. Ceiling is 600 seconds without `--pid`. |
| `--reason TEXT` | yes | Why. At most 500 characters. |
| `--pid PID` | no | Tie the suspension to a running process instead of only a clock: it lifts the moment that process is gone, not merely when `--seconds` elapses. The ceiling on `--seconds` rises to 1800 as a backstop, so a process that never exits still cannot make the silence permanent. |
| `--ref CARD` | no | Put it down for one card only. With none, the whole board. |
| `--store PATH` | no | Police's own state, if it is not in the usual place. |

### What the push gate asks, since 4.62

The gate is `tools/hooks/pre-push`, installed by `tools/install-hooks` as a
symlink so it is version-controlled rather than local configuration. It refuses
a push nine ways and runs no test suite, no browser:

| Order | Check | Refuses when |
| --- | --- | --- |
| 1 | the version against what is shipping | a shipped file changed and `VERSION` did not |
| 2 | the board backup | `tools/board-backup` is missing, or it fails |
| 3 | live-card completeness | a card this push is about is incomplete |
| 4 | `tools/card-holes` | a card has holes in it, or its checklist and its column disagree |
| 5 | `tools/docs-match-code` | the documentation and the code disagree |
| 6 | `tools/docs-examples-run` | a documented example is not what the command accepts |

Since 4.99 (TKT-796) the browser suite (`tools/browser-tests`, 21 Playwright
checks) no longer runs here - a single flaky test used to block an entire
batch of otherwise-good, individually-verified cards. It runs earlier instead,
per card, as a conditional required action on the `verify` column (project
board configuration, not a step in this repo's own release tooling): only a
card whose changes touch `lib/Tira/views/*`, `DashboardWeb.pm`, or
`OnboardWeb.pm` needs it.

**One predicate decides whether a required ACTION is finished, since 4.68.**
The command layer asks `_item_is_done`, which lowercases before comparing, so
`done`, `Done` and `DONE` mean finished to the entry gate, the exit gate, the
outstanding-item count, the move-in reminder and the backward-move reset alike.
They were four hand-written comparisons and one had drifted:
`_remind_one_at_a_time` read the raw status, so a card arriving with an item
already marked `Done` was told to work items that were finished. Nothing is
normalised on write - `Done` stays `Done` on the card, which is TKT-434's
decision - and the predicate is the one place that reads it. TKT-657.

**How the gate decides a checklist is finished, since 4.66.** For the decision
that matters - is anything outstanding at all - it does not decide. It asks.
A checklist item ticked as `Done` - the natural capitalisation, and the one the
column templates themselves use for `To Do` - used to be finished to the card
and unfinished to the gate, because the engine lowercases before comparing and
`tools/card-holes` did not. That refused the push of 4.57, 4.58 and 4.59 over
items every one of which was marked done. `record_list` already attaches
`checklist_done` and `checklist_total` to every row, so the gate reads the
engine's own count for that. Two readers, one definition - the same arrangement
the definition of a complete card already uses (TKT-224).

Be precise about what that does and does not cover, because the difference is
where the next bug would go. A checklist counts as finished only when the
engine's count says so **and** no item on the card contradicts it - the count
confirms, it does not overrule. The two cannot disagree on a record from
`record_list`, since both counts are computed over that very array in the same
call, so requiring agreement costs nothing; it is there because a count-only
shortcut let `stalled()` announce "every checklist item is done" beside an item
visibly marked `To Do`, and a gate that contradicts what it prints is worse
than one that is merely wrong.
Working out **which items to name** in the message is still the gate's own, and
it still compares each item's status itself - case-insensitively now, so the
two agree. That is the second limb of what the card asked for: "either they
share one implementation, or a test asserts they agree." `t/420` is the test,
and it greps this directory so a new case-sensitive comparison cannot appear
quietly. TKT-671.

The two places that compared statuses failed in **opposite** directions, which
is worth knowing before touching either. `premature()` counted a `Done` item as
outstanding and refused a good push - loud, and the reason the card exists.
`stalled()`, which catches a card whose checklist is finished while its column
says otherwise, took a `Done` item as proof the checklist was *un*finished and
returned early, so against `Done` it was permanently blind. A fix to only the
first would have traded a false alarm for a silence.

The unfinished-item message names at most three and now says how many it did
not name. The count was always honest and the list never was: `4 checklist
item(s) unfinished:` followed by three names, with nothing to mark the fourth's
absence. It ends `(and 1 more)`.

Steps 5 to 7 run last deliberately. Documentation edited after a gate has
shipped a broken build here twice, so anything running before the edits proves
nothing about what goes out - and `t/416` asserts their position by index into
the file, not merely their presence, because a reordering would pass a presence
check while destroying the reason they exist.

The suite is not among them. It runs once, in the `verify` column, and its
output is recorded on the card as evidence by `tira.release.record` - which is
what puts the card in `push` in the first place. Before 4.62 the hook ran it
again, over a tree verify had already cleared, at about twenty minutes a
release; the last push to pay that cost took 21 minutes 19 seconds.

`tools/gate-run` still runs the suite and coverage by hand, against a checkout
of the commit rather than your working directory - so a change that passes only
because of an unstaged file fails there instead of failing for everybody else.
It still writes a pass record keyed to the commit's tree. Nothing reads those
records automatically any more: the hook stopped consulting them along with the
suite they existed to skip. TKT-680.

Which modules it holds to 100% is decided by looking at `lib/`, not by a list in
the script. Until 4.73 it named three paths in two places - once as `cover`'s
`--select` arguments and once in the loop that read the result - and
`lib/Tira/OnboardWeb.pm` was in neither, so it carried no coverage requirement
and the gate passed without mentioning it. The run now ends with
`gate-run: checked coverage for ...` naming what it held, and announces any
module it skipped. A module can be skipped only by appearing in the script's
`EXEMPT_COVERAGE` list with a reason written beside it, which is empty today -
the difference being that an exemption somebody wrote down is a decision, and a
module missing from a for-loop is an accident. TKT-594.

**A coverage refusal names the lines, since 4.77.** It used to print the module
and its percentage and stop, while the `Devel::Cover` database that knows which
statement is missing sat in `cover_db` beside it — and finding the line by hand
cost a session twice, most recently `lib/Tira.pm:12134` after two failed attempts
at parsing the text report, whose column layout is not a contract.
`tools/coverage-holes` asks the database instead and prints `file:line` for every
uncovered statement and subroutine, the subroutine by name as well, beneath the
percentage that proves the threshold was applied:

```
gate-run: coverage is below 100% for lib/Tira.pm - no record written: lib/Tira.pm 99.8 100.0 99.8
  lib/Tira.pm:12134
  lib/Tira.pm:8826 sub _task_changed_mark_seen
```

It runs inside the container, because `gate-run` deletes `cover_db` there and
judges coverage afterwards on the host from captured output — so that is the only
moment the answer can be taken. It cannot fail the run: a gate that refused
because its *explanation* broke would be worse than one that explains nothing, so
a refusal that finds no lines says so rather than printing the percentage alone.
Above twenty holes it caps and says how many it held back; `--all` prints every
one. Ask it yourself with `tools/coverage-holes --db cover_db`. TKT-593.

Without `--pid`, the 600-second ceiling was shorter than either gate this
repo ran at the time - coverage at 846s, pre-push at 15m and counting - so
the commonest legitimate reason for a suspension (waiting on a gate) always
outlasted the longest suspension that could be given, and the same reason
was re-supplied over and over as it kept expiring mid-gate. The push gate is
no longer one of those: 4.62 took the suite out of it and it now finishes in
seconds. The coverage gate still is, and it is still the reason `--pid`
exists. `--pid` makes
the reason literally true instead of approximately true, naming the
running gate's own pid:

    d2 tira.rule.suspend --rule priority-skipped --seconds 1800 --pid 12345 --reason "waiting on the push gate"

It lifts as soon as that process exits, or at 1800s if it never does. TKT-361.

The enforcement log entry this writes carries `rule`, `seconds` and `reason`
as fields under a `fields` key, alongside the same prose `detail` a person
still reads - until 3.46 the entry was prose only, so counting or grouping
suspensions by rule needed a regex against a sentence never meant to be
parsed. An entry written before 3.46 carries no `fields` key at all and
still reads back correctly. TKT-348.

`tira.police.suspend` quiets police entirely, which is right when an agent needs
to concentrate and wrong when one rule is chasing one card. **Per card is the
grain that matters**: a card being worked hard collects comments faster than
anybody can fold them, and silencing the whole bridge to get through that
afternoon makes the escape hatch worse than the noise it escapes.

Every other rule keeps watching throughout, and the same rule keeps watching
every other card. It picks itself up when the time runs out — there is nothing
to switch back on — and every putting-down is in the enforcement log with its
rule, its card, its length and its reason, because a silence nobody can account
for is worse than the noise it replaces.

### `tira.card.required`

What a complete card is: the fields every card must have before it can claim to
be finished.

Takes no arguments beyond `-o FORMAT`.

There used to be two definitions - police read one and the push gate kept its
own - and they disagreed in both directions at once. The same card at the same
moment was missing a description to one and missing a parent to the other, and
neither mentioned the other's field. The engine owns it now and anything else
asks, which is the only arrangement where they cannot drift apart again.

Two of the fields carry exceptions that belong to the definition rather than to
whoever is reading it: a SOW has no parent because it sits at the top of the
tree, and a card labelled `standalone` is saying somebody meant it to have none.

The answer is `{"fields": [...], "exempt": {...}}`, not a flat list - until
3.78 the exceptions above existed as this paragraph and nowhere else: not in
this command's own JSON, not in `tira.skills`, and the push gate
(`tools/card-holes`) carried an independent hardcoded copy of the identical
two exceptions, a fourth place they could have silently drifted from. A
caller building a completeness check from this command's field list alone
used to flag every legitimately parentless card - 169 of 304 live cards on
this project's own board at the time, every one of them standalone. Read
`exempt.parent.types` and `exempt.parent.labels` alongside `fields` now,
rather than assuming the field list applies unconditionally. TKT-285.

### `tira.column.endings`

Which columns this board says work ends in.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--type TYPE` | no | `sow`, `epic` or `ticket`. Omit to ask for all three. |
| `-o FORMAT` | no | `toon` (default), `json`. |

A column marked with `tira.column.update --terminal` is an ending; a board that
has marked nothing ends in one called `done`.

Naming `--type` returns a flat list, unchanged from before. Omitting it returns
a hash keyed by all three types - `column_roles`'s existing answer to the same
question - rather than silently picking one type and returning its list with
nothing marking it as scoped. That silent scoping is what TKT-342 reported: the
bare answer on a real board read as "this board declares one ending column" when
it was one type's answer among three, and the natural response to a seemingly
under-declared board - going and marking the others terminal - would have been a
config change made for no reason.

Asked rather than worked out, for the same reason `tira.card.required` exists.
The push gate had its own answer, read from the `done` column role, and could
not read a board that marks its ending instead of naming it - it refused to run
on one - while on a board that had declared no roles its answer came out empty
and every finished card was judged as work still in progress.

### `tira.police.outstanding`

Each row carries `id`, `rule`, `policy`, `ref`, `assignee`, `action`, `seen`,
`tone`, `first_seen` and `last_seen`. A police pass already named the policy
that raised a finding; the outstanding list dropped it until 3.61 - the one
field that says WHICH declaration to change was present where nobody acts
and absent where everybody does, worst where a rule is declared more than
once (`card-duration` on this board's own 8 columns, `checklist-idle` on 7).
`policy` reuses what the pass already computed rather than inventing
anything. TKT-380.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--exit-nonzero-if-any` | no | Exit 1 while anything is outstanding, 0 when clear. An error still exits 2, so a scheduled job can tell clean from findings from could-not-look. Opt-in: without it the exit status is what it always was. |
| `--fresh` | no | Run one police pass inline before reading, instead of answering from whatever the last pass wrote. Opt-in, because a read that quietly ran a pass would move escalation counts because somebody asked a question - see below. Without it, behavior is exactly as it always was. |
| `--by-rule` | no | Group the default output by rule instead of by chased/log-only, each card listed once per rule even when two policies for the same rule matched it. Rules somebody should act on sort before ones the board only logs. `-o json` is unaffected either way. TKT-291. |

Since 2.68 the exit status is taken from the command's own count of findings
when it has one, rather than from the rendered rows. 2.62 gave the default
output a summary - prose rows saying how many are outstanding and as of when -
and `--exit-nonzero-if-any` counted those rows, so a clean board's one line of
prose read as one finding and exited 1 while saying "No violations
outstanding" in the same breath. Counting rows is still the fallback for every
command whose output genuinely is its findings; a command that summarises or
groups states its count explicitly instead.
| `-o FORMAT` | no | `toon` (default), `json`. |

The exit status was the same on a clean board and on one carrying violations,
so a job scheduled to run this produced a log nobody opened and a status nobody
could alarm on — which is how 154 violations accumulated over two days on the
board that reported it, 153 of them `log-only` and so never on the bridge the
agent watches. The full records are ten lines deep and thirteen fields wide;
those 154 came to 1387 lines, which is a data dump where a work list was wanted.

The default output says **when the answer was taken**, and which findings the
board is chasing:

```
2 outstanding, as of the pass at 2026-08-18T12:05:00Z
1 to act on:
  VIO-0002 orphan-card TKT-001 seen 2
1 only recorded, because the board declared them log-only:
  VIO-0001 card-unassigned TKT-001 seen 2
```

Until 3.79 those rows were a plain Perl array of strings, which the default TOON renderer draws as a single inline "primitive array" - every row comma-joined behind one bracketed count and quote marks, so a reader had to parse past that to find the first thing. Each row is now its own line. `--by-rule` groups the same findings by rule instead:

```
2 outstanding, as of the pass at 2026-08-18T12:05:00Z
orphan-card (1):
  VIO-0002 orphan-card TKT-001 seen 2
card-unassigned (1):
  VIO-0001 card-unassigned TKT-001 seen 2
```

TKT-291.

Both of those were asked for. The list reads the violation ledger, and **only a
police pass writes it** — so the answer is as of the last pass, and saying so
matters because the instruction for clearing violations ends "then run
`tira.police.outstanding` again and confirm that violation is gone". Fix the
fault, ask again with no pass in between, and the count does not move by
default: it is not re-evaluated on read, because a pass costs seconds, writes
the ledger and puts lines on the bridge, and a read command that quietly ran
one would move escalation counts because somebody asked a question.

**`--fresh` is the opt-in exception.** The background watcher that keeps the
ledger current ticks on its own interval (30 seconds by default), so the exact
scenario the instruction above walks through - fix, then ask - could still read
as open for up to that long, for no reason but that nothing had told the ledger
yet. Measured live: a fix at 13:40:56 still read as outstanding "as of the pass
at 13:40:33" at both a 2-second and a 5-second recheck, only clearing 36 seconds
later. `--fresh` runs the same pass the watcher would, inline, right before
reading - the loop that clears violations does not have to sleep and guess
whether a fault is actually gone. TKT-423.

An empty board now distinguishes the two things that used to print alike:

```
No violations outstanding, as of the pass at 2026-08-18T12:05:00Z
This board has never been policed, so nothing has been checked
```

And a `log-only` finding is named as one. Both kinds carry tone `note`, so tone
could never have told them apart — which is the whole of the complaint that
raised it: *this outstanding command is act-on-it when the agent looks at it;
they won't act on it but just log only.*

`-o json` is unchanged and remains a bare list of the full records, because that
is what scripts and the clear-violations loop pipe.


What is still true, rather than everything that ever happened.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--store PATH` | no | Police's own state, if it is not in the usual place. |

One entry per finding rather than one per telling, carrying the rule, the card,
how many times it has been said, when it started and how loud it has become. A
finding that was dealt with leaves the list, which is the half that makes it
worth reading.

The bridge is a stream and is right to be one, but a stream can only be read
from where you joined it: it replays everything on connect and repeats each
finding as it climbs. The enforcement log is flat - every row is something that
happened, and nothing on a row says whether it is still true. So the question
"what have I not dealt with" could not be asked, and therefore was not: one
finding on this project's own board stayed open for two and a half hours,
escalating from note to critical, and was read four times and acted on never.
An answer that depends on somebody remembering to look is the thing this
subsystem exists to remove.

### `tira.police.freshness`

When the last pass ran, how long ago that was, and whether that is recent enough
to trust. Since 4.78.

`tira.police.outstanding` answers what is outstanding *as of the last pass*, and
on a clean board that answer is an empty list. On a board whose bridge stopped
eleven hours ago it is also an empty list - the same bytes, with no field to
compare and no arithmetic a caller could do. Measured on a real board on
2026-08-29: a pass at 03:38:41, read at 14:41:50, unchanged, while the board
reported itself clean all day and a `card-duration` policy sat an hour past its
age in that silence.

```
last pass 2026-08-29T03:38:41+0100, 11h 3m ago - stale, so an empty answer from tira.police.outstanding means nothing
```

`-o json` answers `{ taken_at, age_seconds, stale }`, so a caller acts on one
field instead of doing date arithmetic.

**A board nobody has policed is reported stale, not fresh.** `taken_at` is null
and `stale` is true, because "nothing has been checked" and "nothing is wrong"
must not be the same answer - which is the whole reason this command exists.
Reporting an age of zero there would put a confident number on an absence.

**So is a pass time that cannot be read.** A stored stamp that will not parse
gives `stale` true and no `age_seconds`, and the human output says `UNREADABLE`
rather than printing the value as though it were usable. Three ways to be stale -
missing, unreadable, or old - and they are one idea: in none of them can the
board's silence be trusted.

**Stale means older than 300 seconds**, ten times the watcher's default
thirty-second interval. A bridge that has missed ten consecutive passes has
stopped rather than run late, and the threshold is a multiple of the interval
rather than a round wall-clock figure because that is what it is judging.

**Why this is a separate command rather than a richer payload.** `-o json` on
`tira.police.outstanding` stays a bare list, and two other projects pipe and
index it in the loop they use to decide whether work is finished. Changing its
shape would break them silently, in the one command where silence is worst.
`TKT-354` chose one-shape-always for `tira.next` in 3.48, and that precedent does
not transfer: that command had no documented consumers outside this board. The
cost of a second command - a question answered somewhere other than where it is
asked - is paid by `tira.police.outstanding` itself, which names this command in
its own output when the pass it is reporting on has gone stale. TKT-684.

### `tira.policy.bridge.logs`

Read the enforcement log: what police has had to say, and every suspension that
was asked for.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | no | Only what concerns one card. With none, everything. |

**There is no command to write, change or remove an entry, and that is
deliberate.** A log that exists to hold somebody to account cannot be one they
can write - which is why even the agent's own words about its own suspension
reach the record through police rather than around it.

This was called `tira.police.log` until 1.41 and that name still answers, so
nothing breaks on upgrade. It was renamed because the old one said the wrong
thing: see **Whose command is it** below.

### On the card dialog

Opening a card on the live board shows a **What police has said** section: the
card's enforcement log, with when, what kind, and what was said, and the number
of entries in the heading.

It offers nothing to change. Police writes that log and nobody else may - there
is no command to add an entry, and a button on the page would have been the way
around that. A card police has never mentioned shows no section rather than an
empty heading.

### An option a command will not act on

The argument parser is shared, so every command sees every option. Where one
option names the job another option does, the command **refuses it and says
which to use** rather than discarding it:

```
d2 tira.assign.set --ref TKT-001 --assignee ada   # refused
  assign.set does not act on --assignee. Use --person, which is what it reads.
```

`tira.assign.set`, `tira.assign.add` and `tira.assign.remove` take `--person`.
`--assignee` is a real option on the record commands, where it sets the card's
assignee, and is untouched there.

The same applies to an option whose readers are known. `--field` names the field
`tira.history.list` reports on and the fields `tira.search` and `tira.replace`
work over; anywhere else it is refused, naming the options that do set a field:

```
d2 tira.ticket.update --ref TKT-001 --field "key_details+=..."   # refused
  record.update does not act on --field. Use the options that set a field -
  --key-detail, --deliverable, --acceptance, --test-step and the rest.

d2 tira.ticket.discard --ref TKT-001 --comment "Duplicate."   # refused
  record.discard does not act on --comment. Use tira.comment.add --ref REF
  --text TEXT, which is the command that records a reason.

d2 tira.ticket.move --ref TKT-001 --column implement --sdlc-gate G9   # refused
  record.move does not act on --sdlc-gate. Use tira.<type>.update
  --sdlc-gate, which is the command that sets it.

d2 tira.release.record --ref TKT-001 --gate G9 --result pass --details "..." --evidence "..." --uri https://ci.example.com/999 --fix-version 1.0   # refused
  release.record does not act on --uri. Use tira.evidence.add --ref REF
  --summary TEXT --uri TEXT, which is the command that reads it.

d2 tira.attachment.discard --ref TKT-001 --sha SHA256 --comment "Wrong file"   # refused
  attachment.discard does not act on --comment. Use tira.comment.add --ref REF
  --text TEXT, which is the command that records a reason.

d2 tira.project.update --mode chain   # refused
  project.update does not act on --mode. Use tira.project.mode --mode VALUE,
  which is the command that sets it.

d2 tira.ticket.create --title "A card" --text "the whole explanation"   # refused
  record.create does not act on --text. Use tira.<type>.create --problem TEXT,
  which is the option that carries a card body.
```

`--text` is the sharpest of these, because the name is the plausible one. It is
a real option — it is how `tira.comment.add` and `tira.question.ask` carry their
content — so the shared parser accepts it on `tira.ticket.create`, which then
has nothing to do with it. Before this refusal the card was created, the whole
record was printed back, and the command exited 0, so a caller who wrote the
explanation into `--text` got a success message and an empty card. Michael
reported it after filing a card that came back empty, having noticed only
because he read it back (TKT-849, 5.36).

The commands that genuinely read `--text` are untouched: `tira.comment.add` and
`comment.update`, `tira.question.ask`, `question.answer` and `question.update`,
`tira.search`, the `tasklist` verbs `add`, `update`, `unshift` and `slice`,
`tira.dev.found.bug_or_improvement`, and — the one that is easy to miss —
`tira.ticket.list`, `epic.list` and `sow.list`, where `--text` is a working
filter over card content.

`--status` is the widest of them, and it is the one where the refusal is only
half the answer.

```
d2 tira.comment.list --ref TKT-001 --status done   # refused
  comment.list does not act on --status. Use a list that has a status to
  filter on - checklist.list, question.list, required-action.list or
  tasklist.list - since the others have no status field to match against.
```

`--status` is parsed in the global option table, so **every** command in the
tool accepts it and nine of them read it. A sweep of all twenty `*.list`
entrypoints, run against a board carrying two items of differing status in
every list that has one, found sixteen that took the option with no status
field to act on — `assign.list`, `attachment.list`, `column.list`,
`comment.list`, `conversation.list`, `evidence.list`, `gate.list`,
`history.list`, `job.list`, `link.list`, `notify.list`, `policy.list`,
`project.link-types.list`, `project.people.list`, `record.list` (what
`ticket.list`, `epic.list` and `sow.list` all reach) and `warning.list`. Those
are refused now.

`notify.list` is sixteenth rather than fifteenth because the sweep could not
measure it: nothing in the fixture produces a notification, so it came back
empty, and an empty list says nothing about whether a filter works. It was
settled by reading `notification_list` instead, which returns `ref`, `column`
and `at` — no status to filter on.

**Where a list does have a status, the answer was to make it filter, not to
refuse it.** Michael's answer to Q-113 on TKT-748: "if `--status` goes with
`*.list` like this. We should should only those ones with the wanted status. It
is very straightforward to me. No?" The same sweep found exactly one list that
had a status field and ignored the option — `checklist.list` — and it filters
since 5.42. `question.list`, `required-action.list` and `tasklist.list` already
did.

It is the worst of these entries to have left open, and worse in kind than the
ones above rather than merely wider. They drop a value; this one answered a
question nobody asked. `--status done` on a list that ignored it returned every
item, in a shape indistinguishable from a filtered answer, and exited 0 — so a
caller reading 47 required actions back from `--status pending` concludes there
are 47 outstanding on a card that has none.

The refusal also covers `question.ask` and `question.update`, which are not
lists and which no card had reported. `Tira::CLI::Records` passes `--status`
into every question action, and neither `question_add` nor `question_update`
reads it, so both took the option and dropped it. They were found by walking the
readers rather than by anyone being bitten (TKT-748, 5.43).

`attachment.discard` genuinely reads `--comment`, but as an identifier - which
comment to detach the attachment from (`--comment CMT-001`) - not a reason, so
a value that cannot be a comment id is refused the same way the options above
are: until 3.58 it was accepted and quoted back as a missing comment
("Comment 'Wrong file' not found"), which named nothing a caller could act
on. TKT-373.

A move is not the command that sets a gate, and on a board whose rules require
the gate to move with every transition that is worth saying rather than
dropping: the whole card comes back after a move, which reads as confirmation.

That now holds for every card field rather than the two somebody was bitten by.
`--sdlc-gate` and `--comment` were each added to a hand-kept table after an
incident, and the table then covered exactly the options already known to hurt —
measured afterwards, `tira.<type>.move` was still dropping 24 of the 25 fields an
update writes, and `tira.<type>.create` was dropping all eight `--set-`
replacements.

```
d2 tira.ticket.move --ref TKT-001 --column implement --assignee ada   # refused
  record.move does not act on --assignee. Use tira.<type>.update
  --assignee, which is the command that writes it.

d2 tira.ticket.create --title "..." --set-key-details FILE   # refused
  record.create does not act on --set-key-details. Use tira.<type>.update
  --set-key-details, which is the command that replaces it.
```

The list is the one `record_update` itself iterates, so a field added there is
refused on the commands that will not write it without anybody remembering to
add it — which is the property a table extended one incident at a time cannot
have.

Two things are deliberately untouched. `tira.<type>.create` reads all eighteen
append fields and loses none, so only the replacements are refused there — the
obvious rule, that only an update writes fields, is wrong. And `--title` on
`tira.<type>.clone` is genuinely read and keeps working; it is also a display
flag on `tira.dashboard`, which is why the refusal is scoped to the record
commands that move a card about rather than applied everywhere.

### A refusal that names the option

A command that refuses for want of an argument says which option supplies it,
and one that refuses a value says which option carried it:

```
d2 tira.assign.list
  Record reference is required - supply it with --ref

d2 tira.column.add
  Invalid column name - the option is --name
```

The engine raises those messages and has no notion of a command line, which is
why they name a thing rather than a flag; the flag is added where the two meet.
Three refusals name no option, and none of them is about an argument: a
collector that is not installed, a project with no heartbeat, and a directory
that is not a git repository.

This is narrow on purpose: there is no per-command list of the options each one
uses, and inventing one would refuse things that work today. What is declared is
the set where a wrong name looks accepted rather than unknown — which is the set
that misleads. A command that reports success without doing anything is worse
than one that fails.

### Whose command is it

Three commands, and the names now say which is which.

| Command | Whose | What it is |
| --- | --- | --- |
| `tira.police` | **the owner's** | The watching loop, run in a terminal they leave open. An agent never starts or restarts it. |
| `tira.policy.bridge` | the agent's | The channel it listens on, kept running while it works. |
| `tira.policy.bridge.logs` | the agent's | A read of what police wrote. It changes nothing. |

`tira.police.suspend` is the agent's too: it is the agent asking police for
quiet, and it keeps its name because it is asking *police* for something —
unlike the read, which is not asking police for anything at all.

This is written down because leaving it unwritten was expensive. An agent told
"police is mine" gave up the log as well, which is the honest reading of a
shared prefix, and stopped seeing every suspension and escalation ever recorded.
It took three corrections to get the boundary right, and it was wrong in both
directions on the way. **Giving up the read fails silently**: a read nobody
makes and a log with nothing in it look exactly the same.

### `tira.policy.bridge`

**The agent runs this** and acts on what arrives. One way: police speaks, the
agent listens. Shows what is already outstanding when it starts, not only what
happens next.

**A policy set without the bridge running is worse than no policy**, because it
looks like cover.

### `tira.policies`

Prints `docs/POLICIES.md`: the onboarding walk-through, every rule and action,
and a hundred worked use cases. Answers the same way with `--help`.

### `tira.search.index`

Builds the search index for a project. Searching then skips a card whose text
cannot match without parsing it, and parsing is what reading a board costs.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `{indexed, path}`: how many cards, and where the index is. |

The filesystem is the database, and an index is a second copy of the truth. The
moment a read believes the copy, every guarantee built on that premise is gone
- so each row is keyed by the content hash of the file it describes. A row can
never describe anything but the exact bytes on disk, because a changed file has
a different hash and simply misses. There is no such thing as a stale row to
detect and nothing to fall back from: the files always win, by construction
rather than by care.

A corrupt, unreadable or missing index is not an error. Search reads the files,
exactly as it did before any index existed. Ordinary writes keep it current -
they already hold the project lock - and rebuilding is deleting it and running
the command again. A project that never runs it has no index and needs no
SQLite installed at all.

### `tira.column.roles`

Say which column plays which role, so a rule can be written against what a
column means rather than what it is called - and still works after somebody
renames it.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--type TYPE` | to set | Which board. Reading without it answers for all three. |
| `--role NAME=COLUMN` | no | Repeatable. With none, reads the roles back. |
| `--remove-role NAME` | no | Repeatable. Takes a declared role back. |
| `--reason TEXT` | with `--remove-role` | Why it went. Required. |
| `--author ID` | no | Who removed it, for the log. |

Until 2.63 a role could be declared and never taken back: `--role` merged what it
was given into what was there, nothing deleted, and an empty value read as
malformed rather than as a removal. A role typed wrong was permanent, and undoing
one command meant editing `.tira` by hand. `--remove-role` deletes it - unless a
policy names it, in which case the refusal says **which** policy, because a rule
whose role stopped existing matches nothing at all, silently, while somebody
believes it is still protecting them. That is the same failure the declaration
guard already refuses in the other direction.

A removal is accountable. `--reason` is required, on the same ground
`tira.rule.suspend` requires one - a change nobody can account for is worse than
the mistake it corrects - and every removal is appended to a log the board
carries, with **who, why, when, and which column the role pointed at**, readable
even after the role itself is gone. The reason belongs to the removal alone:
passing one beside `--role` is refused rather than stored somewhere nobody would
find it.

Columns are per board, so roles are too - but "which column is the backlog" has
an answer for every board, and reading without naming one answers for all three
at once. Setting is different: writing roles onto a board nobody named is a
surprise, so it is refused, and the refusal is a command that can be run as it
stands rather than the name of an argument.

The vocabulary is the project's own; Tira matches a role without needing to
understand it - with two exceptions, named here rather than left to be
discovered. **`done` is read by Tira itself**: `parent-ahead-of-children` and
`card-unlinked` both ask which column means finished, to leave shipped work
alone, and each says so out loud when no board has told it -
"cannot tell which column means finished on this board. Say so once:
tira.column.roles --type ticket --role done=COLUMN" - naming the policy's own
`--type` in the fix command (or a neutral `--type TYPE` placeholder when the
policy applies to all three), never a hardcoded one. TKT-437. **`entry` is read by
`tira.<type>.create`**: once declared, `--column` naming anything else refuses,
and omitting `--column` lands the card in the entry column rather than the
fixed `backlog` default - closing the bypass TKT-426's chain check leaves open,
a card started directly where the chain check would otherwise refuse it to
move. CLI/agent path only; the browser dashboard's create flow is unaffected.
A board that names no `entry` role is unaffected too. TKT-428. Every other
role, including `in-progress`, is matched rather than understood: a policy can
name one with `--enter-role`, `--before-role` or `--column-role`, and Tira
never reads it on its own account. `entry` alone may be declared more than
once (`--role entry=A --role entry=B`), accumulating rather than the last one
winning - a board can start new cards in more than one place. With several
declared, `record.create` with no `--column` lands in the first one declared,
and `--column` naming any of them succeeds; naming a column that is none of
them refuses, listing all of the declared entries. A board with zero or one
entry column is completely unaffected. TKT-496.

Because `entry` is read on the create path, that path also has to survive
being asked about a board that is not there. **A create run outside any
project now refuses the way the other board-seeking commands do** - `No Tira
project found from '<the directory it searched>'`, the message
`discover_project` raises and `record.show` and `comment.add` were both
measured giving in the identical condition - naming where it looked, so a
caller who is in the wrong directory can see that that is what happened.
It said `Can't use an undefined value as a HASH reference at
lib/Tira/CLI/Records.pm line 36` until 4.80, alone among the commands, and
running a create from the wrong directory is the most ordinary mistake
there is. The entry-role lookup is guarded so that a board declaring no
entry role still creates cards, and the guard was being applied to the
lookup's result rather than to the lookup, so the one failure it existed
to absorb was the one that escaped it. TKT-747.

**The dashboard's Columns dialog can declare `entry` too, since TKT-494.**
Each column row carries an Entry checkbox; saving sends the whole checked set
through `column_roles_set`, replacing the declared entry columns the same way
repeating `--role entry=X` on this command does - not an add-only merge. A
save that never touches the checkboxes sends no `entry` field at all and
leaves the declared entry columns exactly as they were.

Until 1.97 `in-progress` was a second exception and a silent one. Whether any
card was being worked - which `work-without-card` rests on - counted only cards
in the column that role named, so a board declaring `in-progress=implement` with
five columns work happens in had four of them reading as nobody working. It now
asks the board where work happens, the same question `card-unassigned` and
`priority-skipped` ask: not protected, and not marked `--terminal`. Every role is optional - most projects have a column for very
few of them, and the absence of one is not a problem. A role naming a column
that does not exist is refused, because a role pointing at nothing would make
every rule written against it match nothing at all, silently.

## Which numbers in these documents you can trust

Numbers appear in these documents in two ways — as a claim in prose and as part
of a transcript — and only one kind is guaranteed to be current.

Two prose claims are guarded. How many use cases `SKILLS.md` lists, checked
against its own `UC-` entries, and how many rules police the board, checked
against `policy_rules()`. Since 4.76 the second is matched by the shape of the
claim — a number ahead of the word `rules`, with at most two words between them
— in any markdown file the repository carries outside its build and dependency
directories: this one, `README.md`,
`SKILLS.md`, `docs/POLICIES.md` alike — rather than by one phrasing of one
sentence, so it holds a wording nobody has written yet. Those two you can take
as true of the version you are reading.

Every other number in prose is unguarded. It was correct when it was written and
nothing checks that it still is, so treat it as a claim about the version it was
written for.

A number inside a fenced or indented example is a transcript. It records what
somebody's run printed, it is deliberately exempt from the guard, and it is not a
statement about your board — the sample release evidence reading `Full suite run,
6540 tests` is a worked example of the shape, not a count of the current suite. A
transcript figure may still happen to be current; nothing promises it. Run the
command if you need the live one.

The distinction is enforced rather than described, and it is why every
document's fences must close: an unclosed opener inverts every block after it,
so prose starts being read as an example and stops being checked. `SKILLS.md`
carried one for eighteen days and one of its three rule-count claims sat inside
an example block nobody wrote. TKT-704.

## Every write says who made it

`--author` (or the `TIRA_AUTHOR` environment variable, read when `--author` is
omitted) is required on every command that writes a journal or history entry:
moves, record updates, comments, checklist and required-action entries, gates,
evidence, and assignments. A caller supplying neither is refused - "A change
needs to say who is making it" - rather than writing an entry attributed to
nobody. The browser dashboard is unaffected: every mutating route already
threads the signed-in person through automatically. TKT-457, TKT-466.

## Accumulating record fields

On record update, repeated `--key-detail`, `--deliverable`, `--acceptance`,
`--test-step`, `--bdd`, `--atdd`, `--scope-in`, and `--scope-out` values append
in supplied order. Existing values are retained. The corresponding `--set-*`
JSON-array options are the explicit wholesale-replacement controls for all
eight content arrays, including `--set-scope-in` and `--set-scope-out` -
an empty array clears the field rather than leaving it unchanged. TKT-293.

## A truncated read cannot be written back

`description`, `problem_or_feature`, and `solution_needed` truncate at 2000
characters by default on every read (`show`, `history.list`), marked honestly
with `_truncated`/`_length` alongside the shortened text, plus a
`_hint: "use --full to read it whole"` naming the fix in the same output -
`--full` on either command returns the whole thing. Writing a value back
through `ticket.update` (or `epic.update`/`sow.update`) that exactly matches
a truncated read of the field's *current* stored value is refused, naming
`--full`: a read-modify-write done without `--full` would otherwise destroy
everything past character 2000 silently, since the truncated flag never
travelled into the write. A genuinely shorter rewrite, written on purpose, is
unaffected - this is an exact-match check against what a truncated read looks
like, not a length limit. TKT-400. The hint applies the same way to a
truncated `gate_passing_log` entry's `details` or an `evidence` entry's
`summary`, since both share the same truncation logic. TKT-402.

## A card that shipped no release

`--fix-version` records which release contains a card's work, and
`card-metrics --require fix_version` is how a board makes sure the question is
answered. Some cards have no honest answer: a documentation card, a card whose
whole deliverable was asking questions and getting them answered, a card that
was worked and then overtaken. Nothing shipped, so no version is true.

**Write `none`.** It is the reserved word for exactly that, and it satisfies the
rule the way a version does:

    d2 tira.ticket.update --ref TKT-001 --fix-version none

Two cards on this project's own board reached done that way and sat at CRITICAL
eighteen times each, because the only alternatives were writing a version that
was not true or declining the rule for everybody. A violation nobody can close
is worse than no rule, and it teaches whoever reads the bridge that some lines
are not worth acting on.

**One word, not several.** `n/a`, `-`, `None` and `not released` all satisfy the
rule too, because it only tests whether the field is empty - and that is the
danger. If every card invents its own word, nobody can ask how many cards
shipped nothing, and `none` quietly becomes a way of switching the rule off one
card at a time. Which is why it is written down here, and why the cards claiming
it are countable:

    d2 tira.ticket.list --fields ref,fix_version -o json

**It is not a way to answer the question later.** A card that will ship in a
release it does not know yet has no version because the work is not finished,
which is what the rule is for. `none` says the work finished and shipped
nothing.

## Which end of the priority scale is urgent

`--priority` takes an integer from 1 to 5, and **5 is the most urgent**. This is
the opposite of the P1 convention most trackers use, so it is the one field on a
card that a reader can get exactly backwards while being certain they have it
right.

Everything agrees with that and always has: the browser dashboard labels 5 as
`Very High` and 1 as `Low`, and a board ordered by priority puts 5 at the top,
because the question a column answers is what to pick up next. What was missing
was anybody saying so - the direction lived only in the dashboard's own labels,
so a reader working from the command line had nothing to check an assumption
against. The refusal for an out-of-range value now states it too.

A card with no priority is unassessed rather than lowest. It sorts last and says
so, rather than pretending to a number nobody chose.

## What stops a card moving on

Three checks run on a forward move through the CLI or agent path, in this order, and each refuses with the thing it wants:

1. **The column chain** - the destination must be a declared next step. Refuses naming the column you should go to first.
2. **The current column's required actions** - any still unmarked refuses, naming them.
3. **Unjudged answers** - a question answered but never marked refuses, naming the question and the `tira.question.mark` command that settles it. Reading an answer is automatic and does not count; the gate reads the question's own `mark`, so there is nothing to satisfy but the judgement itself. An unanswered question, a discarded one, and an answer marked `not-ok` all pass freely - the gate wants an assessment, not agreement. TKT-584.

A **backward** move is unconditional against all three, because the thing left unmet may be exactly what the card is retreating to fix.

When a move IS refused for required actions, the message names each blocking item with the `REQ-NNN` id you need to mark it done, one per line, and ends with a `tira.required-action.update` carrying a real id rather than the `REQ-NNN` placeholder it used to print. The lines are in the message and not yet in what you see: a refusal is serialised as one error string and every output format escapes the newlines, which TKT-658 covers. `tira.required-action.list --blocking` asks the same question without attempting a move - what the card's current column still owes - where the command without the flag returns every item across every column. Both come from one selection, so they cannot disagree, and an exempted item drops out of both. TKT-598.

A fourth guard runs on the way IN. A column can declare entry required actions with `tira.column.update --entry-required-action TEXT`, and a move into that column is refused while any of them are unmarked - the card stays where it was, and the refusal names each item with its id and a command that runs. The items are put on the card before the refusal, because an entry requirement is satisfied from outside the column that demands it; a list that only appeared once the card was inside would leave nothing to mark. Forward moves only. Marking one done costs the same `--command`/`--proof` pair as any other required action, and a card exempt from an item is let through. TKT-591. Until 4.89 the entry check identified which stored items were its own by matching their TEXT against the column's live entry list, and that had one real gap: renaming the column's entry wording silently un-gated every card already carrying an item under the OLD text, with nothing signalling that anything had changed. Every item a column's entry template itself populates now also carries a marker saying so, and the entry check trusts the marker OR a live text match - either is sufficient. The marker is what survives a rename; the text match is what keeps doing-the-work-early (a card-specific `required-action.add` item, worded and columned the same as the template, marked done ahead of time) satisfying the entry requirement exactly the way it has always satisfied an exit one. TKT-652. An earlier version of this fix trusted the marker exclusively - rejected before it shipped, since it broke that established capability: a manually-completed item stopped being recognized as already-there, and a fresh duplicate pending item was created and announced as outstanding on the very next move even though the work was already proven (t/422 caught it).

The browser column editor shows both templates per column, and since 4.71 shows
them in the order a card meets them: the entry list above the exit one, each
labelled for itself rather than one being the list without a qualifier, and each
add field naming which list it adds to. The stored shape is unchanged - the two
have always been separate fields with separate flags, and the editor was simply
the one surface that did not say which was which. TKT-651.

**A card created into such a column through the CLI gets them too, since 4.67,
and is never refused for them.** This covers `tira.TYPE.create`; the browser's
own create flow calls the engine directly and seeds neither template, which is
unchanged here and is its own gap. Until then the create path seeded only the exit template,
so a card created straight into a column with an entry list was born past that
gate: no items recorded, nothing checking it, the gate skipped rather than
failed. It now calls the same function the move path uses.

Creation cannot be blocked on one, and the reason is worth stating because it
decides the design rather than softening it: a required action's proof is a
command and its output, and before the card exists there is nothing to run a
command against. So the items are recorded as pending and the caller is told on
STDERR:

    BTK-001 was created in implement carrying 1 entry required action(s), owed
    now: REQ-003 ENTRY: say what you will run, and 2 exit required action(s),
    owed before it leaves implement: REQ-001 EXIT: prove the thing; REQ-002
    EXIT: and the other thing
      Work them one at a time: d2 tira.required-action.update --ref BTK-001
      --id REQ-003 --status done --command TEXT --proof TEXT

Each item is named with its own id, and the command at the end carries a real
one, so acting on the message is copying what was printed rather than
cross-referencing texts against `tira.required-action.list` - the same
reasoning the refused-move message follows, and the same cross-reference that
has twice put proofs against the wrong ids on this board.

The two kinds are named by what each is *for* - owed now, against owed before it
leaves. **The exit half of that message fixes an older silence**: the exit
template has been seeded on create since TKT-439 and printed by nothing, so an
agent met those items only when a move was refused.

An entry action that cannot be put on the card - an empty one in the column's
template is the reachable case - is reported with its reason and does not stop
the card being created, nor is it counted among what the card now owes:

    BTK-001 was created in implement, but 1 of that column's entry required
    action(s) could not be put on the card: (an empty entry action) - Required
    item is required

One failure does not silence the rest; items that did attach are still named.

An item named in both templates, or twice in one, is mentioned once - the card
stores it once, and a message reporting the templates raw would give a count
the card contradicts and print the same `REQ` id twice beside itself.

On STDERR rather than stdout because stdout is the card - `-o json` has to stay
a document an agent can parse - and because the browser move path already
reports its entry-population failures there. A column with neither template
prints nothing at all. TKT-681.

None of the four can be skipped by leaving `--type` off - the entry guard included, since it recovers the board type the same way. They need a concrete board type to know which columns exist, while `record_show` and `record_move` resolve a card by ref alone - so a caller who omitted the type used to get a move that succeeded and a guard that returned "nothing to refuse". A card was walked through nine gated columns that way, with 75 required actions pending and not one refusal. The type is now recovered from the record the engine has already loaded, so the guards answer whether or not the caller said which board, and the recovered value goes back into the caller's arguments so the "move here first" line the chain refusal ends with names a command that runs - `d2 tira.ticket.move` - rather than a name with the type missing from the middle of it. The entry guard's refusal prints the type as well, in the `tira.column.update --type TYPE` line that ends it. The other two name their own command, `tira.required-action.update` and `tira.question.mark`, and never print the type. TKT-597. A related promise about what you are told before you call: a command's usage line names the arguments it refuses without, including the `--command`/`--proof` pair that marking a checklist item or a required action done costs, written as one bracketed unit because the pair is required together. Forty-nine commands still print a bare `[options]`; that set is a written-down ledger a test holds, so no new command joins it unnoticed. TKT-575. Moving back to `backlog` additionally resets the tasklist items that were working on the card, leaving `done` ones alone, crossing session boundaries deliberately, and skipping - but naming - any task linked to more than one card. TKT-596.

**Which refusal you get, when more than one applies.** The four guards run in a
fixed order and each returns as soon as it refuses, so the first to object is the
only message you see:

1. the chain - did the card come the way the board declares
2. the exit required actions - is the column it is leaving finished
3. the unjudged answer - is an answer still waiting on a judge
4. the entry required actions - is the column it is entering ready for it

Entry is checked **last**, which is not what the pairing of "entry" and "exit"
suggests. A card that has skipped a column and also has an unmet entry item is
told about the chain, and meets the entry list only once that is cleared - so
clearing one refusal can reveal another, and a caller working through them is
not going backwards. TKT-662.

A move to `discard` is exempt throughout.

## What a date-time field will take

`--start-date` and `--due-date` want an ISO 8601 date-time **with an offset**,
and take all three spellings of one:

    2026-08-19T09:00:00+0100      basic, and the one Tira itself prints
    2026-08-19T09:00:00+01:00     extended
    2026-08-19T08:00:00Z          zulu

The basic `±HHMM` form matters because it is what every timestamp Tira writes
carries — `created_at` and `last_updated` read `2026-08-19T09:00:00+0100` — so
until TKT-572 a stamp copied out of a card was refused when pasted back into
one, with a message about ISO 8601 aimed at a value that already was ISO 8601.
The refusal now names the three shapes instead of naming a standard the input
already met.

An offset is still required, and deliberately so: widening what is accepted
must not turn the check off. A local time with no offset is ambiguous, which is
the thing the mandatory timezone exists to prevent, so it is still refused.

The three shapes above are checked for genuine calendar validity, not just
digit counts. Until 4.87 the shape check alone decided acceptance, so
`2026-13-45T99:99:99Z`, `2026-02-30T00:00:00+0100` and an offset of `+9999`
were all accepted and stored - only to kill `record.list --since` and the
police/dwell rules that read a card's `due_date`/`start_date` back and do
real arithmetic on it, which refuses the same string outright. The refusal
now names which part is wrong and the value actually typed - `Due date
Month '13' out of range 1..12` - rather than repeating the generic "must be
an ISO 8601 date-time" message for a value that was already shaped like
one. The offset's own hours and minutes are range-checked separately from
the calendar fields, since the function that does the calendar checking
(`_epoch_of_datetime`, also used to read an already-stored, already-valid
stamp elsewhere) does arithmetic with an offset but never range-checks it
itself. TKT-633.

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

TKT-562: `--mode` is checked before anything is created, on both commands.
It used to be applied after the project had been fully written, so an
invalid value produced a failed command *and* a real project on disk, with
nothing to roll back and nothing saying so — "it failed" and "it half
worked" are different facts, and only one of them tells you to go and look
at the directory. The next attempt then met a project that should not have
been there. The wizard's own loop always re-asked, so this was only ever
reachable through the `--mode` flag on `project.new` (and on `onboard` when
the prompt is skipped) and through the browser onboarding form, whose mode
field renders its options as a hint and validates nothing. The refusal now
names the option and both values it takes, and it reads them from the
onboarding questions themselves, so a third mode added there cannot be
silently refused here.

TKT-555: re-running `tira.onboard` against a directory that already has
a project shows every field's current value as its default, including
now the project-mode question (single vs chain) - `_wizard_defaults`
previously omitted `mode` from what it returns, so that one question
always showed a blank default even when the project had one set,
despite the wizard's own "Editing the project already at that
directory - press enter to keep each answer" message. Pressing enter
on the blank default was always a no-op (never a silent reset), so this
was a broken promise rather than a data-loss bug.

TKT-556: the wizard's "Do all three boards use the same columns?"
question also now defaults correctly - to whatever an existing
project's boards actually have, identical or not - rather than always
defaulting to yes. `_wizard_defaults` computes column identity across
boards for its own `columns` key already; that same computation now
seeds this question's default too. Not destructive: `column_add` only
ever adds columns that do not already exist, so answering the wrong
branch previously would have added unwanted columns, not removed real
per-board ones.

TKT-560: the wizard's "Which coding agent should be reminded" question
no longer refuses any answer but the literal string `claude` -
`project_update`'s own agent handling (used by both `project.update
--agent` and `tira.onboard`/`project.new`, since they route through it)
already accepts any registered, active person, per TKT-459 - so a
project whose agent genuinely is not named `claude` can now declare it
interactively too, matching what scripted `--agent` use already
supported.

TKT-517: `tira.onboard -o browser` replaces the terminal prompt with a
disposable, no-login HTTP server (`Tira::OnboardWeb`) - one page with every
field the wizard collects, submitted once. Defaults to `127.0.0.1` on a
dynamically-picked free port (`-o browser=127.0.0.1:PORT` for an explicit
one); an invalid submission re-renders the same form with the typed values
kept and the reason shown, never a fresh page. A valid submission creates
the project through the same dispatch the CLI wizard's own answers reach,
renders a thank-you page, and stops the server for real - a further request
afterward gets a 503, and the process itself exits shortly after (a forked
watchdog sends it SIGTERM once the response has had a moment to leave the
socket).

Clearing the form's directory field and submitting anyway falls back to the
session's own directory (the one this invocation was launched for) rather
than the server process's own working directory - until 4.92 a cleared
field silently created the project wherever the onboarding server happened
to be running from, with no field marked required to catch it. A session
with no directory of its own either is refused outright, naming why,
instead of reaching the create step with nothing usable. TKT-776.

TKT-527: `-o browser=0.0.0.0:PORT` is refused for `onboard` specifically,
naming why - this server has no login at all (by design, for its one
submission), so a network-reachable session would be an unauthenticated
project-creation endpoint. `127.0.0.1`, `localhost`, and the plain default
are unaffected; `tira.dashboard`'s own `0.0.0.0` mode is a separate code
path and stays login-gated as before.

TKT-543: the form's initial `GET /` now pre-fills name/members/columns/
prefixes from whatever project already exists at the directory it starts
on, reusing the CLI wizard's own `_wizard_defaults` rather than a second
lookup - matching the CLI path's "Editing the project already at that
directory" behavior. Previously the browser form always started blank
except for the hardcoded `SOW`/`EPC`/`TKT` prefix defaults, regardless of
what was actually stored at that directory.

TKT-553: the form also offers `notify_after` (stuck-card minutes),
`agent`/`session`/`collector` (card-reminder setup), and one field per
`Tira->onboarding_questions()` entry (today, project mode - single vs
chain), each field naming its valid options the same way the terminal
wizard's own prompt does. A submission carrying these reaches
`project_new`/`onboard` the same way the CLI wizard's answers do -
`project_mode` is set afterward only when a mode was actually submitted,
identical to the terminal path. Previously none of these four had any
equivalent in the browser form.

TKT-559: `GET /` also pre-fills those same five fields
(`notify_after`/`agent`/`session`/`collector`/`mode`) from an existing
project, the same way name/members/prefixes/columns already did -
`_fields_from_defaults` was introduced by TKT-543 before these fields
existed on the form and was never extended when TKT-553 added them, so
re-opening the form against an existing project silently showed them
blank even though `_wizard_defaults` already returned the data.

`tira.project.new` bootstraps in one call what `project.create`, `project.people.add`,
`board.refs`, and `column.add` otherwise do across dozens: it creates the project,
adds each member, sets each board's reference prefix, and applies one shared column
set to all three boards. Column names are given as human text and slugified
automatically with the original kept as the label, columns that already exist are
skipped so re-running is safe, and everything is validated before the first write so
a rejected call leaves nothing behind. Prefixes are applied before any record can be
created, because board counters never rewind.

`--agent` names a real person on the project, the same way `--assignee` and
`--reporter` do — not an arbitrary string. `project.new`'s own `--members`
registers who counts; naming an agent not already among them registers it as a
person too, so onboarding can answer "who works this board" and "which of them
is the agent" as the two separate questions they actually are. `project.update
--agent` against a project where that call happens later, on a person nobody
registered, is refused with `Unknown project person`; against one
`person.deactivate` turned off, with `Project person '...' is inactive`.
TKT-459.

### `tira.policy.decline` and `tira.policy.declined`

Records that a rule was considered and deliberately not used, and lists what
has been decided.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--rule NAME` | yes (decline) | The rule being declined. Must be one that exists. |
| `--reason TEXT` | yes (decline) | Why it does not fit this project. |
| `--ref CARD` | no | Scopes the decision to one card instead of the whole board. |
| `--author WHO` | no | Who decided. |
| `-o FORMAT` | no | As above. |

**`--ref` answers a different question than declining board-wide.** "Should
this rule exist at all" and "does this rule apply to this one card" are
different decisions, so a per-card decline does not conflict with the rule
staying declared for every other card - unlike board-wide decline, which is
refused while the rule is declared. This is the answer to a card whose work
legitimately breaks a rule's assumption and has no other honest way to clear
it: `card-sandbox-missing` assumes one project maps to one repository, and a
card doing real work in a second repository could previously only be cleared
by declining the whole rule (losing the check for every other card) or left
as a permanent violation nobody could act on - "a finding that cannot be
cleared honestly is worse than one that is merely wrong." `--ref` reads back
through `tira.policy.declined --ref CARD` the same narrow way it was made.
Reusable by any rule, not scoped to `card-sandbox-missing`. TKT-303.

### `tira.policy.undeclared`

The rules this project has neither declared nor declined - the ones nobody has
decided about yet. No arguments beyond `-o FORMAT`.

The agent is the only party that can declare a policy, and police prints this
for the owner rather than for it, once, when it starts. A project lost
eighty-four minutes to an owner's answer sitting unread because `answer-waiting`
had never been set: not declined, never considered, and nothing on any board
said so. A declined rule is answered and does not appear here; a project that
has decided everything gets an empty list rather than an unknown command.

Police lists the rules a project has not declared, on every run, because a rule
nobody declared is silent in exactly the way a rule being obeyed is. It could
not tell a rule nobody had looked at from one somebody had looked at and
refused, so on a board that had made those decisions it asked an answered
question indefinitely.

**The reason is required.** Without it this would be a way of silencing the
prompt rather than a decision, and a decision with no reason recorded is
indistinguishable from having skipped the question.

Declaring a rule later clears its declining, so a project that changes its mind
does not carry a record saying the opposite. A rule that arrives in a future
release is asked about exactly as it is today, and with every rule either
declared or declined the prompt says nothing at all.

### `tira.policy.review`

The whole policy set in one place: every rule in the catalogue, exactly once,
either declared with the columns it covers, declined with the reason, or
unanswered - plus `duplicates`, policies already in the store that collide on
rule and scope, and `declined_per_card`, the same reason recorded against one
specific card rather than the whole board. No arguments beyond `-o FORMAT`.

    d2 tira.policy.review

Policies are declared one at a time, over weeks, by whoever was working. Reading
them back out of `tira.policy.list` means holding the catalogue in your head to
see what is missing - this is for the review somebody does behind the agent,
where the question is what the set adds up to rather than what one policy says.

Reading the columns down the declared side shows which of the board's working
columns nothing names, which is what `column-unwatched` reports on the bridge.
This shows it without waiting for a pass.

`tira.policy.undeclared` answers the narrower question and is what police prints
for the owner when it starts.

`duplicates` names policies already declared that collide on rule and scope -
the same comparison `policy.add` makes against a NEW declaration since 2.54,
run once across everything already stored. It exists for a board that upgraded
into that refusal carrying pairs from before it existed: nothing removes them
automatically, since which one to keep is a judgment call, but reading them out
of `policy.list` by hand means grouping the JSON yourself. Each group names its
rule and the ids that collide on it; a different scope on the same rule - a
different column, a different `--ref` - is never grouped, matching what
`policy.add` itself would still allow.

`declined_per_card` names every `policy.decline --ref CARD` recorded on this
board, each entry carrying `rule`, `ref`, and `reason`. TKT-303 added that
`--ref` scoping to `policy.decline` and `policy.declined` so a rule could be
answered for one card without declining it board-wide, but `policy.review`
kept reading only the board-wide store - "the whole set in one place" it is
documented to print was missing an entire category of decisions, and the only
way to enumerate them was one `policy.declined --ref CARD` call per card
already suspected. `declined_per_card` is a new key rather than a change to
`declined`'s own shape, so a reader already treating `declined` as board-wide
sees no difference; it is present and empty on a board with no per-card
declines, never absent. TKT-800.

### `tira.project.mode`

Says whether this project is worked by a single agent or by a chain of them,
and sets that answer.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--mode MODE` | no | `single` or `chain`, and nothing else. Without it, the command reads rather than writes. |
| `-o FORMAT` | no | As above. |

Multi-agent is built on single agent rather than beside it. A single agent is
the one somebody types into a terminal, and it owns everything: cheapest in
context and tokens, slowest, because every request goes through it. A chain is
that same agent stepping out of the work and onto the top of a chain of
command, with one agent per card, each named for the card and managed by the
agent that owns its parent.

Several rules mean different things between the two, which is why the answer is
written down rather than inferred. Reading it off the board would be wrong the
first day one agent assigns two cards to two names.

**A project that has never been asked answers with nothing, and behaves exactly
as it always has.** That is the case that matters most: every board that
already exists is one of those, and none of them should change underneath its
owner for a setting nobody turned on. `tira.onboard` asks the question before
it creates anything, and leaving it blank leaves it unset.

### `tira.conversation.add` and `tira.conversation.list`

Records what passed between the user and whoever was working a card, so the
chain above it can see what happened at the bottom.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The card it happened on. |
| `--author WHO` | yes (add) | Who said it. Must be somebody the board knows. |
| `--heard WHO` | no | Who it was said to. |
| `--said TEXT` | yes (add) | What was said. |
| `-o FORMAT` | no | As above. |

Separate from comments on purpose. A comment is somebody writing on the card;
this is a record of something said elsewhere, with who heard it. Conflating the
two would make the card's own discussion harder to read for exactly the people
who need it.

In a chain the user talks only to the core agent, which decides which direct
report hears what — so without this a manager knows what it said downward and
nothing of what came back.

### `tira.agent.sessions`

Lists every child of a card and what it would take to wake each one.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The parent. |
| `-o FORMAT` | no | As above. |

A card agent closes when its turn ends, and waking it must be a resume rather
than a fresh agent — a fresh one works everything out again, which costs tokens
and produces answers inconsistent with what the card already says. Who may wake
it is its parent, because the chain runs one-to-many downward and never the
other way.

### `tira.check.owner`

Who owes a card's final check, going the other direction: up to the parent
rather than down to the children.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | yes | The card whose final check is in question. |
| `-o FORMAT` | no | As above. |

Answers `{ref, owner, via}`. In chain mode a card is managed by the agent
that owns its parent, so that parent's own assignee is who reviews the
child before it ships — one lookup, computable from the parent, not a walk
up the whole ancestry. A card with no parent owes its own check: `owner` is
its own assignee and `via` is absent. A parent that exists but carries no
assignee reports `owner` absent too, rather than walking further up or
guessing. Composed with the two review checks that already exist —
`gate-missing` (the evidence is there) and `checklist-unmoved`/`card-stalled`
(the todo list really is done) declared on a final-check column — this
answers the fourth: who to tell. The judgement check itself, whether the
code aligns with the card, stays a person or an LLM's job; nothing here
moves a card automatically, the same way police asks and never moves.
TKT-372.

### `tira.card.holes`

Which live cards are missing required fields — a title moving through
columns as though it were real work, with nothing behind it.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--type TYPE` | no | Scope to one board; with none, all three. |
| `-o FORMAT` | no | As above. |

Answers a list of `{ref, type, column, missing}`. This is the same check
`tools/card-holes` already made from the pre-push hook, and only against
the cards a push happened to be about — measured live, 26 of 300 cards
missing both `problem_or_feature` and `solution_needed`, 24 of them still
open with no push ever having named them, unblocked indefinitely. Reads
the exact same private definition the push gate's own per-card check uses,
so the two can never disagree about what complete means. Discarded cards are
excluded — set aside, not planned — and a card reported through
`tira.dev.found.bug_or_improvement`, still sitting in the board's own
entry column, is exempt for the same reason the push gate exempts it: a
reporter knows what they saw, not how this project will fix it, and
triage is what turns a report into a ticket. It reports and refuses
nothing — filing a quick report stays as easy as it always was. TKT-374.

The handle lives on the card, set with `tira.ticket.update --agent-session`,
and is read off the board rather than from whatever spawned the agent — because
the thing that spawned it is the thing that closes. A child with no agent yet is
listed with nothing to resume, so the answer is every child rather than only the
started ones.

**Tira spawns nothing and resumes nothing.** It records what the thing that does
needs to find, which is the same boundary that keeps it invoking no shell.

### `tira.project.limit`

Says how much this project is willing to have in flight at once, and sets that
number.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--max N` | no | A whole number of cards, zero or more. Without it, the command reads rather than writes. |
| `-o FORMAT` | no | As above. |

A work-in-progress limit counts the whole board rather than the agent, and
there is no one number that is right for both a single agent and a chain of
six — two is sensible for one and absurd for the other. So the owner is asked
and the answer is stored here, and a `wip-limit` policy declares its column and
leaves the number alone.

It is read when the rule runs, not copied when the policy is declared, so
raising it quiets the rule without touching any policy. Zero is allowed: a
board deliberately frozen is a real thing to say, and refusing to let somebody
say it would only mean saying it some other way.

### `tira.project.gates`

Declares which gate names this project recognises - the one list
`tira.gate.add`'s `--gate` and every record's `--sdlc-gate` are both
validated against once it exists.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--gate-name NAME` | no | Repeatable. Declaring one or more replaces the whole vocabulary, the same way `column.roles --role entry=X` replaces its own declared list. Without it, the command reads rather than writes. |
| `-o FORMAT` | no | As above. |

Until TKT-292 both `--gate` and `--sdlc-gate` took free text with no
documented value set - measured, `--sdlc-gate` accepted `implement, verify,
tests-red, full-suite-and-coverage` and `nonsense` alike, so a typo was never
refused and `gate-missing` could neither be satisfied nor caught being
satisfied falsely. Opt-in, the same shape `column.roles` already has:
unrestricted, exactly as before, until a project declares its own vocabulary
here - then a name outside it is refused on `gate.add` and on `--sdlc-gate`
alike, naming the declared list. A project that has never declared one is
completely unaffected.

`tira.next` answers what to work next. The cards waiting in a protected
column with a priority, most urgent first and then the one that has waited
longest, as `{next, then}` - the answer, and what it was chosen over, so a
caller can check it rather than take it. A board with nothing waiting answers
with `{next: null, then: []}` - the same shape, `next` simply unset - rather
than a card there is no reason to work. Until 3.48 the empty case answered
with a bare `[]` instead, a different TYPE than the busy-board `{next, then}`
hash: a caller doing `result.next` worked every time the board had work and
raised an error the first time it went quiet, which is exactly when an
unattended scheduled caller runs with nobody watching. TKT-354.

A card held on an unanswered question is never offered either. `priority-skipped`
has refused to name such a card as passed over since it was written — parked,
not skipped — so a question is a hold the board can already read: it names the
condition, and the answer arriving releases the card. Until 2.45 only the rule
read it, so a card could be parked by the rule and offered by the command in the
same moment.

A card whose `start_date` is in the future is held the same way - the other
machine-readable, already-validated hold this board carries: a maintenance
window, an embargo, a market close, expressed as "held until a moment" rather
than a question's "held until somebody answers." The card is not offered until
`start_date` passes; a past or absent `start_date` is unchanged, and the card
stays visible on the board and in lists throughout, held rather than hidden.
Until 3.40 `work_order` read the question hold and not this one. TKT-309.

Since 2.67, `tira.next` reads which column plays the `next` role - declared with
`tira.column.roles --type ticket --role next=COLUMN` - and offers a card sitting
there ahead of priority. That is his channel, not the agent's: "you do not add
card on it. i will add which cards on it" - so nothing here writes to that
column, and a card he places there is offered ahead of priority because he moved
it there deliberately, which is a stronger signal than the number on the card.
The column's name is the project's own, so this reads the role rather than a
hardcoded name - a different board can call it anything. A board that has not
declared the role, or whose `next` column is empty, behaves exactly as before:
"if empty then pick from backlog the most high priority ones."

`tira.next` takes the same projection the read commands do — `--fields`,
`--brief` and `--truncate`. Without one it answers with every field of every
card it considered, which was 94KB on one reporting board and 223,584 bytes on
another; `--fields ref,title,priority` answers the same question in a fraction
of that. The projection is applied after the ordering, so asking for `ref` alone
still answers in the order the board enforces.

Discarded cards are never offered. `discard` is a protected column and is not
an ending, so it answered "yes" to both halves of what waiting means until
2.44 - on this project's own board that was 15 of the 24 cards returned,
including the one named as the answer. Work the board abandoned is not work
that is waiting, and the rule stopped naming it at the same moment for the same
reason.

The ordering is not this command's. `priority-skipped` has enforced it since it
was written, and asks the same method, so the rule and the command cannot
disagree about the same board. Without it a caller read every card - 1.95 MB of
JSON for 292 cards on this project's own board, to find the eleven that were
waiting - and sorted by priority and age by hand.

`tira.outstanding [-o FORMAT]` (TKT-808) answers `{questions, tasks}` -
the same project-wide totals TKT-797 already put in the browser dashboard's
sticky header: how many cards carry a genuinely unanswered question
(`questions`, the identical `_policy_questions`/`_card_blocked` logic the
dashboard and `tira.next`'s own ordering both use), and how many tasklist
items are still owed (`tasks`, counting `pending` and `working` only). An
agent working purely through the CLI had no way to answer either half of
this without iterating every card by hand or opening a browser - a real,
newly-widened gap the moment TKT-797 gave the browser its own answer.
Deliberately does NOT match `hero-counts.js`'s own current task count,
which counts every tasklist item regardless of status (a separate, tracked
defect, TKT-817) - "outstanding" means still owed, and a `done` item is not.

`done` is where work ends unless the board says otherwise. Marking another
column terminal is a statement about that column, not a withdrawal of the
default: until 2.46 it switched the assumption off everywhere at once, so every
finished card became live work in the same pass — 171 findings on the board that
reported it, 20 of 20 in the fixture. A board that means it can still mark
`done` as not terminal, because the flag has three values; it has to say so.

`tira.notify.moves` tells the owner when a card moves column, sent by police
rather than by an agent so it costs no tokens. One message per move carrying the
card reference — not one on leaving and another on arriving, which sends two
messages about one event. Off until enabled; every column notifies by default and
any is switchable off with `--column NAME --no-watch`. Nothing is sent unless a bot
token and a destination are both available: `TELEGRAM_BOT_TOKEN` for the token,
and for the destination either this board's own - set once with
`tira.notify.moves --chat ID` - or `TELEGRAM_CHATID` when the board has none. A move is remembered once
announced, so a pass every few minutes does not resend it — and a move that could
not be sent is *not* remembered, so setting the variables later does not lose it.

`tira.stale` answers how long each card has sat in the column it is in now,
reading each card's history backwards and stopping at its most recent column
move. Cards whose entry predates the history are reported without a duration
rather than with an invented one, so they never appear in an `--older-than`
result. One pass over the boards costs a few milliseconds; asking per card
through the API or the CLI costs a hundred to a thousand times more.

`tira.dwell.report` is `tira.stale`'s historical sibling: `tira.stale`
answers how long a card has sat where it is *now*; this answers how long
cards *usually* stay in each column - median, p90 and max seconds, per
column, per type, computed from every card's own recorded moves. Every
`card-duration` threshold on a board is otherwise a guess, picked by hand
and never checked against what the board itself records. `--type
TYPE` scopes to one board; with none, all three. Only completed passes
count: the span between one recorded column change and the next,
attributed to the column the card actually sat in for that span - a
card's *current* column is not a completed pass and never appears in its
own report until the card moves again, and a column nothing has completed
a pass through yet is simply absent from the report rather than shown
with zeroed statistics. TKT-366.

Read it per type before setting a threshold on a column that holds
containers. A SOW or an epic sits in a working column for as long as its
children take, so a threshold set for tickets fires on it forever and no
agent action settles it - the only settling move is finishing every child.
This board's `in-progress` holds the SOW and the epic and no tickets at all,
with a median of 4h31m but a p90 of 57h09m and a max of 5d08h against a
policy of 8h; two CRITICAL reminders fired 63 and 69 times over three days
with nothing to do about them, and re-thresholding from the p90 to 58h
settled both on the first pass. Re-threshold rather than exempt, so a
genuinely stuck container is still caught. TKT-573.

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

TKT-533: `tira.search --tasklist` also matches a tasklist item's text, id, or
a linked ref - opt-in only, so a plain `tira.search` is unaffected. A
tasklist item never carries a `column`; it appears in results (and in
`--refs-only` output) addressed by its own `TSK-NNN` id. Matching is scoped
to the caller's own `--session` (TKT-537) exactly as `tasklist.list` is - a
search under one session cannot surface another session's private item.

TKT-550: `--all-sessions` lifts that scoping for one call, mirroring
`tasklist.list --all-sessions` (TKT-539) and existing for the same reader -
a supervising agent checking several subagents without already knowing each
one's session id, who otherwise could not find an item by text across
sessions at all. It is strictly opt-in, because the boundary it crosses was
put there on purpose rather than left there by accident: without the flag,
TKT-537's privacy holds exactly as before. Every tasklist hit now carries a
`session` field, given the flag or not, since a cross-session answer that
cannot say whose item matched only reproduces the gap `--all-sessions` was
built to close - the next question is always "whose is this".

Records expose a computed `content_hash` through field selection: an opaque
stable token over every meaningful field including placement, excluding
`last_updated` and the read-time-only `checklist_done`/`checklist_total`
counts, so a touched-but-identical record keeps its hash regardless of which
fields were requested alongside it. Export adds
a `board_hash` whenever hashes are requested. `--if-changed HASH` on show and
export answers with `{"unchanged": true}` and exit 1 when nothing differs,
the full (projectable) payload with exit 0 when something does, and exit 2 on
a malformed hash — a bad token must never quietly mean "changed". Combined
with `--since`, the stricter suppression wins; conditional reads never write.

`checklist_done`/`checklist_total` ride alongside the existing `checklist`
array on every show and list response - not opt-in like `content_hash`, since
the count is cheap to compute and the whole point is not having to fold the
array by hand to get it. Computed at read time only: never stored, so a
mutation that round-trips a read (comment.add, checklist.add, and the rest)
never persists a stale copy or journals a spurious change for either field.
A checklist-less card reads `0`/`0`, not an error. TKT-407.

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

**`comments` and `checklist` only replace their one genuine prose leaf**
(TKT-690) - a comment's `body`, and a checklist item's `item` text. Both are
structured, not prose: their other leaves are identity (`id`), `status`,
timestamps, and - for a checklist item - the `proof` array recording what a
command actually produced. A pattern aimed at ordinary text used to rewrite
any of these too: `'done' -> 'FINISHED'` on `--field checklist` silently
turned a completed item into one every gate reads as unfinished, and
`'0' -> '9'` corrupted an id and produced a date no validator would ever
accept. A pattern that would have matched one of these protected leaves is
now named in the response's `protected_hits` (`{ref, field, leaf}` per hit)
rather than silently left alone or silently changed.

`tira.import --file changes.json` accepts a JSON object keyed by record ref.
Values are exact replacement fields. It validates every record and field before
writing the complete set transactionally; `--dry-run` returns the same diff
without mutation. These two are the only commands that read `--dry-run`;
every other command refuses it, naming itself and saying the change is made
rather than previewed. The flag parses everywhere because one global option
spec serves every command, so it used to be accepted and silently dropped -
`tira.ticket.create --dry-run` created the card and printed it back, which cost
eight junk cards on the Tira board itself - TKT-617 through TKT-624 - before it
was noticed. The refusal is
written as an allow-list naming `import` and `replace` rather than a list of
the commands that swallowed the flag, so a verb nobody thought to test is
refused too; that is possible here only because `--dry-run` has exactly two
readers, and it is not a general per-command option catalogue, which
`%MISLEADING_OPTIONS` explains it deliberately is not. TKT-625. Gate and evidence logs remain append-only: annotate commands
append attributed correction notes to stable entry IDs.

An empty or malformed key names the import's own JSON structure at fault -
"An import change is keyed by its own record reference..." - rather than the
generic `_record_data` wording every `--ref`-taking command shares, which
would otherwise have told the caller to supply a flag `tira.import` does not
have. A well-formed key naming a record that genuinely does not exist keeps
its own distinct "not found" message, unaffected. TKT-346.

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

`tira.changelog.check [--file FILE] [-o FORMAT]` cross-references every card's
claimed `fix_version` against a changelog file's own version headings -
`--file` defaults to `Changes`. TKT-347 found a card claiming fix_version
1.07 with no such release recorded, a real gap left by a version bump whose
changelog entry never got written; nothing had checked the two against each
other before. `fix_version` itself already refuses a value that plainly is
not a version at all - `none` and an `n/a - ...` explanation for work
outside a release are unaffected by either check. A card whose claimed
version genuinely has no changelog entry is returned in `missing`, naming
the card and the version; `released_versions` counts how many headings the
file carried.

    d2 tira.changelog.check
    d2 tira.changelog.check --file Changes -o json

## Repairing a damaged board file

`tira.doctor [--repair] [-o FORMAT]` finds board files holding bytes that are
not valid UTF-8, naming the file, the byte and its offset. It reports only,
until `--repair` is given.

    d2 tira.doctor
    d2 tira.doctor --repair

It searches for **bytes** rather than for U+FFFD. The replacement character is
what a lenient read produces when it meets a byte it cannot decode — what you
see in output, not what is on disk — so a check looking for it would find
nothing and call every damaged file clean.

A bad byte is repaired by reading it as latin-1 and writing it back as UTF-8, so
`0xD7` becomes the `×` somebody typed; substituting a replacement character
would make the damage permanent. Nothing else in the file moves. Attachments are
never touched, being bytes that were never meant to decode, and neither is the
notification database.

## Every other command

Each of these ships and is exercised by the suite. The synopsis is the one the
manual's own examples are checked against, and `tools/docs-examples-run` runs
them; the manual carries the worked use cases behind them.


### The changelog

- `tira.changes [--since VERSION]` — the raw changelog, or entries newer than `VERSION` (that version's own entry is excluded). It never exits zero having printed nothing: an empty or blank changelog is a broken or half-written copy of the skill, and it says so and names the file it read, so a script can tell "nothing changed" from "I could not read it". The fourth documentation command, beside `tira.skills`, `tira.usage` and `tira.policies`; every entry names the card it came from. An unknown or malformed `--since` version is refused rather than silently producing the unbounded read.

    ```
    d2 tira.changes --since 3.60
    ```

    prints only entries newer than 3.60 - exactly the bound an upgrade notice already states both endpoints of ("Tira is now X - this board last heard Y"), where reading the whole history to find the newest entry cost 5807 lines for a six-line answer. TKT-404.


### Assignment

- `tira.assign.list --ref REF [-o FORMAT]`


### Attachments

- `tira.attachment.add --ref REF --file PATH [--file PATH ...] [--comment ID] [-o FORMAT]`

  Since 2.66 `--file` repeats: several files attach in one invocation rather than
  one command per file. The cost this fixes is per command RESOLUTION rather than
  per attachment - an unknown `tira` command costs about 0.5s to fail, which is
  the same as any command doing real work, and a 400-card board is no slower than
  a one-card one. Six files in a shell loop cost about 3.9s, of which roughly 3.0s
  was resolving the command six times; batched, the same six cost about 0.65s.

  `--file` is shared by nine commands and is single-valued everywhere except
  here - so giving any of the other eight `--file` twice is now refused, naming
  the flag, rather than silently keeping the last value and discarding the rest.

  A file that cannot be read mid-batch still fails the command - a bad path is a
  real mistake and stops it - but the files attached before it are named in the
  error rather than lost with it, since the reporter's second ask was exactly a
  readable record of how far a killed batch got.
- `tira.attachment.discard --ref REF --sha SHA256 [--extension EXT] [--comment ID] [--author NAME] [-o FORMAT]`
- `tira.attachment.detach --ref REF --sha SHA256 [--extension EXT] [--comment ID] [-o FORMAT]`
- `tira.attachment.remove --sha SHA256 [--extension EXT] [-o FORMAT]`


**What previews in the viewer, since 4.69.** Any attachment the board serves as
text opens as text, and the twelve languages TKT-645 named - Perl, Python,
Java, Go, Rust, PHP, JavaScript, CSS, HTML, XML, C and C++ - are syntax
highlighted. Shell, Ruby, SQL and the config family are highlighted too, not
because the card asked for them but because they share their siblings'
lexical surface and cost nothing once those are in. Before this, nine
extensions previewed and everything else answered "Preview is not supported for
this file in this browser", so a program attached to a card could not be read
from the board at all.

**The engine decides and the viewer asks.** `_attachment_content_type` names
the extensions it knows are text and the ones it knows are binary; anything in
neither is decided by reading the file, where a NUL byte or more than a tenth
of the first 8KB outside the printable and common-whitespace range means
binary. The viewer keeps no extension list of its own any more - it reads the
`content_type` the engine already attaches to every entry. Two lists that had
to agree were what made a `.pl` file refused by one and called binary by the
other.

**A genuinely binary attachment still refuses** rather than rendering as
mojibake, which is why this is a default with two named lists rather than "show
everything". An unknown extension with nothing to read - no content, an empty
file, a missing one - also refuses: that is where offering the download is the
honest answer.

**The highlighter is 4.5KB and embedded**, not fetched. The board makes no
network requests, so a CDN highlighter was ruled out; the twelve languages
share their lexical surface, so one tokeniser with a per-language keyword set
covers them at roughly a twentieth of `highlight.js`. Markup has its own
branch, because tags are not keywords and `<!-- -->` is neither `//` nor `#`.
An unrecognised language renders as plain text.

**The dialog is given the content type; `record_show` does not compute it.**
Deciding an attachment's type stats the stored file and sometimes reads its
first bytes, and a record is read on every gate, every police pass and every
board render — so `tira.ticket.show` still returns attachments without the
field, and `tira.attachment.list --meta-only` is where it is computed. The
browser's detail provider asks there when a card is opened and stamps the
answer on by `sha`, comment and question attachments included, since the viewer
opens those from the same strip. If the attachment store cannot be read the
card still opens: the cost is the preview, not the card.

**The `/attachment` route computes the same content type, from the same
stored bytes** (TKT-713). It once called `_attachment_content_type` with
only the extension - the stored path that lets it read the first bytes of
an unlisted extension was silently dropped by a thin wrapper the route's
own call went through, so the route always fell to `application/octet-stream`
for such a file and served it as a forced download, while the card dialog
(reading `attachment.list`'s already-sniffed answer) correctly called it
text. Both surfaces now agree, because both are handed the path.

### Records: SOWs, epics and tickets

The three boards carry the same nine verbs. `TYPE` below is one of `sow`,
`epic` or `ticket` — write it out, so `tira.ticket.create`, `tira.epic.move`,
`tira.sow.discard`. They are listed once here rather than three times because
there is one set of them and nothing about the verb changes with the board.

Naming them at all is new. They were exempted from the check that this document
names every command, on the stated grounds that they were documented once as a
family — and nothing had checked that the family form was present. It was not.
Nine of the twenty-four were named in no document at all, `tira.ticket.discard`
among them. TKT-233.

- `tira.TYPE.create --title TEXT [record field arguments] [-o FORMAT]`
- `tira.TYPE.show --ref REF [-o FORMAT]`
- `tira.TYPE.list [--column SLUG] [--fields LIST] [-o FORMAT]`
- `tira.TYPE.update --ref REF [record field arguments] [-o FORMAT]`
- `tira.TYPE.move --ref REF --column SLUG [--author NAME] [-o FORMAT]`
- `tira.TYPE.clone --ref REF [--title TEXT] [-o FORMAT]` — content fields and attachments carry over; hierarchy/typed links, comments, and now `gate_passing_log`/`evidence` do not, since a brand-new card has done none of the work they would be proof of. The clone gets only the fresh `clones`/`is-cloned-by` link back to the original. TKT-609.
- `tira.TYPE.discard --ref REF [-o FORMAT]` — takes no reason; a discarded card is explained with `tira.comment.add`, which is what `discard-unexplained` looks for
- `tira.TYPE.restore --ref REF [-o FORMAT]`
- `tira.TYPE.missing --ref REF [-o FORMAT]` — answers the same field list `card-full-details` already computes internally to fire a violation, for the named card in any column, on demand, rather than waiting for the card to reach its declared entry column and for police to notice it. TKT-498.

The live board offers the same three, one per board: `tira.dashboard.TYPE`
opens it on that board, and `tira.dashboard` opens it on the default one.


### Boards

- `tira.board.refs --type TYPE [--prefix PREFIX] [--digits N] [-o FORMAT]`
- `tira.board.show --type TYPE [-o FORMAT]` - each column carries a `count`
  alongside its existing `label`/`name`/`protected`/`queue`/`watched` fields,
  read from the same per-card column data `tira.<type>.list` already has.
  Not stored: the number reflects the cards right now, and asking again after
  a card moves answers differently. TKT-394.


### Checklists

- `tira.checklist.add --ref REF --item TEXT --status TEXT [-o FORMAT]`
- `tira.checklist.list --ref REF [--status STATUS] [-o FORMAT]`
  - `--status STATUS` (TKT-748) narrows to items in that status, taking the
    same three values `checklist.add` accepts — `pending`, `done` and `To Do`,
    compared case-insensitively. `To Do` is included because it is the spelling
    this board itself writes on move-in, and a filter that understood only the
    other two would make every unmarked item unfindable.
  - A value outside those three is **refused**, naming what was given, rather
    than matching nothing — for the reason `required-action.list --status`
    already refuses one: an empty list reads as "no items are done".
  - Until 5.43 the option was accepted and ignored. `--status` is parsed in the
    global option table, so every command in the tool accepts it and only the
    ones that read it honour it; this was the only list on the board with a
    status field that did not. `--status done` returned **every** item, in a
    shape indistinguishable from a filtered answer, and exited 0. Michael's
    answer to Q-113 settled what should happen instead: "if `--status` goes
    with `*.list` like this. We should should only those ones with the wanted
    status."
  - The filter is in the engine rather than the option parser, so the browser
    dashboard — which reads the checklist through a provider on a timer — gets
    the same answer as the CLI. A filter written in the parser would have left
    the two disagreeing, which is what happened to attachment content types on
    TKT-713.
- `tira.checklist.update --ref REF --id CHK-NNN [--item TEXT] [--status TEXT] [--command TEXT ... [--proof TEXT ...]] [-o FORMAT]` - marking `--status done` (case-insensitively) refuses without at least one `--command`/`--proof` pair, repeatable for an item that took several commands to satisfy, and refuses when either half of a pair is empty or whitespace-only - naming the half, rather than repeating the message for a missing pair, since a caller who supplied one and is told to supply one has been sent back to what they already did. `--proof` is the literal output of the paired `--command`, trusted as given: emptiness is checked, quality is not. Every other status change is unaffected. Caught on ZSD-246: a checklist backfilled after the fact, marked Done the instant it was typed - proof is what a done claim now costs. TKT-453. An unknown `--id` refuses naming the card's real ids (or the `CHK-NNN` shape, on a card with none yet) rather than only "not found" - an ordinal like `--id 1` used to fail exactly that way with no hint that ids are not positions, and a caller looping ordinals over a checklist found every call silently failing. TKT-280.


### Required actions

A genuinely separate list from checklist above - never written to by anything
that touches it, and vice versa. Each entry carries the column it applies to.
Populated automatically by move-in, creation-time entry-column population, and
the move-out gate and backward-move reset (all TKT-427/439/445); these three
commands are how an agent reads that list or manages a card-specific item on
top of it directly.

TKT-525: a backward move that actually resets one or more already-done
required items also drops one comment on the card explaining it - naming
the origin and destination columns, listing which item(s) reset, and
noting that their proof was left untouched. One comment per move, never
one per item, and only when something genuinely reset (a backward move
that resets nothing adds no comment). Moving all the way back into
Backlog - always the structurally-first column - is the most extreme case
of this same backward-reset design (TKT-455), which is why it can look
like every required item on the card was silently wiped; the comment
exists so a reader never has to guess.

- `tira.required-action.add --ref REF --item TEXT --status TEXT [--column SLUG] [-o FORMAT]` - adds an item tagged with the card's current column; unlike checklist.add, this item gates the card's next move out of that column. `--column` overrides the tag to name a different column, which is how a required item is backfilled onto a card without physically moving it back through that column first.
- `tira.required-action.list --ref REF [--status STATUS] [--blocking] [-o FORMAT]`
  - `--status STATUS` (TKT-804) narrows to items in that status (`pending` or
    `done`, case-insensitively), the same vocabulary `required-action.update`
    already validates against - a value outside the two is refused by name
    rather than matching nothing. Before this, `--status` was a normal option
    name on other commands (`tasklist.list`, `required-action.update`'s own
    validation), so the generic parser accepted it here too and silently
    discarded it: every item came back regardless of status, plausible but
    wrong, with nothing saying so. Scoped to the non-`--blocking` path only -
    `--blocking` answers a different question (what the card's current
    column still owes) through its own helper, never reaching this filter,
    so `--status` and `--blocking` do not compose.
- `tira.required-action.update --ref REF --id REQ-NNN [--item TEXT] [--status TEXT] [--command TEXT ... [--proof TEXT ...]] [--repeated-reason TEXT] [--repeated-confirm CODE] [-o FORMAT]` - same `--command`/`--proof` requirement on `--status done` as checklist.update above, and the same reasoning: a required item, gating or not, is not evidence of what happened just because it says so. TKT-453. An unknown `--id` refuses naming the card's real ids (or the `REQ-NNN` shape, on a card with none yet), the same fix checklist.update got for the identical bug. TKT-488. Since 4.64 `--command` is usable without `--proof`: it records what is being run and the dashboard shows a clock. It travels with a `--status` or an `--item`, because the command still refuses a call that changes nothing - `--status pending --command "prove -lr t"` on an item already pending is the ordinary shape, and it leaves the status where it was. The proof arrives later, repeating its command. What marks the item done is still `--status done`, which refuses without the pair; supplying a full pair with `--status pending` is accepted, stored, and leaves the item pending - recording evidence and asserting a status are two different acts. So the pair rule is unchanged for done-claims and simply no longer required to say work has started. Until then the same call was accepted and discarded silently. The usage line reflects it: `[--command TEXT ... [--proof TEXT ...]]` - proofs nest inside commands as a group, because a proof cannot arrive without a command and, once any proof is given, the counts must match one for one. Announcing several commands at once is fine; announcing two and proving one is refused with `Every --command needs a matching --proof`. `tira.checklist.update` gained the same engine behaviour - the discard was in a function both share - but no clock, which is a required-action rendering. An announcement writes no `gate_passing_log` entry: that log records what was proved. Announcing over an item that is already done is refused unless `--status` re-opens it - otherwise renaming a finished item while announcing would leave it claiming done with an announcement where its evidence used to be. Two items may announce the same command; the reused-proof refusal is about evidence, and an announcement is not evidence yet. TKT-628. `--status` on `required-action.update` is checked, case-insensitively, against the declared set `{pending, done}` (TKT-668, Q-099) - a misspelling like `Donee` or `donw` used to exit 0 and store cleanly while no gate would ever recognize it as done, so it is now refused, naming the value given and the ones that work. `required-action.add` is deliberately NOT validated the same way: every real path that creates a required item (column entry/exit templates, the move-in population, a person backfilling one by hand) writes `pending` itself, so the misspelling this fix targets only ever reached the board through `.update`. `checklist.add`/`.update` both validate, against `{pending, done, To Do}` - the extra value because it is the actual unmarked spelling this board itself writes on move-in, even though a required item never carries it. The refusal is at the point of writing only: a record whose status was written before this validation shipped still reads and moves normally. Within the declared set, only the comparison against `done` is otherwise defined - so `--status Done` marks an item finished for every gate, and since 4.63 for the browser dashboard too, which had compared against the literal `done` in the count, the icon and the checkbox and so showed items the gate considered finished as outstanding. `pending`/`To Do` are both genuinely unfinished, everywhere. Nothing rewrites what you store. TKT-434, TKT-601, TKT-668.

  **One piece of evidence cannot prove two different instructions.** `--status done` is refused when another item **in the same column** already carries that exact `--command`/`--proof` pair - trimmed before comparison, so a trailing newline cannot slip a duplicate through, and attachment-backed proofs compared by content hash rather than by filename. Reported from the owner's own board and measured across its done column: 422 such reuses on 73 cards, one `prove` run answering eleven separate items including "add the start date". TKT-583.

  **A `--proof` over 2000 characters may contain any character, not only ASCII** (TKT-687). It routes to an attachment rather than being inlined, and the attachment path hashes it with `sha256_hex`, which dies on a character string containing code points above 255 - `Wide character in subroutine entry`, naming a hashing routine the caller has never heard of. This board is unusually exposed to it: the dashboard renders required-action state as emoji, and the standing rule is that a proof must be the actual captured output rather than a hand-written summary, so quoting the dashboard in a real proof was refused. The content is now encoded to UTF-8 bytes before hashing and writing, the same pattern the browser layer already uses for its own responses; a pure-ASCII proof keeps the exact hash it always had, so nothing existing needed migrating.

  The door is priced, not locked - one suite run can honestly prove two items - but paying takes two steps, because a gate that accepts any argument is the hole TKT-585 records:

  1. Add `--repeated-reason TEXT`. The command still refuses, and reads **this item's own instruction** back to you beside the reason you just gave, with a six-character code. The failure being prevented is inattention rather than dishonesty, so the refusal shows you what item you are actually answering.
  2. Repeat the same call adding `--repeated-confirm CODE`. Only then is the item marked done, and the reason stored on it for later reading.

  The code is bound to the claim it was issued for: it is stashed against the card and item, and changing the command, the proof, or the reason between the two steps invalidates it and issues a fresh one - a code cannot be redeemed against a claim it was not written for. Re-running step 1 unchanged returns the *same* code rather than rotating it, so a typo is a retry and not a lockout. On success the stash is cleared.

  On the board, an item marked done this way is highlighted rather than merely ticked, and its proof modal opens with the reason above the evidence - the point of storing a reason is that somebody reads it.

  Moving a card into a column that carries required actions prints a reminder naming how many arrived, to work them one at a time with their own command and proof. That is the preventive half: the reuse happens at the end of a column's work, holding a list nobody read item by item, so the reminder lands at the moment the list arrives. It goes to STDERR, staying out of `-o json` output, and only when the column actually brought outstanding items - a reminder on every move is one nobody reads. TSK-168.

Move-in template population is idempotent against two near-simultaneous moves of the
same card, not only a sequential re-entry. Two browser moves fired close together used
to both read the card's `required_items` before either had written its own addition and
both add the template item, leaving a duplicate `REQ-NNN` entry for the same text and
column. The auto-populate path now checks and adds atomically inside its existing lock,
so the second of two concurrent calls sees the first's addition and skips it. A manual
`tira.required-action.add` is unaffected. TKT-497.


### Collectors

- `tira.collector.install [-o FORMAT]`
- `tira.collector.remove [-o FORMAT]`
- `tira.collector.show [-o FORMAT]`


### Columns

- `tira.column.add --type TYPE --name SLUG [--label TEXT] [--after SLUG|--before SLUG] [-o FORMAT]` — `--after`/`--before` only positions the column; it does not touch a neighbor's own `--next`. If the column immediately before the new one already has an explicit `next` that does not include it, the new column is created anyway but is unreachable via the declared chain - advisory rather than a refusal, a `tira.warning.list` entry is left naming both columns and the `column.update --next` to fix it. TKT-456.
- `tira.column.apply --type TYPE --columns-json JSON [-o FORMAT]` - a whole-layout replace, what the dashboard's Columns dialog Save button calls. Each entry may carry `next`, `required_actions`, `entry_required_actions`, and `administrative_actions`, same shape as `column.update --next`/`--required-action`/`--administrative-action`; until 3.14 a round-trip through this command silently dropped the first two even though the same layout read (`column.list`, and the dialog's own GET) already returned them - a saved layout that changed nothing about a column's chain or template would still lose them. `administrative_actions` (TKT-678) got the identical fix at the moment it was added, rather than repeating the gap for a third list. TKT-454.
- `tira.column.list [--type TYPE] [-o FORMAT]` — naming `--type` returns that type's columns, unchanged; omitting it returns a hash keyed by `sow`, `epic` and `ticket`, so a column's settings across all three record kinds are visible in one call rather than three. A column name is really three separate columns underneath, and checking only one used to read as an answer about all of them.
- `tira.column.remove --type TYPE --name SLUG --reason TEXT [--author ID] [-o FORMAT]` — discards every card physically in the column, taking its own `required_items` with it. Deliberately does NOT walk the rest of the board scrubbing or retagging `required_items` entries that still name the removed column on cards that had already moved elsewhere - unlike `column.rename` (below), a removed column's name can never again equal a card's CURRENT column, so a stale entry is harmless history rather than a gate that can be fooled. TKT-613. **`--reason` is required** (TKT-701), mirroring `column.roles --remove-role`'s own precedent: a column leaving the board discards every card resting in it, and a change nobody can account for is worse than the mistake it corrects. Before this, cards were moved into discard by a filesystem rename rather than through `record.move` - no journal entry, no author, and `discard-unexplained` fired on every one of them forever, unable to tell an administrative removal from abandoned work. Each discarded card is now moved through the ordinary discard path (journalled, attributed to `--author`) and given a comment carrying the reason, so `discard-unexplained` is answered by the act that caused it. A config-write failure rolls every discarded card back to its original column.
- `tira.column.rename --type TYPE --name SLUG --new-name SLUG [--label TEXT] [-o FORMAT]` — renames the column's directory and its config entry, and also rewrites the `column` tag stored on every record's `required_items` entries across the whole type's board that still named the old column, not only cards currently sitting in it - a `required_item_add`d entry stores the column name as its own copy at the time it was written, not a live reference, so before this it stayed stamped with the old name forever and the push/departure gate (which matches items by a card's CURRENT column) went blind to any pending item left tagged that way. TKT-613.
- `tira.column.reorder --type TYPE --name SLUG (--after SLUG|--before SLUG) [-o FORMAT]`
- `tira.column.sync --type TYPE [--apply] [-o FORMAT]`
- `tira.column.update --type TYPE --name SLUG [--notify-after MINUTES] [--watch|--no-watch] [--terminal|--no-terminal] [--queue|--no-queue] [--required-action TEXT ...] [--entry-required-action TEXT ...] [--administrative-action TEXT ...] [--next COLUMN ...] [-o FORMAT]` — a column is identified with `--name`, not `--column`; `--column` is the reflex flag on `record.move`, `record.list`, `notify.record` and `search`, and this command (with `column.add`, `column.rename` and `column.remove`) refuses it with a usage error naming `--name` rather than silently accepting and ignoring it - until 3.39 it was accepted and did nothing, and with `--name` absent entirely the resulting "Column '' not found" read as a claim about the board rather than the actual mistake, a mistyped flag. TKT-305. `--terminal` marks a column as somewhere work ends, which `card-unassigned` asks about; a board that marks nothing treats `done` as its ending. `--queue` marks a column as somewhere work waits, which `tira.next` and `priority-skipped` ask about; a board that marks nothing treats its protected non-ending columns as its queue, which is right until the board adds columns of its own — `protected` says Tira owns a column, not what it means. `--required-action` is repeatable and replaces the column's whole template each call; it is what `tira.<type>.move` checks a card's checklist against on the way in and out of that column, and belongs to this command alone — every other command refuses it, naming this one. `--next` is repeatable and replaces the column's whole set each call; it names every column a genuine fork can legitimately move to next, and is what the chain check (below) tests a forward move against instead of the single positional successor it otherwise derives - a column with nothing configured is unaffected. `--next` refuses a column name that does not exist, rather than accepting a typo silently. Removing a column (via `tira.column.remove` or a `tira.column.apply` layout that omits it) strips its name from every other column's stored `next` too, and `column.apply` strips any `next` entry naming a column absent from the layout being saved regardless of what the caller sent - a removed column can no longer be left behind as a dangling fork target that blocks every forward move through the column that pointed at it. TKT-475. `--administrative-action` (TKT-678) is repeatable and replaces the column's whole exempt-item list each call, the same as `--required-action`; it names specific required-action items, by exact text, that a backward move never resets even though their column falls inside the range TKT-455/TKT-525 already reset - the reset only ever knew which column an item belonged to, not what kind of item it was, so a real build gate and an administrative one ("assign yourself to the card") sharing a column were reset identically. An item not named here resets exactly as before; the column-range design itself is unchanged. The match is on `(column, item text)` alone - an item is exempted whether it arrived via the exit template, the entry template, or a manual `required-action.add` sharing that text, the same reach `--required-action`'s own dedup already has; it is not scoped to only the exit-template items `--required-action` itself declares. A `tira.column.apply` layout round-trip persists this list too, same as `required_actions`/`entry_required_actions`/`next`.


### Comments

- `tira.comment.add --ref REF --author ID (--text TEXT|--file FILE) [--format markdown|text] [--attach PATH ...] [-o FORMAT]` - the stored/read field is `body`, the only one of four write/read pairs (gate `--details`/`details`, evidence `--summary`/`summary`, checklist `--item`/`item`) where the write flag and the field name disagree. Since 3.81 the returned comment also carries `text` alongside `body`, the same value, so a caller reaching for the write-side name on the way back out finds it rather than a silent `None` - built fresh on every read, never persisted onto the stored comment. TKT-353. Since 5.43 an empty or whitespace-only `--text` is **refused** — *A comment needs some text* — which `comment.add` was alone in accepting: every sibling refuses an empty value — `evidence.add` a summary, `warning.add` a message, `question.answer` some text, `checklist.add`/`required-action.add` an item. On **whitespace** they differ, and comment.add now sides with the stricter pair: `warning.add` and `question.answer` test `/\S/`, while `evidence.add`, `checklist.add` and `required-action.add` still test `eq ''` and so accept a value made of spaces. The test is `/\S/` rather than a length check, because a space is not a smaller comment than none (the reasoning TKT-585 settled for `--command`/`--proof`) and because it is the **same test** `discard-unexplained` applies to a comment body when deciding whether a card was explained — so the command and the rule cannot drift apart about what counts as saying something. It lives in the engine, so the browser dashboard's comment provider is guarded by the same rule rather than by a second copy of it. TKT-753.
- `tira.comment.attach --ref REF --comment ID --file PATH [-o FORMAT]`
- `tira.comment.list --ref REF [--last N|--first N] [--meta-only] [--fields LIST] [--since TIMESTAMP] [--count] [-o FORMAT]` - every comment carries `text` alongside `body` since 3.81; `--fields text` selects it the same way `--fields body` selects the original.
- `tira.comment.remove --ref REF --comment ID [-o FORMAT]` - an unknown `--comment` id refuses naming the card's real ids, or the `CMT-NNN` shape on a card with none yet, the same fix `checklist.update` (TKT-280), `required-action.update` (TKT-488) and `gate.list`/`evidence.list` (TKT-490) already got. TKT-491.
- `tira.comment.update --ref REF --comment ID (--text TEXT|--file FILE) [--format markdown|text] [-o FORMAT]` - the updated comment also carries `text` alongside `body`, same as `comment.add`. An unknown `--comment` id refuses the same way as `comment.remove`. TKT-491.


### Evidence

- `tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [-o FORMAT]`
- `tira.evidence.annotate --ref REF --id EVD-NNN --note TEXT [--author ID] [-o FORMAT]` - an unknown `--id` refuses naming the card's real evidence ids, or the `EVD-NNN` shape on a card with none yet, the same fix `checklist.update` (TKT-280) and `required-action.update` (TKT-488) already got. TKT-490.
- `tira.evidence.list --ref REF [--last N|--first N] [--id EVD-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]` - `--id` refuses the same way. TKT-490.


### Gate records

- `tira.gate.annotate --ref REF --id GATE-NNN --note TEXT [--author ID] [-o FORMAT]` - same id-shape refusal as `evidence.annotate`. TKT-490.
- `tira.gate.list --ref REF [--last N|--first N] [--id GATE-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]` - same id-shape refusal as `evidence.list`. TKT-490.
- `tira.release.record --ref REF ... --gate TEXT --result pass|fail|blocked --details TEXT --evidence TEXT --fix-version VERSION [-o FORMAT]` - one command for the gate entry, evidence entry and fix version a passed release needs; refuses rather than defaults on anything missing, and never moves a column. TKT-345. Repeat `--ref` to record the same release across a whole batch that shipped together (TKT-561): each card is recorded independently, so one that cannot be written does not take the rest down with it - the refs that failed come back named, with the reason, and a batch that records nothing at all still fails outright (TKT-569). A single `--ref` answers in exactly the shape it always did, error text included. It is the second command after `record.show` and `tasklist.next` that accepts more than one `--ref`.

On the browser dashboard, the card dialog's Gate Passing Log section renders
its first ten entries and, past that, a "Load more (N more)" button reveals
the rest and disappears once every entry is shown - it does not load a card's
whole log at once. A card with ten or fewer entries never shows the button,
and a card with none shows no section, unchanged from before. TKT-495.


### Hierarchy

- `tira.hierarchy.link --parent REF --child REF [--priority N] [--assignee ID] [-o FORMAT]` - `--priority`/`--assignee` optionally set the child in the same write as the link, the same way `release.record` bundles gate+evidence+fix-version into one call - an untriaged card usually needs a home, a priority, and an assignee in the same breath. Omitting both leaves the command exactly as before, a plain link. An invalid priority or unknown assignee refuses the whole call, the link included, rather than linking and silently dropping the bad value. TKT-432.
- `tira.hierarchy.show --ref REF [--recursive] [-o FORMAT]`
- `tira.hierarchy.unlink --parent REF --child REF [-o FORMAT]`


### The work log

- `tira.history.list --ref REF [--field NAME] [--last N|--first N] [--since TIMESTAMP] [--where CLAUSE ...] [--count] [--truncate N|--full] [-o FORMAT]`


### Links

- `tira.link.add --from REF --type NAME --to REF [-o FORMAT]` - a missing
  `--from`, `--type` or `--to` is refused by name, checked in that order;
  the refusal never names `--ref`, which this command does not take. TKT-396.
  Since 5.44 **`--from` and `--to` naming the same record is refused**, and the
  message names that record, because a caller who reaches it has pasted one ref
  twice. It applies to every declared type — a relation needs two records, and
  the rule keys on the two ends being one card rather than on which relation was
  asked for.

  Until then it was stored, and with a directional type it recorded the
  **opposite** of what was asked: a link writes the forward type on `--from` and
  the reciprocal on `--to`, so when both are one card both writes land on it and
  the second overwrites the first. `A blocks A` came back as `A is blocked by A`,
  silently. Refusing removes the only path to that state rather than correcting
  it.

  The check is in `link_add` rather than the CLI, so the browser dashboard's
  `/link/add` route and a direct engine call are guarded by the same rule.
  Self-links **already stored** are left alone — the refusal is at the point of
  writing only. They remain removable, though only by the type they were *added*
  with; see `tira.link.remove` below. TKT-762.
- `tira.link.list --ref REF [--type NAME] [-o FORMAT]`
- `tira.link.remove --from REF --type NAME --to REF [-o FORMAT]` - same
  refusal shape as `tira.link.add`. **Known defect (TKT-910):** removal matches
  on the type as *given*, so asking for the type a card visibly holds — the
  reciprocal — reports success and removes nothing, while asking for the type the
  link was *added* with removes it. Measured on a self-link, where both ends sit
  on one card and the asymmetry is visible; whether two-card links behave the
  same is the first thing that card measures.


### Notifications

- `tira.notify.compose [-o FORMAT]`
- `tira.notify.list [--ref REF ...] [-o FORMAT]`
- `tira.notify.record --ref REF [--ref REF ...] --column SLUG [-o FORMAT]`
- `tira.notify.moves [--column SLUG] [--watch|--no-watch] [-o FORMAT]` — with no column it switches the whole board on; with one it switches that column, which is how `discard` is silenced. The flags were prose here and in no argument table, and that is exactly how `--watch` shipped refused by a guard naming only `column.update`: nothing an agent could read said which command took it. A bare call with none of `--chat`, `--column`, or `--watch`/`--no-watch` is a read: it reports the current setting (or the untouched default, `enabled: false`) without writing anything to the board - until 3.11 it persisted a default on every call, so the first diagnostic question ("has anybody turned this on?") destroyed the evidence by being asked. TKT-398.

  Since 2.65 the destination is set on the board with `--chat ID`, once, by the
  agent - which is what the feature was asked for and what it could not do. It
  read `TELEGRAM_CHATID` out of the environment, and an agent cannot set an
  environment variable on a police process somebody else started, so on this
  project it was never set and nothing was ever delivered. The variable still
  works and is still read when the board has no destination of its own, so
  nothing that relied on it changes.

  A board that has notifications on and cannot deliver them now says so in the
  prompt police prints when it starts, naming what is missing. It said nothing
  before: `_send_notification` returned 0 and the feature was silently dead from
  2.58 until it was asked about twice.


### Projects

- `tira.project.create --name TEXT [--dir DIR] [-o FORMAT]`
- `tira.project.show [-o FORMAT]` — the project as stored: its name, its people, its boards and its settings. Since 2.64 it withholds every account's stored password - the algorithm, its work factor, the salt and the hash - as do the four `project.people.*` commands, all of which are built on the same read. Before that a command an agent runs to learn how a board is configured handed back the whole of what an offline attempt needs, into transcripts, logs, and whatever gets pasted when somebody asks for help with a board. Everything else about a person is unchanged - id, name, email, active - and signing in is unaffected, because it reads the person from the store rather than through this command.
- `tira.project.validate [--repair-columns] [-o FORMAT]` — Read-only without repair.
- `tira.project.link-types.add --outward NAME --inward NAME [-o FORMAT]` — Names unique.
- `tira.project.link-types.list [-o FORMAT]` — the link types this project has, protected and added.
- `tira.project.link-types.remove --outward NAME [-o FORMAT]` — Protected types remain.
- `tira.project.people.activate --id ID [-o FORMAT]`
- `tira.project.people.add --id ID --name TEXT [--email EMAIL] [-o FORMAT]` — adds somebody the board can then assign work to and record as an author.
- `tira.project.people.deactivate --id ID [-o FORMAT]`
- `tira.project.people.list [-o FORMAT]` — everyone on the project, active and not.
- `tira.project.people.remove --id ID [-o FORMAT]` — Fails while historically referenced.
- `tira.project.people.update --id ID [--name TEXT] [--email EMAIL|""] [-o FORMAT]` — changes a name or an email; the id is what everything else refers to and does not change.


### Sub-items

- `tira.subitem.link --parent REF --child REF [-o FORMAT]`
- `tira.subitem.unlink --parent REF --child REF [-o FORMAT]`


### Task list

A parallel, deliberately lighter system to ticket/epic/sow - free text, three
fixed states, no gates or checklists. It sits below the SOW → epic → ticket
hierarchy: anything smaller than a ticket - a chore, a sub-step, a
note-to-self. `--ref` is sticky-note style - it can name one thing, several
(repeat the flag), or nothing, and nothing checks that a named ref actually
exists. Scoped by `--session`: two different session ids never see each
other's items, and calling with none named uses one shared list, which is
what a single agent working alone wants.
`tasklist.add`/`tasklist.list` — and `tira.search --tasklist`, TKT-580 —
fall back to the `TIRA_AGENT_SESSION`
environment variable when `--session` is not given explicitly, so
multi-agent mode does not have to type it on every call; an explicit
`--session` still overrides it. Until TKT-580 the flag itself was refused
on `search`: `--session` sat in the same guard as `--collector`,
`--agent` and `--heartbeat`, which are reminder settings, and `search` was
not on that guard's whitelist — so the scoping both this page and
`SKILLS.md` describe was reachable only through the environment variable,
and typing the documented flag produced an error naming three commands
none of which was the one typed. A session is a scoping argument, not a
reminder setting, and now has its own guard. Ids are `TSK-NNN`. Every item also carries
an explicit `order` field, set independently of `created_at`, so the queue
can be reordered by
unshift/slice without timestamp games: `tasklist.next`/`shift`/`pop` always
operate on it. `tasklist.list` is a separate, purely-display ordering (see
`--sort` below) - it does not have to agree with queue position.

Status is a stored integer enum (0 = pending, 1 = working, 2 = done).
`tasklist.update --status` accepts either the word or the number; every
other command returns the number.

Since 5.24 the implementation of every command in this section lives in
`lib/Tira/Tasklist.pm` rather than `lib/Tira.pm`, loaded with `require` by
each entry point at the moment it is called - so a command that never
touches the task list never compiles any of it (TKT-832, the second lift
under TKT-746). Nothing about the grammar, arguments, return values or
session scoping described here changed: `Tira::tasklist_add` and its
siblings still answer on the `Tira` class, as one-line forwarders. Two
private helpers stayed reachable from `Tira` for the same reason, because
callers outside the task list use them - `search` reads the list to answer
`--tasklist`, and the police pass walks it for `task-unlinked` and
`task-card-mismatch`.

That status is checked against the board. `task-card-mismatch` (TKT-639)
reports an item whose status contradicts the column its linked card sits in -
saying working about a card nobody is working, saying pending about a card
being worked, or not being done about a card that has gone past the working
columns altogether - and reports two items about one card whose text matches on
the first sixty characters. It reads the tasklist file directly rather than
through `tasklist.list`, so it sweeps every session rather than the caller's
own; see docs/POLICIES.md for why its `--column` set is declared and never
inferred. A `.tira/tasklist.json` written before
this shipped still has the old word - it reads back correctly either way,
and the next write of that item is what actually upgrades the file; nothing
has to run a migration by hand.

- `tira.tasklist.add --text TEXT [--session ID] [--ref REF ...] [--attach FILE ...] [-o FORMAT]`
  - `--attach` is repeatable and content-addressed, the same store record
    attachments already use.
  - When `--ref` names a card that already has a pending or working item in
    the same session, the new item's response carries a `possible_duplicate`
    key (`{id, text}` of that existing item) - a soft signal rather than a
    refusal, matching tasklist's own sticky-note design (Q-075): the new item
    is created regardless, since a caller may genuinely want two distinct
    tasks on one card. A done item does not count as still owed, an
    unrelated card's item is never compared, and an item with no `--ref` at
    all has nothing to compare against. Hit three times in one real session
    before this shipped - each card already had a pickup item from earlier,
    and a fresh one went unnoticed until a manual cross-check. TKT-806.
- `tira.tasklist.list [--session ID] [--all-sessions] [--status STATUS] [--unlinked] [--ref REF] [--sort FIELD:DIR[,FIELD:DIR...]] [-o FORMAT]` — `--sort` takes `asc` or `desc`, and **`DESC` in any capitalisation is read as `desc`** because that is how SQL and every spreadsheet write it. **Anything else is refused**, naming what was given and what is accepted: since 5.42 a direction the parser cannot honour, and a field a tasklist item does not have, are both errors rather than silently wrong answers. Before that, `status:DESC` returned *ascending* order and `bogus:desc` returned the list unsorted — a wrong answer that looked exactly like a right one (TKT-888). The sortable fields are `created_at`, `id`, `last_updated`, `order`, `session`, `status` and `text`. The default is `last_updated:desc,status:asc`, and a bare field with no direction means ascending.
  - `--ref REF` (TKT-802) narrows to items whose `refs` array contains REF -
    "what does this one card have on the shared tasklist", without fetching
    every item and filtering by hand. Composes with `--status`/`--unlinked`
    the same way those two already compose with each other; a REF matching
    nothing returns an empty list rather than every item. Before this, `--ref`
    was accepted by the generic option parser (it is a normal option name on
    many other commands) and silently ignored - `tasklist.list --ref CARD`
    returned the WHOLE shared list, wrongly, with nothing saying so. Found
    live needing exactly this filter, and independently by the owner, who had
    closed a required action on a real card citing `--ref CARD` as proof -
    right only by coincidence (one card had tasks at the time), and wrong the
    moment a second one did.
  - `--unlinked` (TKT-552) returns only items with an empty `refs` array.
    `task-unlinked` (TKT-547) already watches for these, but only reports one
    once it has aged past its grace — so finding them *before* the police
    does meant fetching every item and filtering `refs` by hand. It filters
    linkage only, not status: the rule watches pending and working, but an
    audit that silently dropped done items would answer a narrower question
    than the one asked. It composes with `--status` rather than replacing it,
    since the two read different fields. Omitted, every item comes back
    regardless of linkage.
  - `--status` (TKT-545) narrows to one status, taking the same values
    `tasklist.update` does — `pending`, `working`, `done`, or `0`, `1`, `2` —
    through the same parser, so the two cannot disagree about what a status
    is called. Omitted, every status comes back exactly as before. A value
    that is not a status is refused rather than matching nothing, since an
    empty list would read as "no such work" when it means "no such status".
    Filtering happens before sorting, so `--sort` orders what survived.
    Without it, "what is still on my plate" meant fetching every item as
    JSON and filtering the `status` field by hand — the aggregation a list
    command exists to do, and one `next`/`shift`/`pop` already did
    internally for their own single-item use.
  - defaults to `last_updated:desc,status:asc` when `--sort` is omitted.
    Sortable fields: `status`, `order` (numeric), and any other stored field
    (string comparison) such as `text`, `created_at`, `last_updated`.
  - `--all-sessions` (TKT-539) is a deliberate opt-in that returns every
    item across every session instead of just the caller's own, each item
    still carrying its own `session` field - for a supervising agent
    checking on several subagents without already knowing each one's
    session id. Ignored/unaffected when not given; `--session` still wins
    when both would otherwise apply.
- `tira.tasklist.sessions [-o FORMAT]` (TKT-541) - read-only, no
  session-scoping args of its own (seeing every session is the whole
  point). Returns one row per distinct session - `session`, `count`,
  and a `status` breakdown (`pending`/`working`/`done` counts) - sorted
  by item count descending. Closes the gap `--all-sessions` left open:
  it made cross-session visibility possible, but a supervisor still had
  to hand-dedupe the dump to discover which sessions existed at all.
- `tira.tasklist.update --id ID [--status pending|working|done|0|1|2] [--text TEXT] [--session ID] [-o FORMAT]` -
  at least one of `--status`/`--text` is required; either given alone leaves
  the other field as it was. TKT-523.
- `tira.tasklist.prune [--session ID] [-o FORMAT]` - deletes every item with
  status `done`, scoped the same way list/add are.

The queue is treated like an array list, his words - every array function
applies, scoped the same way `--session`/env-var fallback already work:

- `tira.tasklist.next [--session ID] [--ref REF ...] [-o FORMAT]` - peek at
  the front of the pending queue, without removing it. Returns nothing if
  the queue is empty. TKT-563: given one or more `--ref`, narrows to the
  next pending item linked to any of them instead of the queue's own front
  - Michael's own words, "Get the next task specific from a single or
  multiple card." `tasklist.next` is named alongside `record.show` as the
  only two commands the pre-existing "Multiple refs are only available on
  show" guard allows more than one `--ref` on.
- `tira.tasklist.shift [--session ID] [-o FORMAT]` - FIFO pop: return and
  remove the front of the pending queue.
- `tira.tasklist.pop [--session ID] [-o FORMAT]` - LIFO pop: return and
  remove the back of the pending queue (the most recently added item).
- `tira.tasklist.unshift --text TEXT [--session ID] [--ref REF ...] [-o FORMAT]`
  - insert a new item at the very front, jumping the queue.
- `tira.tasklist.slice --text TEXT --position N [--session ID] [--ref REF ...] [-o FORMAT]`
  - insert a new item at an arbitrary 0-based position within the queue.
- `tira.tasklist.remove --id ID [--session ID] [-o FORMAT]` - delete an item
  entirely, distinct from `tasklist.update --status done`, which keeps it as
  a record of having been finished.
- `tira.tasklist.import --ref REF [--session ID] [-o FORMAT]` - copy a
  card's still-pending required-actions and checklist entries into linked
  task-list items, one per entry, so an agent can work through them via the
  tasklist one at a time. Idempotent: re-running it after new required-
  actions appear only adds the new ones, never duplicates what was already
  imported.

Four sub-verbs operate on one existing item, by id, rather than creating one:

- `tira.tasklist.task.attach.add --id ID --file FILE [--file FILE ...] [--session ID] [-o FORMAT]`
- `tira.tasklist.task.attach.discard --id ID --file FILE [--file FILE ...] [--session ID] [-o FORMAT]`
- `tira.tasklist.task.ref.link --id ID --ref REF [--ref REF ...] [--session ID] [-o FORMAT]`
- `tira.tasklist.task.ref.unlink --id ID --ref REF [--ref REF ...] [--session ID] [-o FORMAT]`

TKT-538: `tasklist.update`, `tasklist.remove`, and the 4 `tasklist.task.*`
sub-verbs above now refuse (the same "No task" error an unknown id gets)
when `--id` names an item belonging to a different `--session` than the
caller's - previously they looked an item up by id alone, so a different
session could silently edit or permanently delete another session's
private item just by guessing its (sequential) id.

TKT-682: `tasklist.task.ref.link` now validates every `--ref` against the
board before storing any of them - a ref naming no record refuses the
whole call, naming the ref that was not found, and nothing is partially
linked. Previously a typo'd or invented ref was stored exactly like a
real one, which read as solved to `task-unlinked` and everyone else even
though nothing was actually linked. `tasklist.task.ref.unlink` is
unchanged: removing a ref, valid or not, can never manufacture a false
link. `task-unlinked`'s own bridge message now names this command
directly (`tira.tasklist.task.ref.link --id ID --ref REF`) instead of
only describing linking in prose.

TKT-516: `-o browser` renders every one of these as a Task List section below
the ticket board (`GET /tasklist`, `POST /tasklist/{add,update,next,shift,
pop,unshift,slice,remove,import,prune,task/attach/add,task/attach/discard,
task/ref/link,task/ref/unlink}`), sticky-note styled by status - pending
amber, working purple-blue, done green - with a status dropdown, remove,
attach, and ref controls on each card. Full CLI parity: nothing above is
CLI-only, and every route above still works regardless of what the
browser's own header shows (see TKT-535).

TKT-881: the Task List section renders **five cards, then ten more per press**
of a `.tasklist-more` button below the grid, which names how many are left
(`Show 10 more (137 left)`). No new route and no change to any command above -
`GET /tasklist` still returns the whole list, and the cap is applied when the
cards are built. It is deliberately not a scroll container: a `max-height` on
`.tasklist-cards` would have shortened the section while the page still
constructed every card, so the section below would have been reachable only by
scrolling past a scrollbar. The list held 142 items when the card was filed, in
a grid about ten columns wide - fifteen rows between the ticket board and the
Repeated Jobs section under it.

Three behaviours the cap deliberately does not disturb. The **search box**
(TKT-529, above) still narrows first, so a filtered list shows five of the
*matches* rather than five of everything and then filtered - otherwise a search
for a task in position 90 would find nothing. A card being **edited in place**
(TKT-554) is still not replaced by a reload. And tasks that are **working** are
ranked above pending ones before the cut, so they fill the visible slots first.
They are still subject to the cap rather than exempt from it: with more than
five of them, the rest queue behind the button like anything else. That last one
is not redundant with the
list's own order - `tasklist.list` defaults to `last_updated:desc,status:asc`,
where `status` is a tiebreak that ranks pending *above* working, so a working
task untouched since yesterday sorts below a pending one edited an hour ago.

How many have been asked for survives the section's 1-second refresh, so the
list does not snap back to five while it is being read; reloading the page
resets it.

TKT-540: `POST /tasklist/{update,remove,task/attach/add,task/attach/discard,
task/ref/link,task/ref/unlink}` now forward the session box's value the way
the other eight routes always have - previously these six ignored it, so
switching sessions in the dashboard and then editing/removing/attaching/
linking there failed with "No task" once TKT-538 started enforcing session
ownership.

TKT-528: a card's ref chip is now clickable - clicking its text opens the
linked card's own dialog (`/record?type=...&ref=...`, same opener the
dialog's own linkage table uses); the chip's remove button still just
unlinks and does not open anything.

TKT-529: the dashboard's existing board search box (`[data-filter]`) also
filters the Task List section now - matching a tasklist card's text, id,
or a linked ref, hiding non-matching cards, and restoring every card when
the box is cleared. Client-side only; unlike the record boards' own
`/search` round-trip, no new route was added.

TKT-531: a tasklist card's ref field now autosuggests as you type -
matching against every ref the dashboard already holds client-side
(`recordsByRef`, populated from `/data`), rendered as a dropdown below
the field. Clicking a suggestion posts to `/tasklist/task/ref/link`, the
same route the existing Link button already uses; no new endpoint.

TKT-530: the Task List section's `Next` button now shows its result in
an inline `.tasklist-notice` element instead of a blocking `alert()`,
and the slice-position/import-ref controls open a small inline capture
(`.tasklist-inline-capture`, an input plus a Go button) next to the
button instead of a blocking `prompt()`. The section's 5 `confirm()`
dialogs (remove policy/task/attachment, prune) are unchanged - each
gates an irreversible action, judged safer left as a native blocking
dialog than replaced.

TKT-532: the browser dashboard's `detail` (`/record`) and `move`
(`/move`) provider closures in `Tira::CLI::browser_providers` no longer
require a `type` field in the request payload - `record_show`/
`record_move` resolve a record by `ref` alone (walking every board's
on-disk files for a matching filename), and never read `type` for that
lookup. `type` is still accepted and used when a caller supplies it;
`move`'s own required-action bookkeeping (which does need a concrete
board type) now recovers it from the moved record's own stored `type`
field instead of requiring it from the caller.

TKT-534: a tasklist card's inline text edit (`.tasklist-card__text-input`)
is a dynamic-sizing `<textarea>` now, not a single-line `<input>` - it
grows with `scrollHeight` as multi-line text is typed. Shift+Enter inserts
a newline; plain Enter still saves, unchanged from before. Pasting an
image while editing calls the same `attachFile` helper drag-and-drop
already uses (TKT-524) and inserts a `[image: filename]` text reference
at the cursor - the image itself is stored as a tasklist attachment, not
embedded as raw data in the text field.

TKT-535: the Task List section's header shows only Add and the new-task
text input now - Unshift, Insert at position, Next, Shift, Pop, Prune
done, and Import from card were removed from the browser entirely, not
tucked behind a toggle. Every tasklist CLI command and its route
still work exactly as before; only the buttons that triggered them from
the browser are gone. Also fixed a genuine pre-existing bug this change
exposed in `reconcileTasklist`: nodes not kept across a refresh are now
removed before the insert pass runs, so an actively-edited card's own
node is never repositioned (and blurred) by an unrelated card being
rebuilt earlier in the same list.

TKT-549: Prune is back in the Task List header, next to Add - the one
button TKT-535 removed that Michael later asked to have restored, with
new behavior beyond what it had before: a manual click asks for
confirmation (`confirm("Prune every done task?")`) before posting to
`/tasklist/prune`, and a standing 5-minute interval (a recursive
`setTimeout`, independent of the dashboard's own `?refresh=N` cadence)
posts to the same route automatically, with no confirmation, so done
items do not pile up even when nobody is watching. The other six
TKT-535 removals (Unshift, Insert at position, Next, Shift, Pop, Import
from card) stay removed - full CLI parity for every one of them is
unaffected either way.

TKT-557: the Task List section's header also offers a known-sessions
dropdown next to the free-text session box - a new `GET /tasklist/sessions`
route (wired through a matching `browser_providers` closure) sources the
same data `tira.tasklist.sessions` (TKT-541) already computes: every
session with its item count. Picking an entry fills the free-text box
and reloads the list; typing an arbitrary session id directly still
works exactly as before. Previously the only way to discover a session's
id from the browser was to already know it.

TKT-554: `reconcileTasklist`'s guard against rebuilding an actively-used
row - previously only checking `tlEditingIds` (the open text-edit
textarea) - now also treats a row as busy when its ref-link input has a
non-empty, unsubmitted value or its file input has a chosen,
unsubmitted file. Without this, the section's 1-second poll
(`setInterval(loadTasklist,1000)`) could rebuild the row from the
server's own snapshot mid-typing or mid-selecting, silently discarding
either one. `attachFile` also clears the file input after a successful
attach, so a row does not stay marked busy forever after the file it
was busy over has already been uploaded.

TKT-590: that guard tested content, and content is not the same as
somebody being there. A ref box that is focused but still empty passed
none of its clauses, so the poll rebuilt the row in the window between
focusing the box and the first character landing - up to a full second
wide, and recurring every second. The guard now also treats the ref box as busy when it is the focused
element, not only when it holds a value. Deliberately scoped to that box:
treating ANY focused input in the row as busy was tried first and regressed
the text editor, which never closed because focus was still inside the row
being rebuilt. The whole test is extracted into one predicate,
`tlRowBusy(row, id)`, called once from `reconcileTasklist` - the inline
conjunction is what made it easy to fix one clause and leave its neighbour
open.

TKT-536: the Policies dialog's Decline button opens an inline reason
capture (`.policy-inline-capture`, an input plus a Go button) instead of
a blocking `prompt()` - the last native prompt/alert in the embedded
dashboard, in the same shape TKT-530 already proved for the Task List
section (its own tlInlineCapture was removed with the buttons that used
it in TKT-535; this is a fresh policyInlineCapture scoped to the policy
editor). An empty reason closes the capture without posting, matching
the old prompt's behavior on an empty answer.

### Repeated jobs

A job carries a schedule and something to do when it comes due. It says either
a `--message`, which reaches the police bridge in the words somebody chose, or
runs a `--command` — never both and never neither, because a record carrying
both cannot say which the bridge should get. `mode` records which it is, so a
reader never has to infer it from whichever field is populated.

- `tira.job.add --schedule CRON|monitor (--command TEXT | --message TEXT) [--expect-every MINUTES] [--restart-every SECONDS] [-o FORMAT]`
- `tira.job.list [-o FORMAT]`
- `tira.job.update --id ID [--schedule CRON|monitor] [--command TEXT] [--message TEXT] [--expect-every MINUTES] [--restart-every SECONDS] [--enabled 1|yes|true|on|0|no|false|off] [-o FORMAT]`
- `tira.job.delete --id ID [-o FORMAT]`
- `tira.job.start --id ID [-o FORMAT]`
- `tira.job.stop --id ID [-o FORMAT]`
- `tira.job.run --id ID [-o FORMAT]`
- `tira.job.feed --id ID`
- `tira.job.help`

    ```
    d2 tira.job.add --schedule "0 * * * *" --message "go hunt some bugs"
    d2 tira.job.list
    ```

    **`--expect-every MINUTES` is how a monitor says how often it ought to
    speak** (TKT-863). It is a whole number of minutes **greater than zero** -
    `0` is refused rather than read as "expect nothing". Leaving it out means
    the monitor declares no expectation, which is not the same as zero and is
    not a default. Refused on a cron job, which is not supposed to be up between
    runs and has no heartbeat to miss. It survives an update that names
    something else, the way `--command` and `--message` do.

    What the dashboard does with it, for an enabled monitor: **lit** when it
    spoke within its declared expectation or declares none, **red** when it has
    been silent longer than what it declared, and **dim** when it has never
    spoken at all. A cron job and a disabled monitor show no heartbeat at all -
    the same two silences `monitor-dead` keeps, and for the same reason.

    The owner chose this shape over a board-wide constant and over deriving one
    from the job (Q-115 on TKT-863). There is nothing to derive from - a
    monitor's `schedule` is the literal string `monitor` - and a constant cannot
    fit both a poller that should speak every minute and one that is legitimately
    quiet for hours because it only speaks when something happens. What reads the
    field is the dashboard heartbeat, and the `monitor-silent` police rule when
    it lands.

    **`tira.job.stop` lets go of a running monitor** (TKT-893). It clears the
    pid the board recorded **and the start time recorded with it**, then signals
    the process - in that order, so a signal that fails cannot leave the board
    still pointing at a pid nobody is responsible for. It succeeds **whether or
    not that process is still there** - the engine cannot read a process table
    by design, so all it knows is that a pid was recorded, and a pid whose
    process already died is exactly what somebody needs to clear. Refusing that
    would leave the record wrong for ever with no way out.

    **It stops the whole monitor, not the process the board recorded** (TKT-920).
    A monitor is three processes - the shell that owns the pipe, the command, and
    the feeder reading its output - or four when `--restart-every` adds a loop.
    Until 5.45 the signal went to the recorded pid alone, which is the shell, and
    the rest were orphaned to init and carried on. The record was cleared at the
    same time, so the board forgot a monitor that was still running; the next
    `tira.job.start` asked that emptied record whether the job was already up,
    was told no, and started a second one. `JOB-006` was found running under two
    pids that way, with the board holding a third that was dead.

    A monitor is now started in a **process group of its own**, and the stop
    signals the group. The answer says which happened:

    | `signalled` | what it means |
    |---|---|
    | `group` | the whole monitor was signalled |
    | `process` | only the recorded process was - a monitor started before 5.45 leads no group, so whatever else it forked is **still running** |
    | `gone` | there was nothing to signal |

    That word is the point of the change as much as the group is. The old
    `tira.job.stop` reported success whether it stopped a monitor or orphaned
    three quarters of one, which is why the leak went a release without being
    seen.

    **Three verbs now refuse while a monitor is running**, and each names this
    one: changing its `--command` (the pid would still be running the old one),
    `--enabled 0` (`monitor-dead` is deliberately silent about a disabled
    monitor, so this is the one change that hides a live process in both
    directions), and `tira.job.delete` (the record would go and the process
    would not, and `monitor-dead` cannot report an orphan whose job no longer
    exists). Changing a running monitor's *schedule* is allowed while it stays a monitor,
    and refused when it would turn it into a **cron job** - that would keep the
    pid on a record `monitor-dead` no longer watches, leaving the process
    running with nothing on the board looking at it.

    A monitor that is **not** running, and every cron job, behave exactly as
    before. The rule is only about the board claiming something untrue.

    **`--restart-every SECONDS` keeps a command running** (TKT-891). When the
    command ends, the board waits that long and runs it again - so nobody types
    a `while` loop into a command field, which is one opaque string the board
    cannot report on. Whole seconds greater than zero; leaving it out means no
    restarting, which is not the same as zero. Refused on a cron job (it fires
    on a tick rather than staying up) and on a message job (a loop can only wrap
    a command). The loop lives in the fixed pipeline script and wraps the
    positional parameters, so a job command still never becomes shell source.

    **A command is a program and its arguments, and since 5.42 quotes group
    them.** `--text "two words"` reaches the program as one argument with the
    quote marks removed, and a cron expression can be passed as one; before that
    the command was split on spaces alone, so both were torn into pieces and the
    job exited 0 having done the wrong thing (TKT-898). Everything that is not a
    quote stays literal, backslashes included — a Windows path keeps its
    separators — so a semicolon, backtick, `$(...)`, pipe or redirect inside an
    argument is text rather than something that happens. There is still no
    shell: if you want one, the command is `sh` and the script is its argument.
    An unbalanced quote is refused, naming the quote and showing the command
    back, rather than running half of what was written.

    **`tira.job.help` takes no arguments and prints `docs/JOBS.md` whole**, the
    way `tira.policies` prints `docs/POLICIES.md` - the same mechanism, not a
    second one, and it falls back to naming the verbs when the document is
    absent. It is the only documentation command that exists to talk an agent
    out of something: writing a crontab entry, or keeping a loop inside its own
    session. This list is the reference; that page is the reason, and it does
    not repeat this one. TKT-886.

    The schedule is a crontab expression, or the literal `monitor` for a
    long-running poller that runs continuously rather than firing on a tick;
    `schedule_kind` records which so nothing re-parses to find out. A `monitor`
    job is never "due", and neither is a disabled one, which is why the
    `job-due` rule stays silent about both.

    A `--command` job RUNS when it comes due, and what it produced goes to the
    police bridge - stdout first, then stderr, with the exit status. The two are
    appended rather than interleaved, so ordering between them is not kept. A command
    that fails reports the failure rather than falling silent, because a job
    that ran and failed would otherwise look exactly like a job that never ran.
    The command is run in list form, the program named separately from its
    arguments, so a semicolon in it is an argument and not an instruction;
    there is no quoting, so a command needing it should be a script.

    A `monitor` job is STARTED rather than fired, with `tira.job.start`:

    ```
    d2 tira.job.add --schedule monitor --command "d2 tira.policy.bridge"
    d2 tira.job.start --id JOB-001
    ```

    Starting one records the pid it started as, and runs it inside a pipeline
    whose other half feeds everything it prints back to the board, registered
    against the job that said it. A pipe is safe here only because that feeder
    is its reader and drains continuously: an unread pipe fills at around 64KB
    and blocks the monitor forever, which is a stopped monitor that still looks
    started. Until 5.41 the output went to a per-job log file for exactly that
    reason, and the file is gone — a monitor that has not CALLED IN is a fact
    about the monitor, where a file nobody has written to and a monitor that
    has died look identical from outside.

    That pid is what makes a death detectable. The `monitor-dead` police rule
    reports a monitor that should be running and is not. It confirms the pid
    against the process table **by when that pid started**: the board records
    the moment it spawned the monitor, so the process either began then or it
    is something else wearing a recycled pid. The window is one minute and
    symmetric — later means a reused pid, and earlier cannot be that monitor
    either, since a process that began before the spawn could not have held its
    pid while alive.

    The stored command is compared only where no start time is available, and
    since 5.34 that order matters. Comparing commands first reported every
    `d2`-wrapped monitor as **dead**: `d2` execs perl with the resolved cli
    path, so `d2 is-agent-sleeping` never appears in the child's argv and a
    containment test could not succeed. Nearly every command on this board
    begins with `d2`, so the rule written to end a silence cried on every pass
    instead — and the false-dead reading also defeated the already-running
    refusal below, letting `job.start` launch a second copy.

    If a monitor starts but its pid cannot be written to the board, the
    process is stopped again rather than left running unrecorded: an
    unrecorded monitor would be reported dead every pass and started a second
    time by the next `job.start`.

    On Windows there is no command line to contain anything: `tasklist` reports
    a program name only, so the check falls back to comparing program names
    (path, `.exe` and case ignored). Two monitors run by the same interpreter
    cannot be told apart there. That is weaker than the Unix guarantee and
    stronger than trusting a bare pid.

    A `monitor` job must carry a `--command`, and `--message` is refused for
    one. A monitor stays running rather than firing on a tick, so it has
    nothing to announce - such a record would be unreachable in every
    direction: never due, refusable by `job.start` for having nothing to run,
    and with no command for the liveness check to look for.

    Starting a cron job is refused (it runs when due), and so is starting a
    disabled one, or one with no command. A monitor that cannot be spawned at
    all is refused naming the program and is NOT recorded as started — whether
    the program does not exist, is not executable, or the spawn failed for any
    other reason.

    What this does not catch is a monitor that is alive but wedged — the
    process is up and the polling has stopped. That needs the monitor to report
    progress, which is a different mechanism and a different card.

    `tira.job.run` runs one job NOW, whatever its schedule says — the command
    line behind the dashboard's play button:

    ```
    d2 tira.job.run --id JOB-001
    ```

    It is the same executor a due job uses, with the due-check simply not
    asked, so a failing job reports its exit status here exactly as it would on
    the bridge. A `monitor` job is STARTED rather than fired, because a monitor
    has no schedule to bypass — it is either up or it is not — and starting one
    that is already running is refused rather than spawning a second process.

    The SCHEDULE is the only thing bypassed. A disabled job is still refused
    and must be enabled first, which the dashboard play button hits too.

    A malformed schedule is refused when it is written, naming the field and
    the range it takes, and nothing is stored. The refusal is the engine's own,
    surfaced unchanged rather than decided a second time here — the command line
    and the stored record cannot disagree about what a valid schedule is.

    `--enabled` takes any of `1`, `yes`, `true`, `on` or their negatives `0`,
    `no`, `false`, `off`, in any casing. A word that is neither is refused and
    quoted back. It used to be read as "true if recognisably true, false
    otherwise", so `--enabled banana` disabled a job and said nothing — the
    same shape as a wrong flag that parses and looks accepted.

    `--command` is the option required actions use for their proofs, which take
    it repeatably, and it is not declared a second time for jobs: a duplicate
    Getopt specification makes Getopt::Long print "Duplicate specification" to
    standard error on every invocation. Giving `--command` twice to a job verb
    is refused rather than silently resolved, because a job runs one command.

    Since 5.41 a running `monitor`'s own output reaches the police bridge, so
    its findings arrive on the one stream an agent reads rather than sitting in
    a per-job log nobody opens. `tira.job.start` runs the monitor inside a
    pipeline whose other half is the feeder, which records what it prints
    against the job that said it; the `monitor-output` rule then announces it,
    twenty lines a pass, the newest, saying how many it skipped or dropped. A
    pipe is safe because the feeder is its reader and drains continuously — an
    unread one fills at about 64KB and blocks the monitor. Registering the
    output rather than leaving it in a file is also what lets the board know
    WHEN a monitor last called in (TKT-851).

    `tira.job.feed` is that other half. It reads standard input and records each
    line against the named job, and it is not a verb anybody types: `job.start`
    builds the pipeline that uses it. It is documented because it ships as an
    entrypoint, and an entrypoint nobody can find is how a feature ends up being
    reimplemented by the next person who needs it.

    It reads CONTINUOUSLY rather than collecting and writing at the end, which
    is the whole reason the pipe is safe — a feeder that waited for EOF would be
    a deadlock with extra steps, since the monitor it is reading never finishes.
    Lines are batched before they are written, because taking the project lock
    once per line would have a chatty poller hammering the board, and whatever
    is left goes in when the input goes quiet so a rare speaker is not held
    hostage to a batch that never fills.

    The whole schedule is visible on the browser dashboard as a Repeated Jobs
    section under the Task List, one row per job. EPC-014, TKT-836 for the
    record, TKT-837 for these verbs.

    **A monitor's card shows its recent output from 5.48.** Until then the log
    panel under a job card was painted from one thing only - the response to a
    Run-now click - and a monitor's button is Start, which returns a job record
    rather than output. The job record now carries a short tail of a monitor's
    own words, separate from the output queue the police pass drains, and the
    card renders from it. TKT-922.

    **A monitor's output did not reach the bridge until 5.47**, which matters
    here because this reference has described that channel as working since
    5.41. The `monitor-output` rule tags each finding with the job id and what
    was said - so two passes carrying different words are not read as one rule
    repeating itself - and passed that tag to a closure that did not declare it.
    Two closures in `lib/Tira.pm` share the name `$report` and one takes three
    parameters where the other takes five. The ledger therefore filed every
    finding the rule ever made as a single entry, and everything after the first
    was suppressed as a repeat, while the words were removed from the record
    regardless. TKT-925.

    That section is not read-only. Each row has a play button that runs the job
    at once whatever its schedule says (`tira.job.run`, TKT-843) and a control
    that opens an editor for its schedule, where a bad crontab is highlighted
    with the engine's own message and cannot be saved.

    **Until 5.46 that last clause was true of monitors in a way nobody
    intended: they could not be saved at all** (TKT-912). Save is disabled while
    the editor asks the server whether the schedule parses, and re-enabled when
    the answer arrives - unless the input changed while the request was in
    flight, in which case the stale answer is discarded rather than painted onto
    text that has since been retyped. That staleness test compared the schedule
    box against the value the request had carried. For a cron job those are the
    same string. For a monitor the value carried is the literal `monitor` while
    the box holds whatever was typed before it, or nothing, so they never matched
    and the answer was thrown away every time - and the line that re-enables Save
    sits below that test. The button went out on the first keystroke of any
    monitor and never came back, whatever else was filled in. The guard now
    recomputes the carried value the same way it was built; it is not removed,
    because without it a verdict about an old schedule lands on a new one.

    Since 5.36 an **Add a
    job** control opens that editor with nothing in it, so a job can be created
    from the page as well as with `tira.job.add` (TKT-858) — the same record,
    the same defaults, and the same refusals, because the page calls `job_add`
    rather than validating for itself.

    A `monitor` created from the page is also started, so it is not left in the
    state `monitor-dead` reports as dead. A `cron` job is not: there is nothing
    to start until it is due.

    Since 5.42 the editor is one form for creating **and** for editing, filled
    from the job, and the row carries the rest of the verbs. **Edit** can
    correct a command, which it could not before — the save had always accepted
    one, and the page had no field to type it into. **Delete** removes the job
    after a confirm, and is refused on a running monitor with the engine's own
    words, which name `tira.job.stop`. **Enable**/**Disable** stops a job being
    due without removing it. A monitor the board can see running carries
    **Stop** and **Restart** and does *not* carry the play button: offering
    Start to something already running invites a second process beside the
    first. Restart stops and then starts, and only if the stop succeeded.

    The schedule kind is a pair of radio buttons rather than the word `monitor`
    typed into a schedule box, and `Message` is not offered for a monitor,
    because `_job_fields` refuses that pairing outright. Looping — the
    `restart_every` field — is a checkbox with an interval, off unless asked
    for; keep it above about two seconds, or the feeder's quiet window never
    elapses and a healthy monitor reports no output at all. `expect_every` is on
    the same form, and left blank it means *no expectation* rather than zero.

    Both can be **unset** as well as set. Unticking the box sends an explicit
    null and the engine clears the field; a save that omits the key leaves it
    alone. `job_update` reads these two with `exists` rather than `defined`, so
    absent and null are different instructions — which is what lets an unrelated
    edit leave a monitor's declared expectation untouched while unticking the
    box actually removes the interval.

    The schedule shows as words on the card face — `Every 30 minutes`, `Every
    day at 09:00`, `Runs continuously`, and since 5.50 hour steps, ranges and
    lists (`Every 2 hours, on the hour`, `Every hour from 09:00 to 17:00`, `At
    09:00 and 17:00`), named weekdays, days of the month and named months
    (TKT-917) — with three deliberate refusals: both day fields restricted,
    since cron ORs them; a list longer than six; and a step selecting one value,
    since `*/60` fires at minute 0 alone and describing it hides a typo — and
    since 5.49 `Runs continuously,
    restarting 5 seconds after it ends` for a monitor with `--restart-every`
    (TKT-915; before that the interval appeared on no card at all) — with the
    cron string kept as the
    tooltip. `Tira::Job::job_schedule_words` produces them, in the engine rather
    than the browser for the same reason the crontab check is asked of the
    engine, and anything it cannot describe with certainty is shown unchanged.
    Run now writes into a tail at the foot of the card: a hundred lines, newest visible,
    under a minute old highlighted.

    Since 5.39 a monitor row also reports whether its process is up, as a green
    or red dot and the words "Running" / "Not running". The verdict is the same
    `job_monitor_alive` the `monitor-dead` rule uses, so the page and the police
    bridge cannot disagree about one monitor. A cron job and a disabled monitor
    show nothing at all — neither is supposed to be up between runs, and a row
    reading "Not running" against every cron job would be a false alarm by
    design (TKT-861).

    Since 5.38 the section is styled to the same depth as the Task List beside
    it — it had no stylesheet rules of its own at all before that — and a
    disabled job is dimmed rather than only saying so. Each row also describes
    itself in words: "Stays running" for a monitor, "Runs a command when due" or
    "Announces a message when due" for a cron job. It used to print the stored
    `mode` and `schedule_kind` values joined by a dash, so a row read
    `command - monitor` (TKT-859).

### Warnings

- `tira.warning.add --message TEXT [-o FORMAT]`
- `tira.warning.clear {--id ID | --all} [-o FORMAT]`
- `tira.warning.list [-o FORMAT]`

