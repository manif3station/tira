# EPIC-469

## Title

Questions on cards: the open-decision page, done properly.

## Source

Owner voice message 3083 (2026-08-09). **Design in progress. Nothing is
implemented and nothing will be until the questions below close.**

## Goal

An agent working a card often cannot move it, but it can ask about a
procedure or a detail. Today every agent keeps its own "open decisions"
markdown file in its own format, and none of them agree. This replaces
that with one asked-and-answered surface that lives on the card.

## What the owner described

1. **A command-line surface for asking.** Any agent can ask a question
   against a card without touching the card's column.
2. **Every question carries its own reference**, so it can be answered,
   quoted and found again.
3. **The full set of operations**: add a question, remove one, update
   one, and change its status.
4. **Two statuses: New and Answered.** He first said several, then cut
   it to three, then in message 3086 cut it again: drop Follow Up
   entirely. Once it is answered it is Answered, full stop.
5. **No nesting. Single level.** His words: forget follow-ups, no
   layers, that is a waste of effort. An agent that wants to press
   further **asks a new question**, and the owner answers that one, and
   so on until it is settled. A conversation is therefore a sequence of
   plain questions, not a tree.
6. **Answering carries a free-text remark.** Every agent has its own
   attitude and writes the answer in its own words; the status is what
   is structured, not the wording.
7. **The owner answers from the command line too** — this is not an
   agent-only surface.
8. **Listing filters by status**, so "what is still unanswered" is one
   command.
9. **Listing filters by time range**, so an agent that has already read
   everything up to a point sees only what is newer rather than
   re-reading the lot.
10. **Output in whichever supported format the agent wants**, with the
    human one readable — each question, who asked it, and where it
    stands.
11. **The dashboard colours the card**: a card holding an unanswered
    question is yellow. No red — see settled point 2.

## Settled

1. **No Follow Up and no nesting** (message 3086, answering question 1).
   Statuses are New and Answered. Pressing further means asking another
   question, not threading one under another. This also removes the
   question about whether answering a sub-question settles its parent —
   there are no parents.

2. **Yellow only** (message 3092, answering question 2). With Follow Up
   gone there is no red: any card holding an unanswered question is
   yellow, and a card with none looks as it does today.

3. **Every card on every board** (message 3103, answering question 3),
   and **addressed by card reference alone** — no board argument. His
   point: the reference already says which card it is, so making
   somebody name the board as well is needless. This works because
   board prefixes are unique within a project, which `project_new`
   already refuses to let collide.

4. **Timestamps, and what the filter reads** (message 3106, answering
   question 4). A question's own stamp is when it was asked and
   **never changes** — there is no "updated" on a question. An answer
   carries its own stamp, and gains an updated stamp only if the answer
   itself is edited. The time filter reads **the answer's latest stamp
   when there is an answer, and the question's stamp when there is
   not**, so an agent catching up sees both newly asked questions and
   newly answered ones without having to reason about it.

5. **A card with unanswered questions is not chased** (message 3107).
   While a question is outstanding the card is not in the agent's
   hands, it is in the owner's, so the stale-card reminder must leave
   it alone. It rejoins the reminders only once every question on it
   has been answered.
6. **Answering the last question notifies the agent** that every
   question on that card is now answered, so it knows it can pick the
   card back up. Message 3112: the wording is that the ticket is clear,
   all questions are answered, and it is back with the agent.
7. **The dwell clock stops while a card is blocked** (message 3115), so
   answering does not leave a card instantly overdue for the time the
   owner took. Dwell is measured from the moment the last question was
   answered, not from the move that put it in the column.
8. **Escalation resets to level 1** when that happens (message 3112),
   not to where it was before the block. Note for implementation: the
   level is derived by counting notification rows, so the reset is a
   marker row that counting starts after — the level stays derived
   rather than becoming stored state.

9. **Partial answers do nothing** (message 3118). Five answers out of
   ten changes nothing and sends nothing: the answers are simply kept
   on the card. Only answering the last one triggers anything.

10. **Answers carry a read mark and an accepted mark**, the two ticks
    of a messaging app. **Reading is automatic**: when the agent runs
    the command that shows the answers, that act marks them read — the
    agent does nothing extra, and the owner can see it has looked.
    **Accepting is deliberate and separate**: a command run per answer
    saying this one is fine. Having read an answer is not the same as
    being satisfied by it.

11. **An answer is marked OK or NOT OK** — he corrected himself in
    message 3121: there are two marks, a tick and a cross, not just an
    accept. **A cross on its own does not settle anything**: an agent
    that marks an answer NOT OK must also ask a new question. Pressing
    further is always a new question, since there are no follow-ups.

12. **The card stays yellow until the agent has accepted everything.**
    Yellow while questions are unanswered, and *still* yellow after the
    owner answers, because the agent has not looked yet. It returns to
    its normal colour only when every answer has been read and
    accepted. So yellow means this card is waiting on somebody, in
    either direction.

13. **Every command's output tells the agent its next step.** After
    listing answers: if you are satisfied, run this command to accept
    it; if you are not, ask a new question. The agent should be able to
    tell from the output alone whether it is waiting on the owner or
    the owner is waiting on it.

14. **Documentation is part of the work, not after it.** Every new
    command and every argument goes in `docs/commands.md` — what it is
    for and when to use it — and in `SKILLS.md` as use cases in the
    existing format, teaching an agent to ask on the card rather than
    just parking it, to read the answers, and what to do next.

15. **The all-clear rides the collector's next heartbeat** (message
    3128), not the instant the owner answers. Tira's engine runs no
    external process, so the agent is only ever spoken to by the
    collector.

16. **The exemption ends when the owner answers the last question**,
    not when the agent marks the answers. He had already said this in
    message 3107 — the reminders resume once the ticket has no
    outstanding questions — and I asked it twice more without
    recognising it as answered. It is also the safe reading: waiting on
    the agent's marks would let an agent avoid reminders forever by
    never marking anything.

## Design closed

Every question answered. Nothing below is guesswork.

## Status

Design closed 2026-08-09, owner said start working (message 3131).
Building:
`DD-470` the question surface (engine and CLI), `DD-471` the dashboard
showing which cards are waiting on an answer.
