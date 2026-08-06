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

## DD-395

Method: Regression TDD + data-loss BDD.

- Red gate: the focused regression failed 25 of 27 assertions and reproduced
  silent replacement in all six content arrays and both scope arrays.
- Docker functional suite: PASS, 12 files and 479 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Acceptance: SOW, epic, and ticket updates retained existing entries,
  appended repeated values in order, and preserved explicit full replacement.
- Security: all 479 assertions passed under `prove -T`; all 75 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain and the documented
  append/replacement distinction matches the executable behavior.
- Platform: shared platform-neutral Perl only; macOS and Windows remain
  stopped.
- Release: committed as `8054cfe`; push was attempted and rejected because the
  configured passphrase-protected SSH identity has no active agent socket.

## DD-396

Method: Regression TDD + contract BDD.

- Red gate: the response-truth test reproduced the unstored second filename and
  absent deduplication metadata.
- Docker functional suite: PASS, 13 files and 502 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Acceptance: target-scoped record and comment deduplication, cross-record
  names, remove/re-add behavior, and JSON CLI response truth passed.
- Security: all 502 assertions passed under `prove -T`; all 75 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain; checklist retention
  and attachment response fields are explicit without location disclosure.
- Platform: shared platform-neutral Perl only; macOS and Windows remain
  stopped.
- Release: committed as `7e2a99d`; push was attempted and rejected because the
  configured passphrase-protected SSH identity has no active agent socket.

## DD-397

Method: ATDD + migration BDD + security TDD.

- Docker functional suite: PASS, 14 files and 574 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Read acceptance: export, full list compatibility, columns, field paths, and
  matched values passed in one-call workflows.
- Mutation acceptance: import/replace dry runs, exact transactional apply,
  mixed-set atomic rejection, mutable-field boundaries, and aliases passed.
- Log acceptance: stable gate/evidence IDs and append-only annotations passed;
  original observations remained unchanged.
- Security: all 574 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain and all new command
  combinations are documented without managed-location disclosure.
- Platform: shared platform-neutral Perl only; macOS and Windows remain
  stopped.
- Release: committed as `c9006f9`; push was attempted and rejected because the
  configured passphrase-protected SSH identity has no active agent socket.
- Real CLI reproduction: installed pre-0.09 `d2` rejected `--full` and
  `--field` with exit 2 and lacked `tira.export` with exit 1. A separate
  disposable project exercised the 0.09 working-tree entrypoints: export
  returned all three types with columns; full list returned the complete ticket;
  search returned two exact description hits; import/replace dry runs did not
  persist; applies matched their previews; gate/evidence originals survived
  annotation; and a mixed import failed atomically without changing the valid
  ticket.

## DD-398

Method: Problem-solving regression TDD + CLI contract BDD.

- Pre-fix reproduction: repeated `--field` options retained only the final
  value, and unscoped search returned an array while scoped search returned an
  object. Checklist removal was already unavailable, and import dry-run already
  supplied complete per-field diffs.
- Post-fix acceptance: repeated search/replace fields accumulate in supplied
  order, unnamed comments remain unchanged, and every search returns
  `{hits,count}`. Checklist permanence and verified import-diff shape are now
  explicit in agent and command documentation.
- Docker functional suite: PASS, 14 files and 582 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 582 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain.
- Platform: macOS and Windows remain stopped.

## DD-399

Method: Problem-solving regression TDD + read-path consistency BDD.

- Real pre-fix CLI: installed 0.10 hierarchy human output exited 0 with three
  warnings and false empty metadata; recursive JSON exposed only four sparse
  node keys although direct epic show contained the full record.
- Red gate: 10 new assertions failed across engine and CLI consistency checks.
- Post-fix CLI: the same disposable project returned the full description,
  assignee, priority, timestamps, linkage, and three children with empty stderr;
  recursive children were complete records and an unknown ref still exited 2.
- Docker functional suite: PASS, 14 files and 595 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 595 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain.
- Platform: macOS and Windows remain stopped.

## DD-400

Method: Problem-solving performance TDD + filesystem-scan BDD.

- Pre-fix installed 0.11 benchmark: 240 tickets / 13 visible columns took
  4.87, 4.99, and 4.72 seconds.
- Red gate: corrected three-column instrumentation observed three full board
  scans where one was expected.
- Post-fix working-tree benchmark: 0.53, 0.78, and 0.45 seconds, with JSON
  byte-identical to the baseline and all 240 records in the same column order.
- Docker functional suite: PASS, 14 files and 596 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 596 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain.
- Platform: macOS and Windows remain stopped.

## DD-401

Method: TDD + path-resolution security BDD + installed CLI ATDD.

- Pre-fix installed 0.12: both routes rejected a real registered alias with
  exit 2 because discovery required a literal filesystem path.
- Post-fix working-tree CLI: both routes resolved the same DD alias and read
  project `Zenandi` with status 0 and empty stderr; an unknown alias exited 2.
- Secrecy: successful and failing streams contained no resolved target path;
  direct existing paths retain precedence and invalid targets identify only
  the supplied selector.
- Docker functional suite: PASS, 15 files and 612 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 612 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 use cases remain and `SKILLS.md` contains none of
  the private selection mechanisms.
- Platform: macOS and Windows remain stopped.

## DD-402

Method: Performance TDD + output-contract BDD + filesystem-ordering ATDD.

- Baseline: 240 cards / 13 columns took 1.06, 0.82, and 0.89 seconds and
  emitted 224,033 TOON bytes while decoding all records.
- Red gate: nine assertions exposed JSON reads, full-card defaults, ref order,
  and missing bare `--title` support.
