# ADR 0006 — Codex and Claude Code are delegates, not engines

- Status: accepted
- Date: 2026-09-24
- Tags: delegation, subscriptions, codex, claude

## Context

The maintainer wants subscription access (ChatGPT/Codex, Claude Pro/Max) usable from Raider.
Research state 2026-09-24 (re-check primary sources before implementing):

- **OpenAI/Codex:** the sanctioned integration path is the official binary — `codex
  app-server` (JSON-RPC over stdio; Codex owns the ChatGPT OAuth and token refresh;
  `clientInfo.name` should honestly be `raider`; the docs mark app-server experimental and
  not supported for production workloads) or `codex exec --json`. `codex mcp-server` was
  removed; app-server is its own protocol, not an MCP drop-in. OpenAI's terms neither allow
  nor forbid third-party clients explicitly; public statements by OpenAI staff endorse using
  a ChatGPT login in other tools. Own PKCE OAuth against the undocumented backend (what
  `claude-code-proxy` does) is a tolerated grey zone; reading `~/.codex/auth.json` directly
  is risky; sharing/reselling a subscription is forbidden.
- **Anthropic/Claude:** OAuth is for Claude Code and Anthropic's own apps. Third parties may
  not offer Claude.ai login nor collect/store/relay its tokens. Running the **unmodified**
  `claude` binary (`claude -p`) or the Agent SDK on one's own subscription is allowed.
  Direct token reuse against `api.anthropic.com` is blocked.
- Sources: openai.com/policies (row/eu terms, service terms), developers.openai.com/codex/app-server,
  learn.chatgpt.com/docs/app-server, learn.chatgpt.com/docs/mcp-server,
  code.claude.com/docs/en/legal-and-compliance, code.claude.com/docs/en/agent-sdk/overview,
  code.claude.com/docs/en/headless.

Codex and Claude Code are agents with their own loop, history, tools and context loaders —
not models answering a request Raider manages.

## Decision

- Subscription access goes **only through the official binaries**, which own the login.
  Raider never reads their auth files and builds no subscription OAuth flow of its own.
- They live in Raider as internal **`Delegate` adapters**, not as `Langertha::Engine::*` in
  core.
- `--use-codex` / `--use-claude` mount narrow tools (`ask_codex`, `ask_claude`). Default task:
  analysis or review; no free edits; no full session dump — the delegate gets an explicit
  input package (objective, artifacts, constraints, budget, return contract).
- Each delegate has a verifiable start profile (binary, version/capabilities, cwd, env
  allowlist, permissions, network, output and time limits). If it can't guarantee isolation
  from its own auto-loaded context (e.g. `claude --bare`), it must not claim the narrow mode.
- A later "external agent owns the main loop" mode is possible but must be labelled as such.
- Experimental upstream integrations get a feature gate and tests against a pinned binary
  version.

## Consequences

- The existing `--claude` / `--codex` / `--openai` flags (load `CLAUDE.md` / `AGENTS.md`)
  are not reinterpreted as delegation.
- Personal local use, SDK-based products and hosting are different cases; this ADR covers
  personal local use only.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (9), §9; maintainer decision 2026-09-24
("the subprocess path is ok").
