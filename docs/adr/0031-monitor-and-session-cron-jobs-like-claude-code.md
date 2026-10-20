# ADR 0031 — Monitor and session cron jobs like Claude Code, and why there is no wakeup tool

- Status: accepted
- Date: 2026-10-20
- Tags: tools, async, claude-code, scheduling, notifications
- karr: #169 (stream M3 of the Claude Code flow plan)

## Context

ADR 0025 listed `Monitor`, `CronCreate`, `CronDelete`, `CronList` and `ScheduleWakeup` as Claude
Code tools without a raider counterpart: `bash_output` polls, which is not the contract of a
stream, and "the model schedules itself" was left to the Hall's configuration. Since then the
task registry exists (ADR 0027): background work is addressable by an ID, ends with one
`<task-notification>`, and the notifications reach the run that started it, the idle REPL and
a waiting non-interactive run. Monitor and the cron tools are the two remaining things a
model does with that machinery in Claude Code.

What Claude Code does (documentation `tools-reference` and `scheduled-tasks`, read
2026-10-20, and the schemas and results in its own session logs):

- **Monitor.** "Runs a command in the background and feeds each output line back to Claude."
  Parameters `description` ("Short human-readable description of what you are monitoring
  (shown in notifications)."), `timeout_ms` (default 300000, "Deadlines above 1800000ms are
  capped to 1800000ms. You are notified at expiry and can re-arm"; at most 600000 in a `-p`
  run), `command` ("Shell command or script. Each stdout line is an event; exit ends the
  watch."), and `ws` (a WebSocket source). It "uses the same permission rules as Bash". Start
  result: `Monitor started (task ID, expires in 30m unless the source ends first; you get one
  notice at expiry — re-arm if you still need the watch). You will be notified on each event.
  Keep working — do not poll or sleep. Events may arrive while you are waiting for the user — an
  event is not their reply.` An event arrives as a `<task-notification>` with `<task-id>`,
  `<summary>Monitor event: "DESCRIPTION"</summary>` and `<event>LINE</event>` (several lines in
  one element when they came together). Stopped with `TaskStop`; stops with the subagent that
  started it; not restored on resume.
- **Cron.** `CronCreate` (`cron`, `prompt`, `recurring`, `durable`) answers `Scheduled recurring
  job ID (CRON). Session-only (not written to disk, dies when Claude exits). Auto-expires after
  7 days. Use CronDelete to cancel sooner.`; `CronDelete` (`id`) answers `Cancelled job ID.`;
  `CronList` lists the jobs with their next run. Five-field cron in the **local** time zone
  (vixie either-or for day-of-month and day-of-week; no `L`, `W`, `?`, names), at most 50
  jobs, the scheduler looks every second, a due prompt "fires between your turns, not while
  Claude is mid-response", a missed run fires once when idle ("no catch-up"), a recurring job
  expires after 7 days and "fires one final time, then deletes itself", **jitter**: recurring
  jobs run late by up to half the gap to the next run (at most 30 minutes), `*/5 * * * *` 15
  seconds early, one-shot jobs on `:00`/`:30` up to 90 seconds early. Jobs are restored on
  `--resume`; `CLAUDE_CODE_DISABLE_CRON=1` turns the scheduler off.
- **ScheduleWakeup.** "Reschedules the next iteration of a self-paced `/loop`" (`delaySeconds`,
  `reason`, `prompt`); "you don't call it directly".

Claude Code does not publish the model-facing description text of these tools. The parameter
schemas and the results above are verbatim; the descriptions below are raider's own wording of
the same contract.

## Decision

### 1. `monitor`

A tool of the shell server (`Langertha::Raider::BashTools`, with `bash`, `bash_output`,
`kill_shell`), mounted wherever the registry exists. `Langertha::Raider::Monitor` runs one
watch.

- **Parameters** as Claude Code: `description` (required), `command` (required),
  `timeout_ms`. Not `ws`: raider has no WebSocket client among its dependencies, and a second
  kind of source is a feature of its own (follow-up). `timeout_ms` is Claude's unit on purpose:
  `bash` keeps its seconds (ADR 0024 §3) because it had them before Claude's unit was known; a
  tool with no such history takes the verbatim parameter, so a model trained on Claude Code
  needs no translation and `ToolNames` has no argument rule for it.
- **The command** runs as `bash -c` in the root, in a process group of its own, stdin from
  `/dev/null`, stdout into a pipe the application's loop reads, stderr into a file (not an
  event). The gates of `bash` apply before it starts, with the same texts: `allowed_commands`
  (`Command not allowed: X`) and the loadguard validator (`Command refused by loadguard: …`).
