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

**Run it exactly as shown above - `d2 tira.policy.bridge`, nothing else.** It
streams every event to its own stdout as it happens; that is what "tail it"
means everywhere else in this guide. It is not an instruction to pipe the
command through the Unix `tail` utility, wrap it in `script`, or redirect it
to a log file for something else to follow - **it takes no log-file argument
at all, and needs none.** An agent that finds a *different* project's bridge
process running some other way (`ps aux` shows one, say) must not copy that
shape: another project's process reflects that project's own history, not a
documented convention here. If you are unsure how to invoke any Tira command,
read its entry in this file or in `docs/commands.md` - do not infer usage
from an unrelated running process.

**6. Add rules as you find you need them.** The best time to add a rule is
just after something went wrong that it would have caught.

## What is different between the two kinds of project

A project is worked by a single agent or by a chain of them, and it says which
(`tira.project.mode`). Almost everything means the same thing either way. These
are the exceptions, and they are the whole list — if a rule is not here, it does
not change:

| Rule | Single agent | Chain |
| --- | --- | --- |
| `wip-limit` | The policy carries `--max`. | The number is the project's (`tira.project.limit`), because no one number fits both. It counts each record kind (sow/epic/ticket) in the column separately, not the whole board merged into one number - since 3.42, an epic sitting In Progress as the permission state for its children does not consume a ticket's budget. |
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
... | via SOW-002 > EPC-003 | VIO-0001 | TKT-077 | seen 1 | ...
```

A line names nobody. It used to carry `for <who>`, inferred from the card —
the assignee if there was one and `anyone` if there was not — and that guess
cost more than it paid: a wrong addressee does not merely fail to help, it
gives every other reader a reason to skip the line. The path stays, because a
path is read from the board rather than guessed.

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
| `card-full-details` | `--enter` | a card reaching a column without the detail that makes it real work. This watches a column boundary; `tira.card.holes` (docs/commands.md) answers the same question board-wide, for every live card right now regardless of which column it sits in - a card left untouched in the backlog stays invisible to a column-scoped rule indefinitely. TKT-374. |
| `card-metrics` | `--enter --require` | a card reaching a column without named metadata |
| `card-duration` | `--column --age` | a card sitting in one place too long. `--age` was otherwise a guess, picked by hand and never checked against what the board itself records - `tira.dwell.report` reads back the real median/p90/max seconds cards spend in each column, from every card's own recorded moves, so the threshold can be a reading instead. TKT-366. |
| `card-stalled` | `--before-column` | a finished checklist on a card that has not moved |
| `checklist-idle` | `--column --age` | a card being worked with no checklist movement |
| `checklist-unmoved` | — | a card moved on with nothing ticked since its last move. **No age**: a move has either happened or it has not. Addressed to the card's reporter, not its assignee - since 3.47, TKT-286: the assignee is often the reviewer for a card sitting in review, who cannot tick a checklist item only the card's own author left unticked, while the reporter is who raised the card and is who a checklist item usually belongs to. A separate, synchronous check exists alongside this one for a column carrying a required-action template (`tira.column.update --required-action`): a move made through the CLI/agent command path refuses outright while any of that column's required items are still unmarked, rather than reporting it after the fact - see UC-054. TKT-427. |
| `orphan-card` | — | a card with no parent |
| `rules-undeclared` | — | a rule this board has neither declared nor declined, which is what an upgrade leaves behind. **No age**: a gap is a gap the moment it opens. Settles only when every rule has an answer — declining one counts, because the point is that nothing is left unconsidered. |
| `parent-ahead-of-children` | — | a parent saying it is finished above a child that is not |
| `priority-skipped` | — | a card being worked while a card of the same kind that should have gone first waits untouched — higher priority, or the same priority and waiting longer, which is the order the board enforces everywhere else. Until 2.55 it compared priority alone, so a tie was broken silently. A card with no creation stamp is not treated as older, because an unknown age is not evidence. The message names whichever fact decided it — until 3.09 a tie still printed the priority sentence, claiming a priority outranked an equal one. **No age option**: being passed over does not ripen. |
| `discard-with-open-questions` | — | a card set aside while it still carries a question nobody answered. **No age**: a question that left with the card is not waiting. |
| `card-changed-by-owner` | — | a card whose newest change was made by somebody who is neither the card's assignee nor the agent the board says works it — asking only about the assignee made it vacuous on an unassigned card, where it fired on the board's own work and could never settle. A column set to `--no-watch` is left alone, like every other card rule. The browser dashboard records who is signed in on every change it makes, so an edit made there carries an author and an edit made from the CLI does not — the card is where instructions for the agent are left, and an edit there used to be invisible until the agent happened to re-read it. No age: a change is not more or less true an hour later, and waiting would only decide how long the agent works from a card somebody has already rewritten. It settles when the agent touches the card, because the agent's own change becomes the newest one — nothing is stored, so there is no timestamp to go stale. |
| `card-still` | `--age` | a card nothing has happened to for that long, in any column work happens in. Dwell is not the question: `card-duration` says how long a card has been somewhere, this says whether anybody has touched it. No column to name, so one policy covers the board — and each column may set its own limit with `tira.column.update --notify-after MINUTES`, or be left out entirely with `--no-watch`, which is how a column where cards legitimately wait stops being a source of reminders. `--age` is the fallback for columns that have said nothing, and neither is asked at all where a column-scoped `card-duration` policy already watches that exact column — a considered decision, with a written reason, stands in for the board-wide number rather than being outrun by it. Until 2.74, `card-duration` and `card-still` could not see each other, being different rules on overlapping scope rather than the same rule 2.54 already refuses to duplicate: a column deliberately given 24h by `card-duration` was still reported CRITICAL at `card-still`'s own board-wide 4h. The finding names the limit that was actually crossed and which of the two sources set it - "this column allows 2h (COLUMN notify_after)" or "the policy allows 6h (no column limit set)" - since elapsed time alone reads as if it were the threshold too: a real reader mistook 2h elapsed against a 2h column limit for the elapsed time being the limit itself, because nothing said otherwise. TKT-290. |
| `board-still` | `--age` | a whole board where nothing has moved for that long. The only rule here that is not about a card. |
| `agent-still` | `--age` | the agent working this board has done nothing for that long, while the board itself may be busy. `board-still` reads the newest change to any card, so a card arriving from another project refreshes it — measured here, an agent stopped for 5h56m while seven cards arrived from elsewhere and `board-still`, declared at 4h, never fired once. This counts only agent action: a card changing column, or a card edited by the agent the board names. It says nothing when no card sits in a working column, because an idle queue is not a stopped agent. And it goes out through the same address `tira.notify.moves` uses, because the one rule whose subject is the agent having stopped is the one rule the bridge cannot usefully deliver — and, being outside the bridge, outside the bridge's own seen/settle throttling too, so it keeps its own: one message per stall, a repeat only after 900 seconds if the same stall continues, and an immediate message for a stall that starts after the last one ended. TKT-422. The message itself opens by naming the board it is about — the `TIRA_HOME` alias if the process that ran the pass had one set, and always the real project path — because this one message, unlike every other rule's, goes to the owner directly rather than to the agent-readable bridge, and on a machine running several projects with this skill an unnamed alert is one he cannot place. TKT-480. |
| `bridge-unread` | `--age` | police has been writing to the bridge and nobody has read it for that long. |
| `column-unwatched` | — | a column work happens in that no column-scoped policy mentions at all, which is what adding a column does to policies that were complete when they were written. **No column and no age**: it is about the columns other policies name, and a gap is a gap the moment it opens. |
| `question-unanswered` | `--age` | a question waiting on the owner |
| `conversation-not-folded` | — | a card talked about since it was last written down. **No age**: the ladder already keeps it from repeating. |
| `card-unassigned` | — | work in progress with nobody on it. **No column**: the board says which columns are work. A board whose work ends in more than one place marks each ending with `tira.column.update --terminal`; one that marks nothing treats `done` as its ending, as before. |
| `column-skipped` | `--enter --require` | a card that arrived in a column without passing through the ones it was supposed to. The required columns are declared rather than inferred from their order, because a card that legitimately skips a step - a documentation-only card with no red test to write - would otherwise be reported for it. The violation names which columns were missed. Police reports it and moves nothing: calling the card back is the agent's. A separate, synchronous check exists alongside this one: a move made through the CLI/agent command path (not this async policy, and not the browser dashboard) refuses outright when it would skip ahead of the board's own declared column order - see UC-054. TKT-426. |
| `answer-waiting` | — | an answer the agent has not read yet. **No age**: the agent could not have acted sooner, so a grace would only delay it. |
| `answer-unjudged` | `--age`, `--read-age` | an answer nobody marked. The second age is optional and runs from when it was read. |
| `answer-ok-not-folded` | `--age` | settled in name only: marked ok, nothing written down. **Written down means a card field** - a key detail, the description, the acceptance criteria - not a comment. A comment is where a conversation happens; a field is what an agent reads back off the card, which is what folding an answer in means. |
| `answer-not-ok-no-followup` | `--age` | a cross with no further question |
| `wip-limit` | `--column` and a number, from the policy or the project | too many things being worked at once, counted separately per record kind (sow/epic/ticket) since 3.42 - an epic sitting In Progress as the permission state for its children does not consume a ticket's budget by existing, and the finding names which kind is over. |
| `gate-missing` | `--column` | work that reached the end with no gate recorded. Declared on a final-check column before push, this and `checklist-unmoved`/`card-stalled` (below) cover two of the four checks a reviewer needs - the evidence is there, and the todo list really is done - with no new code; `tira.check.owner --ref CARD` answers the third question, who should be looking. The fourth, whether the code change actually aligns with the card, stays a person or an LLM's own judgement - no rule can make it, and none here tries. TKT-372. |
| `discard-unexplained` | — | work set aside with no reason given. **A comment is what this wants**, unlike `answer-ok-not-folded` beside it: a discard reason is a note somebody leaves, not content anybody reads back. |
| `commit-without-card` | — | a commit that names no card |
| `work-without-card` | `--age` | a tree changing while nothing is at a working gate |
| `unpushed-work` | `--age` | commits sitting unpushed |
| `board-unbacked` | `--age` | a board with no recent backup, by either mechanism: `tira.backup` or an exported backup on disk. Whichever ran last is the answer. |
| `card-unlinked` | `--require-link` | a card with no dependency link, optionally to a named card |
| `card-sandbox-missing` | `--enter --sandbox` | a card being implemented with no branch or worktree of its own |
| `leftover-process` | `--pattern --age` | something started and never stopped. Always exempts the bridge tail (`d2 tira.policy.bridge`) - the one process `bridge-unread` itself tells an agent to keep running - however broadly `--pattern` is written; a pattern matching a project's own path can otherwise match the tail of that same project's own bridge. |
| `leftover-container` | `--pattern --age` | a container still running |

**Declaring a column chain and declaring its required actions are two separate mechanisms, and they are meant to be set up together.** `tira.column.update --next` names which columns a card may move to (TKT-430); `tira.column.update --required-action` names what a card must do before leaving one (TKT-427). Declaring the first without considering the second is common and easy to miss, because nothing links them structurally - a board can name a perfectly correct chain, or fork, with every column able to move to the right places and nothing required of a card at any of them. When setting up a chain for a board, also ask whether each column along it should require something before a card leaves - a note, a check, a review - and declare it there, in the same sitting.

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
`git`, and the last backup from whichever mechanism backed the board up most
recently: the board's own repository, which is what `tira.backup` commits, or
the dated export directories under the home directory, which is what a release
gate running `tools/board-backup` writes. Reading only the first meant a board
backed up on every push was told its last backup was whenever somebody last ran
the command by hand - and then advised to run that command. A program
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
## 107 use cases

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

Watch for the opposite of that: not a checklist standing still, but a card
moving on while it does. `checklist-idle` asks how long nothing has been ticked
in one column; this asks whether the card left a column without anything being
ticked at all.

    d2 tira.policy.add --rule checklist-unmoved --action bridge-reminder

It reports only a move into a column where work happens - never into done or
discard, where the work is expected to be over - and only while the checklist
still has something unfinished. Both narrowings matter: without them the rule
names two thirds of a worked board, almost all of it the last move into done,
and a rule that fires on two thirds of a board is one somebody switches off.
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
d2 tira.policy.add --rule card-still --action bridge-reminder --age 4h
d2 tira.policy.add --rule rules-undeclared --action bridge-reminder
```

