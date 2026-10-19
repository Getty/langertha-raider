# ADR 0018 — Search, todo and ask tools, the loadguard gate, and the Claude tool-name table

- Status: accepted
- Date: 2026-10-19
- Tags: tools, claude-mode, load, cli
- karr: #152 (stream T of the Claude Code flow plan)

## Context

Raider's toolbox was `list_files`, `read_file`, `write_file`, `edit_file`, `bash` and the web
tools. A session written for Claude Code uses `Glob`, `Grep`, `TodoWrite` and
`AskUserQuestion` all the time, and a raider that runs commands in the same user's account as
several Claude Code and Codex sessions can take the host down with one `prove -lr t`. The
loadguard plugin (`~/dev/loadguard`) solves the second problem for Claude Code from the
outside; raider has to solve it from the inside, as it is not a Claude Code session. The
`raider_ask_user` self-tool of `Langertha::Raider` exists but ends the raid with a `question`
result that no surface resumes. The Claude-mode streams (agents, permissions, hooks, session
conversion) all need to say which raider tool a Claude Code tool name means.

## Decision

- **New stock tools, named after Claude Code's.** `glob`, `grep` (`Langertha::Raider::SearchTools`),
  `todo_write` (`TodoTools`) and `ask_user` (`AskTools`) are in-process MCP servers mounted by
  `Application::_build_stock_tool_servers` like the file and web tools, so they are part of the
  one active tool set (ADR 0005): prompt, catalogue and effect report derive from them.
  Their parameters follow Claude Code's tools (`output_mode`, `-i`, `-A/-B/-C`, `glob`, `type`,
  `multiline`, `head_limit`, `offset`; `todos` with `content`, `status`, `activeForm`).
- **Search sees the same files with or without ripgrep.** `grep` runs ripgrep when `rg` is on
  `PATH`, else Perl; the output is identical (`path:line:text`, `path-line-text`, `--`
  between groups). To make that true the file set is defined by raider, not by ripgrep's
  defaults: it walks without following symbolic links, skips `.git`/`.hg`/`.svn`, includes
  hidden files, skips binary files and files over 10 MB, and does **not** apply `.gitignore`
  (ripgrep runs with `--no-ignore --hidden`). A search tool whose answers depend on whether a
  binary is installed would make sessions irreproducible; the price is that `node_modules`
  and similar are searched unless `path` or `glob` narrows it. `type` is raider's own table of
  extensions. A `type` together with a `glob` cannot be given to ripgrep (its globs override
  its types), so that one combination always runs in Perl. A pattern is a Perl regex in the
  Perl code and a Rust regex in ripgrep; the tool text says to stay with the common syntax.
  `glob` and `grep` are confined to the root exactly like `FileTools` (`realpath`, symlink
  escapes rejected) and show root-relative paths.
- **`todo_write` is run state, not a file.** The tool validates (statuses `pending`,
  `in_progress`, `completed`; at most one `in_progress`; non-empty `content`) and hands the
  whole list to the application, which keeps it as `todos` (emptied by `begin_run`) and emits
  `todo.updated` with `todos`. The session journal records `todo.updated`, and
  `--stream-json` carries it. Per ADR 0013 and ADR 0015 new event types need no new version.
  `todo_write` has no effect class (it changes nothing outside the run).
- **`ask_user` is a stock tool, answered through the application.** A surface that has a person
  sets `Application->on_ask_user` (the REPL does when its input is a terminal); the tool asks
  for it on every call. With none -- one-shot, Hall, cron, ACP, a REPL on a pipe -- the call
  is an error result: "ask_user is not available: this run is not interactive ... Decide
  yourself ... state your assumption". It never blocks a run nobody watches. The library's
  `raider_ask_user` self-tool is left as it is (the application does not enable `raider_mcp`):
  it needs a surface that resumes a `question` result with `respond_f`, none does, and its
  name does not match the Claude Code table. A later surface that wants pausing runs
  (Telegram, ACP) can answer through `on_ask_user` too. Effect class: `message`.
