# ADR 0010 — ACP belongs to the agent, over stdio

- Status: accepted
- Date: 2026-09-20 (recorded 2026-09-24)
- Tags: acp, protocols, surfaces

## Context

Two different "ACP"s exist in the ecosystem: knarr speaks BeeAI/IBM's *Agent Communication
Protocol* (REST `/runs`); Raider targets Zed's *Agent Client Protocol* (JSON-RPC, editor
integration). ACP was first planned "generic in core", then moved. The current code serves
ACP from the Hall over TCP with only `initialize`, `session/new`, `session/prompt` (text)
and `session/cancel`, no authentication, and a fresh one-shot per prompt — editors can't
attach.

## Decision

- ACP belongs **to the agent**: target `Langertha::Raider::ACP`, one raider over **stdio**.
  The Hall is one consumer, not the owner. (Maintainer revision, 2026-09-20.)
- Always name it precisely: "ACP-Editor / Agent Client Protocol" vs. "ACP-BeeAI".
- Target a fixed v1 schema first; v2 (still draft) only negotiated and behind a feature
  gate. stdout carries protocol messages only, logs go to stderr. Only advertise
  capabilities that are implemented.
- Remote agents: SSH is the transport, ACP the conversation; prompts go over stdin, never
  into a remote shell line built from model text.
- **Remote CLI syntax:** `raider NAME@HOST <anything you'd type locally>` runs as raider
  `NAME` on `HOST` (maintainer, 2026-09-24). Detected as the first argument matching
  `NAME@HOST` and dispatched before option parsing, like the existing `hall` / `acp`
  subcommands in `bin/raider`.
- **`raider acp` is the stdio ACP server** an editor starts (maintainer, 2026-09-24). The
  existing ACP client moves to `raider acp connect …` for debugging; the everyday client
  role is `raider NAME@HOST`.

## Source

Maintainer decision 2026-09-20; `docs/RAIDER-REDESIGN-HANDOFF.md` §9.5, §10.2.
