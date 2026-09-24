# Migration manifest — raw copy from langertha core

These files were copied **raw** (no renames, no dist assembly) out of the
`langertha` distribution (commit bca4d0b, 2026-09-20) as the first half of the
Raider extraction. The langertha side (removal / stubs + integrity + requirements
+ docs) is done and landed on langertha's `main`. Assembling this into a working
distribution is the raider-team's job — see `TODO.md` and karr #1–#6.

## Final partition (agreed with the maintainer)

**Ships from langertha-raider** (copied here):

| File (as copied) | Assembly note |
|---|---|
| `lib/Langertha/Raider.pm` | main_module; name kept 1:1 |
| `lib/Langertha/Raider/Result.pm` | **make self-contained** — fold in the base below |
| `lib/Langertha/Result.pm` | base source to fold into `Raider::Result`; **do NOT ship this name** (core keeps a stub) |
| `lib/Langertha/MCP/Client.pm` | **rename → `Langertha::Raider::MCP`**; **do NOT ship `Langertha::MCP::Client`** (never published, core just dropped it) |
| `lib/Langertha/Raid.pm`, `Raid/{Loop,Parallel,Sequential}.pm` | names kept 1:1 |

**Stays in langertha core — use from here, do NOT ship:**

- `Langertha::RunContext` and `Langertha::Role::Runnable` are dependency-free generic
  primitives (a structured run context + the `run_f` contract) and were kept in core.
  `Raid.pm` here `use`s `Langertha::RunContext` and `with`s `Langertha::Role::Runnable`
  from core (`requires 'Langertha'`). Do not add copies of them to this dist.

## The stub rule

- Migrates 1:1 under the same name → removed from core, shipped here (`Langertha::Raider`,
  `Raider::Result`, `Langertha::Raid*`).
- Renamed **and was published** on CPAN → core keeps a reserved stub under the old name
  (`Langertha::Result`).
- Renamed but **never published** → core just drops it, no stub (`Langertha::MCP::Client`).
- Generic + dependency-free + decoupled → kept in core (`RunContext`, `Role::Runnable`).

## Copied tests (`t/`)

`t/71_raider_engine_catalog.t`, `t/82_live_raider.t`, `t/85_raider_result.t`,
`t/86_raider_self_tools.t`, `t/87_raider_plugins.t`,
`t/88_raider_clear_session_history.t`, `t/96_raid_orchestration.t`,
`t/91_plugin_config.t` (langertha keeps a de-Raidered variant on Langertha::Chat).
Tests still reference the old names — adjust to the self-contained ones.

## Still to do here

- Fold base `Result.pm` into a self-contained `Langertha::Raider::Result`; rename
  `MCP/Client.pm` → `Langertha::Raider::MCP`.
- Merge `~/dev/raider` (`App::Raider::*` → `Langertha::Raider::*`, `App::Raider.pm` →
  `Langertha::Raider::CLI`; `bin/raider` stays, keep `bin/raider-hall`; bring `share/`,
  `plugins/`, `examples/`, `Dockerfile`, `maint/`, `README.md`, `Changes`).
- `dist.ini` (`[@Author::GETTY]`, `main_module = lib/Langertha/Raider.pm`) + `cpanfile`.
  Version target **0.502**.
- cpanfile: `Langertha` (>= 0.503, for RunContext/Runnable + the stubs), `Net::Async::MCP`,
  `IO::Async`, `Net::Async::HTTP`, `Future::AsyncAwait`, `Moose`, `MooseX::NonMoose`,
  `Module::Pluggable`. Cosine search is inline — no `Math::Vector::Similarity`.
