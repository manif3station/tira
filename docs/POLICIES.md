# Policies

Tira can watch a project and say when the board has stopped telling the truth.
You declare what this project cares about; a separate process checks it and
reports what it finds.

Two commands, and each person only needs one of them.

| Who | Command | What it does |
| --- | --- | --- |
| The agent | `d2 tira.policy.add ...` | declares what this project cares about |
| The agent | `d2 tira.policy.bridge` | listens, and acts on what arrives |
| The owner | `d2 tira.police` | watches, and says what it finds |

Police never writes to the board. It reads, and it writes only to a log of its
own that the bridge streams to the agent. One process writes to a project; that
is not tidiness, it is the constraint the whole design rests on.

## Read this before you copy anything below

**The use cases in this document are examples, not a prescription.** They are
written against invented projects to show what each rule is for. Your project
is not one of those projects.

Different work needs different rules. A team shipping to a deadline cares about
due dates; a research project does not. A repository with one contributor does
not need a work-in-progress limit; one with six might. Copying all of these in
would produce a board that buzzes constantly, and a channel that buzzes
constantly is one you stop reading — which leaves you worse off than having no
policies at all.

**If you are not sure whether a rule fits this project, do not guess. Raise a
ticket and ask the owner.**

```
d2 tira.ticket.create --title "Which policies should this project run?" \
  --reporter <owner> --assignee <you>
d2 tira.question.ask --ref <TKT-nnn> --author <you> \
  --text "Should police chase due dates on this project?" \
  --reason "There is no outside deadline that I can see, so requiring one on \
every card may be noise. But I cannot tell from the repository whether that is \
true." \
  --option "Do not chase due dates" \
  --option "Require one past a named column" \
  --option "Require one on high priority cards only"
```

A policy set because it seemed sensible is a policy nobody agreed to. A policy
set because it was asked about is one the project keeps.

## Onboarding: from nothing to watching, in five minutes

**1. See what exists.**

```
d2 tira.policies              # this document
d2 tira.policy.list           # what is already declared here
```

**2. Look at how this project actually works** before declaring anything. The
columns tell you most of it:

```
d2 tira.column.list --type ticket
d2 tira.ticket.list -o json
```

A project with `backlog, implement, verify, done` wants different rules from
one with `todo, doing, done`. Rules that name a column need that column's real
name, not one from this document.

**3. Start with three, not thirty.** The rules that catch the most common ways
a board stops being true:

```
d2 tira.policy.add --rule card-full-details --enter implement --action bridge-reminder
d2 tira.policy.add --rule card-stalled --before-column verify --action bridge-reminder
d2 tira.policy.add --rule answer-ok-not-folded --age 10m --action bridge-reminder
```

The first catches a card that left the backlog as a title with nothing behind
it. The second catches a card whose work is finished while its column says
otherwise. The third catches an answer that was accepted and never written
down.

**4. Ask the owner to start police**, in a terminal they can leave open:

```
d2 tira.police
```

**5. Start listening.** This is the part that is easy to skip and must not be:

```
d2 tira.policy.bridge
```

**A policy set without the bridge running is worse than no policy at all**,
because it looks like cover. Police will be saying things and nobody will be
listening. Keep the bridge running for as long as you are working.

**6. Add rules as you find you need them.** The best time to add a rule is
just after something went wrong that it would have caught.

## What is different between the two kinds of project

A project is worked by a single agent or by a chain of them, and it says which
(`tira.project.mode`). Almost everything means the same thing either way. These
are the exceptions, and they are the whole list — if a rule is not here, it does
not change:

| Rule | Single agent | Chain |
| --- | --- | --- |
| `wip-limit` | The policy carries `--max`. | The number is the project's (`tira.project.limit`), because no one number fits both. It still counts the whole board. |
| `card-sandbox-missing` | Usually not declared — most single-agent projects use no work trees. | Real: every card gets a work tree named after it, and the card records which. |
| The bridge | Each agent names itself and hears its own cards. | The core agent reads it unfiltered and walks each line down; every line carries the way down to its card. |

Two things follow from that list being short.

**A project that has never been asked which kind it is behaves exactly as it
always has.** That is every board that existed before this was written, and none
of them should change underneath their owner for a setting nobody turned on.

**The single-agent path needs nothing new.** It is the common case. A chain adds
a setting, a number and a way of reading the bridge; it takes nothing away.

## Several agents on one board

One agent per ticket, named for the ticket, is the model the
`kanban-management` skill sets out — so an agent's concern is exactly one card,
and a bridge that hands every agent every violation is noise by construction. A
channel that becomes noise is one everybody learns to read past, which is the
single failure a warning system cannot survive.

So the bridge narrows to whoever is reading it:

