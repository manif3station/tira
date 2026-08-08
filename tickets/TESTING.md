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

## Latest Verification For `DD-407`

Method: Engine/CLI TDD + HTTP ATDD + Browser BDD (Playwright), from the
recorded Jira research plan in `tickets/DD-407.md`.

- Red gates: `t/20-attachment-detach.t` died on the missing
  `attachment_add_content`/`attachment_detach` engine methods;
  `t/21-dashboard-attachments.t` failed 9 assertions (no providers, routes,
  or dialog markup).
- Functional: PASS in Docker, `Files=22, Tests=852`.
- Coverage: `100.0%` statement and subroutine for all three production
  modules after adding the octet-stream fallback test; `cover_db` cleaned.
- Taint/perlsec: suite PASS under `prove -T`; all entrypoints and
  `dashboard.psgi` compile under `perl -T`; process-primitive scan clean.
- HTTP ATDD: `GET /attachment` streams provider bytes with the provider's
  content type and disposition and answers unknown attachments 404;
  `/attachment/add` and `/attachment/remove` decode JSON payloads and fail
  as structured 422; text-like content (html included) is typed
  `text/plain` so nothing executes in the viewer frame.
- Engine acceptance: content uploads dedup by sha across records without
  temp files, refuse >16MB, and retain UTF-8 original filenames; detach
  removes exactly one reference (record- or comment-scoped), physically
  removes the stored file through the logged `attachment_remove` only when
  no record or comment anywhere still references it, and dies clearly on a
  reference the record does not hold; `tira.attachment.detach` mirrors it.
- Browser BDD: Playwright PASS — comment-owned chip renders inside its
  comment; the viewer overlay opens with an `/attachment?` iframe src and
  closes; confirmed deletion posts the exact detach payload; a real file
  picked through the input posts base64 that round-trips byte-identically.
- Visual review: PASS on strip and viewer screenshots — chips read like
  Jira (filename + delete + Attach file control), `notes.txt` opens inline
  over the dialog with correct `£` rendering and Download/close controls.
  The owner's phone screenshot review caught hover-only edit pencils
  (invisible on touch, so the modal read as read-only); pencils are now
  always visible (`MISTAKE.md` `CAPTION-BLIND` records the miss).
- Agent contract: exactly 100 use cases; no project-location disclosure.
- Platform: labs remain stopped; nothing platform-dependent changed.

## Latest Verification For `DD-408`

Method: Engine/CLI TDD + HTTP ATDD + Browser BDD (Playwright).

- Red gates: `t/22-dashboard-lists.t` failed 6 assertions (no checklist
  providers, no editable-list markup, no array-valued update semantics).
- Functional: PASS in Docker, `Files=23, Tests=882`.
- Coverage: `100.0%` statement and subroutine for all three production
  modules; `cover_db` cleaned.
- Taint/perlsec: suite PASS under `prove -T`; entrypoints and
  `dashboard.psgi` compile under `perl -T`; primitive scan clean.
- HTTP/provider ATDD: array-valued `/update` replaces whole lists in order
  through the engine's replace semantics; scope sides replace independently
  and preserve the other side; list fields refuse plain scalars, plain
  fields refuse arrays, list items must be plain text, linkage is refused
  by name; `/checklist/add` and `/checklist/update` wrap the engine
  commands and fail as structured 422 (unknown ids, missing item/status).
- Browser BDD: Playwright PASS — per-item list edit posts the full
  replacement array, item removal posts the shrunken list, the add box
  appends, checklist status edit posts `/checklist/update` with the
  immutable id, the add form posts `/checklist/add`, and no checklist
  delete control exists. Two script fixes during the run: the title-edit
  selector needed scoping to the heading once list adders shared the input
  class, and one drag-step flake retried clean.
- Visual review: PASS — every value carries a visible pencil, list rows
  show edit/remove with an Add box per section. Noted as follow-up polish
  (not blocking): the labels/affects-versions adders make the details grid
  denser than the DD-406 layout.
- Agent contract: exactly 100 use cases; no location disclosure.
- Platform: labs remain stopped; nothing platform-dependent changed.

## Latest Verification For `DD-409`

Method: Engine-provider TDD + HTTP ATDD + Browser BDD (desktop + mobile).

- Red gates: `t/23-dashboard-linkage.t` failed on missing providers,
  routes, interactive markup, heading pencils, and the mobile media query.
- Functional: PASS in Docker, `Files=24, Tests=937`.
- Coverage: `100.0%` statement and subroutine, all three modules;
  `cover_db` cleaned.
- Taint/perlsec: `prove -T` PASS; entrypoints and `dashboard.psgi` compile
  under `-T`; primitive scan clean.
- Provider/HTTP ATDD: hierarchy link/unlink round-trips through the engine
  (SOW-epic proven, invalid pairs refused with the engine message);
  sub-item link/unlink round-trips; typed links create and remove with
  reciprocals on both records; unknown link types refused; `/link-types`
  serves the configured pairs; all six mutation routes dispatch and fail
  as structured 422.
- Browser BDD: Playwright PASS — typed-link removal and creation post the
  exact payloads (inward name selectable), setting an epic parent posts
  `/hierarchy/link` with the right parent/child orientation, sub-item
  unlink posts its payload, the description pencil renders inside the
  section heading, and one route-literal defect was caught red
  (dynamically-built route strings hid the contract; replaced with a
  literal route table).
- Mobile BDD: dedicated 430x932 pass — zero horizontal page overflow, the
  dialog fits the viewport, and the details grid stacks to one column.
- Visual review: PASS on both viewports — heading pencils in place on
  desktop; the phone layout is genuinely usable with full-width dialog,
  stacked labeled fields, and per-item editors.
- Agent contract: exactly 100 use cases; no location disclosure.
- Platform: labs remain stopped; nothing platform-dependent changed.

## Latest Verification For `DD-410`

Method: Browser BDD (desktop + touch) under the Mandatory Problem-Solving
Loop; the full loop record lives in `tickets/DD-410.md`.

