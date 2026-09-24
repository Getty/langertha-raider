# ADR 0001 — Sibling distribution, naming, and reserved CPAN stubs

- Status: accepted
- Date: 2026-09-24
- Tags: distribution, naming, cpan, dependencies

## Context

`Langertha::Raider` (the agent engine) lived in `langertha` core; the CLI/Hall/ACP app lived
in a separate dist `App-Raider` (github.com/Getty/raider). Core carried a runtime dependency
(`Net::Async::MCP`) only because of Raider. langertha ADR 0026 decided to extract Raider into
a sibling distribution following the `langertha-knarr` / `langertha-skeid` pattern.

## Decision

- Dist `Langertha-Raider`, repo github.com/Getty/langertha-raider (old `Getty/raider` is
  archived). `main_module` is `Langertha::Raider` — the engine class.
- `App::Raider` → `Langertha::Raider::CLI`; `App::Raider::X` → `Langertha::Raider::X`.
  Binaries `raider` and `raider-hall` keep their names.
- Hall, Telegram, Cron and ACP stay **inside** this dist; no further split.
- The MCP client ships only as `Langertha::Raider::MCP`, never in core.
- **Dependency direction is one-way:** Raider → Langertha, never back. `Langertha::RunContext`
  and `Langertha::Role::Runnable` stay in core (generic, dependency-free) and are used from
  here, never copied. The generic tool-calling foundation (`Role::Tools`, `Role::PluginHost`,
  `Plugin`, `Chat`, …) stays in core. Core keeps two soft references: the lazy
  `use Langertha 'Raider'` sugar and an `->isa('Langertha::Raider')` string check in
  `Plugin.pm` — a documented exception, not a precedent.
- **Stub rule for renamed CPAN packages.** Nothing can be deleted from CPAN (BackPAN keeps
  everything). The highest indexed version of every package that was ever published must be
  a stub saying "gone, moved to …". This dist therefore ships reserved stubs for the six
  indexed `App::Raider*` packages. Stubs may only disappear after that stub release is
  indexed. Renamed but never published → simply dropped.
- Engine designs from langertha stay valid here: **ADR 0007** (two-tier history: compressed
  working `history` + never-compressed `session_history` with embedding recall) and
  **ADR 0008** (control surface as virtual self-tools, gated by `raider_mcp`).
- Version line continues at **0.503**.

## Consequences

- Cross-repo changes (langertha, knarr, skeid) are tickets on those repos' karr boards,
  never direct edits from here.
- Never put code back under `App::Raider*`; those names are stubs only.
- A Langertha release must precede any Raider release that needs its new API.
