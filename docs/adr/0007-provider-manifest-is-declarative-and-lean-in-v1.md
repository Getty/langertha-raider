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
