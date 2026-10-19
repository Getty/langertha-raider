# ADR 0019 — Claude Code layout mode and progressive skills

- Status: accepted
- Date: 2026-10-19
- Tags: context, instructions, skills, settings, claude-code

## Context

Raider is meant to behave as close to Claude Code as possible inside a project that is set
up for Claude Code: read the same instruction files, offer the same skills, later ask for
permissions and run hooks the same way (karr #151, plan "raider wie Claude Code",
2026-10-19). Until now:

- Instructions come only from `.raider/instructions.md` (legacy `.raider.md`).
  `CLAUDE.md` / `AGENTS.md` load only with `--claude` / `--codex` (or `skills: [claude]`),
  root level only, as plain files glued into the prompt.
- Skills (`--skills DIR`, `skills:` entries, `.claude/skills` under `--claude`) are glued
  into the system prompt in full; their frontmatter is thrown away. There is no skill tool.
- `.claude/settings*.json` and Claude Code plugins are not read at all.

ADR 0004 asks for itemised context with sources; ADR 0011 fixes `.raider/` as the native
layout; ADR 0014 says what `-M` replaces. This ADR adds the Claude Code layout next to them.

## Decision

### 1. Layout mode

Raider decides once per application, from `root`, which layout it reads:

| Situation | Mode | Claude layout read |
|---|---|---|
| `root/.raider/` exists (or a legacy `.raider.yml` / `.raider.md`) | `raider` | only when the effective config says `claude: true` |
| no raider files, but `CLAUDE.md`, `CLAUDE.local.md` or a `.claude/` directory in `root` or a directory of its memory walk (§2) | `claude` | yes |
| neither | `native` | no |

- Nothing in `$HOME` itself counts as a project marker — neither the home `.claude/`
  (`~/.claude`, or `$CLAUDE_CONFIG_DIR`) nor a `~/CLAUDE.md` — so a project under `$HOME`
  does not turn into Claude mode by accident. In Claude mode `~/CLAUDE.md` is still read as
  part of the memory walk (§2).
- `root == $HOME` is the assistant home (ADR 0002): mode `native`, whatever is there.
- `--bare` reads no layout at all (ADR 0014), mode reported as `bare`.
- `--claude` switches the Claude layout on for this run in any mode; it persists as
  `claude: true` in the project config (the old persisted form `skills: [claude]` is read as
  the same thing). `--codex` / `--openai` (and `skills: [openai|codex|agents]`) keep their
  meaning: `AGENTS.md` of `root` as an instructions item.
- `config explain` shows the mode and the reason (which marker decided it).

Why `.raider/` wins: a project that has a raider layout made a deliberate choice; Claude
files there are someone else's configuration until the project says otherwise. A project
with only Claude files was set up for Claude Code, so raider acts as Claude Code would.

### 2. Instructions in the Claude layout ("memory")

Read like Claude Code, in this order (later = more specific):

1. `~/.claude/CLAUDE.md` (user memory).
2. For every directory from the walk top down to `root`: `CLAUDE.md`, then
   `CLAUDE.local.md`. The walk starts at the repository top (the nearest ancestor with
   `.git`), else at `$HOME` when `root` is under it, else at `root` itself. A level without
   `CLAUDE.md` uses its `AGENTS.md` instead (the Codex convention).
3. `@path` imports inside these files are expanded in place: relative to the importing
   file, `~/` from the home, at most 5 levels deep, never inside code spans or fenced
   blocks, a file imported twice only once, a missing file left as written.
4. `CLAUDE.md` files *below* `root` are not loaded up front. The first time a file tool
   touches a path in such a subtree, that subtree's `CLAUDE.md` is appended to the tool
   result once per session (Claude Code's nested memory).

Each file is its own context item with source and scope (ADR 0004). `-M` replaces only the
raider persona and the native instructions file (ADR 0014), never the Claude memory items —
as Claude Code's `--system-prompt` keeps `CLAUDE.md`.

### 3. Settings

In the Claude layout raider reads `~/.claude/settings.json` < `.claude/settings.json` <
`.claude/settings.local.json` (later wins) into one `Langertha::Raider::Context::Settings`
value with the source of every entry:

- `permissions` — `allow` / `ask` / `deny` rule lists (concatenated across files),
  `defaultMode` (last wins), `additionalDirectories` (concatenated). Only stored here; the
  permission engine (karr stream P) evaluates them.
- `hooks` — per event the matcher groups of every file, concatenated. Only stored; stream H
  runs them.
- `env` — merged per key; applied to raider's process environment, so tools and
  subprocesses see it, as in Claude Code.
- `enabledPlugins` — merged per key; selects the plugins whose skills are offered.
- Every other key is kept as "not used by raider" and listed by `config explain`.

Unreadable or invalid JSON files are reported, never fatal.

### 4. Skills are discovered, listed and loaded on demand

Skill roots, highest precedence first (a name found earlier shadows the same name later;
shadowing is reported):

1. explicit: `--skills DIR`, `skills:` directory entries;
2. native: `.raider/skills`, `~/.raider/skills`;
3. Claude layout only: `~/.claude/skills`, `.claude/skills` (Claude Code's order:
   personal before project), `.agents/skills`, then the skills of every installed **and**
   enabled plugin (`~/.claude/plugins/installed_plugins.json` × `enabledPlugins`,
   project-scoped installs only inside their `projectPath`; the plugin's `skills/` plus the
   manifest's `skills` paths) under the name `plugin:skill` — never shadowed.

A skill is a directory with `SKILL.md` (YAML frontmatter `name`, `description`, the other
keys kept); a flat `*.md` in an explicit directory is a skill named by its file. The system
prompt lists every skill as `name: description` (skills with
`disable-model-invocation: true` are not listed and not loadable by the model). The new
`skill` tool takes a skill name (and optional `args`) and returns the body without
frontmatter, headed by `Base directory for this skill: DIR`, with `$ARGUMENTS` replaced by
`args` (or `ARGUMENTS: args` appended) — the shape of Claude Code's Skill tool. The tool is
mounted only when at least one skill is loadable. Full skill bodies are no longer glued into
the system prompt. Packs (ADR 0012) stay as they are.

## Consequences

- The workspace trust decision of ADR 0004 still does not exist. Until it does, the
  Claude layout loads its instruction files without asking, exactly like the native
  instructions file already does; executable parts (hooks) are only read, never run, until
  stream H.
- Running raider inside a Claude Code project (this repo included) now loads `CLAUDE.md`,
  the user's `~/.claude/CLAUDE.md`, settings env and plugin skills without a flag. Tests must
  isolate `$HOME` / `$CLAUDE_CONFIG_DIR`.
- `skills:` with `claude` and `--claude` change shape (layout switch instead of a file list);
  `Changes` says so. `type => 'file'` skill specs are gone as skills: `CLAUDE.md` and
  `AGENTS.md` are instructions items now.
- Nested `.claude/skills` below `root` and Claude Code's `paths:` frontmatter are not
  supported yet.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream K, decision 1 by the maintainer); karr #151. Complements ADR 0004, 0011, 0014.
