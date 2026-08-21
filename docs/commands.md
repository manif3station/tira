# Complete Command Ecosystem

This is the reference: every command and argument, what it is for and when to
use it. For the use cases — the workflows these commands serve, and which one
to reach for — run `dashboard tira.skills`.

Every workflow in `SKILLS.md` is implemented through the entrypoints this
document names, and a command that ships without being named here fails the
suite - a reader who captured only this file was missing whole families before
that check existed. The shared `Tira::CLI` parser applies TOON-first output,
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
| `--seconds N` | yes | How long. There is no open-ended form; it comes back by itself. |
| `--reason TEXT` | yes | Why. At most 500 characters. |
| `--ref CARD` | no | Put it down for one card only. With none, the whole board. |
| `--store PATH` | no | Police's own state, if it is not in the usual place. |

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

| Argument | Required | What it is for |
| --- | --- | --- |
| `--exit-nonzero-if-any` | no | Exit 1 while anything is outstanding, 0 when clear. An error still exits 2, so a scheduled job can tell clean from findings from could-not-look. Opt-in: without it the exit status is what it always was. |
| `--fresh` | no | Run one police pass inline before reading, instead of answering from whatever the last pass wrote. Opt-in, because a read that quietly ran a pass would move escalation counts because somebody asked a question - see below. Without it, behavior is exactly as it always was. |

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
```

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
discovered. **`done` is read by Tira itself**: `parent-ahead-of-children` asks
which column means finished, and says so out loud when no board has told it -
"cannot tell which column means finished on this board. Say so once:
tira.column.roles --type ticket --role done=COLUMN". **`entry` is read by
`tira.<type>.create`**: once declared, `--column` naming anything else refuses,
and omitting `--column` lands the card in the entry column rather than the
fixed `backlog` default - closing the bypass TKT-426's chain check leaves open,
a card started directly where the chain check would otherwise refuse it to
move. CLI/agent path only; the browser dashboard's create flow is unaffected.
A board that names no `entry` role is unaffected too. TKT-428. Every other
role, including `in-progress`, is matched rather than understood: a policy can
name one with `--enter-role`, `--before-role` or `--column-role`, and Tira
never reads it on its own account.

Until 1.97 `in-progress` was a second exception and a silent one. Whether any
card was being worked - which `work-without-card` rests on - counted only cards
in the column that role named, so a board declaring `in-progress=implement` with
five columns work happens in had four of them reading as nobody working. It now
asks the board where work happens, the same question `card-unassigned` and
`priority-skipped` ask: not protected, and not marked `--terminal`. Every role is optional - most projects have a column for very
few of them, and the absence of one is not a problem. A role naming a column
that does not exist is refused, because a role pointing at nothing would make
every rule written against it match nothing at all, silently.

## Accumulating record fields

On record update, repeated `--key-detail`, `--deliverable`, `--acceptance`,
`--test-step`, `--bdd`, `--atdd`, `--scope-in`, and `--scope-out` values append
in supplied order. Existing values are retained. The corresponding `--set-*`
JSON-array options remain the explicit wholesale-replacement controls for the
six content arrays; scope has no replacement option.

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
rule and scope. No arguments beyond `-o FORMAT`.

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

`tira.next` answers what to work next. The cards waiting in a protected
column with a priority, most urgent first and then the one that has waited
longest, as `{next, then}` - the answer, and what it was chosen over, so a
caller can check it rather than take it. A board with nothing waiting answers
with an empty list rather than a card there is no reason to work.

A card held on an unanswered question is never offered either. `priority-skipped`
has refused to name such a card as passed over since it was written — parked,
not skipped — so a question is a hold the board can already read: it names the
condition, and the answer arriving releases the card. Until 2.45 only the rule
read it, so a card could be parked by the rule and offered by the command in the
same moment.

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

- `tira.changes` — the raw changelog, no arguments. It never exits zero having printed nothing: an empty or blank changelog is a broken or half-written copy of the skill, and it says so and names the file it read, so a script can tell "nothing changed" from "I could not read it". The fourth documentation command, beside `tira.skills`, `tira.usage` and `tira.policies`; every entry names the card it came from.


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


### Records: SOWs, epics and tickets

The three boards carry the same eight verbs. `TYPE` below is one of `sow`,
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
- `tira.TYPE.clone --ref REF [--title TEXT] [-o FORMAT]`
- `tira.TYPE.discard --ref REF [-o FORMAT]` — takes no reason; a discarded card is explained with `tira.comment.add`, which is what `discard-unexplained` looks for
- `tira.TYPE.restore --ref REF [-o FORMAT]`

The live board offers the same three, one per board: `tira.dashboard.TYPE`
opens it on that board, and `tira.dashboard` opens it on the default one.


### Boards

- `tira.board.refs --type TYPE [--prefix PREFIX] [--digits N] [-o FORMAT]`
- `tira.board.show --type TYPE [-o FORMAT]`


### Checklists

- `tira.checklist.add --ref REF --item TEXT --status TEXT [-o FORMAT]`
- `tira.checklist.list --ref REF [-o FORMAT]`
- `tira.checklist.update --ref REF --id CHK-NNN [--item TEXT] [--status TEXT] [-o FORMAT]`


### Required actions

A genuinely separate list from checklist above - never written to by anything
that touches it, and vice versa. Each entry carries the column it applies to.
Populated automatically by move-in, creation-time entry-column population, and
the move-out gate and backward-move reset (all TKT-427/439/445); these three
commands are how an agent reads that list or manages a card-specific item on
top of it directly.

- `tira.required-action.add --ref REF --item TEXT --status TEXT [-o FORMAT]` - adds an item tagged with the card's current column; unlike checklist.add, this item gates the card's next move out of that column.
- `tira.required-action.list --ref REF [-o FORMAT]`
- `tira.required-action.update --ref REF --id REQ-NNN [--item TEXT] [--status TEXT] [-o FORMAT]`


### Collectors

- `tira.collector.install [-o FORMAT]`
- `tira.collector.remove [-o FORMAT]`
- `tira.collector.show [-o FORMAT]`


### Columns

- `tira.column.add --type TYPE --name SLUG [--label TEXT] [--after SLUG|--before SLUG] [-o FORMAT]`
- `tira.column.apply --type TYPE --columns-json JSON [-o FORMAT]`
- `tira.column.list [--type TYPE] [-o FORMAT]` — naming `--type` returns that type's columns, unchanged; omitting it returns a hash keyed by `sow`, `epic` and `ticket`, so a column's settings across all three record kinds are visible in one call rather than three. A column name is really three separate columns underneath, and checking only one used to read as an answer about all of them.
- `tira.column.remove --type TYPE --name SLUG [-o FORMAT]`
- `tira.column.rename --type TYPE --name SLUG --new-name SLUG [--label TEXT] [-o FORMAT]`
- `tira.column.reorder --type TYPE --name SLUG (--after SLUG|--before SLUG) [-o FORMAT]`
- `tira.column.sync --type TYPE [--apply] [-o FORMAT]`
- `tira.column.update --type TYPE --name SLUG [--notify-after MINUTES] [--watch|--no-watch] [--terminal|--no-terminal] [--queue|--no-queue] [--required-action TEXT ...] [--next COLUMN ...] [-o FORMAT]` — `--terminal` marks a column as somewhere work ends, which `card-unassigned` asks about; a board that marks nothing treats `done` as its ending. `--queue` marks a column as somewhere work waits, which `tira.next` and `priority-skipped` ask about; a board that marks nothing treats its protected non-ending columns as its queue, which is right until the board adds columns of its own — `protected` says Tira owns a column, not what it means. `--required-action` is repeatable and replaces the column's whole template each call; it is what `tira.<type>.move` checks a card's checklist against on the way in and out of that column, and belongs to this command alone — every other command refuses it, naming this one. `--next` is repeatable and replaces the column's whole set each call; it names every column a genuine fork can legitimately move to next, and is what the chain check (below) tests a forward move against instead of the single positional successor it otherwise derives - a column with nothing configured is unaffected.


### Comments

- `tira.comment.add --ref REF --author ID (--text TEXT|--file FILE) [--format markdown|text] [--attach PATH ...] [-o FORMAT]`
- `tira.comment.attach --ref REF --comment ID --file PATH [-o FORMAT]`
- `tira.comment.list --ref REF [--last N|--first N] [--meta-only] [--fields LIST] [--since TIMESTAMP] [--count] [-o FORMAT]`
- `tira.comment.remove --ref REF --comment ID [-o FORMAT]`
- `tira.comment.update --ref REF --comment ID (--text TEXT|--file FILE) [--format markdown|text] [-o FORMAT]`


### Evidence

- `tira.evidence.add --ref REF --summary TEXT [--uri URI] [--file PATH] [--author ID] [-o FORMAT]`
- `tira.evidence.annotate --ref REF --id EVD-NNN --note TEXT [--author ID] [-o FORMAT]`
- `tira.evidence.list --ref REF [--last N|--first N] [--id EVD-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]`


### Gate records

- `tira.gate.annotate --ref REF --id GATE-NNN --note TEXT [--author ID] [-o FORMAT]`
- `tira.gate.list --ref REF [--last N|--first N] [--id GATE-NNN] [--meta-only] [--where CLAUSE ...] [--count] [-o FORMAT]`
- `tira.release.record --ref REF --gate TEXT --result pass|fail|blocked --details TEXT --evidence TEXT --fix-version VERSION [-o FORMAT]` - one command for the gate entry, evidence entry and fix version a passed release needs; refuses rather than defaults on anything missing, and never moves a column. TKT-345.


### Hierarchy

- `tira.hierarchy.link --parent REF --child REF [-o FORMAT]`
- `tira.hierarchy.show --ref REF [--recursive] [-o FORMAT]`
- `tira.hierarchy.unlink --parent REF --child REF [-o FORMAT]`


### The work log

- `tira.history.list --ref REF [--field NAME] [--last N|--first N] [--since TIMESTAMP] [--where CLAUSE ...] [--count] [--truncate N|--full] [-o FORMAT]`


### Links

- `tira.link.add --from REF --type NAME --to REF [-o FORMAT]`
- `tira.link.list --ref REF [--type NAME] [-o FORMAT]`
- `tira.link.remove --from REF --type NAME --to REF [-o FORMAT]`


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


### Warnings

- `tira.warning.add --message TEXT [-o FORMAT]`
- `tira.warning.clear {--id ID | --all} [-o FORMAT]`
- `tira.warning.list [-o FORMAT]`

