# ADR 0008 — Learning yields candidates; autonomy must beat a baseline

- Status: accepted
- Date: 2026-09-24
- Tags: memory, learning, evaluation

## Context

A Hermes-style assistant that "remembers you" invites self-modifying behaviour: reflections
written straight into global memory, self-generated skills, policies rewritten by the model.
Research (Reflexion, ACE, MemGPT) motivates experiments; it does not prove a Perl
implementation gets better.

## Decision

- **Learning produces reviewed change requests only.** Reflection and memory extraction
  never write unreviewed global memories, and never directly create skills, policies or
  executable code. They produce candidates (with evidence, scope, status
  `candidate → verified | rejected`, later `stale | superseded`) that a separate authorised
  step promotes.
- Project knowledge never silently becomes a global preference; scope and confidentiality
  are inherited by anything derived.
- **Measurability before autonomy.** A new memory, context or multi-agent strategy becomes a
  default only after it beats a simple baseline in an eval harness: offline with fake
  engines and fake tools as the unconditional gate, optionally live with a hard cost limit.
  Report success, policy violations and legitimate refusals separately.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` §2 (11, 12), §6.5, §14, §15.