```
TIRA_AUTHOR=ada d2 tira.policy.bridge      # ada hears about ada's cards
d2 tira.policy.bridge --author ada         # the same, said on the command
d2 tira.policy.bridge                      # nobody named: the whole board
```

Each violation carries who it is for, written into the line, so a card
reassigned afterwards does not rewrite what was already said. Three things
reach everybody rather than one agent:

- a card assigned to nobody, because filtering that loses it trades noise for
  silence and nobody is watching it by definition;
- anything that is not about a card at all, such as a policy that resolves to
  nothing;
- the whole bridge, to anyone who reads it without naming an agent — which is
  how the owner watches the board.

A work-in-progress limit counts the board, not the agent. One agent per ticket
makes a per-agent limit always one, which measures nothing; counting the board
measures how much is in flight at once, which is a real thing to bound.

**The number belongs to the project, because no one number is right for both
kinds of project.** Two is sensible for a single agent and absurd for a chain of
six, so Tira does not pick one — the owner is asked and the answer is stored:

```
d2 tira.project.limit --max 6        # set it
d2 tira.project.limit                # read it back
```

A policy then declares the column and leaves the number alone:

```
d2 tira.policy.add --rule wip-limit --column implement --action bridge-reminder
```

It is read when the rule runs, not copied when the policy is declared, so
raising it quiets the rule without touching any policy — an owner who raised
the number while the rule still used the old one would believe he had changed
it. A policy may still carry its own `--max`, which is narrower and wins; that
is how a project holds one column tighter than the rest, and it is what every
board that declared this rule before today already does. A policy with neither,
on a project with neither, is refused when it is declared.

The violation names who is holding each card:

```
4 cards in implement, limit is 2: LDT-001 (ada), LDT-002 (grace), LDT-003 (alan), LDT-004 (nobody)
```

Without the names the message reads exactly the same whether three agents have
one card each or one agent has three — and those are opposite situations. The
first is the board working as intended; the second is somebody who should
finish something before starting another. A rule that cannot tell them apart
gets its limit raised until it never fires, which is the same as deleting it.

Quiet belongs to the agent that asked for it:

```
d2 tira.police.suspend --seconds 300 --reason "chasing one failing test" --author ada
```

Ada stops being written to for five minutes. Every other agent carries on
hearing about its own cards, and police in the owner's terminal keeps reporting
everything — an agent is not entitled to silence the person watching the board.
The ceiling, the required reason and the enforcement log are exactly as they
were; what changed is who stops hearing. A suspension with nobody named is
still board-wide, because that is what it meant before anybody could be named.

In a chain of agents the bridge has one reader: the core agent at the top. It
does not hand a message to a ticket agent directly — it hands it to that
agent's manager, who hands it on, and the answer comes back the same way. So
every line about a card says the way down to it:

```
... | for ada | via SOW-002 > EPC-003 | VIO-0001 | TKT-077 | seen 1 | ...
```

`via nobody` means the card has nothing above it, which in a chain means the
core agent keeps it rather than passing it on. A line about no card at all — a
leftover container, a board never backed up — carries no path, because there is
nothing to walk down.

The path is written when the line is written, not looked up when it is read. A
card reparented afterwards must not rewrite what was already said, which is the
same reason the line repeats whose card it is instead of pointing at the board.

The path is read from the board police is watching, never from wherever police
was started, so a line can always be followed to the card it is about.

The bridge carries the words on the card, whatever they are. A board worked in
two languages puts both on it, so the log is written and read as UTF-8 and a
card titled in Chinese reaches the agent as the title somebody typed. Until
2026-08-12 it was written as raw text, which warned on the owner's terminal and
wrote bytes the filter could not match an agent's name against — a line that
went missing while everything reported success.



## Saying no to a rule

Police lists the rules this project has not declared, every run, because a rule
nobody declared is silent in exactly the way a rule being obeyed is — and
remembering which run was the first is not your job.

That leaves one gap: it cannot tell "nobody has looked at this" from "somebody
looked and said no". So say no, and give the reason:

```
d2 tira.policy.decline --rule card-sandbox-missing \
  --reason "nothing here uses work trees, so it would fire on every card being worked"
d2 tira.policy.declined        # what has been decided, and why
```

Police stops asking about that rule. Declaring it later clears the declining,
so a project that changes its mind does not carry a record saying the opposite.
A rule that arrives in a future release is asked about exactly as it is today.

**The reason is required**, and that is the whole design. Without it this would
be a way of silencing the prompt, and a decision with no reason recorded is
indistinguishable from having skipped the question — which is the thing this
subsystem exists to remove. With every rule either declared or declined, the
prompt has nothing to say and says nothing.

## What police tells you to hand the agent

Police watches the board. It cannot declare anything — that is the agent's job,
and an agent that has never been told does not know there is anything to do.

So every time it starts, police prints a prompt for you to copy straight across
to the agent. Which one depends on what the board already has:

