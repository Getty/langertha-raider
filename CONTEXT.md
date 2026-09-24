# Raider — Vision & Vocabulary

What Raider is for, and the words it is written in. Use these words in code, tests, tickets
and ADRs. Decisions live in `docs/adr/`, open work on the karr board — not here.

## Vision

**Perl is the glue of the internet — Raider is the glue for AI.** Raider is the Perl-native
agent runtime that goes "just everywhere": into any project, any environment, onto any
provider and tool, and brings models, tools and other agents together under control — with
traceable context and no hidden privilege escalation.

It is two things at once, from one kernel (ADR 0002):

- **Assistant** (Hermes-agent side): lives in the home directory, reachable everywhere
  (CLI, Telegram, cron, server), remembers the user.
- **Project agent** (Claude-Code side): works inside a project and respects that project's
  context.

Standing requirements:

- **Context discipline** — exactly the context that matters, no pollution. Home doesn't
  bleed into projects, projects don't bleed into the assistant (ADR 0004).
- **Surfaces** — CLI (REPL, one-shot, `--json`) stays central; Hall with Telegram, cron and
  multiple agents; ACP for editors (ADR 0010); a web UI later, as an option.
- **Async *and* turn-based** — a turn is a unit of meaning; async is how it executes
  (ADR 0009).
- **Provider discovery** — `raider --provider host.tld` just works (ADR 0007).
- **Subscriptions** — Codex and Claude reachable through their official binaries
  (ADR 0006).
- **Remote agents** — start agents in other directories / on other hosts (possibly someone
  else's account) and talk to them, e.g. ACP over stdio over SSH.
- **Perl-native tools** — `perl_eval`, `perl_cpanm` with a private local::lib,
  auto-install of missing modules — the concrete form of "Perl as glue".

The first success is not an autonomous swarm. It is Raider knowing, after a restart, which
session and which project it is in, where its information came from, which action actually
happened — and which explicitly did not.

## Language

**Profile**: `assistant` or `project` — a set of defaults (scope, memory, tools, policies)
for one kernel. Not a security boundary.

**Principal**: the locally authenticated person Raider acts for. A surface maps e.g. a
Telegram sender to a principal; a prompt can never set it.

**Workspace**: a registered working directory with a stable id and a trust decision.
_Avoid_: project root (as an identity), repo.

**Session**: a persistent conversation, bound to one principal and one workspace (or the
home), stored as JSONL next to its scope (ADR 0003). _Avoid_: process, PID.

**Run**: the processing of one accepted input inside a session, with a state, budgets and a
config/policy snapshot.

**Task**: an isolated or delegated sub-job with its own id and an explicit input package.

**ContextPlan**: the itemised, explainable context of one model call (ADR 0004).
_Avoid_: mission (for the assembled whole).

**Tool source / active tool set**: tools come from many sources; per run exactly one
active set is assembled and used for prompt, catalogue and permission checks (ADR 0005).

**Delegate**: an external agent with its own loop (Codex, Claude Code, a remote raider),
driven through a narrow task contract (ADR 0006). _Avoid_: engine (for these).

**Engine**: a Langertha model backend (`Langertha::Engine::*`). Answers requests; owns no
loop.

**Skill**: procedural knowledge (description, instructions, maybe resources/scripts),
loaded progressively. **Persona**: tone and working style. **Pack**: a named bundle of
skills, persona defaults and *requested* capabilities (called "packs" in code, "persona" in
Hall/README today).

**Hall**: the optional daemon — process/job supervision, queue, Telegram, cron.

**ACP**: here always the *Agent Client Protocol* (Zed, editors). Knarr's ACP is BeeAI's
*Agent Communication Protocol* — say "ACP-BeeAI" when meaning that one.

## Ecosystem

All four dists depend on `langertha`; `langertha` depends on none of them. Cross-repo work
is a ticket on that repo's karr board.

- **langertha** (`~/dev/langertha`) — provider abstraction on Moose + IO::Async +
  Future::AsyncAwait. ~35 engines (inheritance = wire dialect, roles = capabilities),
  `Role::Tools` with the MCP tool loop, model listing, local engine discovery
  (`new_engine`, `LANGERTHA_<ENGINE>_API_KEY`), plugins, Langfuse, usage/cost, `RunContext`
  and `Role::Runnable`. No config file format and no manifest yet. Raider still reaches into
  private API (`_async_http`, `_langfuse_timestamp`) — to be replaced by public hooks.
- **langertha-knarr** (`~/dev/langertha-knarr`) — "universal LLM hub": proxy/server
  accepting OpenAI, Anthropic, Ollama, A2A, ACP-BeeAI, AG-UI; routes to engines or
  passthrough. `Handler::Raider` already serves one raider per session as model
  `langertha-raider`. Natural server of the provider manifest.
- **langertha-skeid** (`~/dev/langertha-skeid`) — routing control plane in front of many
  LLM nodes (own GPUs, vLLM/SGLang, customer keys). Exposes models to clients by
  configuration, not automatically.
- **claude-code-proxy** (`~/dev/claude-code-proxy`, not Langertha) — Rust proxy with
  Claude Code as client, translating to subscription backends (Codex, Kimi, Grok, …) via its
  own OAuth. Nothing on the Perl side uses subscription auth today.
