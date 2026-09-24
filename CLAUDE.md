# Langertha::Raider — CLAUDE.md

## Status: assembled, pre-redesign

The extraction is done: this dist ships the `Langertha::Raider` engine (from `langertha`
core) plus the former `App::Raider` CLI/Hall/ACP app as `Langertha::Raider::*`
(`App::Raider` → `Langertha::Raider::CLI`; the six old `App::Raider*` names ship as
reserved stubs). Sibling-dist pattern like `langertha-knarr` / `langertha-skeid`
(`requires 'Langertha'`, never the other way round). Repo: github.com/Getty/langertha-raider.

The code works but is structurally messy; a redesign is pending. **Current state, vision
and open questions: `STATE-AND-VISION.md`** — read it before any non-trivial change.
Keep changes minimal until the redesign plan exists. History: `TODO.md`,
`MIGRATION-FROM-LANGERTHA.md`.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle and lane are in `.claude/rules/raider-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `raider-worker` (default) |
| Write/extend tests | `raider-test-writer` |
| Pre-release audit | `raider-release-checker` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`.
