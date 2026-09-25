# ADR 0015 — Session journal format and the single-writer lock

- Status: accepted
- Date: 2026-09-25
- Tags: sessions, persistence, concurrency

## Context

ADR 0003 decided that a session is an append-only JSONL file next to its scope, with one
active writer, and left the event schema, file locking and the resume rules open. ADR 0013
already defined a machine-output event vocabulary (`run.started`, `tool.call`, …). The
journal should not invent a second one.

## Decision

- **File and id.** `<scope>/sessions/<id>.jsonl`, where scope is `<project>/.raider` or
  `~/.raider` (ADR 0011). The id sorts by creation time and is safe in a file name:
  `YYYYMMDD-HHMMSS-xxxx` (UTC, four random hex digits). Creating `<project>/.raider/` also
  writes `.raider/.gitignore` with `sessions/` and `lib/`, unless the file exists.
- **Line format.** One JSON object per line, UTF-8, with `v` (journal format version, 1),
  `seq` (1, 2, 3 … per session), `time` (epoch seconds with fraction) and `type`, plus the
  type's fields. Every event of a run carries `run` (the run's id, `r1`, `r2`, …).
- **Event types in version 1** — the ADR 0013 names wherever one exists:
  - `session.created` — always line 1: `id`, `scope` (`project` | `home`), `root`,
    `principal` (the local user name), `raider` (version).
  - `run.started` — `run`, `engine`, `model`.
  - `message` — `role` (`user` | `assistant`), `content`: the user input and the final
    assistant text of a run.
  - `tool.call` — `call` (id), `name`, `arguments`, `status: "dispatched"`.
  - `tool.result` — `call`, `name`, `status` (`succeeded` | `failed` | `cancelled`),
    `content` (full text; the journal is the never-compressed history).
  - `run.finished` — `run`, `status` (ADR 0009 end states), `metrics`, `error`.
  - `history.cleared` — the REPL's `/clear`; resume rebuilds `history` from the messages
    after the last one (added 2026-09-25, karr #70).
  - `session.created` of a fork carries `forked_from`; the copied history follows as
    `message` events without `run` (added 2026-09-25, karr #69).
  - Readers ignore unknown types and fields; new types are added without a new `v`.
- **One writer, enforced by a lock.** The writing process holds an exclusive, non-blocking
  `flock` on `<id>.lock` next to the journal for as long as it has the session open for
  writing. A second writer fails at once with "session is in use"; it never waits and
  never interleaves. Readers (`session list`, `show`) need no lock.
- **Crash rules.** A last line that is not complete JSON is ignored on read and reported,
  and the next append starts on a fresh line. A `tool.call` without its `tool.result` is
  reported as `unknown` when the session is resumed and is never executed again. A
  `run.started` without `run.finished` counts as `interrupted`.
- **Resume.** Resuming rebuilds the working `history` from the `message` events (user
  input and final assistant text, which is what `history` holds today) and
  `session_history` from all events; ADR 0007 of langertha still applies. The context
  (`.raider.md`, packs, config) is built fresh, not replayed.
- **Secrets.** API keys and auth headers never enter the journal. Tool output is stored as
  is; redaction and retention are follow-up work (ADR 0005).
- **Hall bindings** (ADR 0002 consequence), stored in the hall directory as a small map
  from binding key to session id:
  - a Telegram chat (`bot` + `chat_id`, plus thread when present) → one session, so a
    conversation continues across messages;
  - a numbered slot (`1bjorn`) → one session, continued by each queued mission;
  - a cron job → its own session per job;
  - a plain-name run (`bjorn`, parallel) → a fresh session per run, never shared.
  The hall starts the raider with that session. A mission for a binding that is already
  running waits in a per-binding queue (ADR 0003: new input is queued); the single-writer
  lock stays the last line of defence and makes a run fail loudly only when something
  outside the hall holds the session (amended 2026-09-25, karr #71).

## Consequences

- One event vocabulary for machine output and the journal; a `--stream-json` consumer and a
  journal reader share parsing code.
- Per-session search or embeddings over journals is a derived index (ADR 0003), not part
  of this format.

## Source

Follow-up design required by ADR 0003; maintainer asked to proceed without further
questions (2026-09-25).
