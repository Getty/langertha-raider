# ADR 0030 — Slash commands like Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: cli, repl, skills, commands, permissions, claude-code
- karr: #165 (stream C)

## Context

Claude Code runs `/name args` from three kinds of sources: its built-in commands, custom
commands (`.claude/commands/**/*.md`, `~/.claude/commands`, plugin `commands/`) and skills
(`/skill-name`, `/plugin:skill`). Since Claude Code merged commands into skills, a command file
and a skill are the same thing: both are listed for the model unless
`disable-model-invocation: true`, both are rendered the same way. raider had a fixed set of
built-ins (`/help`, `/clear`, `/reload`, `/permissions`, …), skills only for the model (the
`skill` tool, ADR 0019 §4 / ADR 0026) and no custom commands. A one-shot run sent `/x` to the
model as text.

The rules below follow code.claude.com/docs (`skills`, `commands`; read 2026-10-19). Where
raider deviates, the ADR says so.

## Decision

### 1. One catalogue: commands are skills

`Langertha::Raider::Context::Skills` gains a root layout `commands`: a directory searched
recursively for `*.md`; each file is one entry named by its path below the root without `.md`,
directories joined with `:` (`frontend/component.md` → `frontend:component`). Plugin commands
are `plugin:name` (`plugin:sub:name` for subdirectories): the plugin's `commands/` plus the
manifest's `commands` paths.

Roots per layout (same precedence rule as skills, ADR 0019 §4: the first of a name wins, the
rest is `shadowed`):

