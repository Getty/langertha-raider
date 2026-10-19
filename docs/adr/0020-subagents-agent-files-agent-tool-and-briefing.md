# ADR 0020 — Subagents: agent files, the agent tool and briefing

- Status: accepted
- Date: 2026-10-19
- Tags: agents, tools, skills, sessions, claude-code
- karr: #153 (stream A of the Claude Code flow plan)

## Context

Claude Code offers subagents: Markdown files with YAML frontmatter in `.claude/agents/`,
`~/.claude/agents/` and enabled plugins, started through its `Agent` (formerly `Task`) tool
with `description`, `prompt` and `subagent_type`. A subagent has its own context window, its
own system prompt (the file body), an optional tool restriction (`tools`,
`disallowedTools`), an optional model (`model`), and returns its last text to the caller.
The briefing plugin (`~/dev/briefing`) adds `briefing.skills`: skill bodies put in front of
the subagent's prompt at spawn time, a spawn refused when a declared skill is unknown.

Raider has none of this. ADR 0011 reserved `raiders/<name>.yml` for named agents and left
the schema open; nothing reads it. ADR 0019 brought the Claude layout and the skill
catalogue, ADR 0018 the Claude tool-name table (`Langertha::Raider::ToolNames`), which
already maps `Task` and `Agent` to `agent`. ADR 0016 requires one event loop per raid.

## Decision

### 1. One agent-definition format, found in fixed roots

An agent is a Markdown file with YAML frontmatter, Claude Code's format, in every location.
ADR 0011's `raiders/<name>.yml` is replaced by `agents/<name>.md` (native and Claude layout
use the same file format and the same directory name as plugins and the `agent` tool); it
was never implemented, so nothing migrates.

Agent roots, highest precedence first (the first agent of a name wins; later ones are
reported as shadowed):

1. native: `.raider/agents/`, then `~/.raider/agents/`;
2. Claude layout only (ADR 0019 §1): `.claude/agents/` of the project, then the user's
   `~/.claude/agents/` (`$CLAUDE_CONFIG_DIR` respected) — Claude Code's order for agents
   (project before user, unlike skills);
