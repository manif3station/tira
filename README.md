# Tira

Tira is a filesystem-native Kanban project manager for Developer Dashboard. It
provides Jira-style projects, SOWs, epics, and tickets over a transparent local
filesystem engine accessed exclusively through Tira commands.

Release 0.02 implements the complete command ecosystem: projects, independent
boards, columns, records, links, people, comments, attachments, evidence,
gates, search, dashboards, and agent-efficient TOON output.

## Value

Tira gives people and AI agents a shared project-management model without a
server or opaque database. Folders represent Kanban columns, JSON files
represent work records, and YAML files hold project and board configuration.

## Installation

```bash
dashboard skills install tira
```

## Commands

Create a project:

```bash
dashboard tira.project.create --name "Delivery" --dir ./delivery
```

Create free-ranging records and link them later:

```bash
dashboard tira.sow.create --title "Ship v1"
dashboard tira.epic.create --title "Authentication"
dashboard tira.ticket.create --title "Implement login"
```

Operate the board, relationships, and collaboration data:

```bash
dashboard tira.column.add --type ticket --name in-progress --after backlog
dashboard tira.hierarchy.link --parent SOW-001 --child EPC-001
dashboard tira.link.add --from TKT-001 --type blocks --to TKT-002
dashboard tira.comment.add --ref TKT-001 --author ada --text "Ready for review"
dashboard tira.dashboard --type all -o human
```

## Output

TOON is the default and is also selected explicitly with `-o toon`.
`-o json` returns canonical pretty JSON. `-o human` returns Markdown:

```bash
dashboard tira.ticket.create --title "Add tests" -o json
dashboard tira.epic.create --title "Release gate" -o human
```

Print the complete agent manual as raw Markdown:

```bash
dashboard tira.skills
```

The manual is the complete technical contract. It records every command
signature, argument interaction, output and exit contract, transaction
invariant, and 100 implemented use cases while intentionally keeping managed
project location opaque.

## Managed-storage model

Tira owns a local filesystem-backed database, but its location is intentionally
not part of the agent interface. Backlog and Discard are always present and
protected. Use the CLI for every read and mutation; manual managed-file editing
is unsupported.

See [the foundation guide](docs/foundation.md) and [SKILLS.md](SKILLS.md) for
the complete implemented Tira ecosystem.

## Verification

Run tests only through the workspace Docker environment:

```bash
docker compose -f ~/projects/skills/docker-compose.testing.yml run --rm perl-test \
  bash -lc 'cd /workspace/skills/tira && cpanm --quiet --notest --installdeps . && prove -lr t'
```

The release gate requires 100% statement and subroutine coverage plus the
post-coverage `perlsec` and taint-mode audit recorded in `tickets/TESTING.md`.

## License

Tira is released under the MIT License. See [LICENSE](LICENSE).