- **Nothing declared yet.** The prompt teaches: read `tira.skills`,
  `tira.usage` and `tira.policies`, decide what *this* project needs rather
  than copying somebody else's set, declare it, and start
  `tira.policy.bridge` and keep it running the way the Telegram bridge is kept
  running.
- **Declared, but before rules that now exist.** The catalogue grows, and a
  rule nobody has declared is silent in exactly the way a rule being obeyed is.
  The prompt names the rules this project is not using — by name, because
  "something new exists" is not something anybody can act on — and says to
  declare the ones that fit and leave out the ones that do not.
- **Using everything.** Nothing is printed. Nagging somebody who has already
  done it is how a prompt stops being read.

Both prompts end the same way: gather every question into one ticket in the
backlog rather than asking them one at a time, each with the reason it is being
asked and a voice note attached, and the owner answers them together.

It prints on every run rather than only the first, because remembering which
run was the first is exactly the sort of thing the owner should not have to do.

## The rules

Every rule needs an `--action`. Parameters marked required are refused if
missing, at the moment you declare the policy rather than later.

| Rule | Requires | Catches |
| --- | --- | --- |
| `card-full-details` | `--enter` | a card reaching a column without the detail that makes it real work |
| `card-metrics` | `--enter --require` | a card reaching a column without named metadata |
| `card-duration` | `--column --age` | a card sitting in one place too long |
| `card-stalled` | `--before-column` | a finished checklist on a card that has not moved |
| `checklist-idle` | `--column --age` | a card being worked with no checklist movement |
| `orphan-card` | — | a card with no parent |
| `parent-ahead-of-children` | — | a parent saying it is finished above a child that is not |
| `question-unanswered` | `--age` | a question waiting on the owner |
| `card-unassigned` | — | work in progress with nobody on it. **No column**: the board already says which columns are work. |
| `answer-waiting` | — | an answer the agent has not read yet. **No age**: the agent could not have acted sooner, so a grace would only delay it. |
| `answer-unjudged` | `--age`, `--read-age` | an answer nobody marked. The second age is optional and runs from when it was read. |
| `answer-ok-not-folded` | `--age` | settled in name only: marked ok, nothing written down |
| `answer-not-ok-no-followup` | `--age` | a cross with no further question |
| `wip-limit` | `--column` and a number, from the policy or the project | too many things being worked at once, across the whole board |
| `gate-missing` | `--column` | work that reached the end with no gate recorded |
| `discard-unexplained` | — | work set aside with no reason given |
| `commit-without-card` | — | a commit that names no card |
| `work-without-card` | `--age` | a tree changing while nothing is at a working gate |
| `unpushed-work` | `--age` | commits sitting unpushed |
| `board-unbacked` | `--age` | a board with no recent backup. `tira.backup` clears it, and the line says so. |
| `card-unlinked` | `--require-link` | a card with no dependency link, optionally to a named card |
| `card-sandbox-missing` | `--enter --sandbox` | a card being implemented with no branch or worktree of its own |
| `leftover-process` | `--pattern --age` | something started and never stopped |
| `leftover-container` | `--pattern --age` | a container still running |

## The actions

| Action | Where it goes | Use it when |
| --- | --- | --- |
| `bridge-reminder` | the agent's bridge | you want the agent to act |
| `print-reminder` | the owner's police terminal | you want the owner to see it |
| `log-only` | recorded, said to nobody | you are tuning a rule and do not want the noise yet |

## Saying it in your own words

`--message` replaces Tira's wording with yours, and a few things can be filled
in. Every parameter is optional, and using none of them is perfectly normal -
the option is there so that an agent that wants particular wording can have it,
not because anybody must.

| Parameter | What it becomes |
| --- | --- |
| `{ref}` | the card |
| `{title}` | its title |
| `{column}` | where it is |
| `{assignee}` / `{reporter}` | who it belongs to |
| `{rule}` / `{policy}` | which rule fired, and which policy said so |
| `{detail}` | what the rule actually found |
| `{age}` / `{max}` | the rule's own age or limit |

```
d2 tira.policy.add --rule card-duration --column implement --age 2h \
  --action bridge-reminder \
  --message "{ref} has been in {column} for over {age} - {title}"
```

A parameter Tira does not know is left visible rather than blanked, so a typo
shows up as `{noSuchThing}` in the message instead of quietly deleting half of
it.

The same substitution applies to the six rules that read the machine rather than
the board, so `--message "the board has not been backed up in {age}"` on
`board-unbacked` says how long it has been, on the bridge as everywhere else.

## Ages

`--age` takes `30s`, `10m`, `2h` or `7d`. It is that rule's grace: a card
created seconds ago and one abandoned for an hour are not the same thing, and
one number for everything would make the whole channel unbearable.

## What happens when a rule fires

