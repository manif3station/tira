# Tira

Tira is a filesystem-native Kanban project manager for Developer Dashboard. It
provides Jira-style projects, SOWs, epics, and tickets while keeping the complete
database visible beneath each project's `.tira/` folder.

The first governed release establishes project discovery, independent SOW,
epic, and ticket boards, protected Backlog and Discard columns, immutable
increasing references, and agent-efficient TOON output.

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

Create free-ranging records now and link them in later Tira releases:

```bash
dashboard tira.sow.create --project ./delivery --title "Ship v1"
dashboard tira.epic.create --project ./delivery --title "Authentication"
dashboard tira.ticket.create --project ./delivery --title "Implement login"
```

Commands discover `.tira/project.yml` by walking upward from the current
directory. Set `TIRA_HOME` to a project root to omit `--project` from commands
run elsewhere. An explicit `--project` takes precedence over `TIRA_HOME`.

```bash
export TIRA_HOME=~/projects/delivery
dashboard tira.ticket.create --title "Implement login"
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

The manual is also the technical roadmap for the complete Tira CLI. Every
command signature, argument interaction, project-selection rule, output and
exit contract, transaction invariant, and 100 numbered use cases are recorded
there. Availability labels distinguish commands shipped in `0.01` from
specified commands that agents must not invoke yet.

## Filesystem model

Every project owns `.tira/project.yml`, project-level attachments, and separate
`sow/`, `epic/`, and `ticket/` boards. Each board stores its ordered columns,
prefix, digit width, and next immutable number in `config.yml`. Backlog and
Discard are always present and protected.

See [the foundation guide](docs/foundation.md) and [SKILLS.md](SKILLS.md) for
the complete implemented contract and planned Tira ecosystem.

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
