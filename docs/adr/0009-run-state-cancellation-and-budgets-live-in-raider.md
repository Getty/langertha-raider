# ADR 0009 — Run state, cancellation and budgets live in Raider

- Status: accepted
- Date: 2026-09-24
- Tags: runtime, async, core-boundary

## Context

"Async **and** turn-based" needs explicit run states (`queued`, `running`, `waiting_user`,
`waiting_approval`, `waiting_task`, `paused`, `completed`, `failed`, `cancelled`,
`interrupted`), cancellation and budgets (model calls, tokens, time, tool calls, delegation
depth). The handoff assumed core's `Langertha::RunContext` could be reused for this. Checked
2026-09-24 (langertha 4d2f423): `Role::Runnable` only `requires 'run_f'`; `RunContext` has
`input/state/artifacts/metadata/trace/history` plus `add_trace/branch/merge_branch` — no
status, no cancellation, no budget, no wait states.

## Decision

- Run state machine, cancellation and budgets are built **in Raider**. Core's `RunContext`
  and `Role::Runnable` stay generic (langertha ADR 0026).
- If the Raider implementation proves generic and useful elsewhere, it may later be proposed
  to core via a ticket on the langertha board.
- Waits are persisted as ids and descriptions, never as closures, filehandles or Future
  objects. Note: today's `_continuation` holds engine objects and is not serialisable —
  making waits persistent is a loop rework, not an add-on.

## Implementation notes

- 2026-09-25 (karr #64): `Langertha::Raider->cancel` sets a flag and wakes the event loop
  through a pipe (signal-safe; a plain `later` does not wake a Poll loop interrupted by a
  signal). The raid stops before its next model or tool call and abandons the future it
  is waiting on, which also cancels an in-flight Net::Async::HTTP request. A cancelled raid
  returns a `cancelled` Result, adds nothing to `history`, keeps already recorded tool
  calls in `session_history`, and reports a cut-off tool call as cancelled.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §7; code check 2026-09-24.