Every violation gets a number, `VIO-0001`. The same problem keeps its number,
counts the times it has been said, and rises through four tones: note, warning,
urgent, critical. Past five tellings it also reaches the owner's terminal with a
message he can paste straight to the agent.

Fixing the cause silences it on the next pass. There is nothing to acknowledge
and nothing to clear by hand.

## Said once, then time to fix it

Police passes every thirty seconds, and most problems take longer than thirty
seconds to fix. So a problem is written to the bridge once when it is found,
and then not again until there has been time to act on it:

| Telling | Then quiet for |
| --- | --- |
| the first | 5 minutes |
| the second | 15 minutes |
| the third | 30 minutes |
| the fourth and after | an hour |

A problem that persists gets quieter, rather than repeating at one rate for
ever. `seen 5 times` therefore means five tellings spread over that ladder, not
five passes of a thirty-second loop — which is what the line always claimed.

Three things the quiet period does not do:

- **It does not change what police knows.** A violation waiting out its quiet
  is still in the pass, marked `quiet`, because one that disappeared while
  waiting would read as fixed.
- **It does not delay good news.** A problem that has been fixed goes silent on
  the very next pass, with no waiting at all.
- **It does not hold back anything new.** Each violation has its own clock, so a
  new problem is said the moment it is found whatever else is waiting.

An agent that has asked for quiet with `tira.police.suspend` spends no tellings
while it lasts. It is not being told, so it is not being counted — otherwise it
would come back from five minutes of silence owing the longest gap on the ladder
for a problem nobody had mentioned to it.

If police cannot work out which policy applies — a rule naming a column that
does not exist, for instance — it says so on the bridge rather than guessing.
That message is asking you to be more specific.

## Where things live

Policies live in the project config, so they travel with the project and
anybody can read them. Police keeps its own state — the violation ledger, the
bridge log — outside the project entirely.

## Where the facts come from

Most rules read the board. Six read the machine instead: `leftover-process`,
`leftover-container`, `commit-without-card`, `work-without-card`,
`unpushed-work` and `board-unbacked`.

Tira itself never looks. It invokes no shell and no external process, which is
the guarantee that lets it be trusted inside another tool — so the `tira.police`
command gathers those facts and hands them over as plain values, and the rules
reason about what they are given. The process table comes from `ps`, containers
from `docker ps`, branches, work trees, commits and the state of the tree from
`git`, and the last backup from the board's own repository - what `tira.backup`
writes. A program
that is not installed is not a failure: a machine with no Docker has no
leftover containers, and everything else carries on being watched.

They are gathered again on every pass rather than once at the start, because a
container that comes up an hour into a watch is exactly the thing these rules
are for.

This is worth knowing because of how it failed. The gathering was missing
entirely until 2026-08-12: the engine was handed five empty lists, so all six
rules evaluated against nothing and reported nothing, on every run, while
passing every test they had — the tests handed the engine a world of their own.
A rule that is silent because nothing was looked at is indistinguishable from a
rule being obeyed. If you write a rule that reads the machine, prove it fires
by making the condition real, not by describing it to the engine.
## One hundred use cases

Each is an invented situation and the command that answers it. Find the
situation that looks like your project; ignore the rest. And read the
warning above again before copying more than a handful.

### Detail before work starts

**1.** A card left the backlog as a title and a shrug, and nobody could say what it was for.

```
d2 tira.policy.add --rule card-full-details --enter implement --action bridge-reminder
```

**2.** A team whose review column is where half-written cards pile up.

```
d2 tira.policy.add --rule card-full-details --enter review --action bridge-reminder
```

**3.** A board where anything reaching 'doing' should already be understood.

```
d2 tira.policy.add --rule card-full-details --enter doing --action bridge-reminder
```

**4.** A project that wants the detail earlier, at the point of triage.

```
d2 tira.policy.add --rule card-full-details --enter triage --action bridge-reminder
```

**5.** A team tuning the rule before turning it on for real.

```
d2 tira.policy.add --rule card-full-details --enter implement --action log-only
```

**6.** An owner who wants to see these himself rather than have the agent chased.

```
d2 tira.policy.add --rule card-full-details --enter implement --action print-reminder
```

**7.** Cards must carry a start date and a source by the time work begins.

```
d2 tira.policy.add --rule card-metrics --enter implement --require start_date,source --action bridge-reminder
```

**8.** A project with an outside deadline: every card needs a due date before it is worked.

```
d2 tira.policy.add --rule card-metrics --enter implement --require due_date --action bridge-reminder
```

**9.** A regulated project that needs a source on everything for audit.

```
d2 tira.policy.add --rule card-metrics --enter backlog --require source --action bridge-reminder
```

**10.** Planning-heavy work: dates agreed at planning, not discovered later.

```
d2 tira.policy.add --rule card-metrics --enter planning --require start_date,due_date --action bridge-reminder
```

