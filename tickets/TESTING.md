# Testing record

## 2.22 - what the push gate is asked about

The card check was asked about every card on the board at the moment the hook
ran. That is a different question from whether the commit being pushed is fit
to go, and its answer changes while the push is running. 2.14 was refused three
times for cards that had nothing to do with it; 2.21 was refused for TKT-261, a
card a bug hunt had raised an hour earlier on an unrelated subject.

It now asks about the cards the commits being pushed name, taken from their
subjects the same way the commit gate takes them. With no remote ref, or no
commits in the range, it falls back to the whole board - the direction that
checks more rather than less, and the way the tool is run by hand and by
`tools/prove-the-gate`.

`tools/prove-the-gate` found two faults in the change that reading it did not:

| What reading missed | What running showed |
| --- | --- |
| `grep` exits non-zero when it matches nothing, and the hook runs under `set -e` | The whole gate died silently at the card check; eleven probes reported the gate broken |
| every probe compared against the output of the last hook run, not of the command it ran | The first probe to run something other than the hook was reported as refusing without saying why |

Both fixed and both proved. Prover run on 2026-08-16 against the real gate:
**23 proved, 0 not proved, 0 not measured** - one more refusal than 2.20, since
the hook refusing a card check that fails is now exercised as well as one that
is absent.

## 2.20 - the release where the gate's own refusals were counted

`tools/prove-the-gate` breaks the push gate one check at a time, because a check
that has never been seen to fail is not a check, it is a hope. Nobody had ever
counted how many of the hook's refusals it reaches. I counted by hand three
times while raising TKT-230 and got it wrong twice, both times in the tool's
favour, by reading for a pattern instead of reading the file.

The count is now made by `t/233-what-the-gate-can-refuse.t`: it reads
`tools/hooks/pre-push` for every way the gate can refuse and the prover for what
answers each one. Seventeen refusals, fifteen provoked, two carrying a written
reason why they are not.

| Refusal | Proved by |
| --- | --- |
| a browser test that runs and fails | a stub `node` that answers the installed-check and fails a spec |
| a board backup that fails | the real tool stood aside, a stub exiting non-zero in its place |
| a missing compose file | nothing - the file is how the gate runs the suite, and a probe that removes it breaks the machine the gate runs on |
| a checkout that fails | nothing - provoking it means corrupting the repository being checked, and it cannot be staged in a clone, because what fails is the checkout of this repository |

The browser one is the one that mattered. It was proved for a runner that is
ABSENT and never for a test that RUNS AND FAILS, and the second is what happened
on the release that broke the served dashboard while ten browser tests passed.

The fix also caught a fault in its own earlier half. A guard added so that a
probe blocked by an incomplete card says so, rather than reporting the gate
broken for a reason that has nothing to do with it, silenced the one probe that
makes the board incomplete on purpose - the hollow card, the only probe that
puts a real card on the real board. It was skipped from the moment the guard was
written and nothing noticed, because a skip was neither proved nor failed.

Run on 2026-08-16 against the real gate: **22 proved, 0 not proved, 0 not
measured**, including `a browser test that fails is refused`, `a board backup
that fails is refused` and `a hollow card on the board (TKT-260) is refused`.

## 2.11 - the release that got Windows green again

**Linux, in Docker.** The shared `perl-test` container, 211 files, 5437 tests,
100% statement and subroutine coverage on `lib/Tira.pm`, `lib/Tira/CLI.pm` and
`lib/Tira/DashboardWeb.pm`.

**Windows.** `ssh windev`, Windows 11, Strawberry Perl - **PASS**, 211 files,
5308 tests, "All tests successful". The first green run there since 1.06.

The card named three failing files, because three was what the last run had
reported - against a tree five releases old. The whole suite on the current tree
failed in eight. Two causes accounted for nearly all of it:

- Five assertions asked `-x`. Executability is what makes a file a command on a
  POSIX system and is not a concept on Windows, where the answer is about the
  extension. `t/lib/Shipped.pm` asks it once.
