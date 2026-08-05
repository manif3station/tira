# EPIC-387: Build Tira As A Filesystem-Native Kanban Skill

## Goal

Replace the incomplete prototype with a coherent Developer Dashboard skill that
offers a virtual Kanban experience using ordinary folders, YAML configuration,
and JSON records.

## Delivered slices

1. Governed repository, schemas, project discovery, project creation, entity
   creation, and output formatting.
2. Configurable board columns, record movement, Discard behavior, and views.
3. Hierarchy, sub-item, typed cross-record links, unlinking, and cloning.
4. Project people, assignments, Markdown comments, evidence, and gate logs.
5. SHA-256 attachment storage, retrieval, tombstones, restoration, and comment
   attachments.
6. Comprehensive searching, filtering, validation, repair, and installed-path
   acceptance verification.

DD-388 established the governed foundation. DD-389 delivered slices 2 through
6 as one complete command-contract release: all 100 documented use cases, 70
Developer Dashboard entrypoints, rollback-safe multi-file operations, 100%
coverage, taint security, installed-dispatch proof, and macOS verification.

## Release standard

Each slice is independently tested, documented, committed, and pushed. The epic
closes only when the complete CLI documented in `SKILLS.md` is proven.

Status: implementation complete; release remains open until the mandatory Git
push succeeds.
