# Tira Statement of Work

## Objective

Build Tira as a filesystem-native, Jira-style Kanban system exposed through
Developer Dashboard commands. Tira must support projects, SOWs, epics, tickets,
configurable columns, bidirectional hierarchy and typed links, people,
Markdown comments, attachments, cloning, and agent-efficient output.

## Product contract

- Store the complete project database beneath the project's `.tira/` folder.
- Treat column folders as board state and JSON files as records; do not add an
  index or registry over the filesystem.
- Keep SOW, epic, and ticket boards independent while linking records in both
  directions.
- Never delete work records; move them to the protected Discard column.
- Allocate immutable references from monotonically increasing YAML counters.
- Store attachments once by SHA-256 while retaining original names in records.
- Print TOON by default, pretty JSON with `-o json`, and Markdown with
  `-o human`.
- Keep comprehensive agent instructions in `SKILLS.md`, repository guidance in
  `README.md`, and implementation reference in Perl POD.

## Delivery model

Deliver the system incrementally through documented TDD, BDD, and ATDD tickets.
Every ticket must pass the Docker test and 100% statement/subroutine coverage
gates before documentation, commit, and push.