- Red gate (loop steps 4-5): a real CDP touch drag on the 430x932 pass
  posted ZERO `/move` requests against the HTML5 drag engine — the exact
  reported failure, root-caused to mobile browsers never synthesizing
  HTML5 drag events from touch.
- Fix (step 6): one Pointer Events engine for both inputs — 250ms
  hold-to-drag on touch (native scrolling preserved via
  `touch-action:pan-y`), 6px movement threshold on mouse, floating ghost,
  `elementFromPoint` drop-target highlight, same `/move` contract.
- Re-run (step 7): the identical touch reproduction posts exactly one
  `/move`; the desktop pointer drag posts one `/move` with ghost and
  highlight asserted mid-drag; a card click still opens the dialog.
- Two additional defects found and fixed during the loop: the drag-release
  click reopened the dropped card (now swallowed by a one-shot 50ms
  window), and Playwright's `dragTo` helper proved incompatible with a
  pointer engine (HTML5-DnD-oriented) — the suite now drives raw pointer
  input, which also eliminated the historical intermittent drag flake.
- Stability: four consecutive full Playwright runs PASS after adding a
  deterministic post-drag settle (refresh round trip + one frame).
- Guards (step 8): the touch-drag scenario is permanent in the mobile
  pass; the renderer contract test pins the pointer engine and forbids
  `dragstart`/`draggable`.
- Functional: PASS in Docker, `Files=24, Tests=938`; coverage `100.0%`
  statement and subroutine; taint and primitive-scan gates clean;
  `cover_db` cleaned.
- Platform: labs remain stopped; nothing platform-dependent changed.

## Latest Verification For `DD-411`

Method: Engine TDD + Browser BDD (Playwright).

- Red gates: `t/24-dashboard-comments-attachments.t` failed on missing
  `added_at` stamping and composer/renderer contract; the updated `t/12`
  reference-shape expectation failed against the unstamped engine.
- Functional: PASS in Docker, `Files=25, Tests=953`.
- Coverage: `100.0%` statement and subroutine, all three modules;
  `cover_db` cleaned.
- Taint/perlsec: `prove -T` PASS; entrypoints and `dashboard.psgi` compile
  under `-T`. The primitive scan's single textual hit is JavaScript's
  `RegExp.exec()` inside the embedded dashboard script — inert string data
  to Perl, not a process primitive; no Perl `system`/`exec`/`qx`/
  `readpipe` exists in production code.
- Engine acceptance: content and file-path adds stamp `added_at` from the
  injected clock; dedup re-adds retain the original stamp; every listed
  reference carries the field.
- Browser BDD: Playwright PASS ×3 — chips ordered newest first with
  visible dates, comments ordered `CMT-002` before `CMT-001`, the composer
  starts collapsed (a `[hidden]`-beats-`display:grid` CSS defect was
  caught and fixed) at the top of the comments box, the bold toolbar wraps
  a selection into `**rich**`, markdown text reaches `/comment/add`
  unchanged, and a bold body renders exactly one `<strong>` element with
  no raw-HTML injection path (`innerHTML` absent by contract test).
- Visual review: PASS — dated chips, top composer with formatting bar, and
  formatted bold/italic/code/bullet rendering in comments.
- Agent contract: exactly 100 use cases; no location disclosure.
- Platform: labs remain stopped; nothing platform-dependent changed.

## Latest Verification For `DD-412`

Method: Browser BDD under the Mandatory Problem-Solving Loop (full record
in `tickets/DD-412.md`).

- Red gate: the owned `.card-viewer__text` pane selector matched nothing;
  the owner's screenshot (a real ZSD-138 file, white-on-white in dark
  mode) is the reported reproduction. Root cause: browser default
  plain-text rendering follows dark `prefers-color-scheme` (white glyphs)
  while the dialog CSS forces a light iframe background.
- Fix: text-like attachments are fetched and rendered into the viewer's
  themed `<pre>` via `textContent` — deterministic contrast, no execution
  path; images and PDFs keep their panes.
- Re-run: Playwright asserts the pane content, that text no longer routes
  through the iframe, and that the pane color is not near-white; a
  dark-`colorScheme` capture shows the file fully legible. Playwright ×3
  green (the former no-`pre`-blob guard was scoped to the sections area,
  where a blob would actually live).
- Functional: PASS, `Files=25, Tests=953`; coverage `100.0%` statement
  and subroutine; taint gates PASS; `cover_db` cleaned.

## Latest Verification For `DD-413`

Method: Browser BDD under the Mandatory Problem-Solving Loop.

- Reproduction (loop steps 4-5): with a resident card in the target
  column, releasing 45px below it hit `MAIN.shell` — no `.cards` ancestor
  — and posted ZERO `/move` requests: the reported bounce-back. Drops
  directly onto the resident card worked on both desktop and touch, and
  empty columns worked because their compact list sits where users aim —
  which is why every prior drag test missed the gap.
- Root cause: the drop test required the release point to be inside the
  `.cards` list, which only spans its content height; the natural
  "append below" release point on a populated column is outside it.
- Fix (step 6): `columnAt` resolves geometrically — a direct list hit in
  the card's own board wins; otherwise, within the board's vertical
  stripe, the column whose horizontal band contains the pointer is the
  target; outside the board cancels. Cross-board drops are structurally
  excluded by the board scoping.
- Re-run (step 7): the identical below-card release posts exactly one
  `/move`; onto-card and empty-column drops still pass on desktop and
  touch.
- Guard (step 8): the permanent desktop drag scenario now releases into
  the former dead zone (below content, inside the board stripe) against a
  fixture with a resident card in the target column; the mobile touch
  scenario drops onto the populated column. Playwright ×3 green.
- Functional: PASS, `Files=25, Tests=953`; coverage `100.0%` statement
  and subroutine; taint gates PASS; `cover_db` cleaned.

## Latest Verification For `DD-414`

Method: Browser BDD under the Mandatory Problem-Solving Loop.

- Reproduction: two backlog cards with staggered file mtimes; after the
  initial live refresh both rebuilt cards stamped `mtime:0` and rendered
  in reference order (`TKT-002` before the newer `TKT-003`) — the
  reported broken sort.