- Four tests shelled out by building one string for the shell to take apart -
  `'git' 'init' '-q' '/path' > '/out' 2>&1` and ``cd '$where' && git ...``.
  Correct POSIX quoting; no quoting at all under cmd, which read the quotes as
  part of the path. `t/lib/Run.pm` runs them with a list and moves the handles.

The rest were individual: `t/95` set errno where the code reads the Win32 error,
`t/211` compared a resolved path as a string when Windows answers in forward
slashes and `File::Spec` builds backslashes, and `t/168` compared bytes where
the command's own text-mode STDOUT returns CRLF.

Three assertions in `t/169` run bash stubs through a POSIX shell and are skipped
by name. That was worth doing rather than leaving: on Windows the assertion in
front of them **passed**, because the command never ran, so its exit status was
zero and "a failure is not fatal" was satisfied by nothing having happened.

**git** is installed on the lab through winget (2.55.0.windows.3) and verified
from a fresh session, so every path that shells out to it can be gated there.

**macOS.** Not run for this release. Nothing in it is macOS-specific: the two
helpers introduced are about Windows behaviour and are no-ops elsewhere, and the
Linux gate covers the POSIX path they take.

## 2.02 - the release that found the platform gate had stopped running

**Linux, in Docker.** The shared `perl-test` container, 202 files, 5356 tests,
100% statement and subroutine coverage on `lib/Tira.pm`, `lib/Tira/CLI.pm` and
`lib/Tira/DashboardWeb.pm`. The first run of this gate failed, and usefully:
`t/03` asserts `podchecker` returns 0 for every `.t` file, and a file with no POD
at all returns -1, so a new test failed as "has valid POD" when its real fault
was having none.

**Windows.** `ssh windev`, Windows 11, Strawberry Perl 5.38.2 - **FAIL**, 202
files, 5100 tests. Failures in `t/169-one-place-not-four.t` (assertions 1 and
9-11), `t/187-a-column-nobody-is-watching.t` (27) and `t/95-windows-replace.t`
(10).

This release did not cause them. 2.01 was extracted separately onto the same lab
and run against those three files: identical failures, same assertion numbers.
The platform gate had not been run since 1.06, and about fifty releases shipped
between, so this is accumulated drift. It is raised as TKT-222 rather than
fixed here, because it belongs to no single change.

Two things are worth writing down beside that. `t/95` exists specifically to
prove Windows can replace a file, which is the fault that once stopped Tira
working on that platform at all - so it failing is not cosmetic. And git is not
installed on the lab, which means every path that shells out to git is
unreachable there: `_running_quietly`, the helper this release fixes, returns at
its first line and its descriptor handling never runs. The claim that this
release also repairs Windows bundle import is therefore reasoned and unproven,
and stays that way until the lab has git.

**macOS.** Not run for this release. The lab needs 50G of swap-backed memory and
the host has 15G total, so it runs alone; it is queued behind the Windows work
above rather than skipped silently.

## 1.06 — the release the platform labs changed

**Linux, in Docker.** The shared `perl-test` container, 97 files, 100% statement
and subroutine coverage on `lib/Tira.pm`, `lib/Tira/CLI.pm` and
`lib/Tira/DashboardWeb.pm`. The project's own board is masked by a tmpfs inside
the container, so a test run cannot reach it.

**Browser, on the host.** `t/playwright/login-gate.js` drives a real Chromium
against a real served board: a stranger reaches the login page and not the
board, the page names nobody, a wrong password is refused, a person who does not
exist is answered identically, the right password reaches the board, the session
cookie is HttpOnly, and the work log is closed until expanded. All passed on
2026-08-12.

Looking at it caught what no assertion did: the work log section sat outside the
dialog's scrolling area and clipped the section above it. Every test passed.
Fixed, and the placement is asserted now.

**macOS.** `ssh macdev`, macOS 14.8.5, perl 5.42.2 — **PASS**, 96 files.

It did not pass first time. Two collector tests compared a path Tira reports
against a path the test built itself, and on macOS `/var` is a symlink to
`/private/var`. Tira resolves a project directory to its real path so that two
spellings of one directory are one project — which is what stops the same
project registering two collectors that race the same board. That behaviour was
right and had never once been asserted. It is now, through a symlink, on every
platform.