- native: `.raider/commands`, `~/.raider/commands`;
- Claude layout: `~/.claude/commands`, `.claude/commands` (Claude Code's order, as for skills),
  plugin commands.

A **skill beats a command of the same name** (Claude Code: "the skill"), whatever root order.
An entry carries `kind => 'skill' | 'command'`. Everything else of ADR 0019 holds for commands
too: `description` falls back to the first body line, `disable-model-invocation: true` keeps
it out of the model's listing and the `skill` tool, `paths:` works the same.

`user-invocable: false` keeps an entry from being run as `/name` (it stays loadable by the
model). Frontmatter booleans take `true/false/yes/no/on/off/1/0`.

### 2. Rendering (one renderer for `/name` and the `skill` tool)

New module `Langertha::Raider::SlashCommand` renders an entry's body for given arguments, in
this order:

1. **Arguments.** The argument string is split shell-style (quotes group, backslash escapes).
   `$ARGUMENTS` → the whole string; `$ARGUMENTS[N]` and `$N` → the N-th argument,
   **0-based** as in current Claude Code (`$0` is the first; the brief's `$1..$N` meant the
   positional form — Claude Code's numbering wins); an index without argument stays as typed;
   frontmatter `arguments` (list, or space-separated string) names positions for `$name`,
   which expands to `''` when missing; `${CLAUDE_SKILL_DIR}` (the entry's directory),
   `${CLAUDE_PROJECT_DIR}` (root), `${CLAUDE_SESSION_ID}` (empty without a session),
   `${CLAUDE_PLUGIN_ROOT}` for plugin entries. `\$` is a literal `$`. Inserted values are not
   expanded again. With arguments but no placeholder used, `ARGUMENTS: <args>` is appended
   after a blank line.
2. **Shell injection.** `` !`cmd` `` at line start or after whitespace, and fenced
   ```` ```! ```` blocks, run in `bash -c` in the root before the text goes to the model;
   the output (stdout and stderr, trailing newline trimmed) replaces the placeholder and is not
   re-scanned. Every command goes through the permission policy as a `bash` call
   (ADR 0021) with the entry's `allowed-tools` as extra allow rules: it runs **only on
   `allow`**; `deny` or `ask` aborts the whole invocation with the reason — nobody is asked
   while a command renders, as in Claude Code. A non-zero exit aborts too, except exit 1 of a
   search/compare command (`grep`, `egrep`, `fgrep`, `rg`, `diff`, `cmp`, `test`, `[`). The
   loadguard gate of the `bash` tool (ADR 0018) applies. Settings key
   `disableSkillShellExecution: true` replaces each command with
   `[shell command execution disabled by policy]` instead of running it.
3. **File references** (`/name` only, as in Claude Code's prompt mentions). Each `@path` at
   line start or after whitespace that names an existing file or directory inside the allowed
   roots is attached after the text: a file as `read_file` would return it (counted as read
   for read-before-write, ADR 0023), a directory as a listing. Anything else stays text.

A failed render (abort) sends nothing to the model; the REPL prints the reason, a one-shot run
exits 1.

The `skill` tool (model invocation) uses steps 1 and 2; its result shape (ADR 0026) is
unchanged. A command entry's text has no `Base directory for this skill:` line; a skill's
keeps it.

### 3. Invocation

A line `/name rest` (REPL, the first prompt of the REPL, and a one-shot run) is resolved:

1. a built-in command of that name (§5), unless a user-invocable catalogue entry has the same
   name — then the entry wins, as in Claude Code ("your skill replaces the built-in command,
   but not its aliases"); `/quit`, `/exit`, `:q` always leave;
2. a user-invocable catalogue entry → rendered with `rest`, then sent as one prompt:

       <command-message>NAME is running…</command-message>
       <command-name>/NAME</command-name>
       <command-args>REST</command-args>

       RENDERED TEXT

3. a first word that contains another `/` (a path such as `/etc/hosts is broken`) is an
   ordinary prompt; anything else is `unknown command: /NAME`.

Frontmatter on a `/name` run:

- `allowed-tools` (space/comma list or YAML list, Claude tool names translated by
  `Langertha::Raider::ToolNames`, rule syntax of ADR 0021): extra allow rules for **that run**
  only (source `/NAME allowed-tools`), cleared when it ends; deny and ask rules still win.
  The same grant applies for the rest of the run when the model loads the entry with the
  `skill` tool.
- `model`: the model for that run only (aliases mapped as for subagents, ADR 0020; `inherit`
  or empty is none); not saved. Deviation: on a model-invoked skill `model` is ignored (raider
  cannot switch the engine inside a run).
- `disable-model-invocation`: see §1. `argument-hint` and `description`: shown by `/help`.
  Other keys (`effort`, `context: fork`, `agent`, `hooks`, `shell`) are kept but not acted on;
  `config explain`/`/skills` do not warn about them.

### 4. One-shot runs: `-p` / `--print`

`raider -p "…"` (alias `--print`, as Claude Code) is a one-shot run even on a terminal: the
prompt from argv, else stdin. A one-shot prompt `/name …` goes through §3: a catalogue entry
runs as there; a built-in that only reports (`/help`, `/context`, `/skills`, `/agents`,
`/hooks`, `/memory`, `/permissions`, `/config`, `/stats`, `/metrics`, `/packs`) prints and
exits 0; `/init` and `/compact` run their model turn; the rest (`/clear`, `/prompt`, `/model`
switching, `/pack`, `/reload`) is a usage error in a one-shot run. Unknown → exit 2.

### 5. Built-in commands

Kept: `/clear` (now also `/reset`, `/new`), `/reload`, `/permissions`, `/config`, `/model`,
`/metrics`, `/stats`, `/packs`, `/pack`, `/prompt`, `/skill`, `/skill-claude`. New:

- `/help` — built-ins, then the user-invocable catalogue entries (`/name argument-hint` —
  description, with source).
- `/skills` — every catalogue entry: name, kind, source, model-/user-invocable, shadowed.
- `/compact [instructions]` — summarise the history now (the between-raid summary of
  `Langertha::Raider`), focus instructions passed to the summary.
- `/context` — the context by part with estimated tokens: system prompt (base/mission,
  memory files one by one, skill listing), tool definitions, history; and the model's window
  when known.
- `/memory` — the instruction files loaded and the editable targets (Claude layout:
  `./CLAUDE.md`, `~/.claude/CLAUDE.md`; native: the instructions file), numbered;
  `/memory N` opens one in `$VISUAL`/`$EDITOR` on a terminal (creating it), then reloads the
  context; without a terminal it prints the path.
- `/agents` — the agent catalogue (ADR 0020): name, source, description, tools.
- `/hooks` — the configured hooks by event: matcher, command, source (ADR 0022).
- `/init` — a model turn with Claude Code's `/init` request (analyse the codebase, write or
  improve the instructions file: `CLAUDE.md` in the Claude layout, the native instructions
  file otherwise), with the permission policy as for any prompt.

`/mcp` belongs to stream M1 (ADR 0029).

## Consequences

- Project command files can run shell commands before a prompt is sent — always through the
  permission policy, never asked interactively; in `default` mode only an allow rule (settings
  or `allowed-tools`) lets them run.
- The skill listing grows by the commands; descriptions fall back to the first body line.
- `$1` now means the second argument (Claude Code's current numbering); older command files
  written for `$1` = first argument get the next one.
- Not done (follow-ups on #165): chaining several skills in one line (`/a /b text`), `context:
  fork`, skill `hooks`, `effort`, the listing's character budget, `@file` in ordinary prompts,
  ACP `available_commands`.

## Addendum 1 — decisions taken while implementing (2026-10-19)

- **Roots.** In the Claude layout the native command roots stay in front of the Claude ones
  (`.raider/commands`, `~/.raider/commands`, `~/.claude/commands`, `.claude/commands`, plugin
  commands), as for skills. `--bare` reads none. Command roots come after all skill roots;
  since a skill beats a command anyway, only the order among command roots matters.
- **Shell injection is checked before it runs.** All `!`cmd`` of a body are put to the
  policy first; one refusal aborts before any command ran, so a refused render leaves no side
  effects. Loadguard is checked per command just before it runs. The abort texts follow
  Claude Code: `Shell command permission check failed for pattern "…" in /NAME: REASON`,
  `Shell command failed …: exit code N` and the output.
- **Run rules.** `Langertha::Raider::Permissions` holds run rules (`add_run_rules`,
  `clear_run_rules`); `Application::end_run` clears them on every way a run ends (completed,
  failed, cancelled, interrupted). The `skill` tool adds an entry's `allowed-tools` only after
  a successful render and only inside a run.
- **Run model.** `model:` goes through the subagent model mapping (ADR 0020); a value that
  does not map keeps the current model without a note. An engine that cannot be built ends
  the run `failed`. `end_run` restores the engine.
- **`@path` attachments** are two `<system-reminder>` blocks as Claude Code shows a Read
  (`Called the read_file tool with the following input: {"path":…}`, then `Result of calling
  the read_file tool:` and read_file's text), with raider's tool names. `@"quoted path"`
  works; trailing sentence punctuation is dropped when the path exists without it. A deny or
  ask `Read` rule hides the file (`Permissions::hides_read`). Images and PDFs stay text.
- **Dispatch is fail-safe.** A catalogue that cannot be read counts as empty (an unknown
  command then also names the read error); a built-in that dies prints `error: /NAME: …`.
- **One-shot.** A render error goes to stderr with exit 1, no machine document. `-p` with no
  prompt words reads stdin to its end, also on a terminal (Claude Code refuses there).
  `-p` with `-i` is a usage error.
- **`/compact`** records nothing in the journal (ADR 0015 has no compaction event); a resumed
  session gets the full history back. Claude Code's `PreCompact`/`PostCompact` hooks are not
  fired. Both are follow-ups on #165.
- **`/context`** estimates tokens as characters / 4, the rule of the in-raid compaction.
