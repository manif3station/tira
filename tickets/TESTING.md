# Tira Testing Record

## DD-388

Method: TDD + BDD + ATDD.

### Docker functional and coverage gate

- Shared `perl-test` container: PASS.
- Files: 4.
- Assertions: 133.
- `lib/Tira.pm`: 100.0% statement, 100.0% subroutine.
- `lib/Tira/CLI.pm`: 100.0% statement, 100.0% subroutine.
- Combined: 100.0% statement, 100.0% subroutine.
- `cover_db` removed after the report.

The suite proves project discovery and creation, all three board configurations,
monotonic reference allocation, JSON persistence, rollback, all output modes,
real nested CLI wrappers, private project-context precedence, raw `SKILLS.md`,
metadata, versions, and POD.
The metadata gate also proves that the agent manual contains its required
technical sections, exactly 100 uniquely numbered use cases from UC-001 through
UC-100, and no hard-coded home-directory path.

### Installed Developer Dashboard proof

`dashboard skills install ~/projects/skills/skills/tira` installed
version `0.01`. The installed dispatcher successfully ran:

- `dashboard tira.project.create -o json`
- `dashboard tira.sow.create` with default TOON
- `dashboard tira.epic.create -o human` with Markdown
- `dashboard tira.ticket.create -o json`
- record creation using the private project-context mechanism
- `dashboard tira.skills` with raw Markdown

The disposable project contained all three board configurations and
`SOW-001`, `EPC-001`, and `TKT-001` in their Backlog columns.

### Platform gate

- macOS 14.8.5, Homebrew Perl 5.42.2: PASS, 4 files and 122 assertions. The
  first run exposed a `/var` to `/private/var` canonical-path assertion defect;
  the test now compares canonical paths. The final run used macOS's portable
  `C` locale because the VM's inherited `C.UTF-8` locale is unavailable there.
- Windows 11 lab: unavailable. Its Compose stack has no persistent disk, rebuilt
  Windows from scratch, and the unattended configuration does not install or
  configure OpenSSH. The required setup file also contains a redacted password,
  so no safe automated guest command route existed. This is a lab provisioning
  limitation, not a Tira test failure. The stack was shut down.
- `macdev` and `windev` were both shut down immediately after their respective
  verification work. `macdev` was restarted for the private-context change,
  rerun successfully, and shut down again; both stacks are currently stopped.

### `perlsec` security gate

The final verification sequence used the installed Perl 5.40 `perlsec.pod` and
passed all 133 assertions under `prove -T`. Both modules and every shipped CLI
file compiled under `perl -T`. `Data::TOON` 0.03 and `YAML::PP` 0.41 were
verified. The production source contains no `system`, `exec`, `fork`, `glob`, or
`qx` calls.

The audit caused concrete hardening: canonical and temporary paths are validated
before file mutation, YAML prefixes/digit widths/counters are constrained and
untainted before becoming filenames, nested wrapper library paths are validated
before entering `@INC`, and taint tests sanitize shell-sensitive environment
variables. Tira invokes no external processes. `Data::TOON` supplies bounded
nesting and circular-reference detection for output encoding.

### Release gate

The verified release was committed locally. Push is blocked because the
passphrase-protected `github.mf` SSH identity has no running keyring agent in
this session. The ticket remains open until that commit is pushed.

## DD-389

Method: TDD + BDD + ATDD.

### Complete command contract

- 70 executable Developer Dashboard entrypoints implement UC-001 through
  UC-100; the agent manual contains no roadmap-only command.
- The real installed Developer Dashboard dispatcher resolved all 70 commands.
  This gate exposed and corrected the repeated nested-skill layout required for
  multi-segment commands.
- The Docker suite passed 9 files and 323 assertions including the executable
  command-count invariant.
