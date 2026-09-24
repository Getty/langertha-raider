# ADR 0012 — Packs activate by declarative workspace detection

- Status: accepted
- Date: 2026-09-25
- Tags: packs, config, context, detection

## Context

Today everything that depends on the kind of project has to be switched on by hand:
`--pack`, `perl: true`, `--claude` / `--openai` (or persisted in `.raider.yml`). A Perl
distribution should get the Perl tools and Perl skills without anyone saying so; a
non-Perl repo should not. The maintainer wants rules that say "these packs are loaded
additionally when the directory looks like X", expressed as which files must or must not
exist and what must be in them.

"Profile" is already taken (`assistant` / `project`, ADR 0002; and the `claude` / `openai`
skill profiles in `Langertha::Raider::Config`), so this is not a new kind of profile.
The thing that gets activated is a **pack** — the existing bundle of skills, persona
defaults and requested capabilities.

## Decision

- **A pack can carry a detection rule.** When the rule matches the workspace, the pack is
  activated in addition to the explicitly configured packs. No new bundle type.
- **Rules are declarative, never code.** Three clause lists:

  ```yaml
  detect:
    perl:
      must:     [ { file: cpanfile } ]            # all must hold
      may:      [ { file: dist.ini },             # at least one must hold (if present)
                  { file: Makefile.PL },
                  { file: 'lib/**/*.pm' } ]
      must_not: [ { file: .raider/no-perl } ]     # none may hold
  ```

  - `must` — every condition holds.
  - `may` — if the list is non-empty, at least one condition holds.
  - `must_not` — no condition holds.
  - A rule with no clauses never matches.
- **Conditions** (each is one map, all keys of a map must hold):
  - `file: GLOB` — a file matching the glob exists (relative to the workspace root).
  - `dir: GLOB` — a directory matching the glob exists.
  - `contains: STRING` — with `file`, a matching file contains the literal string.
  - `matches: REGEX` — with `file`, a matching file matches the regex.
- **Bounded evaluation.** Globs are relative to the workspace root and never leave it
  (no `..`, no following symlinks outside it); `**` is capped in depth and file count;
  content checks read at most the first 64 KiB of a file. Exceeding a cap makes the
  condition false and is reported, never an error that stops the run.
- **Where rules come from.**
  - A pack may ship a default rule (e.g. the Perl pack detects `cpanfile` / `dist.ini`).
  - `detect:` in `~/.raider/config.yml` or `<project>/.raider/config.yml` (ADR 0011) adds
    or overrides a rule per pack name; project over home over pack default.
  - Rules from the project's own `.raider/` only apply once the workspace is trusted
    (ADR 0004); before that they are listed, not evaluated.
- **Order of activation.** Explicit choices beat detection:
  1. CLI flags (`--pack NAME`, `--no-pack NAME`, `--no-detect`).
  2. Explicit config (`packs:` adds; `no_detect: [NAME, …]` or `detect: false` turns
     detection off for those packs or entirely).
  3. Detected packs.

  Detected packs add up; exclusive groups of packs still apply, and an explicit pack wins
  over a detected one in the same group.
- **Detection grants nothing.** It only decides *which* packs are active. What an active
  pack requests (tools, commands, MCP servers) is still a request that local policy has to
  grant (ADR 0005). A repository can make a pack activate; it can never make a pack more
  powerful.
- **Explainable and stable per run.** Detection runs when a session starts and on
  `/reload`, not per model call; the result is part of the run's config snapshot
  (ADR 0009). `raider config explain` shows each pack with its source (`flag`, `config`,
  `detected`) and, for detected ones, which clause matched.

## Consequences

- The rule format is the same wherever it is written (pack default, home, project), so a
  user can copy a pack's default rule into their config and change it.
- `perl: true` and the `claude` / `openai` skill profiles can later be expressed as packs
  with default rules; until the migration they keep their current meaning (ADR 0004).
- Pack definitions outside Perl modules (`raiders/<name>.yml`, ADR 0011) are still follow-up
  design; the `detect:` key is meant to fit there unchanged.
- The exact caps (depth, file count) are implementation defaults, documented with the
  feature, not fixed here.

## Source

Maintainer idea, 2026-09-24 (karr #32); rule shape ("must" / "may" / "must not" on files
and their content) from the maintainer, 2026-09-25.