**11.** A board that tracks which release work belongs to.

```
d2 tira.policy.add --rule card-metrics --enter implement --require fix_version --action bridge-reminder
```

**12.** Support work where every card must name who asked for it.

```
d2 tira.policy.add --rule card-metrics --enter triage --require reporter,source --action bridge-reminder
```

### Cards that have stopped matching reality

**13.** A card whose checklist was finished an hour ago and never moved.

```
d2 tira.policy.add --rule card-stalled --before-column verify --action bridge-reminder
```

**14.** A board where 'review' is the first column that means the work is done.

```
d2 tira.policy.add --rule card-stalled --before-column review --action bridge-reminder
```

**15.** A two-column board: anything finished should be in done.

```
d2 tira.policy.add --rule card-stalled --before-column done --action bridge-reminder
```

**16.** An owner who would rather see stalled cards himself than have the agent nudged.

```
d2 tira.policy.add --rule card-stalled --before-column verify --action print-reminder
```

**17.** Cards should not sit in implement for more than a working hour.

```
d2 tira.policy.add --rule card-duration --column implement --age 1h --action bridge-reminder
```

**18.** A fast-moving board where ten minutes in one column is already too long.

```
d2 tira.policy.add --rule card-duration --column implement --age 10m --action bridge-reminder --message "still on this one?"
```

**19.** Review should be quick; anything sitting a day has been forgotten.

```
d2 tira.policy.add --rule card-duration --column review --age 1d --action bridge-reminder
```

**20.** Cards waiting on somebody else, where a week is the point of concern.

```
d2 tira.policy.add --rule card-duration --column blocked --age 7d --action print-reminder
```

**21.** A card in testing that nobody has come back to.

```
d2 tira.policy.add --rule card-duration --column testing --age 4h --action bridge-reminder
```

**22.** Work in the backlog so long it is probably no longer wanted.

```
d2 tira.policy.add --rule card-duration --column backlog --age 30d --action print-reminder --message "is this still wanted?"
```

**23.** A card being worked with no checklist movement for half an hour.

```
d2 tira.policy.add --rule checklist-idle --column implement --age 30m --action bridge-reminder
```

**24.** A slower project where a day without progress is the signal.

```
d2 tira.policy.add --rule checklist-idle --column doing --age 1d --action bridge-reminder
```

**25.** Testing that stalls silently while everyone assumes it is running.

```
d2 tira.policy.add --rule checklist-idle --column testing --age 2h --action bridge-reminder
```

**26.** A team that wants to watch this quietly before acting on it.

```
d2 tira.policy.add --rule checklist-idle --column implement --age 30m --action log-only
```

**27.** Only one thing should be in progress at a time.

```
d2 tira.policy.add --rule wip-limit --column implement --max 1 --action bridge-reminder
```

**28.** A pair working together, so two is the limit.

```
d2 tira.policy.add --rule wip-limit --column implement --max 2 --action bridge-reminder
```

### Work that is not connected to anything

**29.** Tickets created in a hurry with no epic above them.

```
d2 tira.policy.add --rule orphan-card --action bridge-reminder
```

**30.** A board where orphans are common enough that the owner wants to see the pattern.

```
d2 tira.policy.add --rule orphan-card --action print-reminder
```

**31.** A project adopting hierarchy gradually, watching before enforcing.

```
d2 tira.policy.add --rule orphan-card --action log-only
```

**32.** Nothing should reach done without a gate recorded against it.

```
d2 tira.policy.add --rule gate-missing --column done --action bridge-reminder
```

**33.** A release column that must carry evidence.

```
d2 tira.policy.add --rule gate-missing --column released --action bridge-reminder
```

**34.** A team that records gates at review rather than at done.

```
d2 tira.policy.add --rule gate-missing --column review --action bridge-reminder
```

**35.** Work set aside with no explanation, so nobody knows if it was a decision.

```
d2 tira.policy.add --rule discard-unexplained --action bridge-reminder
```

**36.** An owner who wants to see what is being dropped and why.

```
d2 tira.policy.add --rule discard-unexplained --action print-reminder
```

**37.** A larger team where four things at once is the practical ceiling.

```
d2 tira.policy.add --rule wip-limit --column doing --max 4 --action bridge-reminder
```

**38.** A review queue that should never grow past three.

```
d2 tira.policy.add --rule wip-limit --column review --max 3 --action print-reminder
```

### Questions that go nowhere

**39.** A question asked of the owner and left waiting an hour.

```
d2 tira.policy.add --rule question-unanswered --age 1h --action print-reminder
```

**40.** An owner who checks in daily, so a day is the right patience.

```
d2 tira.policy.add --rule question-unanswered --age 1d --action print-reminder
```

**41.** Urgent work where a question waiting ten minutes is already blocking.