- Post-fix default: 0.28, 0.14, and 0.28 seconds; 3,881 bytes; zero JSON reads.
- Post-fix title/full: one read per title card; full JSON retained complete
  records. Every mode used newest-mtime-first ordering and deterministic ties.
- Docker functional suite: PASS, 16 files and 628 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 628 assertions passed under `prove -T`; all 80 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain.
- Platform: macOS and Windows remain stopped.

## DD-403

Method: BDD + HTML security TDD + Playwright ATDD.

- Red gate: 13/18 assertions failed before table rendering and type-specific
  dashboard routes existed.
- Perl acceptance: combined/one-board routing, left-to-right columns, title
  opt-in, HTML escaping, offline output, sort metadata, and table-only scope
  passed.
- Playwright: PASS in Docker with pinned Chromium; column geometry, gradient
  styling, panel treatment, card selection, mtime/ref controls, script init,
  and zero external elements passed.
- Visual review: PASS at 1440x1000; aurora/glass treatment, cyan ticket accent,
  card depth, typography, sticky headers, and horizontal overflow were clear.
- Docker functional suite: PASS, 17 files and 654 assertions.
- Coverage: `lib/Tira.pm` and `lib/Tira/CLI.pm` each reached 100.0% statement
  and subroutine coverage.
- Security: all 654 assertions passed under `prove -T`; all 83 entrypoints
  compiled under taint mode; the production process-primitive scan was clean.
- Agent contract: exactly 100 implemented use cases remain.
- Cleanup/platform: browser/screenshot/HTML/coverage artifacts removed;
  macOS and Windows remain stopped.

## DD-404 and DD-405

Method: Browser BDD + JavaScript timer TDD + PSGI/HTTP ATDD.

- Red gates: DD-404 failed exactly two missing refresh expectations; DD-405
  initially failed because no PSGI adapter, JSON route, or browser output
  contract existed.
- Timer acceptance: default 5, invalid 5, zero-clamped 1, and custom 60 second
  intervals passed with visible refresh and last-updated state.
- Browser acceptance: `/data` returns lightweight placement/title data; JavaScript
  moves cards in place without page reload. It carries only placement/title
  fields; `/record` loads full record data once when a card is clicked.
- Drag/drop acceptance: `/move` is a real record mutation that moves the JSON
  file into the requested column folder before placement refresh.
- Playwright: PASS at 1440x1000 with one shell request and one JSON request,
  30-second scheduling, card movement to `in-progress`, and dialog content.
- Visual review: PASS; the modal has a clear cyan identity, readable full JSON,
  strong depth, restrained backdrop blur, and an accessible close control.
- Docker functional/coverage suite: PASS, 18 files and 714 assertions.
- Coverage: all three production modules reached 100.0% statement and
  subroutine coverage.
- Security: all 701 assertions passed under `prove -T`; all 83 entrypoints and
  `dashboard.psgi` compiled under taint mode; the production process-primitive
  scan was clean.
- Agent contract: exactly 100 implemented use cases remain and private project
  selection terms remain absent from `SKILLS.md`.
- Platform: macOS and Windows remain stopped.

## Latest Verification For `DD-406`

Method: Engine/CLI TDD + HTTP ATDD + Browser BDD (Playwright).

- Red gates: `t/18-comment-remove.t` died on the missing `comment_remove`
  engine method; `t/19-dashboard-dialog.t` failed 16 assertions (no dialog
  providers, routes, or sectioned markup); the two updated `t/17` contract
  assertions failed against the old JSON-blob dialog.
- Functional: PASS in Docker, `Files=20, Tests=790`.
- Coverage: `100.0%` statement and subroutine for `lib/Tira.pm`,
  `lib/Tira/CLI.pm`, and `lib/Tira/DashboardWeb.pm`; `cover_db` removed.
- Taint/perlsec: full suite PASS under `prove -T`; all `cli/` entrypoints and
  `dashboard.psgi` compile under `perl -T` (with the container local-lib on
  `@INC`, which taint mode ignores from the environment); the production
  process-primitive scan (`system`/`exec`/`qx`/`readpipe`) is clean.
- HTTP ATDD: `/people` serves active people as UTF-8 JSON; `/update` and the
  three `/comment/*` routes decode strict UTF-8 payloads (`£` round-trips),
  return provider JSON on success, and answer provider failures and malformed
  JSON as structured `422 {ok:false,error}` without an HTML error page.
- Browser BDD: Playwright PASS. The fixture HTML/JSON are generated by the
  real renderer inside the Docker `perl-test` container; the browser run
  executes on the host with system Chrome because the shared test image ships
  only the Ubuntu snap chromium stub, not a launchable browser. Proven: the
  sectioned dialog renders Details/Description/Checklist/Comments with
  priority label and person names and no raw JSON, `null`, or `undefined`;
  a title edit posts `/update {ref,field,value}` and re-reads `/record`;
  comment add/update/remove post their exact payloads; the author dropdown
  is fed by `/people`; drag/drop still posts `/move`.
- Visual review: PASS on the dialog screenshot after one caught defect — the
  first render showed mojibake (`Â·`, `â`) because raw UTF-8 punctuation in
  the embedded script corrupted when concatenated with decoded record
  strings; replaced with ASCII-safe `\u` escapes and re-verified clean
  middle dots, em-dash placeholders, and the edit affordance.
- Agent contract: exactly 100 implemented use cases remain and private
  project selection terms remain absent from `SKILLS.md`.
- Platform: macOS and Windows labs remain stopped; no platform-dependent
  behavior changed (pure Perl/JS over existing routes).