- Root cause: the browser `/data` callback forces summary/`toon` context,
  which deleted `_mtime` from the payload, and `buildCard` read
  `updated_at`/`last_updated` fields the summary never carries. The
  server-rendered initial board sorted correctly, so the breakage only
  appeared after the first ajax refresh replaced the cards.
- Fix: the data callbacks (CLI-launched server and `dashboard.psgi`) set
  `include_mtime`; `_invoke` honors the explicit flag; `buildCard`
  prefers `_mtime` (epoch seconds) with the old field fallback.
- Re-run: the identical fixture renders `TKT-003` first with nonzero
  stamps after refresh; ×3 Playwright green.
- Guard: the permanent scenario asserts newest-first backlog order with
  nonzero mtimes right after the initial refresh.
- Functional: PASS, `Files=25, Tests=953`; coverage `100.0%` statement
  and subroutine; taint gates PASS; `cover_db` cleaned.

## Latest Verification For `DD-415`

Method: Engine TDD + Browser BDD, from the owner's screenshot review of a
real project board (message 2888).

- Owner-visible defects: attachments rendered as a wrapping chip cloud
  (two per row, long names clipped) rather than a list, and every
  attachment added before 0.22 showed an em-dash instead of a timestamp,
  making the sort look broken.
- Fix: the strip is a vertical one-per-row list (filename left, date
  right-aligned, delete at the row end; linkage chips stay inline);
  `record_show` backfills missing `added_at` from the deduplicated store
  file's own mtime — the moment that content first arrived — persisting on
  the record's next mutation per the legacy-repair precedent.