**Windows.** `ssh windev`, Windows 11, Strawberry Perl 5.38.2 — **PASS**, 97
files, 3623 tests. It did not begin that way: it changed the release.

Tira did not work on Windows at all. Every write is a write to a temporary file
beside the target followed by a rename over it, and `rename` there refuses when
the destination exists: Tira could create a file and never change one. Behind
that sat a second cause with the same symptom — `YAML::PP`'s `load_file` leaves
the file open, and an open handle on Windows makes a file impossible to replace,
so every board config write failed immediately after the config had been read.

Five product faults in total, each with its own card, each fixed and each proved
in the Linux container as well as on the lab:

| | |
| --- | --- |
| TKT-031 | Every write to an existing file failed |
| TKT-032 | The clock's offset and the search for an installed agent were POSIX-only |
| TKT-033 | Output bytes were rewritten by the platform's text-mode layer |
| TKT-034 | The read cache could serve a caller its own stale data |
| TKT-035 | Self-restart never triggered, and five other failures diagnosed |
| TKT-036 | A signed-out board froze instead of saying so |

Eight test files were written in the shape of Linux and now say what they mean
on a platform where the thing they describe does not exist: pseudo-terminals,
the executable bit, path separators, and YAML handles left open by the tests
themselves.

None of this was visible on Linux. The suite has been green throughout the life
of the project and said nothing about any of it. A platform gate run at the end
of a release is not a formality; it is the only thing that was ever going to
find these.

Six failures were left after the first pass and all six are now diagnosed.
One was another real fault: a dashboard on Windows never picked up a new
version, because the entrypoint to restart into was found by asking whether a
file is executable and there is no such bit there. One was a path separator in
an assertion. The other four are one problem about child processes under a test
harness on Windows — spawning them, reading their output back through a pipe,
and replacing standard output while the harness holds it — and those files now
say so where they stand, each naming its reason.

`docs/foundation.md` carries a section listing exactly what is not proved on
Windows. It is not a claim that everything works there; it is a statement of
what has not been shown. The one part of it that matters to a user — whether a
reminder can reach a coding agent on Windows at all — is TKT-037.

## 1.26 — the world gatherer, on real Windows

Windows lab: `ssh windev`, QEMU Windows 11, Strawberry Perl 5.38.2, MSWin32-x64.

Eleven releases (1.15 to 1.25) shipped platform-dependent code without this gate
being run once. Running it found that the world gatherer's program lookup could
not find anything at all on Windows.

The lookup as it was, run on the lab:

```
  git       NOT FOUND
  tasklist  NOT FOUND
  ps        NOT FOUND
```

`tasklist.exe` is in `C:\Windows\System32`. The lookup searched for a file with
the exact name given and tested it with `-x`, and on Windows a program is
`name.exe` while `-x` answers for the extension rather than the file. So every
world fact came back empty and all six rules that read the world were silent -
which is the defect the previous release was about, reintroduced inside its own
fix.

After, on the same lab:

```
perl: v5.38.2 on MSWin32
tasklist found: yes
git found:      no
processes gathered: 138
  0    System Idle Process
  4    System
  124  Registry
```

`git` is genuinely not installed on that machine, so reporting it missing is
correct rather than a failure - a program that is not there contributes nothing,
and that is the documented behaviour.

`t/118-world-on-windows.t` on the lab: 11 of 11, with the two POSIX checks
skipped and saying why - the executable bit is not a thing on Windows, so that
half cannot be simulated there. The Windows half needs no such escape, because
`-f` means the same everywhere, which is exactly why that was the half that
broke unnoticed.

macOS lab: not started for this change. What it would add over Linux here is the
POSIX branch on a second POSIX platform, which the Linux suite already covers -
the fault was Windows-shaped. Recorded rather than skipped silently.

## 1.27 — the process table, on real macOS

macOS lab: `ssh macdev`, QEMU macOS 14.8.5, Homebrew perl 5.42.2 at
`/usr/local/opt/perl/bin/perl`.

