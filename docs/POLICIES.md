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
| `question-unanswered` | `--age` | a question waiting on the owner |
| `answer-unjudged` | `--age` | an answer nobody marked |
| `answer-ok-not-folded` | `--age` | settled in name only: marked ok, nothing written down |
| `answer-not-ok-no-followup` | `--age` | a cross with no further question |
| `wip-limit` | `--column --max` | too many things being worked at once |
| `gate-missing` | `--column` | work that reached the end with no gate recorded |
| `discard-unexplained` | — | work set aside with no reason given |
| `commit-without-card` | — | a commit that names no card |
| `work-without-card` | `--age` | a tree changing while nothing is at a working gate |
| `unpushed-work` | `--age` | commits sitting unpushed |
| `board-unbacked` | `--age` | a board with no recent backup |
| `card-sandbox-missing` | `--enter --sandbox` | a card being implemented with no branch or worktree of its own |
| `leftover-process` | `--pattern --age` | something started and never stopped |
| `leftover-container` | `--age` | a container still running |

## The actions

| Action | Where it goes | Use it when |
| --- | --- | --- |
| `bridge-reminder` | the agent's bridge | you want the agent to act |
| `print-reminder` | the owner's police terminal | you want the owner to see it |
| `log-only` | recorded, said to nobody | you are tuning a rule and do not want the noise yet |

## Ages

`--age` takes `30s`, `10m`, `2h` or `7d`. It is that rule's grace: a card
created seconds ago and one abandoned for an hour are not the same thing, and
one number for everything would make the whole channel unbearable.

## What happens when a rule fires

Every violation gets a number, `VIO-0001`. The same problem keeps its number,
counts its repeats, and rises through four tones: note, warning, urgent,
critical. Past five repeats it also reaches the owner's terminal with a message
he can paste straight to the agent.

Fixing the cause silences it on the next pass. There is nothing to acknowledge
and nothing to clear by hand.

If police cannot work out which policy applies — a rule naming a column that
does not exist, for instance — it says so on the bridge rather than guessing.
That message is asking you to be more specific.

## Where things live

Policies live in the project config, so they travel with the project and
anybody can read them. Police keeps its own state — the violation ledger, the
bridge log — outside the project entirely.
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
d2 tira.policy.add --rule leftover-container --age 30m --action bridge-reminder
```

**72.** A machine where a container running an hour is normal but two is not.

```
d2 tira.policy.add --rule leftover-container --age 2h --action bridge-reminder
```

**73.** A shared build machine where nothing should outlive its job by long.

```
d2 tira.policy.add --rule leftover-container --age 10m --action bridge-reminder
```

**74.** An owner who wants to know what is still running on his machine.

```
d2 tira.policy.add --rule leftover-container --age 1h --action print-reminder
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
d2 tira.policy.add --rule leftover-container --age 30m --action log-only
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
d2 tira.policy.add --rule leftover-container --age 30m --action bridge-reminder
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