- Engine guard: a simulated legacy reference (fixture-edited, with the
  store file's mtime pinned via utime) recovers the exact strftime of
  that epoch through `record_show`.
- Browser guard: the permanent scenario asserts every attachment row has
  identical x, stacked y, and ≥95% of the strip width — a list, not a
  cloud. Playwright ×3 green; mobile dark-mode capture of a
  ZSD-136-shaped fixture visually reviewed.
- Functional: PASS, `Files=25, Tests=954`; coverage `100.0%` statement
  and subroutine; taint gates PASS; `cover_db` cleaned.

## Latest Verification For `DD-416`

- Owner annotation on the 0.26 proof screenshot: the rows showed only the
  date, so same-day attachments gave no visible order even though the
  sort already compared full ISO timestamps.
- Fix: the row stamp renders through `humanDate` (full date and time);
  sorting unchanged. The permanent browser guard now requires the full
  `YYYY-MM-DD HH:MM:SS` stamp on the newest row.
- Functional PASS `Files=25, Tests=954`; coverage `100.0%`; `prove -T`
  PASS; Playwright ×3 green; mobile dark capture visually reviewed with
  intra-day ordering legible (21:34 > 18:02 > 15:31).

## Latest Verification For `DD-417`

Method: Browser BDD under the Mandatory Problem-Solving Loop; the owner's
screen recording (message 2898) is the reported reproduction.

- Diagnosis from the recording: the hold ARMS the drag (ghost and dashed
  drop target visible) but the ghost never tracks the finger — iOS/WebKit
  keeps claiming the movement for scrolling; preventDefault on pointer
  events does not stop that arbitration, only blocking the raw touchmove
  does. The prior touch proof ran emulated Chromium, which is exactly the
  boundary recorded in the DD-410 evidence.
- Fix: a non-passive document touchmove listener prevents default only
  while a drag is armed; pointercancel still aborts cleanly for genuine
  system interruptions; `-webkit-touch-callout:none` suppresses the
  long-press callout on cards.
- Verification stack, honestly bounded: renderer contract guard requires
  the non-passive touchmove blocker; Chromium desktop and CDP touch flows
  remain green ×2; the host cannot launch the Playwright WebKit port
  (missing system libraries — both cached builds fail at startup), so
  engine behavior under real WebKit gesture arbitration is verified by
  the owner's re-test on the physical iPhone — CONFIRMED PASSING by the
  owner ("Fixed. Thanks", message 2905, 2026-08-06), closing the
  acceptance gate.
- Functional PASS `Files=25, Tests=955`; coverage `100.0%`; `prove -T`
  PASS.

## Latest Verification For `DD-418`

- Owner ask (message 2899): the hero should show the project name. The
  heading now renders the project's configured name (HTML-escaped) with
  the product name in the eyebrow; without a resolvable project the
  heading stays "Tira Kanban". `dashboard.psgi` passes the project to the
  renderer like the CLI path.
- Contract: t/17 requires `<h1>Browser project</h1>` and the surviving
  product name. Functional PASS `Files=25, Tests=957`; coverage `100.0%`;
  `prove -T` PASS; Playwright ×2 green.

## Latest Verification For `DD-419`

Method: Browser BDD under the Mandatory Problem-Solving Loop; the owner's
screen recording (message 2910) is the reported reproduction, and the
extracted frames show both faults: a blank backdrop when the card was
opened after scrolling (dialog stranded above the viewport) and modal
content clipped horizontally.

- Root causes: DD-407's `position:relative` on the dialog (added for the
  viewer overlay's absolute positioning) cancelled the UA's fixed modal
  centering, so the dialog rendered at the page top rather than the
  viewport; and long unwrapped content made the sections area wider than
  the phone, enabling horizontal panning.
- Fix: the dialog is explicitly `position:fixed; inset:0; margin:auto`
  (the viewer overlay still positions against it, as fixed establishes
  the containing block); the sections area is `overflow-x:hidden` with
  `overflow-wrap:anywhere` on sections.
- Guards: the mobile pass now scrolls to the page bottom BEFORE opening
  the card and asserts the dialog lands inside the viewport, and asserts
  the sections area has zero horizontal scroll. Playwright ×3 green.
- Functional PASS `Files=25, Tests=957`; coverage `100.0%`; `prove -T`
  PASS. Owner device check requested.

## Latest Verification For `DD-420`

Method: Browser BDD under the Mandatory Problem-Solving Loop (owner
report, message 2915 — three connected findings).

- Root causes: the dialog's native Escape (cancel) closed the whole modal
  with no cleanup path, leaving the attachment viewer overlay alive; on
  the next open it painted the previous attachment over the fresh
  sections — the "old card content". Separately, nothing ever re-read an
  open dialog's record.
- Fix: the dialog's `cancel` event closes only the viewer when one is
  open; the `close` event resets the viewer and error strip; the board's
  refresh cycle calls a dialog reload guarded by an editing-activity
  predicate (open field/comment editors, focused form controls, or the
  expanded composer suppress it).
- Guards: desktop — Escape closes viewer-then-dialog in two steps, and a
  reopened dialog shows the newly clicked card (`/record` mock echoes the
  requested ref) with no viewer remnant; mobile — with the dialog open
  and no editing, a changed record title arrives through a real refresh
  cycle ("Edited elsewhere"). Playwright ×3 green.
- Functional PASS `Files=25, Tests=957`; coverage `100.0%`; `prove -T`
  PASS.

## Latest Verification For `DD-421`

- Owner ask (message 2917): preview video, PDF, TIFF, and documents.
- Server: extension map adds video/audio/tiff types; the `/attachment`
  route advertises `Accept-Ranges: bytes` and answers single byte ranges
  as 206 with `Content-Range` (verified: exact slice, open-ended tail,
  unsatisfiable range falling back to 200 full body) — required for iOS
  media playback and seeking everywhere.
- Viewer: dedicated panes — native video/audio players, image pane with
  an onerror fallback panel (how TIFF degrades on browsers that cannot
  decode it; Chromium proves the fallback path), text pane, PDF iframe,
  and a not-supported panel for other binaries; every close path resets
  all panes.
- Guards: provider content-type checks (mp4→video/mp4 inline,
  tiff→image/tiff, mp3→audio/mpeg); route Range semantics; Playwright
  proves the video player pane and the TIFF fallback panel. One fixture
  count correction in t/21 after adding the media uploads. Playwright ×3
  green; functional PASS `Files=25, Tests=968`; coverage `100.0%`;
  `prove -T` PASS.

## Latest Verification For `DD-422`

- Owner ask (message 2924): a column dropdown in the card dialog to move
  the card between columns like Jira.
- Renderer: the header ref line gains a `card-status` select populated
  from the live board DOM for the card's type, preselected to the current
  column; a change posts the standard `/move` payload then refreshes the
  board and reloads the dialog.
- Loop record: the mobile Playwright refresh guard went red — root cause
  `showModal()` auto-focusing the new select, which the editing guard
  reads as an active edit, suppressing live refresh forever. Fix:
  `autofocus` on the close button so initial focus is a non-editing
  control. A separate guard-script race (text pane asserted before its
  fetch resolved) was replaced with a content wait.
- Guards: t/19 pins `card-status` in live HTML; Playwright asserts the
  option list (backlog + in-progress), the in-progress preselection, a
  selectOption posting `/move`, and the mobile "Edited elsewhere" refresh
  wait — the regression's own detector. Playwright ×3 green; functional
  PASS `Files=25, Tests=969`; coverage `100.0%`; `prove -T` PASS.

## Latest Verification For `DD-423`

- Owner discussion and approval (messages 2927/2928, 2932): protect
  same-field edits from silent last-write-wins between two users on
  different machines; different-field merges must stay unaffected.
- Engine: `record_update` gained `expect => { field => base }`, a
  compare-and-swap checked inside the project lock before any change —
  mismatch dies `Conflict: <field> changed while you were editing` and
  writes nothing; null bases match only unset fields; values compare as
  strings.
- Route: the browser update provider forwards a scalar `base` as
  `expect` (structured bases refused); `_mutation` marks `Conflict:`
  failures with `conflict:true` in the 422 JSON.
- Dialog: each field editor sends the value it opened with as `base`;
  a conflict shows the explanation and reloads the fresh card, message
  kept visible.
- Guards: t/09 engine CAS semantics (stale/matching/null/numeric bases);
  t/19 provider round-trip, structured-base refusal, HTTP 422 conflict
  shape, no-flag on ordinary failures, renderer contract for
  `base:base`, `result.conflict`, and the message; Playwright asserts
  the base in the real update payload and the full conflict recovery.
  Playwright ×3 green; functional PASS `Files=25, Tests=989`; coverage
  `100.0%` on all three modules; `prove -T` PASS.

## Latest Verification For `DD-424`

- EPIC-424 opener (CA01+CA02+CA03): field projection on show, list, and
  export via one engine layer; CLI flags `--fields`/`--exclude-fields`.
- New suite `t/25-field-selection.t` (red first): ref always kept on
  selection; null selections stay visible; comma + repeat accumulation;
  unknown/empty names die naming the offender (CLI exit 2); exclusion
  after selection; export count preserved and uniform across types;
  no-flag reads byte-identical in shape to before; flags on a mutation
  exit 2.
- Browser surface untouched (providers call show/list without
  projection), so the Playwright lab was not required for this change;
  the full HTTP/dialog suites ran green in Docker.
- Functional PASS `Files=26, Tests=1018`; coverage `100.0%` statement
  and subroutine on all three modules; `prove -T` PASS; `cover_db`
  cleaned.

## Latest Verification For `DD-425`

- CA15: empty-value omission on show, list, and export. Emptiness is
  undef, empty string, empty array, or a hash of only such values;
  booleans and numbers never count as empty.
- Pruning lives in the projection layer behind an explicit `omit_empty`
  argument — the CLI defaults it on for the three read commands and
  `--include-empty` restores the fixed-key shape; engine-internal and
  browser callers never pass it and are unaffected (full prior suite
  green unchanged).
- `--fields`-selected keys are exempt from pruning, so a selected empty
  field is returned as visible null.
- New suite `t/26-omit-empty.t` red-first; functional PASS
  `Files=27, Tests=1042`; coverage `100.0%` on all three modules;
  `prove -T` PASS; `cover_db` cleaned.

## Latest Verification For `DD-426`

- CA04: `--since` on show, list, and export with instant-based
  comparison (`Z`/`±HH:MM`/`±HHMM`; offsetless reads as UTC); export
  envelope gains `now` captured before the scan for gap-free chaining.
- Red-first `t/27-changed-since.t`: threshold inclusivity, offset
  equivalence (string order would exclude what instant order includes —
  pinned), future→empty exit 0, garbage→exit 2 naming the failure,
  `now` only with since, projection composition, show→`{}` when
  unchanged, corrupted `last_updated` never hidden, CLI guard exit 2 on
  mutations.
- Functional PASS `Files=28, Tests=1071`; coverage `100.0%` all three
  modules; `prove -T` PASS; `cover_db` cleaned.

## Latest Verification For `DD-427`

- CA05+CA06: stable per-record `content_hash` (canonical JSON minus
  `last_updated`, SHA-256) available via `--fields`; export `board_hash`
  computed from full records regardless of projection; `--if-changed`
  on show and export with unchanged marker + exit 1, payload + exit 0,
  malformed + exit 2; stricter-wins with `--since`; refused elsewhere.
- Red-first `t/28-content-hash.t` (26 checks): stability across reads
  and no-op writes; sensitivity to field edits, comments, and moves;
  board-hash agreement across quiet exports; conditional collapse and
  recovery; projection composition; CLI exit-status contract.
- Functional PASS full suite; coverage `100.0%` all three modules;
  `prove -T` PASS; `cover_db` cleaned. Browser surface untouched.

## Latest Verification For `DD-428`

- CA07+CA17: `--count` (list, export, search) and `--refs-only` (list,
  search); precedence count > refs-only > fields with loud field
  validation preserved; search handles both at envelope level so they
  never leak into its record_list delegation; human output prints a
  bare number / one ref per line.
- Red-first `t/29-count-refs.t` (25 checks) — one test correction
  during the loop: an unscoped field search legitimately matched the
  epic fixture, so the scenario pins `--type` explicitly.
- Functional PASS `Files=30, Tests=1123`; coverage `100.0%` all three
  modules; `prove -T` PASS; `cover_db` cleaned. Browser untouched.

## Latest Verification For `DD-429`

- CA08+CA09: `--brief` as a projection-preset shorthand (title cut at a
  documented 72 chars) and default 2000-char long-text truncation with
  ellipsis plus `_truncated`/`_length` markers on `description`,
  `problem_or_feature`, `solution_needed`, gate `details`, and evidence
  `summary`; `--truncate N`, `--truncate 0` omit-but-mark, `--full`
  restore; contradictions and negative limits exit 2.
- Truncation applies after hashing and projection — asserted by an
  unchanged `content_hash` under a 50-char cut.
- Red-first `t/30-brief-truncate.t` (32 checks); functional PASS
  `Files=31, Tests=1155`; coverage `100.0%` statement and subroutine on
  all three modules; `prove -T` PASS; `cover_db` cleaned. Browser
  untouched (engine flags are opt-in).

## Latest Verification For `DD-430`

- CA10-CA12: comment windows/meta/fields/since/count; record-level and
  board-wide `--meta-only`; enriched attachment metadata (filename,
  real size, content type, added time, sha, `total_size`), newest
  first; `attachment_count` computed record field; engine-owned
  content-type map with the CLI delegating.
- Red loop caught: two Perl block-vs-hashref parses (`+{`), and the
  fixture truth that `original_filename` already carries its extension
  (assembling would have produced `evidence.txt.txt`).
- Red-first `t/31-comment-attachment-meta.t` (43 checks after the
  coverage close: list-level `attachment_count` and the newest-first
  comparator needed a second attachment); functional PASS
  `Files=32, Tests=1198`; coverage `100.0%` all three modules;
  `prove -T` PASS; `cover_db` cleaned. Browser untouched.

## Latest Verification For `DD-431`

- CA16: repeatable ANDed `--where` on list and export — equality,
  empty-as-absence via the CA15 rule, inequality both ways,
  case-insensitive array containment safe on scalars, computed-field
  clauses, projection/count composition, loud unknown-field and
  operatorless failures.
- Red-first `t/32-where.t` (24 checks); functional PASS
  `Files=33, Tests=1222`; coverage `100.0%` all three modules;
  `prove -T` PASS; `cover_db` cleaned. Browser untouched.

## Latest Verification For `DD-432`

- CA19: `record_show_many` + CLI batch surface (`--ref` repeatable,
  `--refs` list, both composing). Keyed-by-ref `{records, order,
  count}`, explicit not-found markers with the rest preserved,
  cross-type batches, 100-ref documented ceiling, loud whole-call
  validation, projection composition, if-changed refusal naming the
  hash-sweep alternative, single-ref behavior byte-compatible.
- Red-first `t/33-batch.t` (25 checks after the coverage close: the
  single `--ref` + `--refs` composition branch needed its own
  scenario); functional PASS `Files=34, Tests=1247`; coverage `100.0%`
  all three modules;
  `prove -T` PASS; `cover_db` cleaned. Browser untouched.

## Latest Verification For `DD-433`

- CA13: `tira.diff` — since mode (kinds, current column/gate/title,
  new-comment ids, `now`) and snapshot mode (per-field before/after,
  named added comments, explicit changed markers for edits and
  structural fields, removals distinguished); one-baseline validation;
  field scoping (snapshot only); count mode; explicit empty results;
  new `cli/diff` entrypoint (t/03 count 83→84).
- Red-first `t/34-diff.t` (29 checks after the coverage close: an
  edited comment and a labels change exercise the changed-marker
  branches); functional PASS `Files=35, Tests=1276`; coverage `100.0%`
  all three modules; `prove -T` PASS; `cover_db` cleaned.

## Latest Verification For `DD-434`

- CA20: `_indexed_log_read` over both append-only logs — windows,
  read-by-id with loud misses, meta-only with text lengths and
  annotation counts, entry-level `--where` via the generalized clause
  parser, count/zero-window existence checks; annotations ride their
  entries; plain reads unchanged.
- Red-first `t/35-log-windows.t` (31 checks); functional PASS
  `Files=36, Tests=1307`; coverage `100.0%` all three modules;
  `prove -T` PASS; `cover_db` cleaned. Browser untouched.

## Latest Verification For `DD-435`

- CA14: `-o json` compact (canonical, stable keys, raw UTF-8, trailing
  newline), `-o json-pretty` preserving the indented shape;
  presentation-only proven by information-identity and a stable-bytes
  assertion; stdout/stderr separation pinned on failure paths.
- `t/00-foundation.t` format contract updated with the change itself —
  recorded as deliberate in the ticket.
- Red-first `t/36-compact-json.t` (17 checks); functional PASS
  `Files=37, Tests=1324`; coverage `100.0%` all three modules;
  `prove -T` PASS; `cover_db` cleaned. Dashboard /data shrinks too;
  dialog behavior unchanged (providers encode their own JSON).

## Latest Verification For `DD-436`

- CA18: per-call opt-in cache under `.tira/cache` — full-argument
  SHA-256 keys, ttl + hi-res board-fingerprint validity (any write
  invalidates immediately), visible stderr hits, atomic stores, corrupt
  fallback with warning, replayed exit statuses, `--no-cache` bypass,
  exit-2 misuse guards.
- Red loop caught: a zero ttl combined with a same-second entry hit the
  cache before validation — the lookup now engages only for ttl >= 1.
- Red-first `t/37-cache.t` (22 checks; the taint gate additionally
  caught a tainted readdir name in the corrupt-entry scenario, fixed
  with a regex untaint); functional PASS `Files=38, Tests=1347`;
  coverage `100.0%` all three modules; `prove -T` PASS; `cover_db`
  cleaned. Browser untouched.

## Latest Verification For `DD-437` (CA21)

- Linkage renders as table rows (ref chip, live title, status pill)
  sorted by priority desc via `/record` lookups with per-render
  caching; typed links keep their label in a compact `--typed` grid
  variant; every linkage mutation contract untouched (t/23 unchanged).
- Visual review caught two things the assertions did not: the typed-row
  ref chip stretching (grid fixed with the `--typed` variant) and the
  stale-fixture trap — a static `pw.html` bakes the old renderer, so
  fixtures must regenerate before any re-check.
- Guards: t/19 pins the table classes, `priorityRank`, and
  `data-linkage-row`; Playwright asserts row content, priority order,
  and the typed label, and the dialog-open detail count moved 1 → 4
  (main read + three linked lookups). Playwright ×3 green; functional
  PASS `Files=38, Tests=1352`; coverage `100.0%`; `prove -T` PASS;
  `cover_db` cleaned; screenshots reviewed.

## Latest Verification For `DD-438`

- Owner video (2969): linkage re-reading every cycle on an unchanged
  epic; editors evicted by in-flight refreshes. Loop record in the
  ticket; pre-fix reproduction failed exactly as predicted ("4 record
  reads in one quiet cycle").
- Fix: refresh compares the fetched record against the rendered
  snapshot (repaint only on real change) and re-checks the editing
  guard after the fetch. reloadCard stays the force path for user
  actions.
- Permanent guards: quiet-cycle fetch budget (≤2 reads/7s) + DOM node
  stability tag + delayed-response editor race in the Playwright mobile
  pass; t/19 pins `lastDialogRecordJson`, the identical-skip, and the
  post-fetch re-check. Playwright ×3 green; functional PASS
  `Files=38, Tests=1355`; coverage `100.0%`; `prove -T` PASS.

## Latest Verification For `DD-439`

- Default refresh interval 5s → 60s in both carriers (header badge and
  script fallback); override, validation, and clamp untouched.
- t/16 now pins `>Refresh 60s<` and the `:60` fallback so the two
  cannot drift apart. The Playwright mobile pass requests `?refresh=2`
  so DD-438's cycle guards still exercise a real cycle at test speed;
  the quiet-cycle budget is 4 reads across ~3 cycles (post-fix costs
  one comparison per cycle, pre-fix four).
- Playwright ×3 green; functional PASS `Files=38, Tests=1357`;
  coverage `100.0%` all three modules; `prove -T` PASS; `cover_db` and
  fixtures cleaned.

## Latest Verification For `DD-440`

- Owner photo (2976): >9 columns forced sideways scrolling. Shipped a
  Standard/Fit-all toggle in every board header, global across boards,
  persisted in `localStorage` (blocked storage → Standard), applied
  before `data-ready` so a remembered choice never flashes.
- Red-first Playwright guard failed as designed ("the board must start
  in standard width mode"), then covered: default state, fit removing
  min-widths and overflow, active-button marking, persistence across
  reload in both directions, and re-application on load.
- t/16 pins the toggle in all three board headers, the storage read /
  write / fallback, the fit CSS, and the narrow-screen revert.
- Visual review on a twelve-column board in both modes changed the fit
  typography (word-boundary wrapping and a smaller card title) before
  shipping. Playwright ×3 green; functional PASS
  `Files=38, Tests=1365`; coverage `100.0%`; `prove -T` PASS.

## Latest Verification For `DD-442`

- Measured first: the 2-second titled dashboard was pure-Perl JSON
  parsing (1992ms of a 2076ms call), not file I/O (2ms) or layout.
- Cpanel::JSON::XS selected at runtime with a JSON::PP fallback.
  Byte-identity for canonical, pretty, and non-reference encodings
  verified before adoption and now pinned by `t/38-json-backend.t`
  against whichever backend is installed — the guard that keeps stored
  records and content hashes stable.
- The existing suite caught the one real divergence (bare-scalar
  encoding); every value-bearing path now states `allow_nonref`
  explicitly while structural paths stay strict.
- After: titled dashboard 12ms, full export 19ms, field search 17ms on
  the same 138-record board. Functional PASS `Files=39, Tests=1387`;
  coverage `100.0%` all three modules; `prove -T` PASS; Playwright ×3
  green; `cover_db` and fixtures cleaned.

## Latest Verification For `DD-443`

- Per-field history journaled at the single write choke point and
  committed at the lock boundary. Red-first `t/39-history.t` (48
  checks): birth entries, before/after edits, validated and honest
  attribution, move journaling, structural-change markers, oldest-first
  ordering, windows, since, where, count, unknown-field refusal,
  truncation with `--full`, and — importantly — that a rolled-back
  multi-record operation records nothing.
- Proven non-invasive: no `history` field on records, `content_hash`
  unchanged by history reads, journal files not mistaken for records by
  the board scan.
- Building it surfaced DD-444: the `_replace_record` family mutates
  without the project lock despite the documented guarantee. History
  handles it correctly (self-flush when no lock frame is active); the
  locking gap is raised separately with evidence rather than absorbed.
- One existing assertion updated deliberately: the window-scope error
  message now names the history list too.
- Functional PASS `Files=40, Tests=1437`; coverage `100.0%` all three
  modules; `prove -T` PASS; `cover_db` cleaned.

## Latest Verification For `DD-441`

- Counts derived from the board DOM (hidden at zero) and a per-column
  add-card control on live boards only; new-card dialog mode with a
  `/create` route and provider through the ordinary engine path.
- Red evidence: the implementation predated its tests here, so the new
  contracts were verified by stashing `lib/` — `t/19` 6–12 and `t/16`'s
  count/add-card assertions failed, then passed once restored. Recorded
  in the ticket rather than glossed.
- Two fixture-truth corrections during the loop: Discard is excluded
  from rendered boards (4 badges, not 7), and the DD-437 detail-request
  assertion is now relative to the dialog open rather than cumulative,
  which is more robust regardless.
- Native form validation was suppressed so the dialog's own error host
  owns the message, matching every other failure in the UI.
- Playwright ×3 green (counts, no-title refusal, create payload, dialog
  switching to the created card); functional PASS `Files=40,
  Tests=1465`; coverage `100.0%`; `prove -T` PASS; visual review of
  counts and the new-card form.

## Latest Verification For `DD-445`

- Owner photo (2990): dropdown labels read `backlog46`, `in-review1`.
  Root cause: 0.54 put the count badge inside the header cell whose
  text DD-422 used for option labels. Values were unaffected, so moves
  always worked.
- Reproduced pre-fix at fixture scale (`["backlog2","in-progress1"]`),
  fixed by reading `.column__name`, re-run green ×3.
- Guard strengthened where it failed: the dialog scenario asserted
  option *values* only, which is why a visibly broken UI passed. It now
  asserts the visible labels carry no digits and pair with their own
  values; t/19 pins the `.column__name` lookup.
- Functional PASS `Files=40, Tests=1466`; coverage `100.0%`;
  `prove -T` PASS; fixtures and `cover_db` cleaned.

## Latest Verification For `DD-446`

- Investigation ran before any code: the 35-command manual sequence was
  verified end to end in a throwaway project, and the CLI mechanics,
  option-collision risks, and the non-re-entrant project lock were
  surveyed first. That is what shaped the design — plural option names
  so `--column`/`--prefix`/`--person`/`--label` keep their arity, and a
  sequence of locked calls with all validation done up front.
- Red-first `t/40-project-new.t`; full suite `Files=41, Tests=1523`;
  coverage `100.0%` statement and subroutine on all three modules;
  `prove -T` PASS; `cover_db` cleaned.
- Adversarial review (23 agents, each finding re-run by an independent
  refuter) caught two high-severity defects that the suite did not:
  colliding board prefixes producing permanently unreadable duplicate
  references, and silent adoption of a different existing project.
  Both are fixed with up-front validation and now have permanent tests,
  as do the over-long column slug and the silently-ignored empty prefix.
- Platform gate: no platform-dependent behaviour — the command is
  filesystem and CLI logic already covered by the Docker suite, with no
  browser surface, so the QEMU labs were not required and were not
  started.

## Latest Verification For `DD-448`

- `tira.onboard` guided setup with the prompt stream injected, so the
  whole flow is exercised without a terminal. Red-first
  `t/41-project-wizard.t`: full run, per-board column sets, re-asks on a
  bad prefix and an unclear yes/no, flags as defaults (including every
  members and columns flag), declining exits 1 with nothing created,
  and abandonment at each of the eight question points aborts with
  nothing created.
- The property that matters most is pinned separately: a bare
  `project.new` exits 2 rather than ever waiting for input.
- Functional PASS `Files=42, Tests=1568`; coverage `100.0%` statement
  and subroutine on all three modules; `prove -T` PASS; `cover_db`
  cleaned. No browser surface, so the Playwright lab was not required;
  no platform-dependent behaviour, so the QEMU labs were not started.

## Latest Verification For `DD-449`

- Remembered dashboard address in `project.yml`, set through
  `project.update`, reported by `project.show`, consumed by
  `-o browser`. Red-first `t/42-dashboard-address.t`: persistence,
  `any` mapping to every interface, partial updates leaving the other
  value alone, refusals for an unsupported host and zero/oversized/
  non-numeric ports with the stored value untouched, the documented
  precedence (command line beats remembered beats default), and a
  project that never set one still serving `0.0.0.0:7899`.
- Functional PASS `Files=43, Tests=1591`; coverage `100.0%` statement
  and subroutine on all three modules; `prove -T` PASS; `cover_db`
  cleaned. Serving is exercised through the injected browser server, so
  no port is bound by the suite.

## Latest Verification For `DD-450`

- Tilde expansion proven where the owner hit it: the guided directory
  answer `~/under-home` creates the project under the home directory
  and nothing named `~` appears. Unit cases cover a bare `~`, absolute
  and relative paths left alone, `~user` deliberately not guessed at,
  and an empty HOME leaving the text as typed.
- Line editing driven through a REAL pseudo-terminal (`IO::Tty`, test
  dependency only — the shipped skill gains no dependency), so raw
  mode, every key, and the restore path execute for real instead of
  being excluded from coverage: Ctrl-A, Ctrl-E, Ctrl-U, Ctrl-K,
  backspace at and away from the start, arrows with both bounds, Home,
  End, unknown escape sequences ignored, non-printing input ignored,
  Ctrl-C, Ctrl-D, and end of input.
- Two defects surfaced by these tests and fixed: enter past the people
  question errored instead of meaning "none", and the first harness let
  the tty driver pre-process keystrokes so the editor was not actually
  under test. Both recorded in the ticket.
- Functional PASS `Files=44, Tests=1638`; coverage `100.0%` statement
  and subroutine on all three modules with no exclusions; `prove -T`
  PASS; `cover_db` cleaned.

## Latest Verification For `DD-451`

- Owner photo (3005): cards overlapping the next column on the
  nine-column MT5 board. Root-caused to `table-layout: fixed` taking
  column widths from the header row, where only a `min-width` was set.
- Measured before and after on a rebuilt nine-column, 102-card board:
  header widths `[134 × 9]` before, `[272 × 9]` after in Standard, and
  `[122 × 9]` in Fit, with zero card spill in either mode.
- New guard `t/playwright/wide-board.js`, verified to FAIL against the
  pre-fix stylesheet (`standard columns must keep their full width, got
  [134,...]`), green ×3 after.
- Main browser gate: 6 of 7 runs green. One run timed out on a
  `waitForFunction`; it did not reproduce across four consecutive runs
  afterwards and the change is stylesheet-only, but it is recorded here
  rather than dismissed, since this suite has timing-dependent waits.
- Functional PASS `Files=44, Tests=1638`; coverage `100.0%` statement
  and subroutine on all three modules; `prove -T` PASS; `cover_db` and
  fixtures cleaned.

## Latest Verification For `DD-452`

- Owner photo (3007): cards still overlapping after 0.60. Checked the
  obvious explanation first and rejected it — the installed copy was
  0.60 (written 01:32) and his dashboard process started at 05:26, so
  he was running the fix. The remaining defect was a different one.
- Root cause: grid items default to `min-width: auto` and will not
  shrink below their content. DD-451 fixed the columns; the cards
  themselves still had a floor, so in Fit mode past about ten columns
  they drew over their neighbours. `overflow-wrap: break-word` cannot
  help here, since it does not change minimum content size.
- Measured at thirteen columns, 1280px, Fit: 81px cells holding 96px
  cards, 21px spill before; no spill after, with Standard still 272px.
- Guard: `wide-board.js` now also runs the thirteen-column fixture and
  fails against the pre-fix stylesheet (`cards spilled in fit mode by
  [14…]px`), green ×3 after.
- Functional PASS `Files=44, Tests=1638`; coverage `100.0%` all three
  modules; `prove -T` PASS; fixtures and `cover_db` cleaned.

## Latest Verification For `DD-454`

- Title contract pinned in `t/16-dashboard-table.t`: a combined
  dashboard reads `Table project :: Kanban :: 3`, a type-scoped one
  reads `Table project :: Tickets :: 1`, and the old generic title is
  asserted gone.
- Checked against a realistic board before shipping: `MT5 :: Tickets ::
  57` for the ticket board and `MT5 :: Kanban :: 57` for all three,
  confirming the count follows what is rendered rather than what is
  stored.
- Functional PASS `Files=44, Tests=1641`; coverage `100.0%` all three
  modules; `prove -T` PASS; fixtures and `cover_db` cleaned.

## Latest Verification For `DD-455`

- Browser guard added to the main pass: shift-click selects two cards
  without opening the dialog, shift-click again deselects, dragging a
  selected card posts two `/move` requests carrying both refs, the
  ghost reads "2 cards", the selection clears after the batch, and a
  plain click clears the selection and opens that card.
- Red check: against the previous renderer the guard does not pass —
  the first shift-click opens the dialog, which then intercepts the
  next click and the run fails. The failure is a timeout rather than a
  crisp assertion, which is recorded here rather than dressed up.
- Fit-mode margins reviewed visually on a thirteen-column board:
  columns 81px before, 86px after, board running edge to edge, no card
  spill in either mode.
- Functional PASS `Files=44, Tests=1641`; coverage `100.0%` all three
  modules; `prove -T` PASS; `wide-board.js` green; main browser guard
  green ×3; fixtures and `cover_db` cleaned.

## Latest Verification For `DD-456`

- Paging guarded end to end in `wide-board.js` on a 26-card column: ten
  visible at first, the button reading "Show N more of M", a column
  with nothing hidden showing no button, pressing it revealing ten
  more, and the count badge still reporting the column total.
- Filter guarded in the main pass: the request reaches the server, only
  matching cards remain visible, and clearing restores the board.
  Recorded honestly — that guard drives the function the input is bound
  to rather than the keystroke, because synthetic key events did not
  fire the debounce reliably in this harness; a renderer assertion pins
  the box being wired to that function.
- Provider and route covered in `t/19`: refs-only results, an empty
  query returning nothing rather than everything, a missing query
  handled the same way, and the URL-decoded text and type reaching the
  provider.
- One drag flake appeared during the run ("drag move request missing")
  and did not recur across five consecutive runs after the batch path
  was hardened to fall back to the dragged card when no selection list
  is present.
- Functional PASS `Files=44, Tests=1654`; coverage `100.0%` all three
  modules; `prove -T` PASS; fixtures and `cover_db` cleaned.

## Latest Verification For `DD-458`

- Red-first `t/44-dwell.t` (26 checks) with the clock fixed so dwell is
  arithmetic rather than a race: measurement from the latest move, a
  twice-moved card measuring from its most recent move, a never-moved
  card reported as `basis: none` with no duration, a renamed column
  leaving the measurement intact, an unreadable stamp degrading to
  `unknown` without taking the board down, `--older-than` excluding
  unmeasured cards, all three boards in one call and a single board on
  request, plus the CLI surface and its exit-2 on a non-numeric age.
- The taint gate caught a tainted `glob` path in the new test before
  release; untainted explicitly, as in `t/27`.
- Functional PASS `Files=45, Tests=1682`; coverage `100.0%` statement
  and subroutine on all three modules; `prove -T` PASS; `cover_db`
  cleaned. No browser surface in this ticket.
