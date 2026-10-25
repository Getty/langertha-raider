# ADR 0033 — The hall event bus is a versioned wire format; refused missions are events

- Status: accepted
- Date: 2026-10-25
- Tags: hall, events, acp, machine-interface
- karr: #170 follow-up (events audit 2026-10-25)

## Context

The hall publishes events on its control socket (`subscribe` with a type prefix) and its
ACP adapter consumes them internally. An event is `{type, ts, …}` with `ts` in whole
seconds; there is no `version`, no `seq`, the JSON is not canonical, and the hall POD lists
only part of the types. ADR 0017 rule 7 does not name the bus, so its format was never
decided.

Since k23 a hall raider entry can be refused before any process starts (a `provider:` that
is no alias, is not stored, or comes with `engine`). That refusal only leaves a line in the
slot log: Telegram stays silent, cron reports `cron.fired` as if it ran, and an ACP
`session/prompt` whose mission was queued and is refused when it is pulled from the queue
waits forever, because the adapter only listens for `raider.spawned` and
`hall.session_error`. The adapter also evaluates a `raider.failed` event that nothing emits.

## Decision

1. **The hall event bus and the control-socket protocol are public wire formats** (added to
   ADR 0017 rule 7). The type list and every type's fields are documented in the POD of
   `Langertha::Raider::Hall` and are the reference.
2. **Envelope, version 1:** every event carries `version` (integer, 1), `type`, `seq`
   (1, 2, 3 … per hall process) and `time` (epoch seconds as a float, like ADR 0013).
   `ts` stays in version 1 for existing subscribers (ADR 0013's compatibility rule: fields
   are only added within a version). Bus events and control-socket answers are written with
   a canonical (sorted-key) JSON encoder.
3. **`raider.refused`** is the event for a mission that does not start because the hall
   refuses its raider entry:

   ```json
   { "version": 1, "type": "raider.refused", "seq": 7, "time": 1761369600.12, "ts": 1761369600,
     "status": "refused", "slot": "1ivar", "name": "ivar", "binding": "acp:…",
     "reason": "provider_not_stored", "error": "provider alias 'intranet' is not stored …",
     "queued": false }
   ```

   - `status` is `refused`, the end state of ADR 0013 (and ADR 0009, update 2026-10-25).
   - `reason` is a short code; the first ones are `provider_not_alias`,
     `provider_with_engine`, `provider_not_stored` and `provider_config` (home config
     unreadable). New codes may be added within version 1. `error` is the human text.
   - `binding` only when the mission has one; `queued` is true when the mission was pulled
     from a queue and refused then.
   - It is its own type and not `raider.done` with `status: refused`: `raider.done` describes
     a process that ran (`id`, `pid`, `exit_code`), a refusal has none.
4. **Surfaces:**
   - The control-socket `spawn` answer keeps `{error}` and adds `status: "refused"` and
     `reason`.
   - **ACP:** a waiting `session/prompt` whose binding gets `raider.refused` is answered with
     JSON-RPC error `-32000` carrying the `error` text, also when the refusal happens on a
     queue pull. The ACP stop reason `refusal` is not used: in ACP it means the model
     refused. The dead `raider.failed` branch is removed.
   - **Cron:** a refused cron mission emits `raider.refused` with `binding: cron:ID`.
   - **Telegram:** the chat gets a short reply without details ("mission not started
     (configuration), see the hall log"); the reason stays in the event and the slot log, so
     alias names and paths do not leak into a chat.
   - **Slot log:** the line keeps existing, in the form of the result line:
     `[hall] raider NAME refused: WHY; mission not run`.

## Consequences

- The ACP adapter's hang on a refused queue pull is a defect fixed by this ADR's card.
- Subscribers that ignore unknown fields (ADR 0013) keep working; `ts` can be dropped only
  with a version 2 of the bus.
- Not decided here: forwarding other `raider.*` events into ACP as message text
  (`Hall/ACP.pm`, today's `else` branch) and richer ACP updates (`tool_call`, `plan`, …);
  both are backlog cards and belong to the stdio ACP server of ADR 0010.

## Source

Events audit 2026-10-25 (orchestrator scratchpad, summarised on karr #170); maintainer
decisions of 2026-10-25.
