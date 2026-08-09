# REPORT 2026-08-09: `tira.question.list -o human` shows no questions, and every human render warns

## Where this came from

Raised by the **developer-dashboard** project, which has just adopted the question
commands as its only channel for asking its owner things. It is filed as a report
rather than as a `DD-NNN` ticket on purpose: this board allocates those numbers and
its `.tira/project.yml` is owned by `root` with mode `600`, so a normal user cannot
read the board to find the next free one. Claiming a number blind would collide.

Also copied to `/tmp/tira-bugs.md` at the owner's request.

## Objective

Make the human view of questions show the questions, and stop every human render
warning.

## Two defects, both in the human renderer only

JSON is correct in every case below, which is what localises them.

### 1. Every `-o human` render warns from `Tira.pm` line 3551

    $ d2 tira.ticket.show --ref DD-531 -o human
    Use of uninitialized value in string ne at .../Tira.pm line 3551.
    # DD-531: tira.question.list renders nothing useful in human output: ...

The card itself renders correctly, so this is cosmetic — but it is on stderr of
every human read, which teaches people to ignore this tool's warnings. That is the
real cost of it.

### 2. `tira.question.list -o human` renders the CARD, with an empty title, and no questions

The damaging one. On a card that genuinely has a question (`Q-003` on `DD-522`):

    $ d2 tira.question.list --ref DD-522 -o human
    Use of uninitialized value in string ne at .../Tira.pm line 3551.
    Use of uninitialized value in concatenation (.) or string at .../Tira.pm line 3570, <$fh> line 36.
    Use of uninitialized value in concatenation (.) or string at .../Tira.pm line 3570, <$fh> line 36.
    Use of uninitialized value in concatenation (.) or string at .../Tira.pm line 3570, <$fh> line 36.
    # DD-522:

...and nothing further. No question, no answer, and the card's title is empty where
the same card renders its title correctly through `ticket.show`. The same three
warnings appear on a card with **no** questions at all (checked on two), so the
warning count is not the question count.

The data is intact:

    $ d2 tira.question.list --ref DD-522 -o json
    {"instruction":"If an answer settles it, ...","questions":[{"id":"Q-003","status":"new",...}]}

## Why this matters more than a cosmetic bug

`UC-101` and `UC-102` exist so that a card carrying an unanswered question is
visibly waiting on the person who owns the decision. That person reads human
output, not JSON. As it stands they see an empty card and four warnings, so the one
workflow these commands were added for does not reach its intended reader.

## Acceptance criteria

- `tira.question.list -o human` lists each question with its answer underneath, and
  its `instruction` line.
- The card's title renders in that view as it does in `ticket.show`.
- No uninitialized-value warning on any `-o human` render.
- A card with no questions says so, rather than printing an empty card.

## Reproduction environment

- Tira at `~/.developer-dashboard/skills/tira` as installed for developer-dashboard.
- Warnings cite `lib/Tira.pm` lines 3551 and 3570.
- `-o json` correct throughout; asking, answering, marking and discarding all work.

## Separate finding while filing this

`/home/mv/projects/skills/skills/tira/.tira/` is owned by `root` and
`project.yml` is `-rw-------`, so this project's own board cannot be read by the
user who owns the checkout. Whatever created it ran as root. It is likely to block
this project's own tooling too, so it is worth checking rather than assuming it was
deliberate.