The previous release recorded this lab as not started, reasoning that it would
only add the POSIX branch on a second POSIX platform that Linux already covered.
BSD ps is not Linux ps, and one command on the lab settled it:

```
Linux:   1 Tue May 26 08:06:05 2026 /usr/lib/systemd/systemd
macOS:   1 Thu 13 Aug 01:52:51 2026 /sbin/launchd
```

Month before day on one, day before month on the other. Both regexes that read
the process table required a month name in the second field.

Before, measured on each machine:

```
macOS   ps produced lines:  192     processes gathered: 0    with a start time: 0
Linux   ps produced lines:  711     processes gathered: 711  with a start time: 711
```

After:

```
macOS   ps produced lines:  178     processes gathered: 177  with a start time: 177
Linux   ps produced lines:  709     processes gathered: 708  with a start time: 708
```

Short by one on each is the header line ps prints for itself — short by the
same one on both, so the platforms agree.

`ps -eo` is correct on macOS: `-e` is identical to `-A` in POSIX mode, and the
"display the environment" meaning is the legacy BSD form. That doubt is settled
and needs no further checking.

Windows lab: not started for this change. The Windows reader takes a different
code path entirely — tasklist, no start times — and was proved on its own lab
one release ago. Recorded rather than skipped silently.

Both labs stopped.

## The labs themselves

The Windows lab had no persistent storage: removing the container threw away the
installed Windows, and this release paid for that with a full reinstall.
`~/vm/win/compose.persist.yml` is a new override beside the original — nothing
existing was edited — adding a storage mount so the disk survives, and an OEM
folder whose script runs at first logon and leaves the machine reachable over
SSH with a working Perl toolchain. The instructions in
`setup-ssh-on-windows.txt` existed only as steps for a person to type; they now
run themselves.

Both labs are stopped after use.

## Working the columns (from TKT-164)

The board defines eight columns and for a long stretch this agent used two:
`implement`, then `done`. The owner asked what was being worked because his
board showed TESTS-RED, IMPLEMENT, VERIFY, DOCUMENT and PUSH all empty, and the
standing instruction is that the board is the report.

A card walks:

| Column | What the card is in it for |
| --- | --- |
| `backlog` | raised, detailed, waiting |
| `tests-red` | the failing test is written and failing |
| `implement` | the fix is being written |
| `verify` | the full suite and coverage are being run |
| `document` | the manual, the reference and Changes are being written |
| `push` | the release is in the push gate, which takes twenty minutes |
| `done` | pushed, and the remote has moved |

`push` is the one that matters most to him: it is the only twenty-minute stretch
where nothing else moves, and an empty board during it reads exactly like a
stuck one.

## When a checklist is ticked (from his correction, 2026-08-16)

"violation like VIO-0173 shouldn't be issued. You only mark as done when you
actually done it. Not when you start doing it. So when every item are marked as
done. Card should be moved out from Implementation?"

He is right, and the rule was reading the board correctly. What was wrong was
the rhythm: finish the code, tick every checklist item, then start the full
gate — about twenty minutes — and only move the card to verify when it comes
back green. So the card sat in implement with a finished checklist for the
length of every gate run, which is exactly what `card-stalled` exists to catch.
It fired on nearly every card worked on 2026-08-16.

Ticking says the work is done, so the column has to say the same thing at the
same moment. And a gate run is not implementation, it is verification.

**Move to verify first, then tick — or both in the same breath. Implement never
holds a finished checklist.**

The visible consequence: a card now sits in verify for the twenty minutes of
its gate rather than in implement. That is the truthful place for it. A card
sitting in verify for much longer than a gate run is a real stall.

## The order cards are worked (from his correction, 2026-08-14)

"can you also working on the higher priority cards first, i see you randomly
pick and work on them disregard the card priority."

He was right. TKT-153 had waited from 09:58 while five cards raised after it were
worked. His own requests were genuinely P1 - they were about his being unable to
see what was happening at all - but the older P2 reports were skipped rather than
queued.

The order is **priority first, then oldest first**. No card is worked before one
that outranks it, and among equals the one that has waited longest goes next. A
card raised during the work does not jump the queue for being newest; it takes
its place by priority and age like everything else.
