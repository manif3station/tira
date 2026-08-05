# Tira Foundation

## Architecture

Tira is a local filesystem database. `Tira.pm` owns context resolution, validation,
locking, atomic persistence, record allocation, and output encoding.
`Tira::CLI` owns shared option parsing and structured errors. Thin executable
files under nested `skills/<entity>/cli/` expose dotted Developer Dashboard
commands.

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

## Output and errors

Default and `-o toon` output is produced by `Data::TOON` 0.03. `-o json` uses
canonical pretty JSON. `-o human` emits Markdown. Errors use the selected
structured format on stderr and exit with status 2. `tira.skills` prints raw
Markdown because its content, rather than metadata about the content, is the
requested result.

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
