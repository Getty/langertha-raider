# ADR 0011 — Home is `~/.raider/`; projects use `<project>/.raider/`

- Status: accepted
- Date: 2026-09-24
- Tags: config, layout, home

## Context

Today everything is project-relative (`<root>/.raider.yml`, `<root>/.raider.md`); there is no
home config. The handoff proposed an XDG split (`~/.config/raider`, `~/.local/state/raider`,
`~/.cache/raider`). ADR 0003 already put assistant sessions under `~/.raider/sessions`.

## Decision

- **One dedicated home directory, `~/.raider/`** — no XDG split.
- Same file names at home and in a project:

  ```
  ~/.raider/                      <project>/.raider/
    config.yml                      config.yml        (shareable)
    instructions.md                 instructions.md
    skills/                         skills/
    raiders/<name>.yml              raiders/<name>.yml
    sessions/<id>.jsonl             sessions/<id>.jsonl
    memory/                         lib/              (Perl tools' local::lib)
                                    .gitignore        (sessions/, lib/)
  ```

- `raiders/<name>.yml` holds **named agents** (role, persona, packs, tools) — at home usable
  everywhere, in a project for that project (e.g. `reviewer`, `tester`). This is also where
  the Hall's per-raider definitions end up.
- Home tools reach projects through **`project_tools`** in `~/.raider/config.yml`: a map from
  a workspace selector (`"*"`, a path glob, or a workspace name) to a list of tools/services.
  All matching entries add up. A project may request home tools but only this map grants
  them (ADR 0005).
- Legacy `.raider.yml` / `.raider.md` stay readable; `raider config migrate` converts them
  explicitly. Old and new files together are reported, not both loaded silently.

## Consequences

- The schema of `raiders/<name>.yml` and how it relates to packs is follow-up design.
- On other operating systems `~/.raider/` maps to the user's home; no Windows-specific
  layout is promised.

## Source

Maintainer comments on the target-state README, 2026-09-24.