Declare that one and an upgrade stops being a line nobody finishes: any rule
this board has neither declared nor declined is reported with a reference, and
it escalates and settles like everything else here. Answering some of them
leaves it open, which is the point — four agents asked by hand all answered
partially.

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

### A conversation that has outrun the card

A card gathers its real content in comments. Somebody pastes evidence, answers a
question, corrects an assumption — and the card's own details go on saying what
they said when it was raised, so the board carries two stories on one card: the
fields an agent reads, and a conversation nobody re-reads.

```
d2 tira.policy.add --rule conversation-not-folded --action bridge-reminder
```

It compares two things the work log already records: the newest comment, and the
newest change to the card. If the comment is later, the conversation has outrun
the card and whoever holds it is reminded to fold it in.

**Any change to the card settles it**, including one about something else. That
is deliberate: the alternative is a marker somebody has to remember to set, and a
reminder that can be silenced by forgetting is worse than one an unrelated edit
clears. There is no command to run and nothing to mark by hand.

A card nobody has commented on is never reported. And when a card is collecting
comments faster than anybody can fold them, put the rule down for that card
alone:

```
d2 tira.rule.suspend --rule conversation-not-folded --ref TKT-001 \
  --seconds 300 --reason "folding a long conversation in one pass"
```

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

## A card that skipped the steps

