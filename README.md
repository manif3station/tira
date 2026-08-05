# Tira

Tira is a filesystem-native Kanban project manager for Developer Dashboard. It
provides Jira-style projects, SOWs, epics, and tickets over a transparent local
filesystem engine accessed exclusively through Tira commands.

Release 0.06 implements the complete command ecosystem: projects, independent
boards, columns, records, links, people, comments, attachments, evidence,
gates, search, dashboards, agent-efficient TOON output, singular record
ownership, planning metadata, immediate parents, and inactive-person controls.
Attachment retrieval streams content without exposing its managed location.
Text is strict UTF-8 end to end, including long comments and currency symbols;
legacy isolated-byte records are repaired when next updated.
Every SOW, epic, and ticket also has an ordered checklist of item/status pairs.

## Value

Tira gives people and AI agents a shared project-management model without a
server or opaque database. Folders represent Kanban columns, JSON files
represent work records, and YAML files hold project and board configuration.

### Why mirror Jira locally?

Tira keeps Jira's familiar project, epic, ticket, and Kanban concepts while
removing payload overhead that quickly consumes an LLM agent's context and
usage allowance. In measured migration examples, Jira responses averaged
about 3.3 times the size of equivalent Tira records, with the gap increasing
on comment-heavy work:

- Jira ADF expands each paragraph into a nested `type`/`content` tree.
- Every Jira comment repeats its author's account, timezone, and avatar block,
  including five image URLs.
- Jira needs separate issue and comment requests; one Tira `show` includes the
  record and its comments.

For example, ZEPG-1 occupied 1.04 MB across two Jira requests and 301 KB in one
Tira read. ZSD-1 was only 1.29 times larger in Jira because it had no comments,
supporting the conclusion that repeated author metadata drives much of the
growth. A heavy ticket can therefore use roughly one-third of an agent's
context with Tira, in one operation instead of two.

Tira deliberately has no HTTP transaction layer. Commands operate directly on
validated local files and column folders, keeping the system simple,
inspectable, and efficient.

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
dashboard tira.checklist.add --ref TKT-001 --item "Run regression" --status "To Do"
dashboard tira.checklist.update --ref TKT-001 --id CHK-001 --status Done
dashboard tira.project.people.deactivate --id ada
dashboard tira.dashboard --type all -o human
```

SOWs, epics, and tickets share planning metadata. For example:

```bash
dashboard tira.ticket.create --title "Security review" --assignee ada \
  --reporter grace --label Security --priority 5 \
  --start-date 2026-08-06T09:00:00Z \
  --due-date 2026-08-08T17:00:00+01:00 --fix-version 3.0.0
```

Assignee and reporter values are person IDs in JSON and names in human output.
Inactive people remain visible on historical work but cannot receive new
ownership.

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
