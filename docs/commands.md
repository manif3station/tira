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
it. The running server notices that the code on disk is no longer the code it
started with, re-executes itself into it with the same arguments and on the same
port, and the page reloads once it sees a version it was not built by. Nothing
has to be restarted by hand.

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

The default output is deliberately cheap: references only, because that is the
path an agent queries. The formats a person looks at carry titles, the Discard
column and the waiting marks, since somebody reading a board wants to see where
things are rather than the smallest possible answer.

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
poll reads a session without extending it - a tab left open overnight does not
keep itself signed in.

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
| `--column COLUMN` | per rule | The column a rule watches. |
| `--age DURATION` | per rule | That rule's grace: `30s`, `10m`, `2h`, `7d`. |
| `--max N` | per rule | A limit, for `wip-limit`. |
| `--pattern TEXT` | per rule | What to match, for `leftover-process`. |
| `--sandbox PATH` | per rule | Where worktrees live, for `card-sandbox-missing`. |
| `--require FIELDS` | per rule | Comma-separated fields, for `card-metrics`. |
| `--require-link TYPE` | per rule | The link a card must carry, for `card-unlinked`. |
| `--link-to CARD` | no | Narrows `card-unlinked` to a link pointing at one card. |
| `--message TEXT` | no | What to say instead of Tira's own wording. |
| `--type TYPE` | no | Declare it for one board only. |
| `--on-column COLUMN` | no | Declare it for one column only. |
| `--ref CARD` | no | Declare it for one card only. |

Anything a rule cannot work without is refused when the policy is set, rather
than discovered later by police - a policy police cannot follow is worse than
no policy, because it reads as cover.

**Where a policy is declared decides how narrow it is.** A policy on a card
beats one on its column, which beats one on its board, which beats one on the
project. Resolution is per rule, so a card that overrides one rule keeps every
other rule the project set.

### `tira.policy.list` / `tira.policy.remove`

See them, or remove one by `--id POL-nnn`. Numbers are never reused.

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

Every violation carries a `VIO-nnnn`. The same problem keeps its number, counts
the times it has been said and climbs four tones - note, warning, urgent,
critical. Past five tellings it also appears in this terminal with a message the
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

### `tira.backup`

Back the board up. A backup is a commit in a git repository Tira manages inside
the board's own storage, beside the project file.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `toon` (default), `json`. |

**The repository is created the first time you back up**, so nobody has to run
`git init` to obey a rule, and a board that never backs up has none — reading
never makes one.

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

### `tira.gates.install`

Install Tira's gates into this project's repository.

| Argument | Required | What it is for |
| --- | --- | --- |
| `-o FORMAT` | no | `toon` (default), `json`. |

Two hooks. `commit-msg` refuses a commit that names no card on this board, or
names one that is sitting in backlog, discard or done - if the work is real
enough to commit, the card is real enough to have been moved. `pre-push` asks
police about the board and refuses the push if it has anything to say.

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

### `tira.police.log`

Read the enforcement log: what police has had to say, and every suspension that
was asked for.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--ref CARD` | no | Only what concerns one card. With none, everything. |

**There is no command to write, change or remove an entry, and that is
deliberate.** A log that exists to hold somebody to account cannot be one they
can write - which is why even the agent's own words about its own suspension
reach the record through police rather than around it.

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

Columns are per board, so roles are too - but "which column is the backlog" has
an answer for every board, and reading without naming one answers for all three
at once. Setting is different: writing roles onto a board nobody named is a
surprise, so it is refused, and the refusal is a command that can be run as it
stands rather than the name of an argument.

The vocabulary is the project's own; Tira matches a role without needing to
understand it. Every role is optional - most projects have a column for very
few of them, and the absence of one is not a problem. A role naming a column
that does not exist is refused, because a role pointing at nothing would make
every rule written against it match nothing at all, silently.

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

### `tira.policy.decline` and `tira.policy.declined`

Records that a rule was considered and deliberately not used, and lists what
has been decided.

| Argument | Required | What it is for |
| --- | --- | --- |
| `--rule NAME` | yes (decline) | The rule being declined. Must be one that exists. |
| `--reason TEXT` | yes (decline) | Why it does not fit this project. |
| `--author WHO` | no | Who decided. |
| `-o FORMAT` | no | As above. |

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