The board defines the columns; nothing checked that a card went through them.
The owner sent a photograph of his own board - TESTS-RED, IMPLEMENT, VERIFY,
DOCUMENT and PUSH, every one empty - and asked what was being worked. Nothing was
wrong with the tool: the agent had been using two of the eight columns, and every
card went from implement to done in one move, so the columns that exist to say
what is happening were empty the whole time.

```text
d2 tira.policy.add --rule column-skipped --enter done \
  --require "tests-red, implement, verify, document, push" \
  --action bridge-reminder
```

A card that arrives in `done` without having been in each of those is reported,
and the violation names the ones it missed rather than only saying that some were
missed - a message that sends the reader back to the history to work out what is
one they stop reading.

The route is read from the work log, which the engine writes on every move, so
the evidence is not written by whoever made the moves. A card still on its way is
not reported: it has not skipped `verify`, it has not reached it.

## A replay is introduced as a replay

The bridge prints what is outstanding when it starts and then live traffic. With
nothing between the two, a pile of old lines about cards that have since moved
reads as a storm of new violations - and the project that asked for this had
already filed a false report from exactly that, and offered it as the evidence.

    replaying 3 outstanding violations raised between 2026-08-14T09:00:00Z and
    2026-08-14T10:15:00Z - this is history, not new traffic

One line, not a mark on every line: an agent parses these, and changing the shape
of all of them for a distinction that only matters at the boundary costs more
than it settles. The count is what the reading agent will see, because the
backlog is filtered to whoever is reading it and a number about somebody else's
work is worse than no number. A bridge with nothing outstanding still says
nothing at all.

A settlement line says a violation stopped being true. This says the lines in
front of you already happened. They are different facts and both are needed.

