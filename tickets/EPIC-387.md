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
DD-390 adds singular ownership, planning and release metadata, generated
immediate parents, and inactive-person lifecycle behavior.
DD-391 removes attachment storage-path output while retaining raw retrieval.
DD-392 hardens Unicode comments, persistence, output, and legacy recovery.
DD-393 documents the measured agent-context advantage of Tira's direct
filesystem Jira mirror.
DD-394 adds ordered item/status checklists to every work-record type.
DD-395 prevents silent data loss by making every accumulating update append.
DD-396 makes attachment deduplication responses report retained filename truth.
DD-397 adds migration-scale reads, previewed bulk corrections, and append-only
log annotations.
DD-398 standardizes search output and adds safe multi-field migration scopes.
DD-399 makes hierarchy reads retain the complete underlying record truth.
DD-400 makes dashboard cost scale with boards and records instead of columns.
DD-401 accepts Developer Dashboard path aliases as private project selectors.
DD-402 adds a metadata-free, modification-time-ordered dashboard fast path.
DD-403 adds self-contained browser-rendered Kanban table output.
DD-404 adds query-controlled automatic refresh to HTML dashboards.
DD-405 serves that HTML through a bounded Dancer2 PSGI listener.

## Release standard

Each slice is independently tested, documented, committed, and pushed. The epic
closes only when the complete CLI documented in `SKILLS.md` is proven.

Status: in progress through DD-405.
