# ADR 0022 — Claude Code hooks

- Status: accepted
- Date: 2026-10-19
- Tags: claude-code, hooks, tools, policy, cli
- karr: #155 (stream H of the Claude Code flow plan)

## Context

In a Claude Code project raider is to behave like Claude Code (ADR 0019). Claude Code runs
*hooks* — commands from the settings files and from enabled plugins — at fixed points of a
session: before and after a tool call, when a prompt is submitted, when the session starts,
when the model stops. They can block a tool call or a prompt, rewrite a tool's arguments, add
context for the model, show a message to the person, keep the model going. ADR 0019 §3 read
the `hooks` of the settings and stored them; nothing ran them. Plugins people actually use
depend on them: briefing (`PreToolUse` on `Agent` rewrites the subagent's prompt with the
skills it declares), loadguard (`PreToolUse` on `Bash` refuses heavy commands under memory
pressure), skilletor (`SessionStart` syncs skills and reports in a `systemMessage`).

The reference is Claude Code's documentation, fetched 2026-10-19:
`https://code.claude.com/docs/en/hooks` (events, matchers, handler fields, exec and shell
form, input and output, exit codes, timeouts, async), `.../permissions` ("Precedence among
rules, hooks, and mods", "Hook approvals in plan mode") and `.../plugins/plugins-reference`
(`${CLAUDE_PLUGIN_DATA}` and how its id is built). Where raider differs, it says so below.

## Decision

### 1. Where hooks come from, and when they run at all

Only in the Claude layout (ADR 0019 §1). A native or raider project, `--bare` and the home
directory run none, whatever `.claude/settings.json` says. The sources, in this order:
`~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`
(`Context::Settings->hooks`), then every installed and enabled plugin in
`Context::Plugins` order — its `hooks/hooks.json` (the event map under a top-level `hooks`)
and the manifest's `hooks` (a file path inside the plugin, an inline map, or a list of both;
a file named twice counts once). Every group keeps its source (the settings label, or
`plugin:<name>`). `disableAllHooks` — the last settings file that sets a JSON boolean wins —
turns them all off. A broken plugin hooks file is reported (`hook.message`, once), never
fatal. Managed settings, skill and agent frontmatter hooks do not exist in raider.

### 2. The runner: `Langertha::Raider::Hooks`

