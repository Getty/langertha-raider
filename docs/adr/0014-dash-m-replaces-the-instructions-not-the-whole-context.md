# ADR 0014 — `-M` replaces the instructions, not the whole context

- Status: accepted
- Date: 2026-09-25
- Tags: cli, context, packs

## Context

Today `-M TEXT` replaces the entire system prompt: the default persona, `.raider.md`,
loaded skills and active packs are all dropped, and only `TEXT` remains. Since #19 the
`-M` text survives `/reload` and `/pack`, but toggling a pack with `-M` still has no
visible effect. That clashes with two accepted decisions:

- ADR 0004: context is a plan of separate items with sources, not one mission blob.
- ADR 0012: packs switch themselves on by detection. With `-M`, a detected `perl` pack
  would still request the Perl tools while its skill text silently disappears.

The hand-written tool list also lives in the default persona text, so `-M` removes the
model's description of its tools as a side effect.

## Decision

- **`-M` replaces the instructions item only**: the default persona together with
  `.raider.md`. Skills, packs (configured, flagged or detected) and the tool description
  stay separate context items and still apply.
- **`--bare` gives an isolated context**: no `.raider.md`, no skills, no packs, no
  detection. `-M TEXT --bare` is exactly today's `-M TEXT`. `--bare` without `-M` uses the
  default persona alone.
- The tool description is never part of what `-M` replaces. Until ADR 0005 derives it from
  the active tool set, it is emitted as its own item next to the instructions.
- `/pack`, `/reload` and detection behave the same with or without `-M`; with `--bare`,
  `/pack NAME` still switches a pack on explicitly.
- `raider config explain` (and later `raider context explain`, ADR 0004) shows the
  instructions source as `-M`, `.raider.md` or `default`, and `bare` when set.

## Consequences

- This changes the meaning of `-M` for anyone who relied on it to drop everything; they
  need `--bare`. `Changes` must say so plainly. The dist is unreleased, so no deprecation
  cycle is needed for the CPAN interface, only for existing `raider` users of the old
  App-Raider.
- The Hall passes a raider's mission as the prompt, not as `-M`, so the Hall is not
  affected.
- The persona text needs to be split from the tool list; that is part of this change, not a
  separate refactor.

## Source

karr #34 (from #19); follows ADR 0004 and ADR 0012.