## A board with more than one ending

`card-unassigned` asks the board which columns are work rather than taking a
column on the policy, because a policy naming its columns stops covering the
board the moment somebody adds one. It used to answer that question with
protected-ness - and protected means Tira owns this column, not that work stops
here.

developer-dashboard's work ends in three places:

```text
d2 tira.column.update --type ticket --name done-not-released --terminal
d2 tira.column.update --type ticket --name admin-done --terminal
d2 tira.column.update --type ticket --name release-to-pause --terminal
```

Without those, the rule fired on nine shipped cards within a minute of being
declared - telling them to assign somebody to work that had shipped days
earlier. Nine notes in one pass, all wrong, on the first run, which is the noise
this guide warns costs a channel its standing.

A board that marks nothing treats `done` as its ending exactly as before, a
column added tomorrow is still watched without being named anywhere, and the
columns consulted are those of the card's own board rather than the tickets'.

## Where an explanation belongs

Two rules in this set ask for an explanation and want it in different places,
and a project learned that by escalation: they wrote a decision into a comment
in full - the question, the answer and its consequence - were told again on the
next pass, escalated to a warning, then wrote the same words into a field with
`--key-detail` and it settled immediately.

| Rule | Where it wants the explanation |
| --- | --- |
| `answer-ok-not-folded` | a card field |
| `discard-unexplained` | a comment |

The difference is deliberate. A discard reason is a note somebody leaves about
work that has stopped; a folded answer is content the next agent reads off the
card, and a comment is not read back that way. What was wrong was that neither
rule said which it wanted, so learning the convention from one taught the wrong
thing about the other. Both messages name the place now.

## A rule about the machine says what it asked it

`card-sandbox-missing` reads the world rather than the board: police runs `git
branch` and `git worktree list` and hands the answers over. A project read this
off their bridge -

    missing branch and the work tree it records,
    /home/mv/dd-worktree-sandbox/dd-532, which is not there for DD-532

- while the directory, the work tree and the branch all existed on their
machine, and had nothing to check the claim against.

**The branch it wants is named exactly after the card**, and a reference is upper
case by construction. Git branches are conventionally lower case, so on a project
following that convention the check can never match. The violation now names the
branch it wanted and, if one differs only in case, says so:

    a branch named DD-532 - dd-532 differs from it only in case

**The work tree it wants is the one recorded on the card**, checked against what
git reported. The message says how many came back, because none is a different
fault from one being gone: police pointed at a repository that does not hold the
work trees reports an empty list, and that read exactly like a tree somebody had
deleted.

## A card police cannot read

A board reported nothing at all: zero violations across twenty-seven declared
policies and three hundred and fifty-nine cards, `watching` set, exit 0. It was
not a clean board. Two real violations were sitting on it, and an answered
question raised no bridge note, which is how it was noticed.

One card's history journal held a single byte that is not valid UTF-8 — a
multiplication sign written as latin-1. History is decoded strictly, so the read
died inside the rule loop and stopped every rule on the board at that card.

Only rules that read a journal can reach it: `conversation-not-folded`, which
asks when the card was last written to, and `column-skipped`, which asks where
the card has been. A board declaring neither never saw it, which is why the same
Tira behaved differently on two boards with the same answer rules declared.

**A card that cannot be read is set aside and named, not skipped.** The pass
carries on and every other card is still checked. What it could not read comes
back as `unreadable`, with the reason, and is said out loud in the owner's
terminal:

    police could not read M5T-034: malformed UTF-8 character in JSON string,
    at character offset 32. Every other card was still checked; nothing on
    this one was.

Skipping it quietly would be the same fault one level down — a card nobody can
check would look exactly like a card with nothing wrong.

**An unreadable journal is not an unwritten card.** Neither rule accuses it of
anything on the strength of their own failure to read it.

**A pass that failed outright is never presentable as a clean pass.** Police has
always kept the reason in an error field; nothing read it. The bridge is written
from the violations and the terminal from escalations, so a failure landing in
neither was a failure nobody heard about. It now reaches the terminal, saying
what it is:

    police could not finish this pass: <reason>. This is not a board with
    nothing wrong, it is a board that was not read.

Nothing repairs the bytes. The board is the reporter's and the damage is
already written; what changed is that Tira works around it and says so, so the
next board with a stray byte is told rather than silenced.

## A card damaged by one byte

The section above describes a card police could not read at all. Most of the
time the damage is smaller than that: one byte somewhere in a journal that is
not valid UTF-8, written by a tool that got the encoding wrong. A single such
byte — a multiplication sign written as latin-1 — silenced a board of 359 cards.

Skipping that card was the first answer and it was the weaker one. **A skipped
card is a card nobody is checking**, which is the very thing this section exists
to prevent, one level down. On the reporting board the two skipped cards were
carrying three real violations that nothing had ever mentioned.

**So the file is read past the bad byte.** Decoding substitutes rather than
refuses, the entry comes back whole apart from the byte that was never valid,
and every rule judges the card exactly as it judges any other.

The damage is still reported, once, on the quiet ladder:

    M5T-034: its history holds 1 byte that is not valid UTF-8, substituted
    while reading. The card was checked; the file on disk is untouched.