- **Loadguard is a gate in front of `bash`, ported from the plugin.** `Langertha::Raider::Loadguard`
  is the `validator` of the bash tool (`MCP::Run`'s own hook), so a refusal is the bash tool's
  error result "Command refused by loadguard: ...". It is not part of the approval gate of
  ADR 0005: that decides *may* a call run (policy, permissions); this decides *can the host
  take it now*, and a person cannot approve it away. The mechanism and the numbers are the
  plugin's (`docs/design.md` of loadguard): heavy commands are found in command position by
  the same tokenizer rules; refusal when PSI `memory full avg10` >= `LOADGUARD_PSI_FULL`
  (10 %), swap used >= `LOADGUARD_SWAP_USED` (90 %), or the heavy slots
  (`LOADGUARD_HEAVY_SLOTS`, `max(1, nproc/2)`) are all held; no process scan under pressure;
  light commands never refused; fail-open without `/proc/pressure` or swap;
  `LOADGUARD_THROTTLE=0` turns it off. The reason names the figures and the advice that fits
  (wait; a single test file only when slots are the problem, never under pressure; no new
  agent sessions). Differences from the plugin, on purpose: the plugin counts heavy
  processes inside `app-loadguard.slice`; raider has no such slice for its children, so a
  slot is held by the topmost heavy process (or `bash -c STRING`) *below a running `raider`
  process* found in `/proc` (any raider of the user, so several raiders share the slots), and
  the Codex/Claude wrapper forms are not needed. The tokenizer is a port, not a shared
  library; the two copies must be kept in step by hand. Every path into `/proc` goes through
  `proc_dir`, so tests build a `/proc` in a temporary directory (`Test::Raider::FakeProc`)
  and never create load.
- **Self-confinement is off by default.** `LOADGUARD_CONFINE=1` makes `bin/raider` re-exec
  itself (`Loadguard->confine_command`) under `systemd-run --user --scope` in
  `app-loadguard.slice` with `MemoryHigh/Max/SwapMax` as percent of RAM
  (`LOADGUARD_MEMORY_HIGH` 30, `_MAX` 40, `_SWAP_MAX` 10) and `CPUWeight` 50 and
  `OOMPolicy=continue`, when a user manager bus and a delegated memory controller exist;
  otherwise it does nothing (fail-open). Raider re-executes itself the way the Hall starts
  raiders: the packed binary directly, otherwise `$^X $0` (`Langertha::Raider::Binary`).
  It is off by default, unlike the plugin, because the whole raider, including a Hall
  daemon and everything it spawns, shares one limit.
- **One table for the Claude Code names.** `Langertha::Raider::ToolNames` maps `Read` ->
  `read_file`, `Write` -> `write_file`, `Edit`/`MultiEdit` -> `edit_file`, `Bash` -> `bash`,
  `Glob` -> `glob`, `Grep` -> `grep`, `LS` -> `list_files`, `WebFetch` -> `web_fetch`,
  `WebSearch` -> `web_search`, `TodoWrite` -> `todo_write`, `Task`/`Agent` -> `agent`,
  `Skill` -> `skill`, `AskUserQuestion` -> `ask_user`, `ExitPlanMode` -> `exit_plan_mode`;
  `mcp__server__tool` passes through unchanged; anything else is unknown (undef), never
  guessed. The table names targets, including tools that do not exist yet (`agent`, `skill`,
  `exit_plan_mode`). The way back answers with the current Claude name (`Edit`, `Agent`).

## Consequences

- The stock tool set has 11 tools (`engine:1`..`engine:6`, then Perl, then Hall); tests that
  pinned the positions moved.
- `grep` uses an external `rg` when there is one: the standalone binary does not carry it, so
  a packed raider uses the host's ripgrep or the Perl code. The Perl code is the reference.
- The tools only show one `bash` view of the host's load; a command that is not recognised as
  heavy (`bash -c 'prove'`, `sudo prove`, a 3.8 GB one-liner) is not refused. `LOADGUARD_CONFINE`
  is the backstop for those.
- The streams A (agents), P (permissions) and H (hooks) use `ToolNames`. Claude Code's
  *argument* names (`file_path`, `old_string`, ...) differ from raider's (`path`, ...); mapping
  them, where a permission rule such as `Read(~/.ssh/**)` needs the path, is left to stream P.
- `raider_ask_user` and `ask_user` are two ways to ask. If a surface that resumes
  `question` results appears, either can go.
