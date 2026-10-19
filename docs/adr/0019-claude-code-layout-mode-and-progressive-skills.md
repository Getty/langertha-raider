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
  stream H. (Addendum 2: stream H runs them, see below and ADR 0022.)
- Running raider inside a Claude Code project (this repo included) now loads `CLAUDE.md`,
  the user's `~/.claude/CLAUDE.md`, settings env and plugin skills without a flag. Tests must
  isolate `$HOME` / `$CLAUDE_CONFIG_DIR`.
- `skills:` with `claude` and `--claude` change shape (layout switch instead of a file list);
  `Changes` says so. `CLAUDE.md` and `AGENTS.md` are instructions items now, not skills.
  (Addendum 1: `type: file` is a skill again, see below.)
- Nested `.claude/skills` below `root` and the `paths:` frontmatter: see Addendum 1.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream K, decision 1 by the maintainer); karr #151. Complements ADR 0004, 0011, 0014.

## Addendum 1 — follow-ups of the Claude mode (karr #157, 2026-10-19)

Decided while working the follow-ups; the numbers continue the sections above.

### 5. Claude mode has no persona

Layout mode `claude` (no raider files, only Claude Code ones) means raider acts as Claude Code
would. So there, raider's own default persona (Langertha, the terse style) is not used: the
instructions item is a neutral base text in the manner of Claude Code (no name, the working
rules, `CLAUDE.md` overrides it) followed by the memory items. Packs that are on only because
of `enabled_by_default` (caveman) stay off; `--pack`, `packs:` / `-o packs=`, `/pack` and
detection still switch packs on — an explicit choice always holds. `-M` still replaces the
instructions item. A raider project that merely reads the Claude layout (`claude: true`,
`--claude`) keeps the persona: the project made a deliberate raider choice (§1) and its
`.raider/instructions.md` customises exactly that persona. `config explain` shows
`instructions: claude base` and the default packs as switched off by `layout`.

### 6. `/reload` reads the context again

`/reload` re-reads layout mode, memory, settings (the `env` is applied again; a key the
settings dropped gets back the value it had before), enabled plugins and the skill catalogue,
and swaps the system prompt and the skill tool. Nested `CLAUDE.md` files and skills already
announced in the session are not announced again. Not re-decided: what came from flags and the
config file at start (`--claude`, `claude:`, `--bare`, explicit skill directories) and the pack
selection (so the default packs of Claude mode are decided at start).

### 7. One boolean parser for raider's own keys

`claude`, `perl` and the scalar form of `detect` go through `Langertha::Raider::Config->parse_bool`
wherever they come from (`-o`, config file, API): `true/yes/on/y/1` and `false/no/off/n/0/""` in
any case; a boolean object by truth; anything else croaks. `-o claude=false` is false, never the
true string `"false"`.

### 8. `skills:` entries are never dropped silently

A `type: file` entry is one skill file: a flat `*.md` skill named by its file name (so is a
`type: dir` entry that names a file, i.e. `--skills FILE`). A file that is not there is a
skill problem shown by `config explain`. An entry with an unknown `type`, without a `path`, or
that is neither a string nor a map croaks. (`CLAUDE.md` / `AGENTS.md` stay instructions items;
a hand-written file skill of either is just a skill.)

### 9. Nested skills and conditional skills (`paths:`)

As in Claude Code, skills can appear while working:

- **Nested `.claude/skills`.** The first time a tool touches a path below `root`, the
  `.claude/skills` of every directory on the way (below `root`, Claude layout only) is read
  once. Its skills come after all others: a name that is taken keeps the earlier skill, the
  shadowing is reported.
- **`paths:` frontmatter** (a YAML list, or a comma separated string; `*`, `**`, `?`, `{a,b}`;
  a glob without `/` matches the file name in any directory). A skill with `paths:` is not
  listed at the start and not loadable by the `skill` tool. When a tool touches a matching
  file it becomes listed for the rest of the session. The globs are relative to the directory
  that holds the skill's `.claude` (`.raider`); skills from user directories, explicit
  directories and plugins are relative to `root`.
- **Announcement.** Both ways add a second `<system-reminder>` block to the tool result, as
  Claude Code words it: `The following skills are available for use with the Skill tool:`
  and the `name: description` lines. The system prompt is not rebuilt.
- **The `skill` tool is mounted** in the Claude layout always (skills can arrive later), and
  elsewhere whenever the catalogue holds a skill the model can invoke now or after a match.
  This replaces "mounted only when at least one skill is loadable" of §4 for the Claude
  layout.

Not supported: `paths:` as a gate for rules/memory files, and a `paths:` glob over a file that
only a `bash` command touched (only tools with a `path` / `file_path` argument count, as for
nested memory).

## Addendum 2 — what makes `.raider/` a raider project (2026-10-19)

raider writes `.raider/sessions/` (the journal, ADR 0015), `.raider/.gitignore`
and `.raider/lib/` (perl_cpanm's local::lib) into any project it runs in.
Counting any `.raider/` as the marker turned a Claude Code project native from
its second run on: CLAUDE.md, `.claude/skills`, `.claude/agents` and the
settings were no longer read. `.raider/` now decides the mode only when it
holds project files: `config.yml`, `instructions.md`, or one of the
directories `skills/`, `agents/`, `raiders/`, `packs/`. The reason names the
file (`.raider/config.yml in root`). Found by stream A (karr #153).

## Addendum 3 — hooks run (karr #155, 2026-10-19)

Stream H runs the `hooks` of §3, and those of the enabled plugins, in the Claude layout and
only there; ADR 0022 records how. In the same step `disableAllHooks` became a key raider
uses (the last settings file that sets it wins), so `config explain` no longer lists it as
unused. The workspace trust of ADR 0004 still does not exist: hooks run without asking,
like the instruction files, until it does (ADR 0022, "Workspace trust").