- **Registry.** An entry of kind `monitor`, ID `monitor_N` (predictable, like `bash_N`), with
  `recipient` (the run that started it: `main` or a subagent's agent ID) and `tool-use-id`.
  `kill_shell` (Claude `TaskStop`) stops it through the registry — `Successfully stopped task:
  monitor_1 (DESCRIPTION)` — and `bash_output` answers its status.
- **Events.** Each stdout line is an event. The lines that arrive within 0.2 s of the first
  line of a batch are **one** notification: `<summary>Monitor event: "DESCRIPTION"</summary>`
  and `<event>` with the lines joined by a newline (`&`, `<`, `>` escaped, ADR 0027 §4). A
  line over 2000 characters is cut (`... [line truncated]`), a batch over 8000 (`... [N more
  characters not shown]`). A last line without a newline is an event. The delivery is ADR
  0027's: in front of the recipient's next model request, in the idle REPL as a turn, with a
  waiting run as its next message.
- **The end** is one notification, each with `<status>`: the command exited — `completed`
  (`Monitor "D" ended (exit code 0)`) or `failed` (`Monitor "D" failed with exit code N`, with
  the last 20 lines of stderr in `<result>`); the deadline — `killed`, `Monitor "D" timed out
  after 5m`, and in `<result>` "The watch ended at its deadline. Start it again with monitor
  if you still need it." (Claude's "one notice at expiry"); a stop — `killed`, `Monitor "D" was
  stopped`.
- **Limits on events.** More than 20 notifications within 10 seconds, or more than 500 in all,
  stop the monitor: the command is stopped, no further event is delivered, and the end
  notification (`killed`, `Monitor "D" was stopped: too many events`) says how many and what to
  do ("filter the stream (grep --line-buffered) or print only what changed"). Claude Code
  stops a monitor that floods too; its numbers are not published, these are raider's. The
  burst is counted in notifications (batches), not lines, so a noisy command costs at most
  five notifications a second before it is stopped; with 0.2 s batches that is about four
  seconds of flood.
- **Deadline.** Default 300 s, at most 1800 s, at least 1 s. A run nobody can answer (the
  application has no `on_permission_request`: `raider -p`, `--json`, a Hall raider without a
  permission channel) at most 600 s, as Claude Code. Applied silently (Claude Code's cap is
  silent too).
- **Lifetime.** A monitor belongs to the session like a background shell (ADR 0024 §4): the
  first Ctrl-C leaves it (`background_pids`), `/clear` leaves it, leaving raider and the
  application going away stop it. Unlike a shell it **ends with the subagent that started
  it** (silently: `quiet`, as Claude Code stops them "with it"), at the end of every run of
  that subagent. Not restored on resume (nothing is: ADR 0024).
- **Non-interactive runs.** A main run that would end while one of its monitors still runs
  waits for it (`background_running` counts monitors next to agents), as it waits for
  background agents (ADR 0027 §3): the events are its next messages, it ends when the
  monitor has ended. The 10 minute cap above bounds the wait. The interactive REPL does not
  wait.
- **Subagents** have `monitor` wherever they have `bash` (their `tools:` list names `Monitor`
  separately; the `bash` family of ADR 0025 does not bring it, as Claude Code's list does not).

### 2. `cron_create`, `cron_delete`, `cron_list`

`Langertha::Raider::CronTools` (a server of its own, `raider-cron`) over `Langertha::Raider::Cron`
(the arithmetic).

- **Parameters and results** as Claude Code (`cron`, `prompt`, `recurring` default true,
  `durable`; `id`), with the texts above in raider's words (`dies when raider exits`). IDs are
  `cron_N`. `cron_list` answers one line per job — `cron_1 - 7 * * * * (recurring, next run
  2026-10-20 10:27:00): PROMPT` (the prompt cut at 100 characters) — or `No scheduled jobs.`
  Errors: `Invalid cron expression "X": REASON` (field count, range, unsupported syntax, a
  date that never comes), `No prompt given`, `Too many scheduled jobs (50). Cancel one with
  cron_delete first.`, `No scheduled job with ID: X`.
- **Expressions.** Five fields, local time (the time zone of the process), `*`, values, ranges,
  steps, lists; `0` and `7` are Sunday; day-of-month and day-of-week both constrained match if
  either does. The next minute is found by walking months, days, hours, so daylight saving
  time neither loops nor skips a day.
- **Jobs are entries** of the registry (kind `cron`) with a `stop`, so leaving raider stops
  them and `kill_shell` on a cron ID deletes the job. A one-shot job and an expired recurring
  job end `completed`, a deleted one `killed`.
- **Scheduler.** An `IO::Async::Timer::Periodic` on the application's loop, once a second,
  only while jobs exist. It turns for as long as the loop does: during model requests and
  tool calls of any run and while the REPL waits for input — the same loop that delivers
  notifications. `tick` takes the clock from a code reference (tests move it); nothing in the
  code waits for real time.
- **Firing.** A due job posts its prompt into the registry's queue **`cron`**, not `main`.
  `main` is what a running turn pulls before each model request; a scheduled prompt must not
  be pulled into a turn in progress ("fires between your turns"). The idle REPL takes it: with
  nothing typed the read ends, a meta line `scheduled job cron_1 (* * * * *)` is shown and the
  prompt runs through `REPL::run_prompt` as a turn of its own — as if the person had typed it
  (the notifications that wait go in front as reminders, ADR 0027 §4), journaled as a run
  with that prompt. A prompt that starts with `/` is text for the model, not a command (Claude
  Code runs only skills the model may invoke on its own; raider has none that reach a fire).
  With a line being typed the prompt waits until the line has been answered. A job that is
  due again while its previous fire still waits is not queued twice; a job whose time passed
  during a long turn fires once afterwards and is rescheduled from now (no catch-up).
- **Expiry.** A recurring job expires 7 days after creation: the first fire at or after that
  time is its last, then it is deleted. At most 50 jobs.
- **Jitter** as documented (`Cron->jitter`): the offset is a fixed fraction of the allowed span
  taken from a hash of the job ID, so a job always runs the same number of seconds off, as the
  documentation says ("evenly spaced runs … the same number of minutes late every time"):
  recurring late by up to half the gap to the next run (at most 30 minutes), a gap of exactly
  300 seconds 15 seconds early, one-shot on `:00`/`:30` up to 90 seconds early.
- **Where the tools exist.** `Application->scheduling` (default off) mounts them; the REPL
  sets it (`CLI::Main`, when it starts an interactive session) and nothing else does. A run
  with a single prompt (`-p`, `--json`), a Hall raider and ACP have **no idle state in which
  a scheduled prompt could run as a turn**: the process answers one request and ends, or is
  driven by a peer that decides when a turn begins. Offering `cron_create` there would
  promise something raider cannot keep, so the model does not see the tools ("cron … only as
  long as the run lives" is the result: in `-p` it is never offered). `CLAUDE_CODE_DISABLE_CRON`
  (any value but empty, `0`, `false`, `no`, `off`) removes them in the REPL too.
- **Subagents** never have them (`@NEVER` of `Subagent`): a scheduled prompt runs in the main
  conversation; a subagent that scheduled one would write to a conversation it does not own.
- **Not durable.** `durable` is accepted and ignored; the schema says so. Jobs are not written
  to disk and not restored on `--resume`/`--continue` (Claude Code restores them, with
  exceptions). Durable scheduling is what the Hall's cron is for (CONTEXT.md: the Hall owns
  process supervision, queue, Telegram, **cron**); a second, file-based scheduler in the REPL
  would be two schedulers with two lifetimes. Restoring jobs on resume is a follow-up.

### 3. No `ScheduleWakeup`

`ScheduleWakeup` has one caller: the self-paced `/loop` skill, which ends each iteration with
"wake me in N seconds with this prompt" (or `stop: true`). Raider has no `/loop` (ADR 0030
brought custom commands and skills, not Claude Code's bundled skills), and outside `/loop` the
model has nothing to call it for — "check again in 20 minutes" is a one-shot `cron_create`,
which is how Claude Code's own documentation describes a one-time reminder. A wakeup tool
without `/loop` would be a second spelling of a one-shot cron job with a different fallback
(the 20 minute re-arm of an iteration that forgot to reschedule) that has nothing to belong to.
It is not built, `ToolNames` leaves `ScheduleWakeup` unmapped, and the Stop hook input has no
`session_crons`. **Revisit with `/loop`** (a follow-up of its own): the wakeup would be a job
of kind `cron` with `recurring => 0`, created and replaced by the loop, so nothing here has to
change for it.

### 4. Names, effects, permissions

- `ToolNames`: `Monitor → monitor`, `CronCreate → cron_create`, `CronDelete → cron_delete`,
  `CronList → cron_list` (and back). No argument is renamed.
- `ToolEffects`: `monitor` is `code`, like `bash`; the cron tools have **no effect class**: a
  job only queues a prompt for a later turn, and everything that turn does passes the gate when
  it does it. A prompt gives no permission (ADR 0005) — a fired prompt is as much a prompt as a
  typed one; the model could as well write the same text in its next answer. This is
  Claude Code's "no permission required" for `CronCreate`.
- **Permissions: Monitor = Bash.** A `Bash(...)` rule — allow, ask or deny, prefix or exact —
  applies to `monitor` calls as well (Claude Code: "`Bash(npm run *)` — Bash, Monitor"), and
  `Monitor` / `Monitor(...)` names the monitor alone. A multi-part command is covered part by
  part, `suggest_rule` offers `Bash(command)`, and `auto` mode's read-only bash allowance holds
  for a monitor of a read-only command. Plan mode and runs nobody can approve refuse a monitor
  as they refuse `bash`.
- **Binary packing.** Nothing is loaded by name: `Monitor`, `Cron`, `CronTools` are `use`d, the
  timer is `IO::Async::Timer::Periodic` (inside the `IO::Async::**` the build already packs),
  the jitter hash is `Digest::SHA`, already a dependency (no new XS library), and the
  command is a `bash` child like `bash`'s. No `$^X`, no new dependency.

## Deliberate differences from Claude Code

- `monitor` has no `ws` source.
- IDs are `monitor_N` and `cron_N`, not random.
- Cron tools only in the REPL; jobs are not durable and not restored on resume.
- A `-p` run waits for its monitors (Claude Code's `-p` waits up to a ceiling of its own).
- The limits on events are raider's own numbers.
- No `ScheduleWakeup`, no `/loop`, no `session_crons` in hook input.
- The tool descriptions are raider's wording; schemas and results are Claude's.
- A cron prompt that starts with `/` is text, not a command.

## Consequences

- The shell server has a fourth tool (`monitor`) and the stock server list one more entry
  (`engine:7`, the cron server) when the REPL runs; golden tests of the tool lists grew.
- `Application::background_running` counts monitors, so the end-of-input wait of the piped REPL
  and of `-p` waits for them (bounded by their deadline).
- `Tasks::notification_text` has an `event` element.
- The REPL asks one more question while idle (`idle_pending`): notifications of `main` and the
  prompts of `cron`.
- Follow-ups: `/loop` (and with it a wakeup), restoring cron jobs on resume, a `ws` source for
  `monitor`, a `/tasks` view of monitors and jobs, `session_crons` in hook input, Hall-level
  durable jobs reachable by the model.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md` (stream M3);
karr #169. Claude Code documentation (tools-reference, scheduled-tasks) and its session logs as
cited. Builds on ADR 0005, 0021, 0024, 0025, 0027.
