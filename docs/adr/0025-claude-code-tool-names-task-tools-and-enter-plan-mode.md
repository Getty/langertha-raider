# ADR 0025 — Claude Code tool names, the task tools, and enter_plan_mode

- Status: accepted
- Date: 2026-10-19
- Tags: tools, claude-code, policy, scenarios
- karr: #159 (stream D, worker C; points 6 and 7 of the list on #156)

## Context

`Langertha::Raider::ToolNames` (ADR 0018) is the one place that says which raider tool a
Claude Code tool name means; agent files, permission rules, hooks and the session converter
(`maint/claude-log-to-scenario`) all go through it. Stream L compared raider with real Claude
Code sessions (#156) and found three gaps in the table:

- `MultiEdit` mapped to `edit_file` with its `edits` list passed through, which `edit_file`
  cannot take; the converter split it into one `edit_file` per edit. Stream D (worker A) builds
  a `multi_edit` tool.
- `BashOutput` / `KillShell` / `TaskStop` had no target; stream D (worker B) builds
  `bash_output` and `kill_shell` (ADR 0024).
- Current Claude Code replaced `TodoWrite` with `TaskCreate`, `TaskUpdate`, `TaskList` and
  `TaskGet`, and has `EnterPlanMode` next to `ExitPlanMode`; the table knew none of them.

Sources, read 2026-10-19 (wording and behaviour only, no content copied):

- the local Claude Code sessions, `~/.claude/projects/**/*.jsonl` (4644 files): every
  `tool_use` name with its count, the tool lists of the `deferred_tools_delta` attachments, and
  the `tool_result` texts of `TaskCreate`, `TaskUpdate`, `TaskStop`;
- the installed Claude Code 2.1.303 (the bundled JavaScript in the binary): the definitions of
  `TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet` (input schema, results), `TodoWrite`
  (`isEnabled` is the negation of the task tools' switch `CLAUDE_CODE_ENABLE_TASKS`),
  `EnterPlanMode` (no input, result text, the "Enter plan mode?" dialog with "Yes, enter plan
  mode" / "No, start implementing now", "Only the main session can enter plan mode."),
  `TaskStop` (`task_id`, deprecated `shell_id`, aliases `KillShell` and `KillBash`) and the set
  of removed tool names (`TaskOutput`, `BashOutput`, `AgentOutput`, ...);
- Claude Code 1.0.98 (`node_modules/@anthropic-ai/claude-code/cli.js` of an old checkout):
  `BashOutput` (`bash_id`, `filter`), `KillBash` (`shell_id`), `MultiEdit`, `SlashCommand`;
- Claude Code 2.1.274 (a container image's npm install): `sdk-tools.d.ts`, the SDK's types of
  every tool input, and in its bundle the `TaskOutput` schema — `task_id`, `block` (default
  `true`), `timeout` (milliseconds, default 30000, at most 600000).

## Decision

### 1. The table

| Claude Code name | raider tool | arguments |
|---|---|---|
| `Read` | `read_file` | `file_path` ↔ `path` |
| `Write` | `write_file` | `file_path` ↔ `path` |
| `Edit` | `edit_file` | `file_path` ↔ `path` |
| `MultiEdit` | `multi_edit` | `file_path` ↔ `path`; `edits` unchanged |
| `Bash` | `bash` | `timeout` ms ↔ s |
| `TaskOutput` | `bash_output` | `task_id` ↔ `bash_id`, `timeout` ms ↔ s, `block` written down (§5) |
| `BashOutput` (older) | `bash_output` | unchanged (`bash_id`, `filter`) |
| `TaskStop`, `KillShell`, `KillBash` | `kill_shell` | `task_id` ↔ `shell_id`; `shell_id` passes |
| `Glob`, `Grep` | `glob`, `grep` | unchanged |
| `LS` (gone from current Claude Code) | `list_files` | unchanged |
| `WebFetch`, `WebSearch` | `web_fetch`, `web_search` | unchanged |
| `TodoWrite` | `todo_write` | unchanged |
| `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet` | `task_create`, `task_update`, `task_list`, `task_get` | unchanged |
| `Task`, `Agent` | `agent` | unchanged |
| `Skill` | `skill` | unchanged |
| `AskUserQuestion` | `ask_user` | shape differs, passes unchanged (ADR 0018) |
| `EnterPlanMode`, `ExitPlanMode` | `enter_plan_mode`, `exit_plan_mode` | none / unchanged |
| `mcp__server__tool` | the same | unchanged |

The way back (`claude_name`) answers with the current name: `MultiEdit` for `multi_edit`,
`TaskStop` for `kill_shell`, `TaskOutput` for `bash_output`, `Agent` for `agent`. A hook therefore sees `kill_shell` as
`TaskStop` with `task_id`; its `updatedInput` (`task_id` or `shell_id`) comes back as
`shell_id`. A hook on `Edit|MultiEdit` gets `multi_edit` as `MultiEdit` with an absolute
`file_path` like the other file tools (`Hooks` `%FILE_TOOL`). Any other name stays unknown
(`undef`): an agent file or a rule naming it names nothing, a rule with it is invalid and
reported, the converter leaves the call out with a note. The table never guesses.

### 2. Every Claude Code tool name known, and why the rest have no raider tool

Counts are `tool_use` blocks in the local sessions (all versions, sub-agent transcripts
included); "listed" means the name only appears in Claude Code's tool lists, never called.

| Name | Seen | raider |
|---|---|---|
| `Bash` | 136163 | `bash` |
| `Edit` | 18929 | `edit_file` |
| `Read` | 11716 | `read_file` |
| `Write` | 6465 | `write_file` |
| `Agent` | 3972 | `agent` |
| `Skill` | 1173 | `skill` |
| `WebFetch` | 531 | `web_fetch` |
| `AskUserQuestion` | 234 | `ask_user` |
| `TaskStop` | 135 | `kill_shell` |
| `WebSearch` | 110 | `web_search` |
| `TaskUpdate`, `TaskCreate` | 23, 21 | `task_update`, `task_create` |
| `Grep`, `Glob` | 8, 1 | `grep`, `glob` |
| `ExitPlanMode` | 2 | `exit_plan_mode` |
| `TaskList`, `TaskGet`, `EnterPlanMode` | listed | `task_list`, `task_get`, `enter_plan_mode` |
| `MultiEdit`, `TodoWrite`, `BashOutput`, `KillShell`, `KillBash`, `LS`, `Task` | older versions | `multi_edit`, `todo_write`, `bash_output`, `kill_shell`, `list_files`, `agent` |
| `SendMessage` | 1241 | `send_message` since ADR 0027 §5: continues a subagent by agent ID or name (was unknown here: raider has no teammates) |
| `SubagentHandback` | 726 | unknown: a sub-agent handing its result back; raider's sub-agent ends with its answer (stream A) |
| `ListAgents`, `TeamCreate`, `TeamDelete`, `AgentOutput`, `AgentOutputTool` | 279, removed | unknown: the agent-team machinery, same reason |
| `ToolSearch` | 737 | unknown: loads deferred tool schemas; raider mounts the whole active tool set (ADR 0005), nothing is deferred |
| `Monitor` | 713 | `monitor` since ADR 0031 §1: streams the stdout lines of a background command as notifications (was unknown here: `bash_output` polls, which is not the same contract) |
| `EnterWorktree`, `ExitWorktree` | 401, 66 | `enter_worktree`, `exit_worktree` since ADR 0032: moves the session's working root into a git worktree; the root and the compiled context stay (ADR 0004) |
| `StructuredOutput` | 82 | unknown: the SDK's final structured answer; raider's machine output is `--json` (ADR 0013) |
| `Artifact`, `ArtifactComments`, `ArtifactData`, `DesignSync` | 34, listed | unknown: claude.ai pages; no counterpart |
| `CronCreate`, `CronDelete`, `CronList` | 10, 7, listed | `cron_create`, `cron_delete`, `cron_list` since ADR 0031 §2: session jobs in the REPL; a scheduled prompt gives no permission, so ADR 0005 holds (was unknown here) |
| `ScheduleWakeup`, `RemoteTrigger` | 24, listed | unknown: the wakeup belongs to the self-paced `/loop` raider does not have (ADR 0031 §3); `RemoteTrigger` fires a cloud routine |
| `SendFeedback`, `PushNotification`, `SendUserFile`, `SendUserMessage`, `ReadNotifications`, `FetchInboxMessage`, `EndConversation`, `Workflow` | 4, 1, listed | unknown: host integrations of claude.ai and the desktop app |
| `TaskOutput` | listed (removed in later 2.1) | `bash_output`, see §5 |
| `NotebookEdit`, `NotebookRead` | listed | unknown: Jupyter cells (`cell_id`, `cell_type`, `edit_mode` insert/delete); `edit_file` on the JSON would accept the arguments only lossily, and raider reads no notebooks |
| `SlashCommand` | older versions | unknown: the model runs a custom slash command; raider has no model-invocable commands (skills go through `skill`) |
| `ListMcpResourcesTool`, `ReadMcpResourceTool`, `ReadMcpResourceDirTool` | listed | unknown: MCP resources; raider uses MCP tools only |
| `PowerShell`, `LSP`, `REPL`, `JavaScript` | in the 2.1.303 tool set | unknown: other shells, a language server, Claude Code's own code sandboxes (raider's `perl_eval` is another language and contract) |
| `TestingPermission`, `Frame`, `FrameRead`, `SuggestBackgroundPR`, `AutofixPr` | internal or removed | unknown |

`bash` and `bash_placeholder` (63 and 10 calls) appear in the logs too: tool names of sessions
driven by other harnesses through Claude Code's transcript format, not Claude Code tools.
`raider_name('bash')` stays undef: a raider name is not a Claude name.

### 3. The task tools: one family is offered, the task tools by default

Claude Code 2.1 offers exactly one family: `TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet`
(`isEnabled`: the tasks switch on) or `TodoWrite` (`isEnabled`: off), switched by
`CLAUDE_CODE_ENABLE_TASKS`, on by default. Two families at once would give the model two ways
to keep one list. raider does the same:

- `Langertha::Raider::TodoTools` has both: `task_server` (the four task tools) and `server`
  (`todo_write`). `Application->task_tools` picks one: true by default, false with
  `RAIDER_ENABLE_TASKS=0` (also `false`, `no`, `off`), mirroring Claude Code's switch.
  `todo_write` stays exactly as ADR 0018 decided.
- **A mapping to `todo_write` was rejected**: `TaskCreate` adds one task, `todo_write` replaces
  the list; ids, descriptions, owners, metadata and dependencies have no place in it. The task
  tools take Claude Code's arguments without loss.
- **Arguments** (Claude Code's schema): `task_create(subject, description, [activeForm],
  [metadata])`; `task_update(taskId, [subject], [description], [activeForm], [status],
  [addBlocks], [addBlockedBy], [owner], [metadata])` with `status` one of `pending`,
  `in_progress`, `completed`, `deleted`; `task_list()`; `task_get(taskId)`. Ids are strings
  `"1"`, `"2"`, ... and never used again, a deleted one included.
- **Answers** (Claude Code's words): `Task #N created successfully: SUBJECT`; `Updated task #N
  ` plus the changed fields in Claude Code's order (`subject, description, activeForm, owner,
  metadata, status, blocks, blockedBy`) — with nothing changed it ends on the space, as Claude
  Code's does; `Updated task #N deleted`; `Task not found` for an unknown id, as a plain
  result, not an error (as Claude Code); `No tasks found`; `#N [STATUS] SUBJECT (OWNER)
  [blocked by #A, #B]` per line, only blockers not yet completed, tasks with
  `metadata._internal` left out; `task_get`: `Task #N: SUBJECT`, `Status: ...`,
  `Description: ...`, `Blocked by: ...`, `Blocks: ...`. Metadata merges, a key set to null is
  removed; `deleted` removes the task and every link to it, and ignores the other fields.
  `addBlocks`/`addBlockedBy` link only tasks that exist, but count as a change for every id new
  to the list (Claude Code's rule).
- **One list, one event.** Both families hand their list to the application, which keeps it as
  `todos` and emits `todo.updated` (journal, `--stream-json`). The items keep the shape of ADR
  0018 — `content` (for a task its subject), `status`, `activeForm` (defaults to the subject) —
  and a task adds `id`, `description`, `blocks`, `blockedBy`, and `owner` / `metadata` when
  set. Consumers of `content`/`status` work with either family.
- **Lifetime.** The task list lives as long as the application's conversation, as Claude Code's
  does: runs go on with it (a `TaskUpdate` in the next prompt finds task 1), `/clear`
  (`note_history_cleared`) empties it, ids go on counting. `todo_write`'s list stays state of
  the run (ADR 0018), emptied by `begin_run`: it is resent whole on every change, so nothing is
  lost.
- Effects: none (`ToolEffects` `[]`), so every mode allows them, plan mode included.

### 4. `enter_plan_mode`

- **The tool** (`PlanTools->enter_server`, mounted always, before `exit_plan_mode`): no
  arguments. Its handler (`Application::_enter_plan_mode`) switches the mode to `plan`
  (`permission.mode`, why `enter_plan_mode`), which mounts `exit_plan_mode` from the next
  request on, and answers Claude Code's text with raider's tool names: "Entered plan mode. You
  should now focus on exploring the codebase and designing an implementation approach.", the
  six steps ("4. Use ask_user if you need to clarify the approach", "6. When ready, use
  exit_plan_mode to present your plan for approval") and "Remember: DO NOT write or edit any
  files yet. ...". Already in plan mode it answers the same and switches nothing.
- **The person agrees, through the permission gate.** Claude Code's tool "REQUIRES user
  approval": it asks "Enter plan mode?" in the modes that ask, and in `bypassPermissions` it
  runs without a question. raider puts that into `Permissions::decide`, the one place modes are
  resolved (ADR 0021): `enter_plan_mode` (raider's own) **asks in `default`, `acceptEdits` and
  `auto`**; `bypassPermissions` allows it; in `plan` it is allowed (it changes nothing). The
  rest is the gate's ordinary path: deny rules first (`EnterPlanMode` in a deny list refuses it,
  in `bypassPermissions` too), an `EnterPlanMode` allow rule lifts the question, the REPL/ACP
  ask "once / for this session (`EnterPlanMode`) / no", the person's "no" is Claude Code's
  rejection text (ADR 0026), and with nobody to ask (one-shot, `--json`, Hall) it is refused
  with how to allow it. That is right without a person: nobody could approve the plan later,
  so plan mode would only end the run with a plan instead of the work.
- Effect class: none (`ToolEffects` `[]`); the question comes from the policy, not from an
  effect.
- **Not for subagents** (ADR 0020). Claude Code refuses the tool in an agent ("Only the main
  session can enter plan mode."); raider does not offer it there at all — a subagent's tool set
  drops it as it drops `ask_user`, even when the agent file lists `EnterPlanMode` — so no
  request offers the model a tool that can only fail. A subagent's mode comes from its caller.

### 4a. Subagents: their own task list, families in agent files

A subagent (ADR 0020) gets its own `TodoTools` instance for whichever family the application
mounts, so its list never touches the caller's and counts its ids from `"1"`; its
`todo.updated` goes to its own journal. The `tools` / `disallowedTools` of an agent file name
tools in families, because one name of a family cannot be honoured alone: `TodoWrite` and the
`Task*` names are one family (a file written for either shape of Claude Code means the task
list, whichever shape is mounted); `Edit` and `MultiEdit` are one (a `MultiEdit` left allowed
after `Edit` was disallowed would edit anyway); `Bash` brings `bash_output` and `kill_shell`
(its background shells are unusable without them), while those alone do not bring `bash`.

### 5. `TaskOutput` and `BashOutput` mean `bash_output`

`TaskOutput` read the output of a background shell or agent until Claude Code 2.1.274 and is
gone in 2.1.303 (listed among the removed tool names); it replaced `BashOutput` (`bash_id`,
`filter`). Its schema, from the 2.1.274 bundle: `task_id`, `block` (default `true`: wait for the
command to finish), `timeout` (milliseconds, default 30000, at most 600000). raider's
`bash_output` (ADR 0024) has `bash_id`, `filter`, `block` (default **false**) and `timeout`
(seconds, default 30, at most 600) — the same contract with other names, units and one other
default. The mapping is lossless when the default is written down:

- `raider_input` of a `TaskOutput` input (it carries `task_id`): `task_id` → `bash_id`,
  `timeout` ms → s (rounded up, as for `bash`), and `block: true` when it is missing.
- `raider_input` of a `BashOutput` input (`bash_id`, no `task_id`): unchanged.
- `claude_input` (a hook's `tool_input`, `TaskOutput` is the current name): `bash_id` →
  `task_id`, s → ms, and `block: false` when it is missing. `filter`, which `TaskOutput` does
  not have, passes through like every key only one side knows.

So raider → Claude Code → raider gives the same call with `block: false` spelled out, which is
what it meant; a `TaskOutput` call converted from a session waits as it did in Claude Code.

### 6. Converter and scenarios

`maint/claude-log-to-scenario` turns a `MultiEdit` into one `multi_edit` call (no more split,
no "all or none" note) and writes `app: { task_tools: false }` for a section that uses
`TodoWrite`, so the draft mounts `todo_write`. The scenarios that test `todo_write` (16, 17, 65,
claude-logs log-07) carry the same key. New scenarios 125–129 (task tools, the list across
prompts, `enter_plan_mode` approved, refused and in `bypassPermissions`); tests t/197 (task
tools), t/198 (`enter_plan_mode`), t/199 (hooks and rules with the new names), t/180 (a second
synthetic session).

### Deliberate differences from Claude Code

- **The task list is not on disk.** Claude Code keeps it in `~/.claude/tasks/` and across
  resumes; raider keeps it in memory for the conversation. A resumed session (`--continue`)
  starts with an empty list.
- **No team semantics.** Claude Code's task tools assign owners automatically, notify
  teammates and append "Call TaskList now ..." in agent teams; raider has no teams, so `owner` is
  only stored and shown.
- **`TaskCreated` / `TaskCompleted` hooks** run from the task tools of the application since
  karr #163 (ADR 0022 addendum); a subagent's own task list fires none yet.
- **Input coercion.** Claude Code repairs some misshaped task inputs (aliases such as a `task`
  wrapper); raider checks the schema as it is and answers `Error: ...`.
- **`enter_plan_mode` in plan mode** answers without asking; Claude Code would show its
  dialog again.
- **`todo_write`'s answers** stay raider's ("Todo list updated: ..." with the list) instead of
  Claude Code's "Todos have been modified successfully. ...", and it keeps the one-item-in-
  progress check and does not empty the list when every item is completed; it is the
  non-default family now.

### Addendum (karr #163): the task list on resume

`replay_session` (resume, `--continue`) restores the task list of the task tools from the
session journal: `Journal->tasks` is the `todos` of the last `todo.updated` since the last
`history.cleared` (`/clear` empties the list), counting only entries with an `id`, so a
`todo_write` list restores nothing — and with `task_tools` off nothing is restored either.
The tools go on with it (`TodoTools->restore_tasks`: no `on_update`, no hook; the next id
follows the highest id present). Ids of tasks deleted before the session ended are not kept,
so a resumed session may reuse the id of a task that was deleted last. `fork_session` copies
the list as a `todo.updated` event. No journal change (ADR 0015).

## Consequences

- **Incompatible:** the default tool set offers `task_create`, `task_update`, `task_list` and
  `task_get` instead of `todo_write`, plus `enter_plan_mode`. `RAIDER_ENABLE_TASKS=0` brings
  `todo_write` back. `MultiEdit` in a rule, an agent file or a hook matcher now means
  `multi_edit`, not `edit_file`.
- `enter_plan_mode` asks in `default` mode; in a non-interactive run it is refused unless an
  `EnterPlanMode` allow rule or `bypassPermissions` allows it.
- Follow-ups: `TaskCreated`/`TaskCompleted` hooks; restoring the task list on resume from the
  journal's last `todo.updated`; sub-agents (stream A) should not get `enter_plan_mode`
  (Claude Code: "Only the main session can enter plan mode.") and should treat `TodoWrite` and
  the task tools as one family in an agent file's `tools:`. (`multi_edit` as a writing file tool in permission rules and `acceptEdits` is worker
  A's part of stream D.)
