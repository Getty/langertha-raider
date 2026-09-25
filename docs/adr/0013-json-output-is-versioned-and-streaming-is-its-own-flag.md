# ADR 0013 — `--json` is versioned; streaming is its own flag

- Status: accepted
- Date: 2026-09-25
- Tags: cli, json, machine-interface

## Context

`raider --json` prints one pretty-printed document when the run ends:
`{response, metrics, elapsed}` on success, `{error, elapsed}` on failure. It has no
version, so no consumer can tell which shape it gets, and there is no way to follow a run
while it happens. The Hall already depends on it: every raider it spawns runs with
`--json`, and Hall/ACP reads the captured log back. The handoff (§ RDR-04) and the
target-state README ask for a versioned `--json` and a separate `--stream-json`, and warn
against silently turning `--json` into a stream. Exit codes are already distinct since
the thin `bin/raider` (0 success, 1 run failed, 2 usage, 3 configuration).

## Decision

- **`--json` stays one document per run**, written once at the end, on stdout, and
  nothing else goes to stdout (banners, spinners, trace and diagnostics go to stderr or
  are off). It never becomes a stream.
- **Every document carries its format version and the run's outcome:**

  ```json
  { "version": 1, "status": "completed",
    "response": "…", "metrics": { … }, "elapsed": 1.23 }
  { "version": 1, "status": "failed",
    "error": "…", "elapsed": 0.42 }
  ```

  - `version` is an integer. Version 1 is today's fields plus `version` and `status`, so
    existing consumers keep working.
  - `status` uses the run states of ADR 0009 that can end a run (`completed`, `failed`,
    `cancelled`, `refused`, `interrupted`); only the ones the CLI can actually produce are
    emitted.
- **Compatibility rule.** Within a version fields are only added, never renamed, removed
  or changed in meaning; consumers must ignore fields they don't know. A breaking change is
  a new version, chosen explicitly with `--json=2`; plain `--json` stays on the old version
  for at least one release after the new one ships, and `Changes` says so.
- **`--stream-json` is a separate flag** and excludes `--json`. It writes JSON Lines to
  stdout: one compact event per line, flushed per event.
  - Every event has `version`, `type`, `seq` (1, 2, 3 … per run) and `time`.
  - Event types in version 1: `run.started`, `run.state` (ADR 0009 state changes),
    `message` (a finished assistant message), `tool.call` (tool name and arguments),
    `tool.result` (tool name, ok/error, size; the content is cut to a fixed length and
    flagged `truncated`), and `run.finished`.
  - `run.finished` is always the last line, also on failure, and its payload is exactly
    the `--json` document of that run. A consumer that only wants the result reads the
    last line.
  - Token deltas (`text.delta`) are left out of version 1; they can be added later
    without a new version, because consumers ignore unknown types.
- **Same exit codes** for `--json`, `--stream-json` and human output.
- **Surfaces follow later, not in this step.** The Hall may switch from reading the `--json`
  log to consuming `--stream-json`; ACP keeps its own protocol (ADR 0010) and is not
  replaced by this format.

## Consequences

- The `--json` code in `Langertha::Raider::CLI::Output` gains `version` and `status`, and
  the documented format moves into the POD of `bin/raider` as the reference.
- Streaming needs the run loop to report tool calls and state changes as they happen; the
  Trace plugin already sees tool calls and is the natural source for them.
- A secret in a tool argument or result can end up in the stream; the truncation limits
  exposure but is not a filter. Redaction is follow-up work together with ADR 0005.

## Source

Proposal: `docs/RAIDER-REDESIGN-HANDOFF.md` § RDR-04 and the machine-interface section;
target-state README; karr #40 (from #21).