```
d2 tira.policy.add --rule question-unanswered --age 10m --action print-reminder
```

**42.** The agent should notice its own unanswered questions too.

```
d2 tira.policy.add --rule question-unanswered --age 2h --action bridge-reminder
```

### An answer read and left unjudged

Having read an answer removes the excuse for not judging it, and the record
knows the difference: every answer carries when it was read as well as when it
was given.

```
d2 tira.policy.add --rule answer-unjudged --age 2h --read-age 10m --action bridge-reminder
```

Two hours to notice an answer at all; ten minutes to judge one you have already
opened. `--read-age` is optional — **a policy with one age behaves exactly as it
always has**, so nothing changes meaning on upgrade.

Reading it again buys no further grace: reading is what records the read, so a
rule that reset on it would be silenced by the very act it is chasing somebody
past. A judged answer is chased by neither clock. And a read age longer than the
age it sits inside is refused rather than ignored, because a second grace that
outlasts the first says nothing and would be believed.

### A card being worked with nobody on it

A card in a working column with no assignee says work is happening and cannot
say by whom.

```
d2 tira.policy.add --rule card-unassigned --action bridge-reminder
```

It takes no column, and one is refused rather than ignored. The board already
says which columns are work: every board is created with its backlog and discard
columns marked protected, and everything else is somewhere work happens. So a
column added tomorrow is covered the day it exists.

That is the whole reason it is a rule. `card-metrics --enter implement --require
assignee` reports the same thing for one named column, and stops covering the
board the moment somebody adds another - silently, which is the failure this
rule exists to avoid.

A card waiting in the backlog is not reported, because that is what a backlog
is. Neither is one that was set aside, nor one that is done: a finished card
with nobody on it is history, and chasing it would mean chasing every card the
board has ever finished.

### An answer nobody has been told about

An agent that stopped to ask something stays stopped until it learns it has been
answered. Every other rule about a question chases neglect and waits out a
grace first; this one announces the answer.

```
d2 tira.policy.add --rule answer-waiting --action bridge-reminder
```

It takes no `--age`, and one is refused rather than ignored. A grace here would
only be a delay: the agent could not have acted sooner, because it did not know.

Reading the answer is what stops it — and reading is what records it, so there
is nothing to dismiss by hand and nothing that goes quiet because somebody said
it had. An answer reworded after it was read is announced again, because that is
news the agent has not seen. A question set aside is not announced at all.


**43.** An answer given and never marked, so nobody knows if it settled anything.

```
d2 tira.policy.add --rule answer-unjudged --age 10m --action bridge-reminder
```

**44.** A slower rhythm where an hour is fair before chasing.

```
d2 tira.policy.add --rule answer-unjudged --age 1h --action bridge-reminder
```

**45.** A team that wants the owner told when his answers are being ignored.

```
d2 tira.policy.add --rule answer-unjudged --age 30m --action print-reminder
```

**46.** A question marked settled with nothing written into the card.

```
d2 tira.policy.add --rule answer-ok-not-folded --age 10m --action bridge-reminder
```

**47.** A project where documentation lags a little; half an hour is fair.

```
d2 tira.policy.add --rule answer-ok-not-folded --age 30m --action bridge-reminder
```

**48.** An owner who wants to know when his answers are not being written down.

```
d2 tira.policy.add --rule answer-ok-not-folded --age 1h --action print-reminder
```

**49.** A cross on a question with no follow-up, which settles nothing.

```
d2 tira.policy.add --rule answer-not-ok-no-followup --age 10m --action bridge-reminder
```

**50.** A team that allows longer to think before asking again.

```
d2 tira.policy.add --rule answer-not-ok-no-followup --age 2h --action bridge-reminder
```

**51.** Watching the pattern before deciding whether it matters here.

```
d2 tira.policy.add --rule answer-not-ok-no-followup --age 10m --action log-only
```

**52.** Questions on a board the owner reads once a week.

```
d2 tira.policy.add --rule question-unanswered --age 7d --action print-reminder
```

### Work that has drifted from the board

**53.** A commit landing with no card named in its message.

```
d2 tira.policy.add --rule commit-without-card --action bridge-reminder
```

**54.** An owner who wants to see untracked commits himself.

```
d2 tira.policy.add --rule commit-without-card --action print-reminder
```

**55.** A repository adopting the convention gradually.

```
d2 tira.policy.add --rule commit-without-card --action log-only
```

**56.** The tree changing for a quarter of an hour with nothing at a working gate.

```
d2 tira.policy.add --rule work-without-card --age 15m --action bridge-reminder
```

**57.** A project with longer sessions where an hour is the right patience.

```
d2 tira.policy.add --rule work-without-card --age 1h --action bridge-reminder
```

**58.** Exploratory work where five minutes is too eager but a day is too late.