It is `card-damaged` rather than `card-unreadable`, because the two call for
opposite things from whoever reads them. One is a file to clean when there is
time. The other is a card nobody is checking right now.

**Nothing rewrites the file.** History is the permanent record of a board, and a
program that edits it unattended is a worse problem than the one it solves.
Repairing a file is a separate command somebody runs deliberately.

**Said once per card, not once per rule.** Two rules read a card's journal by
different routes, so a board declaring both opens the same damaged file twice in
a pass. The damage is one fact about one card and is reported as one.

## Two rules a board answers but does not declare

`card-damaged` and `card-unreadable` are not policies. A policy says what a
board wants watched; these two say whether watching was possible at all. So
there is nothing to configure, nothing to scope, and **a board that has declared
nothing still hears them** — silence about a corrupt record is the fault this
whole section exists to prevent.

They must still be answerable, and for two releases they were not. Every other
rule can be put down for a while or refused outright; these were raised straight
into the pass, outside the catalogue both of those commands check against, so a
board with permanently damaged files had a violation it could not stop by any
means. Found by probing for a check that fires and cannot be stopped — the
mirror of a check that never fires.

    d2 tira.rule.suspend --rule card-damaged --seconds 600 \
      --reason "the repair command does not exist yet"

    d2 tira.policy.decline --rule card-damaged \
      --reason "these files are known bad and will not be repaired"

Both take a reason, like everything else here, and a suspension comes back by
itself. `tira.policy.add` still refuses them, because there is nothing to
declare, and they do not appear in `tira.policy.undeclared` for the same reason.

## When Tira itself moves

Installing a new Tira tells the owner and nobody else: police prints its setup
prompt to his terminal when it starts. The agent — the party that has to read
what changed, learn the commands that are new, and declare the rules that
arrived with them — was told nothing at all. A rule nobody has declared is
silent in exactly the way a rule being obeyed is, so an upgrade nobody mentions
leaves a board quietly running an older rulebook.

Police now says it on the bridge:

    2026-08-15T08:00:00Z | UPGRADE | Tira is now 1.82 - this
    board last heard 1.81. Read what changed, learn what is new, and see
    which rules this board has still neither declared nor declined | fix:
    d2 tira.changes; d2 tira.usage; d2 tira.policy.undeclared

It is written **first**, above the violations, because it changes how they
should be read: a rule that arrived with this version is one the board has not
declared yet, and its absence from the lines below is not evidence of anything.

**Once per version, not once per start.** Police restarts in order to pick a new
version up, so a line written on every start would arrive on a loop for as long
as nobody upgraded again.

**A version going backwards is a change too.** A board now running something
older than it last heard about is a board whose agent may be working from a
rulebook the installed Tira no longer has, and that is worth the same line.


## Work taken out of turn

He caught this by eye: "can you also working on the higher prioity cards first,
i see you randomly pick and work on them disregard the card prioity". The repair
at the time was a sentence written into a document, which is the kind of check
this project has learned not to trust.

It is worth a rule for a sharper reason than forgetfulness. **The agent raises
its own cards and sets their priority**, so "work the highest first" is a weak
promise when the same party decides what is highest - anything can be made
urgent and the order is always satisfied. What a rule can watch is the part that
cannot be marked as its own homework: not what priority was set, but whether
something above the card being worked is being left alone.

    d2 tira.policy.add --rule priority-skipped --action bridge-reminder

`priority-skipped` reports a card in a working column while a card of the same
kind, with a higher priority, sits untouched where it was raised. It names both,
and the priority that was passed over. **Remember that 5 is the urgent end**;
that is not this rule's decision but it is the one thing that would invert it.

**The message names whichever fact actually decided it.** Until 3.09 the
message only had one sentence available - "waits at priority N, above this
card's N" - so a tie in priority decided by the age tie-break (below) printed
two equal numbers while claiming one outranked the other, which disproves its
own sentence and sends the reader to "fix" code that was never broken. A tie
now says instead that the older card "waits at the same priority and has been
waiting since" the date that settles it; a genuine priority gap keeps the
original wording unchanged.

**A card waiting on an unanswered question is parked, not skipped.** A higher
card that cannot start until the owner answers is not being ignored, and
reporting it would blame the agent for the one delay that is not its doing. The
moment the answer arrives the excuse is gone and the card is reported again.

**Cards of different kinds are not compared.** An epic sits where it was raised
for as long as its tickets take, which is what an epic is for, so judging a
ticket against one would leave every board with a hierarchy permanently in
violation.

**A card with no priority is unassessed, not urgent.** Treating unset as the top
would stop work on a board the moment somebody raised a card and did not finish
thinking about it.

**No age.** Being passed over does not ripen into being passed over more, and
the quiet ladder already stops the same line arriving twice a minute. An age is
refused when the policy is declared rather than ignored when it runs.


## Questions that went with the card

A card can be discarded while it still carries questions nobody has answered,
and nothing said so. The questions go with the card: not answered, not
withdrawn, not asked anywhere else. They stop being visible, and **the decision
they were waiting on is never made**.

    d2 tira.policy.add --rule discard-with-open-questions --action bridge-reminder

