# ADR 0024 — Bash results and background shells like Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: tools, claude-code, shell, async
- karr: #159 (stream D of the Claude Code flow plan, item 5 of the list on #156)

## Context

`bash` was `MCP::Run::Bash` (CPAN dist MCP-Run). Its result always started with
`Exit code: N`, then `=== STDOUT ===` / `=== STDERR ===` blocks, also for exit 0. A timeout
killed the command. `run_in_background` was ignored: the command ran in the foreground and
blocked the run, and there was nothing like Claude Code's `BashOutput` / `KillShell`
(`TaskOutput` / `TaskStop` in newer versions). A model trained on Claude Code reads the
results differently from what raider gave it, and a long job (a test suite, a server) had no
way to run while the model goes on.

What Claude Code answers, taken from its own session logs (`~/.claude/projects/*/*.jsonl`,
versions 2.1.27x–2.1.30x, about 37000 `Bash` results):

- exit 0: the output alone, stdout and stderr in one stream; no output:
  `(Bash completed with no output)`; not an error.
- any other exit status: an error result `Exit code N`, a newline, then the output
  (`Exit code N` alone when there is none). No colon.
- long output: an error result keeps its start and its end around
  `... [N characters truncated] ...`; a successful one over about 30000 characters is saved
  to a file with a 2 KB preview (`<persisted-output>`). No inline result over 29840
  characters was found.
- a command still running after its timeout (default 120 s, `timeout` in ms, at most
  600 s — a request for 3600000 ms reports "its 600s timeout") is **not killed**:
  `Command did not complete within its 120s timeout and was moved to the background (ID:
  X). Output is being written to: PATH. You will be notified when it completes. ...`,
  not an error.
- `run_in_background: true`: `Command running in background with ID: X. Output is being
  written to: PATH. You will be notified when it completes. To check interim output, use
  Read on that file path.`
- `TaskStop`: `Successfully stopped task: X (COMMAND)` (inside a JSON object with
  `task_id`, `task_type`, `command`); errors `No task found with ID: X` and
  `Task X is not running (status: completed)`.
- No `BashOutput` / `KillShell` / `TaskOutput` call is in the local logs.

## Decision

### 1. Raider's own shell tools

`Langertha::Raider::BashTools` (internal, ADR 0017) is one MCP server with `bash`,
`bash_output` and `kill_shell`, mounted by `Application::_build_stock_tool_servers` at the
place of the old server (`engine:2`). It is built once per application (`Application->bash_tools`)
with the root, `allowed_commands`, the loadguard validator and the application's loop.
MCP-Run is no longer used; its dependency is dropped from the `cpanfile`. Nothing was
changed in MCP-Run.

