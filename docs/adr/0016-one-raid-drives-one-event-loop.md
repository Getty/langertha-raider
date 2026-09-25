# ADR 0016 — One raid drives one event loop

- Status: accepted
- Date: 2026-09-25
- Tags: async, engines, core-boundary
- karr: core k228 (raised in the core k195 review)

## Context

A raider can use several engines: `engine`, `compression_engine` and every engine in
`engine_catalog`, which the model can switch to itself with `raider_switch_engine`. Since
core ADR 0028 raider reaches an engine's loop only through the public
`$engine->async_loop`, which is `Maybe[loop]`: an injected client or the synchronous
fallback has no loop, and raider then uses the process-wide `IO::Async::Loop->new`.

Nothing forced these engines onto one loop. When they sat on different loops, a raid
awaited futures that belong to two loops. A `->get` drives only one loop, so the future on
the other loop never finishes and the raid hangs. The hang was reproduced with a
`compression_engine` on one loop and the turn engine on another, and MCP was not involved.

## Decision

- **A raid drives exactly one IO::Async loop.** Every engine a raider may use (`engine`,
  `compression_engine`, every `engine_catalog` engine, and `embedding_engine` unless
  `no_session_embeddings` is set) must resolve to the same loop, each resolved as
  `async_loop // IO::Async::Loop->new` (embedding engine added 2026-09-26, karr #24).
- `Langertha::Raider::_check_engine_loops` checks this at the start of `raid_f` and
  `respond_f`. If an engine resolves to a different loop than `engine`, it croaks and names
  that engine (`compression_engine`, `engine_catalog '<name>'`, `embedding_engine`). The
  rule is documented in the `raid_f` POD.
- **Rejected: binding the inline MCP to each active engine's loop.** The core ticket
  suggested this. It cannot fix the hang, because one `->get` still drives only one loop,
  and the reproduced hang did not involve MCP at all.

## Consequences

- The check is stricter than the hang. It also refuses a catalog engine on another loop
  that the raid may never use, because the model can switch engines during a raid
  (`raider_switch_engine`) and the check cannot know in advance which engines it will use.
- `async_loop` builds each engine's HTTP client early. The check calls it on every engine,
  so the sync-fallback warning (core ADR 0027) can appear at raid start rather than at the
  first request.
- The inline MCP is added to `$self->engine`'s loop. Since every engine shares that loop,
  this binding is correct by construction.
- The `embedding_engine` is part of the check: session-history embeddings run in the
  background through `simple_embedding_f` on the raid's loop, so an embedding engine on
  another loop would leave them pending forever (karr #24). An auto-detected embedding
  engine is `engine` itself.
- Not covered: user-supplied `mcp_catalog` clients that sit on another loop.

## Source

Core karr k228; raider commits 540fdd4 (the check, `t/89_raider_engine_loops.t`) and
e2d8618; core ADR 0028 (`async_loop` is `Maybe[loop]`).
