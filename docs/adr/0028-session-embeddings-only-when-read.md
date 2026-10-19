# ADR 0028 — Session embeddings only when something reads them

- Status: accepted
- Date: 2026-10-19
- Tags: raid-engine, embeddings, application, cli
- karr: #162

## Context

`Langertha::Raider` embeds every `session_history` entry in the background
(`_embed_session_slot`) whenever the engine can embed or an `embedding_engine` is
given. The only reader of those vectors is the `search` of the `raider_session_history`
self-tool (`raider_mcp`). The application (`Langertha::Raider::Application`) mounts no
such tool, so each message cost an embedding request nothing used: noise, cost, latency
and, on a provider without an embeddings endpoint, a 404 in the log.

## Decision

1. The application decides: `Application->session_embeddings` is `{ enabled => 1 }`
   only when a tool named `session_history` or `raider_session_history` is mounted, and
   otherwise `{ enabled => 0, reason => ... }`. `_build_raider` passes
   `no_session_embeddings` from it. Today the application mounts neither, so its raider
   never embeds.
2. Whether the engine can embed stays the raider's business (`_get_embedding_engine`:
   `embedding_engine`, else an engine that does `Langertha::Role::Embedding`). Embeddings
   run when both hold: a reader is mounted AND the engine can embed.
3. `Langertha::Raider` used directly keeps its behaviour (embeds when it can, unless
   `no_session_embeddings`); engine-API users with the history tool lose nothing.
4. `raider config explain` shows the state (`session_embeddings`, line
   `session embeddings: off (no session history tool is mounted)`).

## Consequences

Mounting a history tool in the application later only needs `session_embeddings` to
see it; no other switch. The core raider default is not made stricter (it would change
the public engine API for users who read `session_history` vectors differently).