An internal module (ADR 0017) that runs the hooks of one event and merges what they say into a
`Langertha::Raider::Hooks::Result`; acting on it is the caller's business. `run_f($event,
\%input)` takes the input in raider form and never fails.

- **Matchers** as Claude Code's: `*`, empty or missing match all; only letters, digits, `_`,
  `-`, spaces, `,`, `|` is a list of exact names; anything else is an unanchored regular
  expression (Perl's; the common syntax is JavaScript's too). The field matched: the tool
  name for the tool events, `source` for `SessionStart`, `agent_type` for
  `SubagentStart`/`SubagentStop`, `reason`, `trigger`, `notification_type` for the events
  that have them; every other event ignores the matcher. An invalid expression skips its
  group and is reported. Tool names are Claude Code's (`ToolNames->claude_name`; `mcp__*`
  unchanged; a raider-only tool keeps its raider name, so only match-all groups see it).
- **Only `type: command` runs.** `http`, `mcp_tool`, `prompt` and `agent` hooks are skipped
  and reported. `if` (permission rule syntax) runs only on tool events; it is decided by
  `Permissions->rule_matches` (the deny/ask way of matching: any part of a bash command);
  a rule raider cannot decide runs the hook, as Claude Code does when it cannot tell.
- **Exec form when `args` is present** (`command` is spawned directly, looked up on `PATH`,
  every `args` element one argument, no shell), **shell form otherwise** (`sh -c`; `shell:
  bash` uses bash; PowerShell is not supported). The docs' table gives `"bash"` as the
  `shell` default while its text says shell form is `sh -c` on Linux; raider follows the text.
- **Placeholders** `${CLAUDE_PROJECT_DIR}`, and for plugin hooks `${CLAUDE_PLUGIN_ROOT}` and
  `${CLAUDE_PLUGIN_DATA}`, are replaced in `command` and every `args` element and exported to
  the process (inherited `CLAUDE_PLUGIN_*` removed for settings hooks). The data directory is
  `<claude_home>/plugins/data/<id>`, the id being the plugin key with every character other
  than a letter, digit, `_` or `-` replaced by `-` (`briefing@getty` → `briefing-getty`);
  it is created before a plugin hook runs. `${user_config.*}` is not supported.
- **Processes**: each hook in its own session (`setsid`, no terminal, as in Claude Code), in
  the root, all hooks of an event in parallel, on the raid's loop (ADR 0016). The same
  command (with the same `args`) from several settings files runs once; a plugin's copy runs
  separately.
- **Timeouts** in seconds: 600, 30 on `UserPromptSubmit` (the docs' defaults). Over time:
  `TERM` to the process group, `KILL` two seconds later, output discarded, a non-blocking
  error. `onFailure: "block"` makes a failed or timed-out hook do what exit 2 does on its
  event (not on `Stop`, `SubagentStop`, `TaskCompleted`, `TeammateIdle` or async hooks).
- **Async** (`async`, and `asyncRewake` the same — raider has no idle session to wake): not
  waited for, no timeout, no decision; their `additionalContext` and `systemMessage` are
  collected (`take_async_results`) and delivered with the next prompt. `shutdown` stops the
  rest (`TERM`, then `KILL`), as `claude -p` does at its end.
- **Input on stdin**: the caller's fields plus `hook_event_name` and `cwd`. Tool events get
  `tool_name` in Claude's name and `tool_input` in Claude's form
  (`ToolNames->claude_input`); `file_path` of `Read`/`Write`/`Edit` is absolute, as Claude
  Code hands it.
- **Reading the answer**, as the docs' table: stdout that is one JSON object is the answer,
  anything else plain text, `{…}` that does not parse invalid. Exit 0: the fields apply.
  Exit 2: blocks (a `PreToolUse` deny; a block on `UserPromptSubmit`, `PostToolUse`,
  `PostToolUseFailure`, `Stop`, `SubagentStop`, `PreCompact`, …), stderr is the reason unless
  the JSON gives one, and the JSON cannot undo it; on an event that cannot block it is a
  non-blocking error. Other exit codes: a valid JSON answer decides (Claude Code ignores the
  code then), otherwise a non-blocking error with the first stderr line. `hookSpecificOutput`
  must name its event. On `Stop`, `SubagentStop` and a plugin's `UserPromptSubmit`, exit 2
  with empty stdout and "No such file or directory" is a missing script, not a block.
- **Merging**: `continue: false` wins over everything (`stopped`, the first `stopReason`).
  `PreToolUse`: deny > ask > allow, the reasons of the winning decision in configuration
  order; `defer` (Claude Code's `-p` only) counts as no decision; the deprecated top-level
  `approve`/`block` count as allow/deny. `updatedInput` replaces the whole input (the docs'
  rule); the hooks of one event run in parallel on the same input and cannot build on each
  other, so **the last one in configuration order wins** and two different ones are
  reported; it is translated back with `ToolNames->raider_input`, a `file_path` that is still
  the absolute form of the original relative `path` gets the original back, and it never
  applies to a denied call. `additionalContext`, `systemMessage` and plain-text context
  (`UserPromptSubmit`, `SessionStart`) are collected, never merged away.
- **A report per hook** (source, plugin, command, outcome, exit, duration, output) — the
  journal's `hook.ran`.

### 3. Argument translation in `ToolNames`

`claude_input($tool, \%args)` / `raider_input($tool, \%args)`: `path` ↔ `file_path` for
`read_file`, `write_file`, `edit_file`; the `bash` `timeout` seconds ↔ milliseconds (whole
seconds from raider, milliseconds rounded up to a whole second back); every other key passes
unchanged, because raider's tools took Claude Code's names where they have the argument
(`old_string`, `pattern`, `glob`, `output_mode`, `-i`, `command`, `url`, `todos`, `skill`,
`prompt`, `subagent_type`, `plan`, …). `ask_user` differs in shape, not names (a `question`
and option strings against `questions` objects); no lossless mapping exists, so its
arguments pass unchanged. The round trip is lossless unless an input carries both names of
one argument (then the translated key wins).

### 4. Where the events fire

- **`PreToolUse`** — the raider's new `_tool_hook` (constructor-only, internal, like
  `_tool_gate`; only the application sets it, only in the Claude layout): after
  `plugin_before_tool_call`, **before the inputSchema check and the gate**, on the call as
  it would run. A deny (or exit 2) does not run the call: an error result "Tool call 'X' was
  denied: PreToolUse hook: <reason>" through `plugin_after_tool_call`, so the call keeps one
  `tool.call` and one `tool.result`. `updatedInput` replaces the arguments, which are then
  schema-checked and gated like the model's. Its `additionalContext` is appended to the tool's
  result. `tool.call` in the journal stays the model's call; the rewrite is in `hook.ran`.
- **The gate weighs a hook's allow/ask (ADR 0021)**, as Claude Code's permissions page
  says: hook decisions never bypass permission rules. A deny — by a rule, by plan mode —
  stays. `allow` lifts only an ask of the *mode* (the prompt), never an ask rule. `ask` turns
  an allow (by a rule or the mode, `bypassPermissions` included) into an ask, which takes
  ADR 0021's path: the person is asked, or nobody can and it is refused — without suggesting
  a rule, since a rule cannot lift a hook's ask. In plan mode an allow changes nothing for a
  change, as the docs' "Hook approvals in plan mode" says.
- **`PostToolUse`** — `Langertha::Raider::Plugin::ClaudeHooks`, after NestedMemory and before
  Events, so `tool.result` is the result as the model gets it. Only for a result that is not
  an error and was not cancelled. `tool_response` is raider's result (an MCP `content` list),
  not Claude Code's per-tool shapes. `additionalContext`, and the reason of a `decision:
  "block"` or the stderr of exit 2 (the tool already ran: feedback), are appended as
  `<system-reminder>` blocks (`PostToolUse:Bash hook additional context: …`), the way
  NestedMemory appends.
- **`SessionStart`** — before the first prompt of a session: `startup` for a new session or
  a run without one, `resume` after `replay_session` (`--continue`/`--resume`), `clear` after
  `/clear`. `compact` is not fired: raider's compaction happens inside a raid with no point
  that matches Claude Code's (follow-up). Its context goes in front of that first prompt.
- **`UserPromptSubmit`** — before every prompt (`run_prompt`, which every surface uses). A
  block (or `continue: false`) means the model never sees the prompt; the run ends `failed`
  with "The prompt was blocked by a UserPromptSubmit hook: <reason>" (no new run status,
  ADR 0013). Plain stdout and `additionalContext` go in front of the prompt as
  `<system-reminder>` blocks; the journal's `message` keeps the prompt as typed.
- **`Stop`** — after the model's final answer. A block (or `additionalContext`) sends
  "Stop hook feedback:\n<reasons>" back as the next user message with `stop_hook_active`
  true; the answer before it and the feedback go into the journal as `message`s, so a resume
  replays the conversation as it went. At most `stop_hook_limit` (8, Claude Code's cap)
  continuations per run; then the run ends and that is reported.
- **Async results** are taken before each prompt; **`shutdown_hooks`** stops async hooks when
  the command line is done (one-shot after its run, the REPL when it ends); `/reload` builds
  the runner anew from the settings and plugins it reread.
- `continue: false` on a tool event cancels the run (`cancelled`, ADR 0009); on `Stop` it
  ends without a continuation.

### 5. Input fields raider sends

`session_id` (the session's id, else a stable per-application stand-in), `transcript_path`
— **the session journal (raider's JSONL, ADR 0015), not Claude Code's transcript format**;
absent without a session — `cwd`, `permission_mode` (ADR 0021's mode names are Claude Code's),
`hook_event_name`, and per event `tool_name`/`tool_input`, `tool_response`, `prompt`,
`source` and `model`, `stop_hook_active` and `last_assistant_message`. Not sent:
`tool_use_id`, `prompt_id`, `effort`, `scratchpad_dir`, `mcp_server`, `duration_ms`,
`background_tasks`, `session_crons`, `agent_id` / `agent_type` (no subagents yet).

### 6. Events and display

`hook.ran` (hook_event, source, plugin, matcher, command, args, outcome, exit, duration_ms,
message, stdout/stderr cut at 2000 characters) for every hook; `hook.message` (hook_event,
kind `system` | `error` | `stopped`, text) for a `systemMessage`, a non-blocking error or a
stop. Both go into the session journal and to `on_event`; per ADR 0013/0015 new event types
need no new version. The command line shows `hook.message` as a meta line (`hook: …`,
`hook error: …`); `--stream-json` carries both.

### 7. Briefing loaded natively (interface for stream A)

When raider loads an agent's `briefing.skills` itself (stream A), the briefing plugin's
`briefing-preload` must not load them a second time: it would put every skill body into the
prompt twice, or deny a spawn raider briefs correctly, as it resolves skills through its own
copy of the lookup. The runner's `native_briefing` skips hooks whose command is
`briefing-preload` on `PreToolUse` for `Agent` and on `SubagentStart` (reported as
skipped); briefing's `SessionStart` check still runs. Raider's own loading wins. Off until
stream A sets it with its native loading. `SubagentStart`/`SubagentStop` are supported by
the runner (matcher on `agent_type`, `additionalContext`, Stop-style decisions) but fired
nowhere yet: stream A fires them around a subagent run, with `agent_id` / `agent_type`.

### 8. Workspace trust

ADR 0004's trust decision still does not exist. Hooks run in the Claude layout without
asking, exactly as the instruction files are loaded (ADR 0019) — and as `claude -p` runs a
repository's hooks without its trust dialog. The ways out: `disableAllHooks` in the
settings, a raider project (`.raider/`), `--bare`. When ADR 0004's trust lands, hooks of an
untrusted folder are among the first things it gates.

## Not supported

`http`, `mcp_tool`, `prompt`, `agent` hooks; `shell: powershell`; `${user_config.*}` and
`CLAUDE_PLUGIN_OPTION_*`; `defer`; `updatedToolOutput`; `PostToolUseFailure`,
`PermissionRequest`, `PermissionDenied`, `Notification`, `PreCompact`/`PostCompact`,
`SessionEnd` and the other events not named in §4 (the runner handles any event; nothing
fires them); SessionStart's `initialUserMessage`, `sessionTitle`, `watchPaths`,
`reloadSkills`; the 10,000-character cap and its spill file; skill and agent frontmatter
hooks; managed settings and `allowManagedHooksOnly`; the prompt builder's raider runs no
hooks (it is raider's own tool, not a Claude Code session).

## Consequences

- A Claude Code project's hooks now act on raider: a policy hook refuses calls, a context
  hook feeds the model, a Stop hook can keep a run going (at most 8 times). Tests that run
  in a Claude layout must isolate `$HOME` / `$CLAUDE_CONFIG_DIR` (already the rule).
- Running hooks means running external programs from the packed binary through
  `IO::Async::Process` (fork, `setsid`, `exec`). No new dependency, nothing loaded by name;
  the packed binary still needs a check (stream B).
- Follow-ups: `compact` for `SessionStart`; `PostToolUseFailure`; `tool_use_id` (the raider
  has no stable tool call id at the hook yet); the subagent events and `native_briefing`
  with stream A; the session store makes `.raider/` in a Claude-only project on the first
  saved session, so the next start reads it as a raider project and runs no hooks (nor the
  rest of the Claude layout) — a stream K question, noted on the card.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md` (stream H);
the coordinator's decisions for k155 (design questions decided by the stream, maintainer's
go-ahead). Complements ADR 0005 (gate), ADR 0016 (one loop), ADR 0018 (`ToolNames`),
ADR 0019 (settings, plugins), ADR 0021 (permissions).
