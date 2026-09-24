# ADR 0005 — One active tool set per run; permissions never come from prompts

- Status: accepted
- Date: 2026-09-24
- Tags: tools, policy, security

## Context

Tools come from many places: built-in tool servers (files, web, perl, hall), `bash`, packs,
project MCP servers, and services that run once in the home (e.g. a Telegram bot) and should
be available inside project raiders. Today the tool list in the mission text is hand-written
and incomplete (`perl_*` and hall tools missing), pack fields like `add_allowed_commands` /
`extra_mcp` are loaded but ignored, and each surface wires tools its own way.

## Decision

- **Tool sources are many** — home, project, packs, MCP servers, home-hosted services. The
  home configuration decides which home tools and services are mounted into project
  instances; a service like the Telegram bot runs **once** in the home and is attached to
  project raiders when configured to.
- **Per run, exactly one active tool set** is assembled from those sources. The prompt's tool
  description, the tool catalogue sent to the model and the permission check all derive from
  that one set — no second hand-maintained list.
- **One execution path for all surfaces** (CLI, Hall, Telegram, ACP, delegation):
  validate arguments → resolve target/scope → check policy → ask for approval if required →
  execute with limits → normalise and record the result.
- **Permissions never come from prompts.** A skill, pack, persona, project file, provider
  manifest, model output or sub-agent may *request* capabilities (`add_allowed_commands`,
  `extra_mcp`, …) but never grant them. The limit is local policy. A model saying
  `approved=true` has no effect.
- Approvals are bound to session, run, tool, canonical arguments and policy revision; a
  change invalidates them.
- Arbitrary code execution (`bash`, `perl_eval`, `perl -c` — which runs `BEGIN`/`use`) is
  treated as such. The word "sandbox" is only used for boundaries that were actually tested.

## Consequences

- Dead pack/Hall fields get implemented as capability *requests* or removed — not carried on
  silently.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (6, 8), §8, §12; tool-source model clarified
by the maintainer.
