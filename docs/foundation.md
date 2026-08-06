# Tira Foundation

## Architecture

Tira is a local filesystem database. `Tira.pm` owns context resolution, validation,
locking, atomic persistence, record allocation, and output encoding.
`Tira::CLI` owns shared option parsing and structured errors. Thin executable
files under nested `skills/<entity>/cli/` expose dotted Developer Dashboard
commands.

There is no HTTP service or transport layer: commands read and atomically
update the managed YAML, JSON, attachment, and column-folder structures
directly. This preserves Jira-style work organization without carrying Jira's
ADF and repeated per-comment author metadata through an agent's context.

Measured migration examples found Jira payloads about 3.3 times larger on
average. ZEPG-1 required two Jira requests totalling 1.04 MB, while one Tira
record read including comments was 301 KB. A comment-free ZSD-1 was only 1.29
times larger in Jira, indicating that repeated comment-author metadata is a
major source of the widening payload gap.

Developer Dashboard resolves, for example,
`dashboard tira.ticket.create` to `skills/ticket/cli/create`. The wrapper loads
the root Tira library through a validated path and delegates all behavior.

## Project creation

`tira.project.create` creates private managed project metadata, an attachment
store, and independent SOW, epic, and ticket boards. Each board begins with:

```yaml
prefix: TKT
digits: 3
next_number: 1
columns:
  - name: backlog
    label: Backlog
    protected: true
  - name: discard
    label: Discard
    protected: true
```

Prefixes differ by entity: `SOW`, `EPC`, and `TKT`.

## Record creation

Only `title` is required. Creation takes the private project lock, validates the YAML
counter fields, allocates an immutable reference, atomically writes canonical
pretty JSON into Backlog, then advances `next_number`. If counter persistence
fails, Tira removes the new record so the operation does not leave half-written
state.

New entities contain the complete agreed work-record shape. Their hierarchy,
sub-item, and typed-link collections are empty, so they remain free-ranging
until explicit link commands are used. Project-location selection is private
and deliberately omitted from agent-facing commands and documentation.

Release 0.03 adds the same planning fields to every record type: singular
assignee, optional reporter, case-insensitive labels, zoned start/due
date-times, free-text SDLC gate and lifecycle, priority 1-5, fix version, and
affected versions. The `parent` field is generated from immediate linkage. A
same-type parent takes precedence over the broader SOW/epic hierarchy.

Project people carry an `active` flag. Deactivation blocks new assignee and
reporter references without rewriting historical records; activation restores
eligibility. Historical person references prevent removal.

Release 0.06 adds an ordered `checklist` array to every record. Each entry has
an immutable `CHK-NNN` ID, an item, a user-controlled status, and creation and
last-update timestamps. Tira does not interpret checklist status as workflow
state; users decide what each value means and update it explicitly.

Release 0.07 makes accumulating record updates loss-safe. Content-array and
included/excluded scope arguments append in order, matching labels and the
agent contract. Only an explicit `--set-*` JSON-array option replaces a full
content array.

Release 0.08 separates stored attachment-reference truth from request metadata.
Deduplication is evaluated against the target record or comment list. The add
response returns that list's retained `original_filename`, the caller's
`supplied_filename`, and a Boolean `deduped`; these response-only fields are
not written into the attachment reference.

Release 0.09 adds migration-scale operations without introducing an index,
service, watcher, changelog, or general log mutation. Export and field-aware
search still scan the filesystem. Bulk import validates all requested records
before an atomic multi-file transaction; replace is restricted to mutable text
content and supports dry-run diffs. Gate and evidence corrections append
annotations to stable entry IDs, preserving original observations.

Release 0.10 makes field scope an ordered list at the CLI and engine boundary.
Search always returns `{hits, count}`; repeated fields accumulate for both
search and replacement, and scoped replacement never visits unnamed fields.

Release 0.11 makes hierarchy nodes complete record projections with an added
`children` array. This keeps hierarchy and direct record reads consistent,
while unresolved references retain the structured exit-2 failure contract.

Release 0.12 reads each selected dashboard board once and groups the returned
records into configured columns in memory. Runtime filesystem work therefore
scales with selected boards and records rather than visible column count.

Release 0.13 allows private project selection through Developer Dashboard path
aliases. Tira delegates alias semantics to DD's installed registry/config
classes, gives real filesystem paths precedence, and keeps resolved targets out
of alias-facing command output and errors.

Release 0.14 makes the default dashboard a directory/stat projection: valid
JSON filenames supply refs and file mtimes supply newest-first ordering, with
ref tie-breaking. `--title` reads each record once; JSON output reads full
records while retaining the same filesystem order.

Release 0.15 adds a self-contained HTML projection for the combined dashboard
and three type-specific entrypoints. CSS and JavaScript are embedded, dynamic
values are escaped, no network resources are loaded, and card mtimes are
included only as HTML data needed for local mtime/ref sorting.

Release 0.16 adds a visible, query-controlled refresh timer to that document.
It also adds a minimal Dancer2 PSGI projection: browser mode accepts only
explicit local bind names and valid TCP ports. Its data route returns the
lightweight card placement dashboard, and embedded JavaScript moves cards
between columns without reloading the document. Drag/drop calls the actual
record move, physically moving the JSON file between column folders. Card
clicks make one detail request and render the record in a Jira-style
sectioned dialog; update, comment, and people routes apply validated engine
mutations and answer failures as structured 422 JSON, and a last-updated
indicator advances only after successful data application. The default
listener is `0.0.0.0:7899`.

## Output and errors

Default and `-o toon` output is produced by `Data::TOON` 0.03. `-o json` uses
canonical pretty JSON. `-o human` emits Markdown. Errors use the selected
structured format on stderr and exit with status 2. `tira.skills` prints raw
Markdown because its content, rather than metadata about the content, is the
requested result.

## UTF-8 boundary

Tira decodes command-line and text-file input as strict UTF-8 character data,
then encodes JSON, YAML, TOON, JSON output, and Markdown output as UTF-8 bytes.
Attachments bypass text encoding and remain raw. The record reader accepts
canonical UTF-8 first; if an older record contains an isolated byte written by
the former mixed string boundary, it maps that byte to its intended Unicode
code point and rewrites canonical UTF-8 on the next mutation.

## Concurrent editing

Every mutation serializes under the private project lock and lands through an
atomic same-directory rename, so simultaneous saves — even in the same second
— can never corrupt or interleave a record file. Field updates are
read-modify-write of a single field inside that lock, so two people editing
*different* fields of one card both survive in either order. For the remaining
case — two people editing the *same* field — `record_update` accepts an
`expect` map of scalar field bases and refuses the write with a
`Conflict: <field> changed while you were editing` error when the stored value
no longer matches; the dashboard sends each editor's opening value as its base,
surfaces the conflict, and reloads the fresh card instead of silently
overwriting.

## Security properties

Tira invokes no shell or external process. It validates and untaints canonical
filesystem paths before mutation, constrains prefixes and numeric widths before
they influence filenames, uses project locking, writes through same-directory
temporary files, and atomically renames completed data. The full suite and
every shipped Perl entrypoint pass under taint mode.

## Agent command contract

`SKILLS.md` is the normative technical interface for agents. It now documents
global grammar, option precedence, output and exit behavior, atomicity rules,
every command family with its full argument signature, and exactly 100 numbered
implemented use cases. It deliberately leaves project location opaque.
`dashboard tira.skills` returns that contract verbatim.
