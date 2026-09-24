# ADR 0003 — Sessions are JSONL files stored next to their scope; one writer per session

- Status: accepted
- Date: 2026-09-24
- Tags: sessions, persistence, concurrency

## Context

Today a session is a process: when it ends, the conversation is gone. Hall raiders are
one-shot subprocesses with no memory between missions. Resuming, cancelling, Hall, cron and
multiple clients all need a session that outlives a process. The handoff proposed a central
SQLite store under `$XDG_STATE_HOME`; the maintainer prefers something that moves with the
project.

## Decision

- **A session is data, not a PID.** It is an append-only JSONL file of events (requests,
  model turns, tool invocations with status, results).
- **Storage follows the scope:**
  - project sessions → `<project>/.raider/sessions/<id>.jsonl` — they travel with the
    project when it is moved or copied;
  - assistant/home sessions → `~/.raider/sessions/<id>.jsonl`.
  (This deliberately differs from Claude Code, which keeps project sessions centrally under
  `~/.claude/projects/<path-slug>/`.)
- Sessions can contain tool output and secrets, so they are **never committed by default**:
  when Raider creates `.raider/`, it also writes `.raider/.gitignore` excluding `sessions/`.
  `.raider/lib` (the local::lib target of the Perl tools) is a sibling, not a conflict.
- **One active writer per session.** New input is queued; parallelism happens between
  sessions or in explicitly isolated tasks. Two sessions writing the same workspace need a
  workspace write lock or separate worktrees.
- Tool invocations are recorded with an explicit status
  (`planned → authorized → dispatched → succeeded | failed | cancelled | unknown`). Replaying
  a journal never re-executes external side effects; `unknown` is surfaced, never blindly
  retried.
- ADR 0007 (langertha) stays: the journal is the never-compressed `session_history`; the
  working `history` is a budgeted projection of it.

## Consequences

- Event schema, file locking and index/search over JSONL are follow-up design work
  (tickets), not decided here.
- A central SQLite store is not planned; if search over many sessions needs an index, it is
  a cache derived from the JSONL files, not a second source of truth.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (3, 7), §6, §7.3; storage location changed by
the maintainer.
