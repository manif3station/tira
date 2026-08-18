
## PUSH-IS-A-GATE

**What happened.** On 2026-08-18, pushing 2.63 took over eight minutes with no
output, so I treated the wait as dead time and spent it working: I edited
`lib/Tira.pm` to redact the password from `project_show`, added
`t/271-a-read-that-gives-away-a-password.t`, and ran four separate `perl-test`
containers against the same tree. Only when I inspected the process tree did I
see what the pre-push hook actually does:

    git(1564016)---bash---docker---docker-compose---...

It runs the full suite in Docker. So the push was a gate run, against the live
mounted tree, while I was changing that tree and competing for the same
containers.

**Why it matters.** It is `GATE-THEN-EDIT` from the other end — that rule says
do not edit after a gate passes; this is editing *during* one that has not
reported yet. The verdict would have been about a tree that no longer existed,
and a failure would have been unattributable: mine, or the release's? The same
reasoning already bans a second test container during a coverage run, and I
broke it four times in ten minutes without noticing.

**How to avoid it.** `git push` in this repo is a gate, not a network
operation — treat the whole push window exactly like a coverage run: no tree
edits, no second container. If the wait must be used, use it for the board, for
reading, or for probes against a scratch board outside the tree. Check
`pstree -p <pid>` before assuming a long-running command is idle on the network.