- `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement and
  subroutine coverage.

### Security and rollback

The post-coverage suite passed under taint mode. All 70 executable entrypoints
compiled under `perl -T`, and production code contains no shell/process calls.
The audit hardened tainted directory enumeration, generated destination paths,
attachment hashes/extensions, types, slugs, and project creation paths.
Executable failure injection proves reciprocal JSON and column filesystem
changes restore their original state after later persistence failure.

### Release gate

Commit `add2c42` is present on `origin/master`.

## DD-390

Method: TDD + BDD + ATDD.

### Docker functional and coverage gate

- Functional suite: PASS, 10 files and 389 assertions.
- `lib/Tira.pm`: 100.0% statement, 100.0% subroutine.
- `lib/Tira/CLI.pm`: 100.0% statement, 100.0% subroutine.
- Combined: 100.0% statement, 100.0% subroutine.

The suite proves the symmetric metadata schema across SOWs, epics, and tickets;
case-insensitive labels; singular ownership; ISO 8601 validation; priorities;
versions; generated immediate parents; inactive-person enforcement; human name
and priority rendering; CLI argument combinations; and release 0.02 data
normalization.

### `perlsec` and taint gate

The complete 389-assertion suite passed under `prove -T`. All 72 executable
entrypoints compiled under `perl -T` with the installed dependency path, and a
production-source scan confirmed no shell/process primitives. The first
standalone compile attempt omitted the taint-safe local-library include path;
the corrected strict loop compiled every entrypoint successfully.

No macOS or Windows lab run was required because DD-390 changes only the shared
Perl data model and CLI parser and introduces no platform-dependent branch.
Both platform stacks remain stopped.

### Installed dispatch gate

Developer Dashboard installed the working tree as Tira 0.03. The raw skills
manual resolved, and all other 71 help routes resolved, proving all 72 shipped
entrypoints including person activate/deactivate.

### Release gate

The implementation was committed as `294fadc`. `git push -u origin master` was
attempted and rejected because the configured passphrase-protected GitHub SSH
identity has no active agent socket. No non-interactive GitHub CLI or Git
credential-helper route is configured, so the mandatory push remains open.

## DD-391

Method: TDD + security BDD.

- Docker functional suite: PASS, 10 files and 394 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 394 assertions passed under `prove -T`; all 72 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Installed dispatch: Tira 0.04 rejected attachment path output before managed
  storage lookup, returned status 2 and empty stdout, and exposed no location.
- Platform: no platform-dependent code changed; macOS and Windows remain
  stopped.
- Release: committed as `d4f3654`; the mandatory push was attempted and
  rejected because the configured passphrase-protected SSH identity has no
  active agent socket.

## DD-392

Method: TDD + security BDD.

- Docker functional suite: PASS, 10 files and 404 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- UTF-8 regression: a greater-than-40-KB argv comment containing `£` produced
  no warning and round-tripped through output, persistence, and reread.
- Legacy repair: isolated byte `0xA3` recovered as `£`; the next mutation wrote
  canonical UTF-8 bytes `0xC2 0xA3`.
- Security: 404 assertions passed under `prove -T`; all 72 entrypoints compiled
  in taint mode; no production process primitive was found.
- Installed dispatch: Tira 0.05 created and reread Unicode metadata, title, and
  comment text with empty stderr.
- Platform: no platform-dependent branch changed; macOS and Windows remain
  stopped.
- Release: committed as `cd63423`; the mandatory push was attempted and
  rejected because the configured passphrase-protected SSH identity has no
  active agent socket.

### Platforms

- macOS 14.8.5, Homebrew Perl 5.42.2: all 322 assertions passed.
- Windows 11: unchanged lab provisioning limitation; the fresh VM does not
  provide an automated OpenSSH guest route. No Windows-specific branch exists.
- `macdev` and `windev` are stopped.

## DD-393

Method: DocsDD.

- Docker functional suite: PASS, 10 files and 404 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` retained 100.0% statement and
  subroutine coverage.
- Security: all 404 assertions passed under `prove -T`; all 72 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Documentation: the measured Jira/Tira payload comparison and no-HTTP local
  filesystem architecture are recorded in README and the foundation guide.
- Platform: documentation-only; macOS and Windows remain stopped.

## DD-394

Method: TDD + BDD + ATDD.

- Docker functional suite: PASS, 11 files and 445 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Acceptance: all three record types passed checklist default, add, update,
  list, validation, legacy normalization, human output, and CLI-route checks.
- Security: all 445 assertions passed under `prove -T`; all 75 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain, with checklist
  command combinations incorporated without disclosing managed location.
- Platform: no platform-dependent branch changed; macOS and Windows remain
  stopped.
- Release: committed as `19fe726`; push was attempted and rejected because the
  configured passphrase-protected SSH identity has no active agent socket.
  The remote-backed installer therefore remains on 0.05 until 0.06 is pushed.