```
d2 tira.policy.add --rule work-without-card --age 4h --action bridge-reminder
```

**59.** Commits sitting unpushed for an hour, where push is part of done.

```
d2 tira.policy.add --rule unpushed-work --age 1h --action bridge-reminder
```

**60.** A team that pushes at the end of the day, so overnight is the concern.

```
d2 tira.policy.add --rule unpushed-work --age 12h --action bridge-reminder
```

**61.** Work that must never sit locally, on a shared machine.

```
d2 tira.policy.add --rule unpushed-work --age 15m --action bridge-reminder
```

**62.** An owner who wants to know when work is stranded on somebody's disk.

```
d2 tira.policy.add --rule unpushed-work --age 4h --action print-reminder
```

**63.** One card, one branch, one worktree - so two cards never share a tree.

```
d2 tira.policy.add --rule card-sandbox-missing --enter implement --sandbox ~/sandboxes --action bridge-reminder
```

The card records which tree it is being worked in, and the agent that made the
tree is the one that records it:

```
d2 tira.ticket.update --ref TKT-001 --sandbox ~/sandboxes/TKT-001
```

Tira makes no work trees. It checks that a card being worked has one and says
which, and it says three different things because each wants a different fix:
no tree at all, a tree with the right name that no card has claimed, or a card
claiming a tree that is not there. The middle one is why the recording matters
— a work tree existing on the machine says nothing about which card it belongs
to, so one left behind by a card finished last week has exactly the right name
for a card started this morning.

**64.** A team keeping worktrees under the repository's parent directory.

```
d2 tira.policy.add --rule card-sandbox-missing --enter implement --sandbox ../worktrees --action bridge-reminder
```

**65.** A board where the sandbox is expected by the time review starts.

```
d2 tira.policy.add --rule card-sandbox-missing --enter review --sandbox ~/sandboxes --action bridge-reminder
```

**66.** A project trialling worktrees before making them the rule.

```
d2 tira.policy.add --rule card-sandbox-missing --enter implement --sandbox ~/sandboxes --action log-only
```

**67.** Backups every two hours on a board that lives outside git.

```
d2 tira.policy.add --rule board-unbacked --age 2h --action bridge-reminder
```

**68.** A quieter project where a daily backup is enough.

```
d2 tira.policy.add --rule board-unbacked --age 1d --action bridge-reminder
```

**69.** A board holding work that would be painful to lose, checked hourly.

```
d2 tira.policy.add --rule board-unbacked --age 1h --action print-reminder
```

**70.** A team that has already lost a board once.

```
d2 tira.policy.add --rule board-unbacked --age 30m --action bridge-reminder --message "back it up; we have lost one before"
```

### Things started and never stopped

**71.** Test containers still running, which have corrupted a coverage figure before.

```
d2 tira.policy.add --rule leftover-container --pattern perl-test --age 30m --action bridge-reminder
```

The pattern is not optional, and a policy without one is refused. Most machines
run more than one project: without it this named eleven containers on the
machine it was written for, of which nine belonged to other projects entirely -
a trading terminal, two web sites, an Obsidian server. Naming somebody else's
running work is an invitation to go and stop it, and a rule that reports what
nobody here can act on is one everybody learns to read past.

**72.** A machine where a container running an hour is normal but two is not.

```
d2 tira.policy.add --rule leftover-container --pattern myproject- --age 2h --action bridge-reminder
```

**73.** A shared build machine where nothing should outlive its job by long.

```
d2 tira.policy.add --rule leftover-container --pattern build- --age 10m --action bridge-reminder
```

**74.** An owner who wants to know what of HIS is still running.

```
d2 tira.policy.add --rule leftover-container --pattern tira --age 1h --action print-reminder
```

**75.** Polling loops left spinning after their output was read.

```
d2 tira.policy.add --rule leftover-process --pattern "until " --age 30m --action bridge-reminder
```

**76.** Background tails that nobody stopped.

```
d2 tira.policy.add --rule leftover-process --pattern "tail -f" --age 1h --action bridge-reminder
```

**77.** Development servers left listening after the work moved on.

```
d2 tira.policy.add --rule leftover-process --pattern "plackup" --age 2h --action bridge-reminder
```

**78.** Long sleeps, which are almost always a forgotten wait loop.

```
d2 tira.policy.add --rule leftover-process --pattern "sleep" --age 45m --action bridge-reminder
```

**79.** Watchers started for one task and never ended.

```
d2 tira.policy.add --rule leftover-process --pattern "watch " --age 1h --action bridge-reminder
```

**80.** Browsers left open by an end-to-end run.

```
d2 tira.policy.add --rule leftover-process --pattern "chrome" --age 30m --action bridge-reminder
```

**81.** A test harness that should never outlive its suite.

```
d2 tira.policy.add --rule leftover-process --pattern "prove" --age 30m --action print-reminder
```

