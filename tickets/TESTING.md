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
