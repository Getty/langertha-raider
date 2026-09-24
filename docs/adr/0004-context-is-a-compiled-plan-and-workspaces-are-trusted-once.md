# ADR 0004 — Context is a compiled plan; workspaces are trusted once

- Status: accepted
- Date: 2026-09-24
- Tags: context, instructions, trust

## Context

Today the mission is a concatenated string: a hard-coded persona, `.raider.md`, loaded
skills and active packs. `CLAUDE.md` / `AGENTS.md` are opt-in per flag (`--claude`,
`--codex`/`--openai`), root level only. The maintainer wants project instructions to apply
automatically and home context not to bleed into projects (and vice versa).

## Decision

- **Every model call gets a `ContextPlan`**: a list of context items, each with source,
  scope, trust level, confidentiality and token share, plus the reason it was included,
  cut or excluded. No global "mission" blob that contains everything.
- Selection order: filter by scope and permission **first**, then rank by relevance, then
  apply the token budget. High similarity in recall never compensates for missing access.
  Pinned constraints and the current task are never silently dropped — if they don't fit,
  the run fails with an explained budget error.
- `raider context explain` shows the plan without calling a model or running tools.
- **Discovery ≠ trust ≠ activation.** On the first run in an unknown workspace Raider lists
  the instruction sources it found (`CLAUDE.md`, `AGENTS.md`, `.raider/…`) and asks once.
  After that, they load automatically. Headless without a stored decision: they are read as
  data, not as instructions. Executable extensions (MCP starts, hooks, capability requests)
  always need their own decision.
- Parent walk stops at the registered workspace root; nested instruction files apply only to
  their subtree.
- Home is a source, not a global prompt block: only explicitly portable preferences (e.g.
  language, answer format) flow into projects; project knowledge never silently becomes a
  global preference.

## Consequences

- The `--claude` / `--codex` / `--openai` flags keep their current meaning until the
  migration replaces them; they are never silently reinterpreted as delegation (ADR 0006).
- Changes §1.3 of the original vision ("apply as soon as Raider sees them") to "apply after
  a one-time trust decision per workspace".

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (4, 5), §4.