**82.** Tunnels opened for one debugging session.

```
d2 tira.policy.add --rule leftover-process --pattern "ssh -L" --age 2h --action bridge-reminder
```

**83.** Node processes left running overnight on a shared box.

```
d2 tira.policy.add --rule leftover-process --pattern "node" --age 12h --action print-reminder
```

**84.** A quiet watch on containers while the team decides what is normal.

```
d2 tira.policy.add --rule leftover-container --pattern ci- --age 30m --action log-only
```

### Starting sets for different kinds of project

**85.** A solo agent project, minimum sensible watch: detail, stalls, and folded answers.

```
d2 tira.policy.add --rule card-full-details --enter implement --action bridge-reminder
```

**86.** ...and the second of those three.

```
d2 tira.policy.add --rule card-stalled --before-column verify --action bridge-reminder
```

**87.** ...and the third.

```
d2 tira.policy.add --rule answer-ok-not-folded --age 10m --action bridge-reminder
```

**88.** A project with a deadline, adding dates to the minimum set.

```
d2 tira.policy.add --rule card-metrics --enter implement --require due_date --action bridge-reminder
```

**89.** ...and chasing cards that sit too long.

```
d2 tira.policy.add --rule card-duration --column implement --age 4h --action bridge-reminder
```

**90.** A shared repository, adding commit attribution.

```
d2 tira.policy.add --rule commit-without-card --action bridge-reminder
```

**91.** ...and worktree isolation so two cards never collide.

```
d2 tira.policy.add --rule card-sandbox-missing --enter implement --sandbox ~/sandboxes --action bridge-reminder
```

**92.** ...and pushing, because work on one disk is work nobody else has.

```
d2 tira.policy.add --rule unpushed-work --age 2h --action bridge-reminder
```

**93.** A board holding real delivery work, adding backups.

```
d2 tira.policy.add --rule board-unbacked --age 2h --action bridge-reminder
```

**94.** ...and gates, so nothing reaches done unchecked.

```
d2 tira.policy.add --rule gate-missing --column done --action bridge-reminder
```

**95.** A project where the owner is often away, so questions reach him loudly.

```
d2 tira.policy.add --rule question-unanswered --age 4h --action print-reminder
```

**96.** ...and his answers are chased when nobody acts on them.

```
d2 tira.policy.add --rule answer-unjudged --age 30m --action bridge-reminder
```

**97.** A tidy machine, watching what gets left behind.

```
d2 tira.policy.add --rule leftover-container --pattern test- --age 30m --action bridge-reminder
```

**98.** ...and processes too.

```
d2 tira.policy.add --rule leftover-process --pattern "sleep" --age 45m --action bridge-reminder
```

**99.** A team keeping work in progress honest.

```
d2 tira.policy.add --rule wip-limit --column implement --max 2 --action bridge-reminder
```

**100.** ...and making sure nothing is dropped without a word.

```
d2 tira.policy.add --rule discard-unexplained --action bridge-reminder
```

<!-- 100 use cases -->

### Dependencies that exist only in the words

**101.** A release gate every card must wait on, and nobody remembers to link
to it.

```
d2 tira.policy.add --rule card-unlinked --require-link is-blocked-by --link-to TKT-026 --action bridge-reminder
```

**102.** A project where every card should relate to something, so nothing
floats unattached.

```
d2 tira.policy.add --rule card-unlinked --require-link relates-to --action print-reminder
```

**103.** Watching the habit before enforcing it.

```
d2 tira.policy.add --rule card-unlinked --require-link is-blocked-by --action log-only
```

A card is never asked to depend on itself, and work in the column carrying the
`done` role is left alone - it shipped before the gate existed and cannot be
linked to it retrospectively. If no column carries that role, nothing is
skipped, because guessing which column means finished would be worse than
asking.

### A parent that says it is finished before its children are

**104.** An epic marked done with a ticket under it still open, which is the
board overstating progress in the one direction nobody checks.

```
d2 tira.policy.add --rule parent-ahead-of-children --action bridge-reminder
```

**105.** The same, reported into the owner's own terminal rather than to the
agent.

```
d2 tira.policy.add --rule parent-ahead-of-children --action print-reminder
```

**106.** Watching before enforcing, on a board where parents are moved early
on purpose.

```
d2 tira.policy.add --rule parent-ahead-of-children --action log-only
```

The violation is reported against the parent, because that is the card telling
the lie, and it names every child still open so nobody has to go looking. A
discarded child is settled - discarding is a decision, not unfinished work.

Which column means finished comes from the board's roles rather than from a
name, so a project that calls it `archived` or `shipped` is watched exactly the
same. A board that has never said which column that is does not get guessed at:
the policy is reported as unresolved, so the silence can be seen instead of
being mistaken for approval.
