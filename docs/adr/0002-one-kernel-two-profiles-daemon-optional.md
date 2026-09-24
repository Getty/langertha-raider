# ADR 0002 — One kernel, two profiles; the daemon is optional

- Status: accepted
- Date: 2026-09-24
- Tags: architecture, profiles, hall

## Context

Raider has to be two things (see `CONTEXT.md`): a personal **assistant** living in the home
directory, reachable from anywhere (CLI, Telegram, cron), remembering the user — and a
**project agent** working inside a repository and respecting that project's context, the
way Claude Code does. These goals pull in different directions. Today the Hall is a daemon
that spawns one-shot `raider` subprocesses, and "session" effectively means "process".

## Decision

- There is **one runtime kernel**. `assistant` and `project` are **profiles** of it: they
  differ in scope, memory access, active tools and default policies — not in code paths.
- A profile is **not a security boundary**. Limits are enforced by the runtime (ADR 0005),
  not by which profile was chosen.
- **The daemon is optional.** One-shot and REPL run the kernel embedded in the process. The
  Hall runs the same kernel for long-lived reachability and job supervision; it is never a
  prerequisite for local CLI use.
- Surfaces (CLI/REPL, Hall, Telegram, Cron, ACP, a later web UI) are thin adapters onto the
  same application service; none of them owns its own tool loop, config precedence or
  permission logic.
- No new generic HTTP model service in Raider — `langertha-knarr` already is that
  (including `Handler::Raider`).

## Consequences

- The Hall stops handing every spawned raider the hall root as shared context; it binds
  sessions (ADR 0003) instead.
- Code that today lives in `bin/raider` or `Raider::CLI` and decides behaviour moves into the
  shared service so every surface gets it.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (1, 2), §3, §10.
