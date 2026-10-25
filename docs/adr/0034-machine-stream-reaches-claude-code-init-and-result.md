# ADR 0034 — The machine stream reaches Claude Code's init and result level

- Status: accepted
- Date: 2026-10-25
- Tags: cli, machine-interface, events, hooks, claude-code

## Context

ADR 0013 fixed the stream envelope and six event types. Since then the stream carries
thirteen more types (`model.usage`, `permission.*`, `hook.ran`, `hook.message`,
`mcp.server`, `mcp.tools_changed`, `agent.*`, `todo.updated`, `worktree.*`) that the
reference POD in `bin/raider` does not list and no test checks through the machine output.
Compared with Claude Code's `--output-format stream-json`:

- Claude Code's `system/init` names session, working directory, tools, permission mode and
  version up front; raider's `run.started` has only `engine` and `model`, the session id
  appears first in `run.finished`.
- Claude Code's `result` has a machine-readable end subtype (`error_max_turns`,
  `error_during_execution`, …); raider's `run.finished` has `status` and a free-text
  `error`, so `max_iterations` is indistinguishable from an engine error.
- `permission.*` and the tool hooks in `hook.ran` carry no call id, so with parallel tool
  calls they cannot be matched to their `tool.call`.
- ADR 0022 lists `PostToolUseFailure` as a follow-up; `PostToolUse` fires only on success.

## Decision

All of this is **additive within version 1** of ADR 0013 (new fields, no renames).

1. **`run.started`** additionally carries `session` (the session id), `run` (the run id),
   `cwd` (the working root), `permission_mode`, `tools` (the tool names the model sees, in
   order) and `raider_version`. MCP server status stays in `mcp.server`.
2. **`reason`** on the `--json` document (and thus on `run.finished`): a short code for why
   the run ended, set whenever `status` is not `completed`. The first codes come from the
   code paths that end a run today (for example `max_iterations`, `engine_error`,
   `hook_stopped`, `user_cancel`, `signal`, `provider`); the implementation lists them in
   the `bin/raider` POD, and new codes may be added within version 1. `error` stays the
   human text.
3. **`call`** (the raid's call id, `c1`, `c2`, …) on every `permission.*` event and on
   `hook.ran` for tool-scoped hook events (`PreToolUse`, `PostToolUse`,
   `PostToolUseFailure`), when the event belongs to a tool call.
4. **`PostToolUseFailure`** hook fires when a tool call fails (error result, refused by the
   gate, or cancelled), with Claude Code's input fields; `PostToolUse` stays success-only.
   This settles that item of ADR 0022's follow-ups.
5. **Every event type the stream can carry is documented** in the MACHINE OUTPUT section of
   `bin/raider` (fields and when it fires) and covered by at least one test that reads it
   through `--stream-json`. The known drifts are fixed with it: the example lacks `call` and
   `status` on `tool.*`; `message` is not only the final answer (also before stop feedback
   and background notifications); `Hooks::Result`'s synopsis says `hook.run` for `hook.ran`.

## Not decided here (backlog cards)

`run.state` wait states of ADR 0009, `task.*` events and task notifications in the stream,
a `context.compacted` event with `PreCompact`/`PostCompact`, the `SessionEnd`,
`StopFailure` and `PermissionRequest` hooks, `tool_use_id` for `PreToolUse`, intermediate
assistant text as `message`, a `denied` status on `tool.result`, partial `text.delta`.

## Source

Events audit 2026-10-25 against Claude Code (docs of 2026-10-25, `claude` 2.1.310);
maintainer decision of 2026-10-25 ("P1 now, P2 as cards").
