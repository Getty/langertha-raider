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
`config explain` as not used by raider. `permissionMode` too: a subagent runs in its caller's
mode (§4), and nothing in a file may widen that (ADR 0021 §1, `for_subrun`).

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

An `agent` call passes the caller's gate like any other call (ADR 0021). Without a rule it
is allowed in every mode — `ToolEffects` gives it no effects, so the modes treat it like a
reading tool: starting a subagent changes nothing by itself, and every call the subagent
makes goes through the policy it inherits (§4). Rules decide otherwise: `Agent(name)` /
`Task(name)` as deny refuses starting that agent (an error result, no `agent.started`), as
ask puts the spawn to the person (refused when nobody can be asked). A call without
`subagent_type` counts as `general-purpose` for these rules, so leaving the argument out
does not get around `Agent(general-purpose)`.

### 4. The subagent run

- **Same process, same loop.** A subagent is a new `Langertha::Raider` on the parent's loop
  (ADR 0016), awaited by the parent's `agent` call; its last assistant text is the tool
  result. A failure is an error result with the reason; cancelling the parent cancels the
  subagent; it gets the parent's `max_iterations`.
- **Own context.** Empty history: the subagent sees only its prompt, never the parent's
  conversation. Its mission is compiled like the parent's with the agent body in the place
  of raider's persona and native instructions — exactly what `-M` replaces (ADR 0014) — so
  Claude memory items stay, as in Claude Code. The skill listing stays when the subagent's
  tool set has `skill`; without it the listing would point at a tool it cannot call.
- **Own tool set.** The caller's active set filtered by §2, then: `ask_user` is removed (a
  subagent has nobody to ask, as in Claude Code), and `agent` is removed at the depth limit.
  Stateful tools (`todo_write`) get their own instance, so a subagent's list does not
  overwrite the caller's. The subagent's prompt and catalogue derive from this set alone
  (ADR 0005).
- **Inherited permissions** (ADR 0021). The subagent's policy is the caller's
  `for_subrun`: the mode the caller has when the `agent` call starts, the same rules and
  additional directories, and the *same* session rules. Its raider gets the application's
  gate with that policy, so each of its tool calls is decided as the caller's would be — a
  write refused in a non-interactive `default` run is refused in its subagent, a deny rule
  holds in both, `bypassPermissions` lets both write. A call the policy asks about goes to
  the same person (`on_permission_request`: the subagent has no `ask_user`, but approving a
  tool call is the surface's question, not the model's); "yes, for this session" adds a
  session rule both policies see, "yes, once" is bound to the subagent's own session and
  run. With nobody to ask it is refused, as in the caller. The subagent's `permission.*`
  events go to its journal only. A mode change stays with the policy that made it: the
  subagent gets its own `exit_plan_mode` (when the caller's set has one), which never
  switches a mode and in plan mode tells the model to give its plan as its answer — the
  caller gets it. A nested subagent inherits from its caller, not from the main run.
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
  (ADR 0013, 0015). A child session is never the "latest" session that `--continue`
  resumes; `session list` shows its parent and agent.
- **One after the other.** The raid loop awaits tool calls in turn and in-process tool
  calls block, so several `agent` calls of one model turn run sequentially. The tool text
  does not promise concurrency; running them in parallel is follow-up work.

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
  not model-invocable), then Skilletor
  (`Langertha::Raider::SkillResolver::Skilletor`, the Perl dist `Skilletor`): a skill
  that one of `~/.claude/skilletor.json`, the project's `.claude/skilletor.json` or
  `.claude/skilletor.local.json` declares, read straight from its source — the `local`
  directory or the shared cache `~/.claude/skilletor/cache/<hash>/` the skilletor CLI fills
  too — without installing anything (`Skilletor->resolve_item`). The catalogue wins for a
  name both know: an installed copy is what Claude Code would load.
  - **Lazy.** Skilletor is asked only for a name the catalogue does not know, and only when
    one of those files exists: a project without skilletor sees no lock, no cache, nothing
    written under the home. One resolution serves every later name.
  - **Fetch once** (`fetch => 'missing'`): a source without a cache is fetched (git, https
    tarball) the first time one of its skills is needed, and served from the cache
    afterwards, so a spawn does not touch the network each time; keeping the cache current
    stays the skilletor CLI's job (`skilletor sync`).
  - **Claude layout only.** `skilletor.json` is Claude Code configuration and lives in
    `.claude/`; a native or raider project (and `--bare`) reads no `.claude/` at all
    (ADR 0019), so its chain is the catalogue alone. Skilletor finds its files under
    `$HOME/.claude`, as the skilletor CLI does — `$CLAUDE_CONFIG_DIR` is not consulted for
    them.
  - **Never fatal.** A templated skill (`.njk`, which the Perl port does not render), a
    broken `skilletor.json`, a source that cannot be fetched or is not trusted yet: the
    name does not resolve, and the resolver gives the reason (`why_unresolved`).
