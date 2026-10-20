# ADR 0027 — Background subagents, send_message and subagent parity with Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: agents, tools, async, claude-code, sessions
- karr: #161 (stream A2 of the Claude Code flow plan; agent part of the list on #156)

## Context

ADR 0020 gave raider subagents: agent files, the `agent` tool, a child run on the caller's
loop. It left out what replays of real Claude Code sessions (#156, items 15–20) show is
used most: background subagents (`run_in_background`, completion as a
`<task-notification>`), continuing a subagent (`SendMessage`, 1393 calls in the local logs),
the built-in `Explore` and `Plan` types, the `agentId`/usage trailer of a result, worktree
isolation (257 subagent metas with a worktree) and nesting (`spawnDepth` 2 and 3 in the
logs). ADR 0020 §4 also ran several `agent` calls of one turn one after the other.

What Claude Code does, from its session logs (`~/.claude/projects/*/*.jsonl` and
`*/subagents/agent-*.meta.json`) and its documentation (code.claude.com/docs/en/sub-agents,
tools-reference, worktrees; read 2026-10-19):

- **Foreground result**: the subagent's report, then
  `agentId: ID (use SendMessage with to: 'ID', summary: '<5-10 word recap>' to continue this agent)`
  and `<usage>subagent_tokens: N\ntool_uses: N\nduration_ms: N</usage>` in the same text
  block. Newer versions wrap the report in a "[Subagent hand-back]" preamble.
- **Background start** (`run_in_background: true`): at once `Async agent launched
  successfully.`, the `agentId` line, "The agent is working in the background. You will be
  notified automatically when it completes. …", an output file.
- **Completion**: a user message
  ```
  <task-notification>
  <task-id>ID</task-id>
  <tool-use-id>TOOL_USE_ID</tool-use-id>
  <output-file>PATH</output-file>
  <status>completed</status>
  <summary>Agent "DESCRIPTION" finished</summary>
  <note>…the same task-id may notify more than once.</note>
  <result>REPORT (& < > escaped)</result>
  <usage><subagent_tokens>N</subagent_tokens><tool_uses>N</tool_uses><duration_ms>N</duration_ms></usage>
  <worktree><worktreePath>P</worktreePath><worktreeBranch>B</worktreeBranch></worktree>
  </task-notification>
  ```
  delivered before the next model request; when the session is idle it starts a turn.
- **SendMessage** to an agent: a running one gets the message "at its next tool round"
  (`Message queued for delivery to ID at its next tool round.`); a finished one is resumed
  from its transcript under the same ID, in the background (`Resuming agent ID`), and
  notifies again.
- **TaskStop** stops a background task — a shell or an agent, by ID or name. A stopped
  agent can be resumed by SendMessage.
- **Nesting**: "a subagent can spawn subagents of its own, up to three layers below the
  main conversation"; `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` changes it, `1` turns nesting
  off. A subagent that started background subagents waits for them before it finishes.
- **Concurrency**: at 20 running subagents another spawn fails with `Concurrent subagent
  limit reached` and the error says not to retry (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`).
  Agent calls of one message run at the same time.
- **Explore** ("fast, read-only agent optimized for searching and analyzing codebases",
  thoroughness quick / medium / very thorough) and **Plan** (research for a plan): read-only,
  Write and Edit denied, no Agent; they start without CLAUDE.md, are one-shot and return no
  agent ID, so they cannot be resumed. Both run on the caller's model.
- **Worktree isolation**: "an isolated copy of the repository branched by default from your
  default branch rather than the parent session's HEAD" (`worktree.baseRef`: `fresh` default,
  `head`); removed automatically when the subagent made no changes, kept otherwise; locked
  while the agent runs. Observed path `.claude/worktrees/agent-ID`, branch
  `worktree-agent-ID`.
- **Parameters** of `Agent`: `description`, `prompt`, `subagent_type`, `model`,
  `run_in_background`, `isolation`, `name` (and `effort`, fork-only details, teams).

ADR 0024 (stream D) built background shells: IDs `bash_N`, `bash_output`, `kill_shell`
(Claude `TaskStop`, `TaskOutput`), no notification ("no channel to notify a model between its
calls"). The coordinator decided on 2026-10-19: one background registry in the application
for shells and agents, agent IDs with their own prefix, `TaskStop` stays `kill_shell` and
accepts agent IDs once stream D is merged, `bash_output` likewise; the notification form
below is the one shells use too.

## Decision

### 1. Every subagent has an agent ID and lives in the application's task registry

`Langertha::Raider::Tasks` (internal, ADR 0017) is the application's registry of background
work and its notification queue; one per application, so per REPL session, like the shells of
ADR 0024 §4. Every subagent run — foreground or background — gets an **agent ID** `agent_N`
(a counter per application, predictable for scenarios, the counterpart of `bash_N`) and stays
in the registry after its run, so it can be continued (§5). The entry knows its agent, the
`agent` call id (`tool-use-id`), `description`, optional `name`, status (`running`,
`completed`, `failed`, `killed`), the last report and the usage of its last run.

The agent ID is what the model sees and addresses. Hook inputs keep `agent_id` as ADR 0020
§7 defines it (the child session id, unique across processes); `session.created` of a child
session gains `agent_id` (the agent ID) and `name` (the spawn's `name`, if any), which is how
a later process finds it again (§5). A new agent ID skips the `agent_id`s of the current
session's existing child sessions, so a session continued with `--continue` never hands out
`agent_1` twice.

### 2. Foreground result

A completed subagent answers with its report and the trailer of Claude Code:

```
REPORT
agentId: agent_1 (use send_message with to: 'agent_1' to continue this agent)
<usage>subagent_tokens: N
tool_uses: N
duration_ms: N</usage>
```

- `subagent_tokens`: input plus output tokens of the subagent's last model response — the size
  of its context at the end, as Claude Code's `totalTokens`; `0` when the engine reports no
  usage. Taken from the subagent's own `model.usage` events (the token ledger's source, karr
  #163), so usage is read from a response once; the ledger already counts every subagent
  call into the session total, and the caller's stream gets no copy (that would count it
  twice). `tool_uses`: the subagent's tool calls in this run.
  `duration_ms`: wall clock of this run.
- An isolated subagent whose worktree is kept (§7) adds `worktreePath: P` and
  `worktreeBranch: B` lines after `<usage>…</usage>`.
- The one-shot built-ins (`Explore`, `Plan`, §6) get no `agentId` line, only the usage. Started
  in the background they get a bare `agentId: agent_N` line (no `send_message` hint), so the
  model can stop them with `kill_shell`.
- Failed, cancelled and refused calls stay error results as in ADR 0020; a failed or
  cancelled one names its agent ID (`Agent 'x' (agent_1) failed: …`) because it can be
  continued.
- No hand-back preamble: the report is the result, as in the Claude Code versions before it.

### 3. Background subagents

`agent` takes `run_in_background` (boolean). Everything that can refuse a call — unknown
type, empty prompt, briefing (ADR 0020 §6), permissions (`Agent(name)` rules), the
concurrency limit (§9), isolation errors (§7) — answers at once as before. Otherwise the
subagent starts on the application's loop and the call answers at once, not an error:

```
Async agent launched successfully.
agentId: agent_1 (use send_message with to: 'agent_1' to continue this agent)
The agent is working in the background. You will be notified automatically when it completes. You know nothing about its results until that notification arrives — do not report, assume, or predict them; continue other work or respond to the user in the meantime.
Do not duplicate this agent's work — avoid working with the same files or topics it is using.
```

- **Runs while nothing awaits it.** The loop turns during every model request and tool call
  of any run of the application, and while the REPL waits for input (§4).
- **Permissions.** A background subagent inherits the caller's policy (ADR 0020 §4) but
  cannot ask: a call its policy asks about is refused as in a run nobody can approve
  (ADR 0021), with a reason that says it ran in the background. The person is not asked
  in the middle of typing at the prompt. The run rules of a slash command (ADR 0030,
  `allowed-tools`) are copied into its policy when it starts, not shared: a later
  command's rules do not reach it, and the end of the command that started it does not
  take them away (a foreground subagent lives inside the run and shares them, as it
  shares the session rules). It keeps the model it resolved when it started, whatever a
  command's `model:` does to the run afterwards. (An agent that inherits — no `model` —
  gets the session's configured model, not a command's `model:` of the current run; that
  it should follow the run's model, as "the caller's model" of ADR 0020 §5 means, is open.)
- **Lifetime.** A background subagent belongs to the application, not to the turn: the
  first Ctrl-C (cancel the turn) leaves it running, as it leaves background shells
  (ADR 0024 §4); leaving raider (second Ctrl-C, SIGTERM, end of the REPL) and the
  application going away cancel every live subagent. Starting a new conversation
  (`/clear`, `/reset`, `/new`) cancels the background agents of the old one without a
  notification and drops the notifications queued for it — their reports would answer a
  conversation that no longer exists; background shells keep running and notifying, as
  they belong to the session (ADR 0024).
- **A run does not end before its background children.** A run that would end — final
  answer — while background subagents it started (directly) are still running waits for
  them on the loop, delivers their notifications (§4) and goes on with them as its next
  message; it ends when it answers with none left. This holds for a subagent (Claude Code:
  "a subagent that launches background subagents waits for their results before it
  finishes") and for a non-interactive main run (`raider -p`, piped REPL input at its end),
  whose answer would otherwise be lost. The interactive REPL does not wait: it goes back to
  the prompt and delivers when the agent finishes. Cancelling a run while it waits (Ctrl-C
  on `raider -p`) ends it `cancelled`. A subagent that ends failed or cancelled stops its own
  running children first, waits for them and drops their queued notifications — nobody is
  left to read them.
- **Journal.** `agent.started` gains `agent_id` and `background` (always, true or false);
  `agent.finished` gains `agent_id`. Both go to the stream and journal of the run that is current when they
  happen (the caller's session in any case — a background agent finishing between turns
  appends to the session journal outside a run).

### 4. The task notification

When a background subagent's run ends (completed, failed, killed) the registry queues a
notification for its caller, in Claude Code's form:

```
<task-notification>
<task-id>agent_1</task-id>
<tool-use-id>c3</tool-use-id>
<status>completed</status>
<summary>Agent "DESCRIPTION" finished</summary>
<result>REPORT</result>
<usage><subagent_tokens>N</subagent_tokens><tool_uses>N</tool_uses><duration_ms>N</duration_ms></usage>
</task-notification>
```

- `status`: `completed`, `failed` (summary `Agent "D" failed: REASON`, no `<result>`, with
  `<usage>`), `killed` (summary `Agent "D" was stopped`). `&`, `<`, `>` are escaped as
  `&amp;`, `&lt;`, `&gt;` in every element (report, summary, description), so no text of the
  agent can close the element early. A kept worktree adds the `<worktree>` element (§7). No
  `<output-file>` and no `<note>`: raider has no transcript file meant for the model.
- **Delivery** — a notification is a user message to the run that started the agent (the
  main conversation for an agent of the main run, the calling subagent for a nested one):
  - while that run is in a raid: in front of its next model request, after the tool results
    of the current turn — pulled from the queue through the raider's `on_iteration` hook
    (which the application's and every subagent's raider now occupy), not pushed with
    `inject()`, which loses a message that arrives just as the raid ends;
  - the REPL, idle at the prompt with nothing typed: a new turn whose message is the
    notification(s), shown as a meta line (`background agent agent_1 finished`);
  - the REPL with a line being submitted: the notifications go in front of that line in the
    same turn, each wrapped as
    `<system-reminder>\n[SYSTEM NOTIFICATION - NOT USER INPUT] …\n<task-notification>…</task-notification>\n</system-reminder>`
    as Claude Code delivers them next to a genuine message;
  - a run waiting for its children (§3): as its next message.
  Several notifications that are due together form one message, in finishing order.
- The notification is journaled as the user `message` it is, with `notification => 1`; the
  reminders delivered with a typed line are journaled as such a message of their own before
  the line. A turn that only delivers notifications runs no `UserPromptSubmit` hook (nobody
  submitted a prompt); `Stop` hooks run as after any turn.
- The REPL waits for input on the loop: with a terminal through `Term::ReadLine::Gnu`'s
  callback interface (characters fed from a loop watcher), else it prints its own prompt
  (instead of `IO::Prompt::Tiny`) and runs the loop until the input is readable or a
  notification is due. End of input (Ctrl-D) leaves the REPL.
- The queue is the registry's: ADR 0024's shells post into it after stream D's merge
  (`bash_N` notifications, status `completed`/`failed`/`killed`, summary
  `Background command "…" completed (exit code N)`), which closes ADR 0024's follow-up.

### 5. `send_message`

A stock tool `send_message` (Claude Code `SendMessage`) with `to` (an agent ID or the
`name` given at spawn — the newest agent of a name wins), `message`, and `summary`
(accepted, journaled, not sent). It is mounted wherever `agent` is (same depth rule) and has
no effect class of its own: like `agent`, it only drives a subagent whose calls carry their
own effects through the inherited policy.

- **Running agent**: the message is injected into its raid before its next model request;
  result `Message queued for delivery to agent_1 at its next tool round.`
- **Finished agent** (`completed`, `failed`, `killed`): it is resumed — a new run of the same
  subagent with its history, in the background, with the message as the next user message;
  result `Resuming agent agent_1 in the background. You will be notified when it finishes.`;
  a notification follows (§4). The resumed run gets a new run in the same child session
  (`run.started`…`run.finished`) and `agent.started` with `resumed: true`; `SubagentStart`
  does not fire again (the subagent started once). Its worktree is used again, created anew
  from the same branch if it was removed. Resuming counts against the concurrency limit (§9).
- **From a child session**: an agent ID the registry does not know (a later process after
  `--continue`/`--resume`) is looked up among the child sessions of the current session
  (`parent` = it, `agent_id` = the ID); its history is replayed into a new subagent
  (ADR 0015 replay), which then resumes as above. The agent's definition is looked up by
  name in the current catalogue; gone → error.
- **Errors** (`isError`): `No agent found with ID or name: X`; `Agent agent_1 (Explore) is
  one-shot and cannot be continued.` (§6); `to` addressing a task of another kind (a shell
  once stream D posts them) → `X is not an agent.`
- Sending from a subagent to its caller (`to: "main"`), teammates and other sessions are not
  covered.

### 6. Built-in `Explore` and `Plan`

Besides `general-purpose` (ADR 0020 §1, 4.), the catalogue has two built-ins, each shadowed
by a file agent of its name like `general-purpose`:

| name | description (agent tool text) | tools |
|---|---|---|
| `Explore` | Claude Code's: read-only search agent for broad fan-out searches …; tells the caller to give a thoroughness (`quick`, `medium`, `very thorough`) | all of the caller's except `agent`, `send_message`, `write_file`, `edit_file`, `multi_edit`, `exit_plan_mode` |
| `Plan` | Claude Code's: software architect agent for designing implementation plans … | the same |

- Bodies follow Claude Code's prompts for these agents in raider's tool names: Explore — a
  file-search specialist in read-only mode (no file creation, no state-changing `bash`,
  absolute paths in the report, parallel searches, adapt to the thoroughness); Plan — explore,
  design, detail the plan, end with "Critical Files for Implementation".
- **Without memory.** Their mission has no Claude memory items (CLAUDE.md, AGENTS.md), no
  native instructions and no packs — only the body, the tools and the skill listing when the
  set has `skill` (`compile_mission(..., memory => 0)`, the catalogue's `memory` key) — as
  Claude Code starts them "without CLAUDE.md files". A nested `CLAUDE.md` can still reach
  them through a tool result, since they share the caller's tool servers and context.
- **One-shot**: no `agentId` in the result (§2), `send_message` refuses them (§5); they still
  appear in the registry while running (so `kill_shell` can stop a background one).
- Model: the caller's (no `model` key); `bash` stays, its read-only use is the body's
  instruction (as in Claude Code; the inherited permission policy still applies) — the same
  holds for `perl_eval` and `perl_cpanm` when the perl tools are on.
- `claude-code-guide` and `statusline-setup` are Claude Code helpers about Claude Code
  itself and are not built in.

### 7. `isolation: "worktree"`

*Decided, not implemented with #161: the coordinator moved it to a follow-up stream
(2026-10-19). Implemented by ADR 0032 (#168), which settles the base fallback, `.worktreeinclude`,
the frontmatter field and the cleanup paths, and maps `EnterWorktree`/`ExitWorktree`.*

`agent` takes `isolation` (`"worktree"`; any other value is an error result). The subagent
then works in a git worktree of its own:

- **Where**: `<repository top>/.claude/worktrees/agent-ID` in the Claude layout (ADR 0019),
  `<repository top>/.raider/worktrees/agent-ID` otherwise; branch `worktree-agent-ID`.
  The repository is the one containing the root (`git rev-parse --show-toplevel`); a root in
  a subdirectory maps to the same subdirectory of the worktree. Not a git repository → error
  result `isolation "worktree" needs a git repository; ROOT is not inside one.`, nothing
  starts.
- **Base**: `worktree.baseRef` as Claude Code: `fresh` (default) — the remote's default
  branch (`origin/HEAD`) when there is one, else the local default branch (`init.defaultBranch`,
  then `main`, `master`), else `HEAD`; `head` — the root's current `HEAD`. Read from the
  Claude settings (`worktree.baseRef`, ADR 0019) in the Claude layout, from
  `.raider/config.yml` (`worktree_base_ref`) otherwise.
- **Locked** (`git worktree lock --reason "raider agent agent_1"`) while a run of the agent
  runs, unlocked after.
- **Own tools**: the subagent's file, search and shell tools are built for the worktree root
  (the same classes and settings as the caller's, root replaced); every other tool is the
  caller's, filtered as ADR 0020 §4. Its permission policy is the caller's `for_subrun` with
  the worktree as root, so project rules (`Edit(src/**)`) mean the same files in the copy.
  Its mission is compiled for the caller's context (the copy has the same files).
- **Cleanup** after each run: no changes — clean `git status --porcelain` (untracked files
  count as changes) and no commit on the branch beyond the base — removes the worktree
  (`git worktree remove`) and deletes the branch; otherwise both stay, and the result (§2)
  and the notification (§4) name path and branch. A failed git command is reported in the
  result (`worktree kept: REASON`), never fatal for the answer.
- **Journal**: `agent.started` gains `worktree` (path) and `branch`; `agent.finished` gains
  `worktree_kept` (boolean).

### 8. Nesting depth

`max_agent_depth` (ADR 0020 §4) defaults to **3**, Claude Code's "up to three layers below
the main conversation": the main run has depth 0, its subagents depth 1, and a run at depth 3
gets no `agent` and no `send_message`. Order: the config key, else the environment variable
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` in the Claude layout (Claude settings `env` included,
ADR 0019), else 3. `1` turns nesting off (ADR 0020's former default). The config key also takes `0` (no `agent`
tool at all, as before); the variable must be a positive integer. A value that does not fit
is ignored, and `config explain` lists it as ignored and says where the depth came from.

### 9. Parallel agent calls and the concurrency limit

- **Parallel.** The `agent` and `send_message` tools are asynchronous tools of
  `Langertha::Raider`: a tool may be given as an in-process handler that returns a `Future`
  (`async_tools`, a new attribute of the engine class) instead of an `MCP::Server` code that
  blocks; the MCP server still carries its schema and text. Consecutive calls of tools the
  raider marks as concurrent (`agent`) in one model turn are dispatched together — each
  through the whole path of a tool call (gate, hooks, plugins) — and their results are
  appended in call order. Any other call ends the group; nothing else changes order. A self
  tool is never in a group; all members are awaited before a stop or failure of one of them
  is passed on. Once a cancel is requested no tool call starts at all, of any tool.
- **Call context for plugins.** With calls running at the same time a plugin can no longer
  pair `plugin_after_tool_call` with the last `plugin_before_tool_call`, so a raider passes a
  per-call hash (`{ id => TOOL_CALL_ID }`) as one more argument to both hooks; the Events
  plugin keys `tool.call`/`tool.result` by it. Plugins that take two arguments are
  unaffected. The raider runs the before-hooks itself (`_plugin_before_tool_call_f`, the same
  loop as Langertha's `plugin_pipeline_tool_call_f` plus the argument); passing the context
  from core's `PluginHost` too is follow-up work in Langertha.
- **Limit.** At most `max_concurrent_agents` subagent runs at once per application — all
  depths, foreground and background — default **20** (config key, else
  `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` in the Claude layout). A spawn beyond it is an error
  result `Concurrent subagent limit reached (20 running). Do not retry this call now; wait
  for running agents to finish.` and nothing starts. Resumes (§5) are refused the same way.
- The text of `agent` no longer says calls run one after the other: "Launch multiple agents
  concurrently whenever possible, to maximize performance; to do that, use a single message
  with multiple agent calls."

### 10. Tool names and the agent tool text

- `ToolNames`: `SendMessage` → `send_message` (`to`, `message`, `summary` unchanged).
  `TaskStop` stays `kill_shell` (ADR 0025) and `TaskOutput` stays `bash_output`; after
  stream D's merge both accept agent IDs and names: `kill_shell` cancels a running agent
  (`Successfully stopped task: agent_1 (DESCRIPTION)`, then a `killed` notification),
  `bash_output` answers with the agent's status and, once it has ended, its report in an
  `<output>` element (the element of Claude Code's `TaskOutput`; the error text for a failed
  agent); `block` waits on the loop, so other background work goes on meanwhile.
  `BashTools` gets the registry (`tasks`) and never knows `Subagent`: an ID or name it does
  not own as a shell is looked up there. `bash`, `bash_output` and `kill_shell` are async
  tools too (§9), bound to their caller; an `async_tools` entry carries `applies` (called with
  the tool's source), so a handler takes over only the server it was made for, never a
  same-named tool of an MCP server.
- Background shells register as kind `bash`. Waiting for children (§3), cancelling with a
  run and `background_running` concern agents only; a run never waits for shells. A shell
  notifies its caller (§4) exactly once — also when stopped by `kill_shell`, never when
  raider tears it down; a shell whose starting subagent has ended notifies nobody. A
  foreground command run for a background agent survives the first Ctrl-C like the agent
  (`bash` only; `perl_eval`/`perl_cpanm` children are still ended).
  `ListAgents` and `SubagentHandback` stay unmapped; `EnterWorktree`, `ExitWorktree` are
  mapped since ADR 0032.
- `agent` parameters: `description`, `prompt`, `subagent_type`, `model` (`sonnet`, `opus`,
  `haiku`, mapped as ADR 0020 §5; overrides the agent's `model`; any other value is an error
  result, as Claude Code's enum would reject it), `run_in_background`, `isolation`, `name`.
- The tool text follows Claude Code's current `Agent` description in raider's names: when to
  use it and when not, that the agent's report is not shown to the user, background use and
  notifications, `send_message` to continue an agent, parallel calls, `isolation`, and the
  agent list (`- name: description (Tools: …)`).

## Deliberate differences from Claude Code

- Agent IDs are `agent_N`, not random 17-character IDs (scenarios name them; `bash_N`).
- No output file and no `<note>` in the notification; no "[Subagent hand-back]" preamble.
- A non-interactive main run waits for its background agents (§3); Claude Code's `-p`
  behaviour depends on its fork mode.
- Background subagents keep the caller's filtered tool set (minus `ask_user`) instead of
  Claude Code's fixed list for background agents.
- Explore/Plan run on the caller's model (Claude Code's Fable → Opus exception does not
  apply: model aliases are Anthropic-API-only anyway, ADR 0020 §5).
- No forks (`subagent_type: "fork"`), no teams, no `effort`, no `/tasks` UI; `ListAgents`
  and `to: "main"` are not offered.
- No periodic sweep of kept worktrees (`cleanupPeriodDays`).

## Consequences

- Every run below the depth limit has two more tools (`agent`, `send_message`), and with
  depth 3 subagents have them too: tool lists in prompts and golden tests grow.
- ADR 0020 §4 "One after the other", "Depth limit default 1" and the "Not covered"
  background/resume items are superseded by §8, §9, §3 and §5.
- `Langertha::Raider` (the engine class) gains asynchronous in-process tools and grouped
  dispatch — the first change to its tool loop that runs calls of a turn at the same time.
- The REPL drives the loop while it waits for input; without `Term::ReadLine::Gnu` on a
  terminal it prints its own prompt.
- Background subagents consume the engine while the person types; a session can leave
  agents running when the person quits — they are cancelled, their work in a kept worktree
  stays.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md` (stream
A2), maintainer's go-ahead 2026-10-19, coordinator's decision on the shared registry
(2026-10-19); karr #161, #156 (items 15–20). Claude Code session logs and documentation as
cited above. Builds on ADR 0005, 0015, 0016, 0019, 0020, 0021, 0022, 0024, 0025.