3. Claude layout only: the agents of every installed **and** enabled plugin (the plugin's
   `agents/` plus the manifest's `agents` paths, inside the plugin root), named
   `plugin:agent` — never shadowed.
4. the built-in `general-purpose` agent, unless a file agent of that name shadows it.

`--bare` reads no agent root at all; only `general-purpose` is left (as with skills).

Every root is walked recursively for `*.md`; hidden files and directories (`.local.*`
overrides, editor files) are skipped. The agent's name is the frontmatter `name`, else the
file name without `.md` (briefing's rule). A file without `description` is not an agent: it
is skipped and reported. Frontmatter is read with the lenient reader of
`Context::Skills` (YAML first, `key: value` lines as fallback).

### 2. Frontmatter

| key | meaning in raider |
|---|---|
| `name`, `description` | identity and the line in the agent tool's text |
| `tools` | allow-list (comma-separated string or YAML list). Claude names go through `ToolNames`; raider names are taken as they are; `mcp__*` passes through. Absent, empty or `*`: every tool of the parent's active set. A list whose names are all unknown means no tools (the safe side). |
| `disallowedTools` | removed from the result of `tools` (same name rules) |
| `model` | §5 |
| `skills` (Claude Code's own) and `briefing.skills` | §6; both are honoured, `skills` first, duplicates once |
| body | the agent's instructions (§4) |

A name in `tools`/`disallowedTools` that is neither a raider tool nor in the table (Claude
Code's `NotebookEdit`, `KillShell`, …, and permission patterns such as `Bash(git:*)`, which
would grant more than they say if read as `bash`) is ignored and reported by `config explain`; refusing
the whole agent would make most agents written for Claude Code unusable. Every other key
(`color`, `permissionMode`, `hooks`, `mcpServers`, `maxTurns`, …) is kept and listed by
`config explain` as not used by raider; `permissionMode` is for stream P.

### 3. The `agent` tool

A stock tool `agent` with Claude Code's parameters: `description` (a short label),
`prompt` (the task), `subagent_type` (optional, default `general-purpose`). Its text says
what Claude Code's says and lists every agent as `- name: description (Tools: …)`, the tools
in raider names, `*` for "all of the caller's". The built-in `general-purpose` has Claude
Code's description and all of the caller's tools. An unknown `subagent_type` is an error
result that names the available agents.

The tool is mounted whenever the run is below the depth limit (§4); it is part of the one
active tool set (ADR 0005). Effect class: none of its own — the subagent's tool calls carry
their effects in the subagent's journal.

### 4. The subagent run

- **Same process, same loop.** A subagent is a new `Langertha::Raider` on the parent's loop
  (ADR 0016), awaited by the parent's `agent` call; its last assistant text is the tool
  result. A failure is an error result with the reason; cancelling the parent cancels the
  subagent; it gets the parent's `max_iterations`.
- **Own context.** Empty history: the subagent sees only its prompt, never the parent's
  conversation. Its mission is compiled like the parent's with the agent body in the place
  of raider's persona and native instructions — exactly what `-M` replaces (ADR 0014) — so
  Claude memory items and the skill listing stay, as in Claude Code.
- **Own tool set.** The caller's active set filtered by §2, then: `ask_user` is removed (a
  subagent has nobody to ask, as in Claude Code), and `agent` is removed at the depth limit.
  Stateful tools (`todo_write`) get their own instance, so a subagent's list does not
  overwrite the caller's. The subagent's prompt, catalogue and approval gate derive from
  this set alone (ADR 0005); which permission mode it inherits is stream P's to wire.
- **Depth limit.** `max_agent_depth` (config key, default 1): the main run has depth 0, a
  subagent of it depth 1, and a run at depth `max_agent_depth` gets no `agent` tool. The
  default is Claude Code's behaviour (subagents cannot start subagents); a higher value
  allows nesting.
- **Journal as a child session.** When the calling run has a session, the subagent gets its
  own session in the same store: `session.created` carries `parent` (the caller's session
  id), `parent_call` (the `agent` tool call id), `agent` (the name) and `depth`; its run
  journals as any run does. The caller's journal and event stream get `agent.started`
  (`call`, `agent`, `description`, `session`, `model`) and `agent.finished` (`call`,
  `agent`, `session`, `status`). The subagent's own events go only to its journal, so a
  consumer of the caller's stream keeps one run per stream. New types need no new `v`
  (ADR 0013, 0015).

### 5. Model mapping

`model` absent or `inherit`: the caller's engine and model. `sonnet`, `opus`, `haiku` or a
full `claude-*` model id: only when the caller's engine is the Anthropic API
(`isa Langertha::Engine::Anthropic`, not the other Anthropic-dialect engines) — the
subagent then gets an engine of the same class and arguments with that model, on the same
loop. The aliases resolve through one table (`opus` → `claude-opus-5-5`, `sonnet` →
`claude-sonnet-5-5`, `haiku` → `claude-haiku-5-5`), overridable per alias by the config key
`agent_models`. In every other case the subagent inherits, and `config explain` says why
("model sonnet: inherited, engine openai is not the Anthropic API"). Never an error: an agent
file must run under any engine.

### 6. Skills as includes (briefing)

The skills an agent declares (§2) are resolved when it is spawned, put in front of the task
in briefing's format, and the result is the subagent's prompt:

```
# Briefing — pre-loaded skills

The skills below have been injected directly into your context by the
briefing plugin, one <skill> element each. Treat them as already loaded —
do NOT call the Skill tool for any of these names; their content is already here. …

<skill name="NAME" dir="/abs/skill/dir">
BODY WITHOUT FRONTMATTER
</skill>

---

# Original task

PROMPT
```

The header is briefing's text word for word, so an agent behaves the same under Claude Code
with the briefing plugin and under raider.

- **Resolution.** A skill name is resolved through a chain of resolvers behind one
  interface (`resolve(name)` → name, directory, `SKILL.md`, or nothing): first the skill
  catalogue of the context (ADR 0019 §4 — every root and plugin, including skills that are
  not model-invocable), then Skilletor (the sources declared in `skilletor.json`, read
  straight from the source without installing — wired once the Skilletor dist is on main;
  until then the chain has only the catalogue).
- **Unknown skill: no spawn.** If any declared skill does not resolve, the `agent` call is
  an error result `briefing: agent 'NAME' references unknown skill(s): a, b` and no
  subagent starts — never a partial briefing (briefing's hard-fail policy). `config explain`
  reports such agents up front, as `briefing doctor` does.
- **Budget.** Above 64 KB of skill text the spawn goes ahead with a warning event (the
  briefing size note); the parent's journal records it.

## Consequences

- Every raider run now has the `agent` tool (below the depth limit), so tool lists in
  prompts and golden tests grow by one entry.
- Raider reads agent files written for Claude Code without a plugin and without Node; the
  repository's own `.claude/agents/raider-*.md` are the real test case.
- A subagent costs a second conversation on the same engine; nothing limits how many
  subagents a run starts except `max_iterations` of the caller.
- Not covered: background subagents, agent-scoped `mcpServers` and `hooks`, `maxTurns`,
  the CLI `--agents` JSON, resuming a subagent by id, the Hall's per-raider definitions
  (they are expected to become agent files, follow-up).

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream A), maintainer's go-ahead 2026-10-19; karr #153. Briefing format:
`~/dev/briefing/hooks/briefing-preload`. Replaces the `raiders/<name>.yml` part of ADR 0011;
builds on ADR 0005, 0014, 0016, 0018, 0019.