Since 2.69 `discard-with-open-questions` reports a card reaching ANY ending
column, not only Discard - done included, and any other column a board has
marked `--terminal`. Before that, TKT-349 reached done with a question still
open and police said nothing through a full pass on a board with thirty
policies declared - a done card's open question was load-bearing on work that
shipped, which is worse than a discarded card's, where the work is not
happening. Endings are read from the board's own declaration
(`_ending_columns`), so a board naming its ending column something other than
`done` is covered without the rule naming it.

`discard-with-open-questions` reports a card that still has an
unanswered question, and names the questions:

    SAT-001 set aside carrying Q-001, still unanswered - decide whether each
    still matters, ask the ones that do on the card they belong to now, and
    discard them here. There is no command that moves a question: asking it
    where it belongs and discarding it here is the move.

**Police asks and moves nothing.** Whether a question still matters is a
judgement about the work, and a rule that carried questions between cards on its
own would be making that judgement by machine — where a wrong guess is
indistinguishable from a decision somebody made.

**There is no command that moves a question, and the message does not pretend
otherwise.** Asking it on the card it belongs to now and discarding it on the
old one *is* the move. A message naming a command nobody can run is worse than
one that explains itself.

**Three things are not this rule.** A question answered before the card was set
aside is settled. A question withdrawn with `tira.question.discard` is the agent
having already done what this asks. And an unanswered question on a *live* card
is `question-unanswered`'s business, not this one's.

### Onboarding it

Declare it alongside the other question rules, which together cover every place
a question can stall:

    d2 tira.policy.add --rule question-unanswered --age 2h --action bridge-reminder
    d2 tira.policy.add --rule answer-waiting --action bridge-reminder
    d2 tira.policy.add --rule answer-unjudged --age 2h --action bridge-reminder
    d2 tira.policy.add --rule answer-ok-not-folded --age 10m --action bridge-reminder
    d2 tira.policy.add --rule answer-not-ok-no-followup --age 2h --action bridge-reminder
    d2 tira.policy.add --rule discard-with-open-questions --action bridge-reminder

The first five watch a question while its card is alive. The last watches the
one moment they can all be escaped at once.


## A board where nothing is happening

Every other rule here reports something wrong with a card. This one reports that
there are no cards doing anything — which no per-card rule can express, because
it has nothing to attach itself to. **A board where every card sits in the
backlog and none has moved for a day looks, to every other rule, exactly like a
board with nothing wrong.** It is the silence-is-not-compliance shape one level
up.

    d2 tira.policy.add --rule board-still --age 8h --action bridge-reminder

    nothing has moved on this board since 2026-08-15T09:00:00Z, which is 5h -
    no card created, no field written, no column changed. If that is expected
    while something is being worked out, put this rule down for a while with a
    reason rather than leaving it unanswered:
    d2 tira.rule.suspend --rule board-still --seconds N --reason TEXT

**The age is required and there is no default.** An hour of quiet is nothing on
a research board and a working day is a crisis on a delivery one, so a guess
would fire wrongly on somebody's board rather than usefully on anybody's.

**Everything counts as movement**: a card created, a field written, a comment, an
answer, a checklist tick, a card discarded, a column changed. It is the newest of
those anywhere on the board, so one card being worked keeps a board of forgotten
ones quiet — which is right, because somebody is working.

**An empty board is not a stuck board.** Nothing has moved for want of anything
to move, and greeting a new project with a complaint about work nobody has
raised would teach its agent to read past this channel on its first day.

### When the board is busy and the agent is not

`board-still` reads the newest change to any card, which is the right measure on
a board only its own agent writes to. On a board that receives reports from other
projects it is measuring somebody else's work.

Measured here, and it is why `agent-still` exists: the agent's last action was
01:31 and its next was 07:27 — five hours fifty-six minutes — while `board-still`
was declared at 4h and did not fire once. Seven cards arrived from other projects
during that window and every arrival refreshed the stamp it reads. The board was
busy; the agent was not.

    d2 tira.policy.add --rule agent-still --age 4h --action bridge-reminder

    nothing has been worked on this board since 2026-08-18T01:31:00Z, which is
    5h - no card moved column and none edited by the agent. Cards still waiting:
    TKT-302, TKT-349. Cards arriving from other projects do not count as work,
    which is why board-still can be quiet while this is not.

**Two things count as the agent acting**, both already recorded: a card changing
column, and a card edited by the agent the board names with
`tira.project.update --agent`. A card created or edited by another project is
neither. A move counts whoever made it — moving a card through this board's
columns *is* working this board, and the browser is where the owner moves cards,
so reading the author of a move would report a stopped agent on a board being
worked by hand.

**An idle queue is not a stopped agent.** Nothing is reported unless a card sits
in a column that is neither an ending nor a queue. An earlier 7h49m gap on this
board was investigated and found to be correct work throughout — there was simply
nothing being worked — and a rule that fired on elapsed time alone would have
been wrong then and right later, which is no rule at all.

**It reaches somebody other than the agent.** Every other rule writes to the
bridge and trusts the agent to read it. This one's subject is the agent having
stopped, so the bridge is precisely where it cannot help: during the stoppage
above, `card-still` reported both stranded cards correctly and escalated them to
CRITICAL, addressed to the party that had stopped. It sends through the same two
variables `tira.notify.moves` uses, and stays silent if a board has set no
address.

