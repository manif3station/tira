# Testing record

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