- **Unknown skill: no spawn.** If any declared skill does not resolve, the `agent` call is
  an error result `briefing: agent 'NAME' references unknown skill(s): a, b` and no
  subagent starts — never a partial briefing (briefing's hard-fail policy): no child
  request, no child session, no `agent.started`. A name a resolver can say more about is
  followed by its reason (`… unknown skill(s): a (skilletor: a@src is a template;
  templates are not supported in Perl), b`); without reasons the text is briefing's word
  for word. `config explain` reports such agents up front, as `briefing doctor` does,
  with the reasons, and marks each declared skill found through skilletor with its source
  (oversized briefings are not flagged there yet).
- **Budget.** Above 64 KB of skill text the spawn goes ahead with an `agent.warning` event
  (`call`, `agent`, `message` = the briefing size note) before `agent.started`; the parent's
  journal records it.
- The child's journal `message` is the briefed prompt — what the child was actually sent.

### 7. Hooks around and inside a subagent (Claude layout, ADR 0022)

- **Native briefing wins.** Raider briefs every agent itself (§6), so the hook runner runs
  with `native_briefing` (ADR 0022 §7): hooks whose command is the briefing plugin's
  `briefing-preload` are skipped — reported as `skipped` — on `PreToolUse` for `Agent` and
  on `SubagentStart`. Running them too would put every skill body into the prompt a second
  time, or deny a spawn raider briefs correctly, since the plugin resolves skills through
  its own copy of the lookup. Only those hooks are skipped: every other `PreToolUse` hook
  on `Agent`/`Task` runs through the generic tool path (ADR 0022 §4), and its
  `updatedInput` — a rewritten `prompt`, another `subagent_type` — is what the spawn gets.
  Briefing's `SessionStart` check still runs.
- **`SubagentStart`** fires once the subagent's session exists and before its first
  request — not for a spawn §6 refuses — with `agent_id` and `agent_type` (the agent's
  name, which the matcher is tested against) besides the caller's session fields.
  `agent_id` is the child session's id; without a session (a library run,
  `--no-session`) it is `local-agent-<pid>-<address>`, unique while the subagent runs.
  Its `additionalContext` goes **in front of the briefed prompt**, as a
  `<system-reminder>` block worded like the main run's prompt context ("SubagentStart hook
  additional context: …"), so the child sees it first and its journal `message` shows it.
  `continue: false` fails the subagent before its first request ("a SubagentStart hook
  stopped it: <reason>"; `agent.started` and a failed `agent.finished`, no prompt
  journaled).
- **`SubagentStop`** fires after the subagent's final answer, mirroring `Stop` of the main
  run (ADR 0022 §4): input adds `agent_transcript_path` (the child journal),
  `stop_hook_active`, `last_assistant_message`; a block (or `additionalContext`) sends
  "SubagentStop hook feedback:\n<reasons>" back to the subagent as its next message and
  it goes on, at most `stop_hook_limit` (8) times; the turns in between go into the child
  journal. `continue: false` ends it without a continuation.
- **The subagent's own tool calls** run `PreToolUse` (its raider gets the tool hook) and
  `PostToolUse` like the caller's, with `agent_id`, `agent_type` and the subagent's
  `permission_mode` in the input, as Claude Code sends them inside a subagent; a hook's
  allow/ask is weighed by the subagent's gate. `continue: false` there cancels the
  subagent, not the caller's run.
- **Where the reports go.** `hook.ran`/`hook.message` of `SubagentStart` and
  `SubagentStop` go to the caller's stream and journal, beside `agent.started` /
  `agent.finished`; those of the subagent's own tool calls go to its journal only, like
  its `permission.*` events — the person does not see a subagent's `systemMessage` live
  yet (follow-up).

## Consequences

- Every raider run now has the `agent` tool (below the depth limit), so tool lists in
  prompts and golden tests grow by one entry.
- Raider reads agent files written for Claude Code without a plugin and without Node; the
  repository's own `.claude/agents/raider-*.md` are the real test case.
- `Skilletor` is a hard dependency (loaded with the context); resolving through it may run
  `git` or fetch a tarball the first time a source is needed, which the standalone binary
  has to carry.
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