### When nothing is meant to move

Planning that has not finished, a decision waiting on a conversation, a day off:
these are boards that are quiet on purpose. Put the rule down rather than
leaving the question unanswered —

    d2 tira.rule.suspend --rule board-still --seconds 600 \
      --reason "planning is not finished, so nothing is meant to move yet"

— which takes a reason, has a ceiling, is written to the enforcement log, and
comes back by itself. There is nothing to switch on again afterwards, and the
silence is accounted for rather than merely absent.


## Telling police where the repository is

`card-sandbox-missing` reads the machine rather than the board: police runs
`git branch` and `git worktree list` and hands the answers over. It ran them in
the directory holding the board, which is the right guess only when the board
and the work live in the same place.

A project reported the rule firing on a card whose branch, directory and work
tree all existed:

    missing a branch named DD-532 (the machine reported 0 branches) and the
    work tree it records, /home/mv/dd-worktree-sandbox/dd-532 - the machine
    reported no work trees at all, which is what police watching the wrong
    repository looks like

The rule was right and its subject was wrong. Their board does not sit inside
the repository their work happens in, so every question came back empty.

**A project can say where its work lives:**

    d2 tira.project.update --repo /path/to/the/repository

Police reads that instead, so the rule gives the same verdict wherever the board
sits and wherever police was started — which was the real fault, because a check
whose subject depends on how it was launched cannot be relied on.

**The path is checked when it is set.** A directory that is not there, or one
that is not inside a git repository, is refused at that moment rather than
becoming a violation nobody can clear.

**And the rule refuses to be declared where no repository can be resolved:**

    Policy rule 'card-sandbox-missing' reads branches and work trees from a git
    repository, and this project is not in one. Say where the work lives with
    tira.project.update --repo PATH

That is this guide's own rule about missing arguments applied to the one rule
that reads the machine: a policy police cannot follow is worse than no policy,
because it reads as cover.

**A board that does sit inside its repository needs to say nothing.** Nothing
changes underneath a project that has declared no repository.

**And the backup question is about the board, not about the repository.**
`tira.backup` writes into the board's own storage and nowhere else, so that is
where `board-unbacked` looks for it, whatever repository the project has
declared. Until 1.96 it looked wherever `--repo` pointed, so a board that had
declared one was told it had never been backed up - permanently, however many
times anybody backed it up. developer-dashboard reported exactly that: the rule
raised at 07:55 and escalated twice while the board was backed up three times in
between, against a seven-day age. Everything else police reads from the machine
- branches, work trees, unpushed commits, whether the tree is changing - still
comes from the declared repository, because those are questions about the work.


## A bridge nobody is reading

Every other rule here asks whether the board is in order. This one asks whether
the answers are reaching anybody — which is the question that makes the rest
worth anything.

It exists because of a measured failure on this project's own board.
`unpushed-work` raised a violation at 17:58, escalated it to urgent, and it was
still open at 19:42 while four commits sat unreleased. The rule worked. The
escalation worked. Police said it four times, in the words written for it, and
nobody was listening. The owner found it before the agent did.

**A rule nobody reads is the same as a rule that never fired.** A board with
policies declared and an agent that does not tail the bridge is an unwatched
board that *looks* watched — worse than no policies at all, because the policies
read as cover.

    d2 tira.policy.add --rule bridge-unread --age 30m --action bridge-reminder

    the bridge has not been read since 2026-08-15T11:00:00Z, which is 2h, and
    police has been writing to it. A rule nobody reads is the same as a rule
    that never fired: tail it with d2 tira.policy.bridge and keep it running
    while you work

**Reading means reading.** There is no command to acknowledge the bridge and no
flag to set: asking for the backlog is what tailing it does, so the mark is made
by the reading rather than by a claim about it. A tail left running keeps the
mark fresh on every poll, so an agent doing the right thing is never reported
for it.

**A bridge with nothing on it is not unread.** There is nothing to read, and
sending an agent to look at an empty file is how it learns to stop looking.

**The period is required.** How long an agent may go without looking is a
decision about how it works: a minute is absurd on a board polled hourly and a
day is useless on one being worked now.


## Adding a column does not silently narrow a rule

A rule that names a column stops covering the board the moment somebody adds
another. Nobody has to do anything wrong: the policy was complete when it was
written, and a column added later narrowed it without saying so.

This project did it to itself. `checklist-idle` and `card-duration` were
declared for one column on a board with five, so a card could sit untouched in
any of the other four for ever — which is exactly what happened, and the owner
was the one who noticed a card parked for six hours.

    d2 tira.policy.add --rule column-unwatched --action bridge-reminder

    no policy scoped by column watches document, and card-duration,
    checklist-idle are declared for other columns - a rule naming a column stops
    covering the board the moment another is added, silently. Declare what
    belongs there, or decline the rules that do not

**What is reported is a column nothing watches**, not every rule that fails to
cover every column. The wider version was written first, and running
`tira.policy.review` against this project's own board killed it: `gate-missing`
is declared for `verify`, `push` and `done` deliberately, because a card in
`tests-red` has no gate to show yet, and the wider check demanded it be declared
there too. Nothing could have answered that. **A violation nobody can close is
the fault this guide keeps meeting** — it teaches whoever reads the bridge that
some lines are not worth acting on.

