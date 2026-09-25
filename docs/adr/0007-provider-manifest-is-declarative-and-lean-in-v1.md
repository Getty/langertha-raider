# ADR 0007 — The provider manifest is declarative and lean in v1

- Status: accepted
- Date: 2026-09-24
- Tags: provider-discovery, manifest, ecosystem

## Context

Vision: `raider --provider host.tld` fetches a manifest and just works. Knarr would serve it
automatically from its model list; Skeid would expose a configured subset per customer key.
The original idea included MCP servers, packs/skills and a default mission in the manifest —
which makes a remote document able to inject tools and prompts.

## Decision

- Name: `/.well-known/langertha.json` (ecosystem-wide, not Raider-specific). Our own draft,
  not an existing standard; check RFC 8615 registration rules before publishing it as one.
- **Core** owns schema, value objects, parser/validator and builder. **Raider** owns local
  trust, aliases, secret binding and activation. **Knarr** exports a manifest from what it
  actually exposes (never its internal config or upstream keys). **Skeid** publishes a
  filtered manifest per authorisation context.
- **v1 contains only** endpoints, wire dialects, model ids, declared capabilities and auth
  mechanisms. No shell commands, Perl classes, secret paths or system prompts.
- MCP servers, packs, skills and default missions come **later** as inactive, versioned
  references in separate extensions; installing, loading and running them each needs local
  policy.
- Four states stay separate: what the provider claims, what the adapter understands, what a
  probe observed, what local policy authorises.
- Protected MCP resources use MCP authorization / RFC 9728 metadata — no home-grown OAuth.
- Fetching: HTTPS, size/time/redirect limits, no credential forwarding across origins, no
  self-granted access to loopback/link-local/metadata addresses; internal Knarr/Skeid
  origins are allowed by explicit local approval.

## Consequences

- Changes §1.5 of the original vision: tools/packs/mission in the manifest are postponed.
- Work in core, knarr and skeid is tickets on their boards.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (10), §11.

## Update (2026-09-25, core ADR 0029)

Core's manifest v1 fixes the vocabulary this ADR left open. Capability names are core's
`%ROLE_TO_CAPS` names: a tool-calling model declares `tools_native` (not a raider-invented
`tool_calling`), and a name the client does not know counts as absent. The dialect list
separates `anthropic` (first party, native `output_config.format`) from `anthropic-compat`
(the `/anthropic` shims). The raider adapter takes the conservative path on
`anthropic-compat`: structured output is a synthetic tool plus a forced named `tool_choice`,
even where one model behind the shim could do it natively, because the dialect names the
endpoint, not the model. Example model entry:

```json
{ "id": "example-model", "endpoint_ref": "chat",
  "capabilities": { "tools_native": true, "streaming": true } }
```
