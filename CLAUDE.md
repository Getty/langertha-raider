# Langertha::Raider — CLAUDE.md

## Status: pre-migration bootstrap

This distribution does not contain code yet. It is the target for extracting
`Langertha::Raider` (the autonomous-agent engine, currently living in `langertha`
core) and the `App::Raider` CLI/Hall/ACP app (currently the standalone `raider`
repo) into one sibling distribution — the same pattern as `langertha-knarr` and
`langertha-skeid` (sibling dist, `requires 'Langertha'`, never the other way
round). Full decision record and migration plan: `TODO.md`.

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