Which rule belongs on which column is a judgment. A column no column-scoped rule
mentions at all is not: it is a place work happens that the policies do not know
exists.

**One violation, however many columns are blind.** This is one state — the board
has grown past its policies — and it is answered when they catch up.

**Only rules that name a column at all count as watching.** A board-wide policy
covers every column by construction, so it neither creates this nor closes it.

**And only columns where work happens.** Which those are is the board's own
answer, the same one `card-unassigned` and `priority-skipped` ask for: not
protected, and not marked `--terminal`. A rule watching the finished column for
idleness would report every shipped card for ever.


## Reading the whole set in one place

Policies are declared one at a time, over weeks, by whoever was working. Reading
them back out of `tira.policy.list` means holding the catalogue in your head to
see what is missing, which is the work this saves:

    d2 tira.policy.review

Every rule in the catalogue appears exactly once, in one of three states —
declared with the columns it covers, declined with the reason, or unanswered.
Reading the columns down the declared side shows which of the board's working
columns nothing names, which is the gap `column-unwatched` reports — visible by
reading rather than by working out.

`tira.policy.undeclared` answers a narrower question and is what police prints
for the owner when it starts. This one is for reviewing the whole set at once.


## A scope that means something

Declaring a policy on a card beats declaring it on the column, which beats the
board, which beats the project — per rule, so one exception cannot switch the
rest off. That is the promise. `discard-unexplained` did not keep it: a policy
declared with `--ref` for one card reported every discarded card, because its
branch looped every record and never consulted the resolver every other card
rule uses.

    d2 tira.policy.add --rule discard-unexplained --ref TKT-001 \
      --action bridge-reminder

now reports TKT-001 and nothing else, and the same rule declared without a card
still reports the whole board.

**A scope a rule cannot act on is refused.** `board-still`, `bridge-unread` and
`column-unwatched` are about the whole board, so a card scope could never narrow
any of them, and it is refused when it is set:

    Policy rule 'board-still' is about the whole board rather than one card, so
    a card scope could never narrow it. Declare it without --ref

Storing it instead would leave a policy that reads as narrow and behaves as
wide, and the natural conclusion on seeing it fire everywhere is that the rule
is broken rather than that the scope was never read.

`wip-limit` is not one of these, though it looks like one. It counts a column,
so a card scope seems meaningless — until you notice the cascade uses exactly
that to give one card a different limit from the rest of its column. It keeps
its card scope.

**A rule's own column field is part of its scope, not a setting.** The same
resolver ranks `--ref`, `--on-column` and `--type`, but several rules also
carry a column-shaped field of their own — `card-duration`, `checklist-idle`,
`wip-limit` and `gate-missing`'s `--column`; `card-full-details`'s `--enter`;
`card-stalled`'s `--before`. Declaring the same rule once per column, the way
this project's own board declares `card-duration` — once for `implement`,
once for `verify`, and so on — used to tie every declaration at the same
rank, and the last one declared silently won for every card board-wide,
whichever column it was actually in.

    d2 tira.policy.add --rule card-duration --column implement --age 4h \
      --action bridge-reminder
    d2 tira.policy.add --rule card-duration --column verify --age 24h \
      --action bridge-reminder

now resolves a card in `implement` against the first declaration and a card
in `verify` against the second, rather than both against whichever was
declared last. A card in neither column resolves to no `card-duration`
policy at all — narrower than either, not broader than both.


## Repairing a damaged file

`card-damaged` reports a card whose history holds bytes that are not valid
UTF-8. Police reads past them so the card is still checked, and never rewrites
the file: history is the permanent record of a board, and a record somebody's
tooling quietly rewrites is not evidence any more.

Cleaning it is a command somebody runs on purpose:

    d2 tira.doctor                 # what is damaged, and where
    d2 tira.doctor --repair        # clean it

    M5T-034.jsonl | byte 0xD7 at offset 280
    M5T-084.jsonl | byte 0xD7 at offset 288

It searches for **bytes**, not for the replacement character. U+FFFD is what a
lenient read produces when it meets a byte it cannot decode — what you see in
output, not what is on disk — so a doctor looking for it would find nothing and
report every damaged file clean.

A bad byte is repaired by reading it as latin-1 and writing it back as UTF-8, so
`0xD7` becomes the `×` somebody typed. Substituting a replacement character
instead would turn the damage into data permanently.

Afterwards `card-damaged` settles by itself, because the file reads strictly
again.

**107.** The owner edits a card in the browser while the agent works from the
command line, and the agent should go and read it.

```
d2 tira.policy.add --rule card-changed-by-owner --action bridge-reminder
```

The dashboard records who is signed in on every change it makes, so an edit
made there carries an author and an edit made from the CLI does not. The rule
compares rather than remembers — the newest change on the card was made by
somebody who is not the agent working it — so it settles the moment the agent
touches the card, and there is no stored timestamp to go stale. No `--age`: a
change is not more or less true an hour later, and waiting would only decide
how long the agent works from a card somebody has already rewritten.