A command runs as `bash -c COMMAND` in a fork that puts itself in a process group of its
own, takes stdin from `/dev/null`, changes into the root (or `working_directory`) with
`chdir` and writes stdout **and** stderr into one file in a private temporary directory, so
the output is one stream in the order written, as in Claude Code. (`MCP::Run` prefixed
`cd 'DIR' && `, which sends the `cd` into the background together with the first command
of `x & y` and runs `y` in raider's own directory — fixed, with a test.) A file instead of a
pipe also means a background command never blocks on a full pipe while nobody reads.

### 2. Results

- exit 0: the output, trailing newlines removed; without output
  `(Bash completed with no output)`.
- otherwise an error result `Exit code N` + newline + output. A command ended by a signal
  reports `128 + N`, the shell convention.
- output over 30000 characters (`output_limit`) keeps its first and its last 15000 around
  `\n\n... [N characters truncated] ...\n\n`, for both outcomes.
- the output is decoded as UTF-8 (invalid bytes become U+FFFD).
- The gates and their texts stay as they were: `Command not allowed: WORD`
  (`allowed_commands`), `Command REASON` (the validator, i.e. `Command refused by
  loadguard: ...`), `No command given: ...`. Both are asked before anything starts, in the
  foreground and the background.

### 3. timeout and description

`timeout` is in seconds (raider's unit since ADR 0018; `ToolNames` turns Claude's
milliseconds into seconds), default 120, at most 600 (more is cut to 600; 0, negative or not
a number is the default). `description` is accepted and ignored (Claude Code shows it to
the person; raider's trace shows the command) — since ADR 0027 it names a background shell
in its notification.

A command still running after its timeout is moved to the background, as in Claude Code:
the loop adopts it (§4) and the result is
`Command did not complete within its Ns timeout and was moved to the background (ID: bash_N).
Read its output and see whether it has finished with bash_output (bash_id: bash_N); stop it
with kill_shell (shell_id: bash_N).` — not an error. Nothing is lost: `bash_output` returns
everything from the start.

### 4. Background shells

- `run_in_background: true` starts the command the same way and answers at once
  `Command running in background with ID: bash_N. Read its output ...` (same hint).
- IDs are `bash_1`, `bash_2`, ... per application — predictable, so scenarios can name them.
- **Supervised by the application's loop** (ADR 0016): an adopted shell is registered with
  `$app->loop->watch_process`, so it is reaped when it ends while the loop runs (a model
  request), with its exit status. `bash_output` and `kill_shell` also look themselves
  (`waitpid WNOHANG`, then `unwatch_process`), because a tool call runs while the loop is
  not turning; when the loop got there first but has only queued its callback, they let it
  run once (`loop_once(0)`).
- **Lifetime: the application's**, i.e. a REPL session — as Claude Code keeps background
  tasks per session. They live across the runs (turns) of a session; the first Ctrl-C
  (cancel the turn, `Runner::cancel_run`) stops the tool children of the run but leaves the
  background shells (`BashTools->background_pids`, `terminate_children(keep => ...)`).
  Leaving raider (second Ctrl-C, SIGTERM: `terminate_children` without `keep`), and the
  application going away (`BashTools::DEMOLISH` → `stop_all`), stop every shell still
  running. A one-shot run ends them when it ends.
- `bash_output(bash_id, filter?, block?, timeout?)`: the output written since the last call
  and the status, in the tag form of Claude Code's `BashOutput`:
  `<status>running|completed|killed</status>`, `<exit_code>N</exit_code>` once it has
  finished, `<stdout>…</stdout>` when there is new output (both streams). `filter` is a
  regex on lines; lines that do not match are consumed. `block: true` waits for the end, at
  most `timeout` seconds (default 30, at most 600) — the `block` of Claude Code's newer
  `TaskOutput`, here default false (as `BashOutput`). A failed command is reported by its
  exit code, not as an error of `bash_output`. An incomplete UTF-8 sequence at the end of a
  running shell's output waits for the next call.
- `kill_shell(shell_id)`: SIGTERM to the process group, SIGKILL after 2 seconds (as
  `MCP::Run::Bash` did), then `Successfully stopped task: bash_N (COMMAND)`.
- Errors (`isError`): `No task found with ID: X`, `Task X is not running (status: S)`,
  `Invalid filter regex: ...`.
- The argument names are `bash_id`, `filter`, `shell_id` (Claude Code's `BashOutput` /
  `KillShell`); `ToolNames` maps the Claude names onto them (stream D, worker C).

### 5. Effects and permissions

`bash` stays `code`, also in the background: the same gate (ADR 0021) decides before the
command starts, the loadguard gate too. `bash_output` is `read` (it returns what a shell of
the session wrote). `kill_shell` has no effect class: it can only stop a shell raider itself
started with `bash` — which passed the gate as `code` then — and starts nothing; asking
before stopping would make stopping harder than starting. So both are allowed in every
mode, plan mode and runs nobody can approve included, while `bash` is refused or asked as
before (ADR 0021 §3).

## Deliberate differences from Claude Code

- **No output file path and no notification.** Claude Code names its output file and
  notifies the model when the task ends. Raider's output file is internal (outside the root,
  where the file tools do not reach) and there is no channel to notify a model between its
  calls; the texts point to `bash_output` instead. *Notification superseded by ADR 0027 §4:
  a background shell that ends notifies its caller with a `<task-notification>` through the
  application's task registry (summary from `description`, else the command); the texts
  then say "You will be notified when it completes."; the output file stays internal.*
- **No persisted output.** Claude Code saves a successful output over ~30000 characters to a
  file and returns a 2 KB preview; raider keeps start and end inline, the form Claude Code
  uses for failed commands, for both. The threshold of that form differs in Claude Code
  (results of ~17900 characters were cut to ~10000); raider uses one limit, 30000.
- **`bash_output`'s format is not verified** against a log (none exists locally); it follows
  `BashOutput`'s tags without the timestamp. `kill_shell` answers with TaskStop's message as
  plain text, not the JSON object.
- **IDs** are `bash_N`, not random nine-character IDs.
- **No persistent shell.** Every command starts in the root (Claude Code keeps a shell whose
  `cd` carries over and says `Shell cwd was reset to ...`); unchanged from before.
- Without a handler of their own, a SIGHUP/INT/TERM during a foreground command stops it
  before raider goes (as `MCP::Run::Bash` did); the CLI has its own handlers.

## Consequences

- **Incompatible:** the result text of `bash` changed (no `Exit code: 0`, no
  `=== STDOUT ===` / `=== STDERR ===` blocks, combined output), a timeout no longer kills
  the command, and the `compress` argument of MCP-Run is gone. Scenarios and tests that
  expected the old text were updated (`03`, `10`, `20`, `22`, `claude-logs/log-03`, `05`, `07`,
  `09` — its deviation note is gone —, `11`).
- The stock tool list has two more tools (`bash_output`, `kill_shell`) on `engine:2`;
  server positions are unchanged.
- A background shell writes into a temporary file without a size limit; a runaway command
  can fill `/tmp` until it is stopped or the application ends.
- The loadguard slots (ADR 0018) count a background command like any other child of raider,
  since it is one.
- The standalone binary no longer needs `MCP::Run` (`scripts/build-binary.sh` and
  `scripts/verify-binary.sh` still name it).
- Follow-ups: notify the model when a background shell ends (a note in the next tool result
  or turn); `/bashes` in the REPL to list and stop shells.
