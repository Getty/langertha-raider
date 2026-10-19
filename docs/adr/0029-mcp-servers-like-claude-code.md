# ADR 0029 — MCP servers like Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: tools, mcp, claude-code, config, policy, cli
- karr: #164 (stream M1 of the Claude Code flow plan)

## Context

Raider mounts only its own in-process tool servers (files, search, bash, web, perl, hall,
skill, agent, plan). Claude Code, which raider is to behave like in a Claude Code project
(ADR 0019), connects to MCP servers the person configures: in `~/.claude.json`, in a
project's `.mcp.json` and in enabled plugins. Their tools reach the model as
`mcp__<server>__<tool>`, the permission rules and hooks name them that way, and a project's
servers only start after the person approved them. ADR 0005 already lists MCP servers as a
tool source and ADR 0004 says executable extensions — MCP starts among them — need their own
decision. ADR 0021 already parses `mcp__server__tool` rules and has `source_servers` for
foreign servers; nothing mounted one.

The reference is Claude Code's documentation, fetched 2026-10-19:
`https://code.claude.com/docs/en/mcp` (scopes, precedence, `.mcp.json` fields, expansion,
plugin servers, tool names, statuses, approvals and workspace trust, `MCP_TIMEOUT` /
`MCP_TOOL_TIMEOUT`), `.../settings` and `.../settings-reference` (the approval keys), and what
Claude Code writes on this machine (below). Where raider differs, it says so.

## Decision

### 1. Modules

- `Langertha::Raider::MCP::Config` — the pure configuration model: the sources of the
  layout mode, precedence, name normalisation, `${VAR}` expansion, the per-server timeouts,
  workspace trust and the approval state. Reads files, starts nothing. Internal (ADR 0017).
- `Langertha::Raider::MCP::Server` — one configured server: connect (stdio or streamable
  HTTP), status, its tools under the prefixed names, call forwarding with the original name
  and the per-call timeout, the captured stderr, shutdown. Duck-typed like `Net::Async::MCP`
  (`initialize`, `list_tools`, `call_tool`), so it is just another engine `mcp_servers`
  entry and `Langertha::Raider`'s dispatch stays as it is. Internal.
- `Langertha::Raider::MCP::Stdio` and `Langertha::Raider::MCP::HTTP` — the two transports
  (JSON-RPC over a child process; MCP's streamable HTTP). Internal. Why raider has its own
  client instead of `Net::Async::MCP`: §10.
- `Langertha::Raider::MCP::View` — a configured server as a subagent sees it (§11). Internal.
- `Langertha::Raider::MCP` — the set of one application: starts every server that may start,
  in parallel, each bounded by the startup timeout; the status report; the views a subagent
  gets; stop all. Internal.

The application, the subagent, the REPL and `Config.pm` get small hooks only (a few lines
each), so the parallel rewrite of those files (stream A2) and this one stay cheap to merge.

### 2. Sources per layout mode, and precedence

The same entry schema everywhere (§3). Sources, **highest precedence first**:

| # | Scope | Where | Read in |
|---|---|---|---|
| 1 | `raider-project` | `mcp:` of the project config (`.raider/config.yml`, legacy `.raider.yml`) | every mode but `bare` |
| 2 | `raider-home` | `mcp:` of `~/.raider/config.yml` | every mode but `bare` |
| 3 | `local` | `projects["<project dir>"].mcpServers` of Claude's global config | Claude layout |
| 4 | `project` | `mcpServers` of `<project dir>/.mcp.json` | Claude layout |
| 5 | `user` | top-level `mcpServers` of Claude's global config | Claude layout |
| 6 | `plugin` | every installed and enabled plugin (ADR 0019 §4, `Context::Plugins` order): `<plugin root>/.mcp.json`, then the manifest's `mcpServers` | Claude layout |

- **A name found earlier wins with its whole entry**; fields are never merged across scopes
  (Claude Code's rule). The shadowed entries are kept for the report. A broken entry still
  shadows: what the person wrote at the higher scope is what counts.
- **Raider's own files first, then Claude Code's sources in Claude Code's order.** This is
  the order ADR 0021 §3 gives the permission mode (`.raider/config.yml` > `~/.raider/config.yml`
  > the Claude settings): a raider file is a deliberate raider choice. Within each family the
  more specific scope wins, as in Claude Code (local > project > user > plugin).
- **Like permissions, not like hooks.** Permissions combine the raider config (always) with
  the Claude settings (Claude layout); hooks exist only in the Claude layout because raider
  has no hooks of its own. MCP servers have a raider form (`mcp:`), so they combine like
  permissions: `raider-*` in every mode, Claude's sources only in the Claude layout (mode
  `claude`, or a raider project with `claude: true`). In mode `claude` there is no
  `.raider/config.yml` (it would make the mode `raider`, ADR 0019 Addendum 2), so there only
  `raider-home` joins Claude's sources.
- **`--bare` mounts no configured server**, from any source. Unlike permission rules (local
  policy, kept under `--bare`, ADR 0021 §4), a server is a tool source and an executable
  extension; `--bare` is the minimal run.
- When raider runs in the home directory itself, the home file is the project file
  (ADR 0011): its `mcp:` is scope `raider-home`.
- **Claude's global config** is `$CLAUDE_CONFIG_DIR/.claude.json` when `CLAUDE_CONFIG_DIR`
  is set and not empty, else `~/.claude.json`. The **project dir** is
  `Context::Layout->project_dir` in the Claude layout (where `.claude/` lives; also the
  `CLAUDE_PROJECT_DIR` of hooks) and the root otherwise. The `projects` entry is looked up by
  that path as written and by its real path.
- **Plugin servers** are named `plugin:<plugin>:<server>`. The plugin's `.mcp.json` holds
  the map under `mcpServers` (a file without that key is read as the map itself, the shape
  Claude Code's plugin examples use both ways); the manifest's `mcpServers` is a path inside
  the plugin, an inline map, or a list of both (the shape of the manifest's `hooks`). A file
  named twice counts once; a path that leaves the plugin root, or a file that does not
  parse, is reported and contributes nothing. A server named twice inside one plugin: the
  later declaration wins (the manifest after the default file).
- Unreadable or invalid JSON (`.mcp.json`, the global config) is reported, never fatal. A
  wrong shape of a raider config's `mcp:` (not a mapping, an entry that is not a mapping) is
  a configuration error like a wrong `permissions:` (exit 3); a field-level problem of any
  entry is the server's status `invalid`.
- `mcp:` is read only at the top level of a config file; inside a section it is reported by
  `config explain`.

### 3. Entries

The fields of `.mcp.json`, in every source, the raider config included (no snake_case
renaming: the entry is Claude Code's format, so it can be copied either way):

```yaml
# .raider/config.yml or ~/.raider/config.yml
mcp:
  github:
    type: http
    url: https://api.example.com/mcp
    headers: { Authorization: "Bearer ${GITHUB_TOKEN}" }
  db:
    command: npx
    args: [ -y, "@bytebase/dbhub" ]
    env: { DB_URL: "${DB_URL:-postgres://localhost/dev}" }
    timeout: 60000
```

- `type`: `stdio` (the default when there is none), `http` (alias `streamable-http`),
  `sse`, `ws`, `sdk`. **An entry with `url` and no `type` is invalid** — Claude Code reads it
  as stdio and the docs call it a configuration error.
- stdio: `command` (required, a non-empty string), `args` (a list of strings or numbers),
  `env` (a map of strings or numbers). http: `url`, `headers` (a map of strings or numbers).
  `timeout` (milliseconds, a number): the per-call limit of this server; below 1000 it is
  ignored with a warning.
- **Not supported, status `unsupported` with the reason:** `sse` (deprecated in Claude Code;
  the installed `Net::Async::MCP` speaks streamable HTTP only), `ws`, `sdk` (servers of the
  Agent SDK), `headersHelper`, `oauth` (no OAuth flow in raider; a server that needs it is
  not connected). An http entry whose `url` is empty after expansion is `not_configured`,
  not an error (Claude Code: "not configured", a plugin's placeholder).
- Any other field is ignored with a warning.

### 4. Expansion

`${VAR}` and `${VAR:-default}` (name: anything but `}` and `:`; default: anything but `}`)
in `command`, every `args` element, `env` values, `url` and `headers` values — the fields
Claude Code expands, for every source.

- A variable that is set (empty counts as set) gives its value; one that is not set gives
  the default; one with neither stays as written, and the server gets the warning
  `${VAR} is not set` — it still starts, as in Claude Code.
- The variables are the process environment raider has when the model is built (after the
  Claude settings' `env` is applied, ADR 0019 §3).
- **Plugin servers** additionally get `${CLAUDE_PLUGIN_ROOT}` (the install path),
  `${CLAUDE_PLUGIN_DATA}` (`Context::Plugins->data_dir`, the same directory their hooks get,
  ADR 0022 §2) and `${CLAUDE_PROJECT_DIR}` (the project dir) directly; they win over the
  environment. Other sources get `CLAUDE_PROJECT_DIR` only from the environment — so
  `${CLAUDE_PROJECT_DIR:-.}`, as the docs say.
- **Credential variables are never handed to a remote server**: in `url` and `headers`,
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK` (Claude Code's
  list) and raider's engine keys `LANGERTHA_*_API_KEY` expand to the empty string, a default
  is ignored, and the server gets a warning. Copying the value into a variable of one's own
  passes it, as in Claude Code.

### 5. Names

- Every character of a server name outside `A-Z a-z 0-9 _ -` becomes `_`; the same for a
  tool name. A tool reaches the model, the permission rules and the hooks as
  `mcp__<server>__<tool>`; a plugin server's part is `plugin_<plugin>_<server>` (both
  normalised), so its tools are `mcp__plugin_<plugin>_<server>__<tool>`, Claude Code's form.
  The server is asked for the tool by its original name.
- **A server part that holds `__` or starts or ends with `_` is `invalid`**: the name of its
  tools could not be split back into server and tool (ADR 0021's `mcp__server__tool` rules,
  `ToolNames->is_mcp`). Claude Code builds such names anyway; raider refuses them rather than
  let a rule match the wrong server.
- Two servers whose parts normalise to the same string: the one of lower precedence is
  `invalid` ("tool names collide with server X").
- **Rules and hook matchers use the names the model sees**: the server part of an
  `mcp__server__tool` rule is compared with the normalised server part, the tool part with
  the normalised tool name (slice 2).

### 6. Timeouts

- `MCP_TIMEOUT` — the startup timeout in milliseconds for each server (connect, initialize,
  list the tools), default 30000 as in Claude Code.
- `MCP_TOOL_TIMEOUT` — the per-call limit in milliseconds; a server's `timeout` wins over it.
  Unset: no limit of raider's own (Claude Code's default is about 28 hours).
- A value that is not a positive whole number is ignored with a warning (the default holds).

### 7. Approval of project servers, workspace trust

Servers of scope `project` (`.mcp.json`) and `raider-project` (`mcp:` of the project config)
come with the repository and **start only when approved**. `local`, `user`, `raider-home` and
`plugin` servers are the person's own configuration (enabling a plugin is the decision) and
need none. Statuses: `approved` / `pending` / `rejected`, each with the source that decided.

Sources of the decision, one set per server name for both project scopes:

- **The Claude settings** (Claude layout): `enableAllProjectMcpServers` (a JSON boolean, the
  last file that sets one wins), `enabledMcpjsonServers` and `disabledMcpjsonServers` (lists,
  concatenated), read by `Context::Settings`.
- **The home config's `mcp_approvals:`** (every mode but `bare`): keyed by the absolute (or
  `~/`) path of a project dir, matched against its real path; per path `enable_all` (a
  boolean), `enabled` and `disabled` (lists of names). Only `~/.raider/config.yml` holds it —
  in a project file it is ignored and reported, so a repository cannot approve its own
  servers (as `project_tools:` and `providers:`, ADR 0011). No globs: approving every
  repository at once is not offered.

**Workspace trust.** Claude Code ignores approvals committed in a project's
`.claude/settings.json` in a folder the person never trusted, and in such a folder applies an
untracked `.claude/settings.local.json` only when the folder is the person's configuration
home. ADR 0004's trust does not exist yet; until it does, **raider takes Claude Code's own
record as the trust decision**: a project dir is trusted when it or a directory above it has
`hasTrustDialogAccepted: true` in Claude's global config. Then:

| Settings file | Approvals count |
|---|---|
| `~/.claude/settings.json` | always |
| `.claude/settings.json` | trusted folder only |
| `.claude/settings.local.json` | trusted folder, or the project dir is the home directory or the parent of `$CLAUDE_CONFIG_DIR` |

Claude Code also checks with git that `settings.local.json` is untracked; raider does not
run git for this and relies on the trust alone (a trusted folder applies a tracked file
too, as in Claude Code). Approvals that do not count are reported with the reason.

**Order**: a `disabled…` entry from **any** source — a settings file of an untrusted folder
included, as the docs say — rejects. Else an `enabled…` entry or an enable-all from a counted
source approves. Else the server is `pending`.

**Asking** (slice 3). An interactive REPL asks once per pending server before the first
prompt (after the banner, before a prompt given on the command line), with Claude Code's
three choices: use this server, use this and all future project servers, continue without
it (`1`/`2`/`3`, `y`/`n`; a closed input is no answer and the server stays pending). After
"all" nobody is asked again. Each answer holds at once for the session
(`MCP::Config->session_approvals`, which count before every file, then the set is built anew
with `reload_mcp`) and is persisted where it will count next time:

- Claude layout in a trusted folder: `.claude/settings.local.json` — `enabledMcpjsonServers`,
  `enableAllProjectMcpServers: true`, `disabledMcpjsonServers` — exactly what Claude Code
  writes (verified in the settings files of this machine), so Claude Code and raider share it.
- Otherwise (native or raider mode, or an untrusted folder, where `settings.local.json`
  would not count): `mcp_approvals:` of `~/.raider/config.yml` under the real path of the
  project dir (`Config->update_home`).

  The settings file is read, changed and written back with sorted keys (JSON keeps no key
  order); the home config through `Config->update_home` (`enable_all: 'true'`, the YAML
  writer dumps no boolean objects). With nowhere to write the answer holds for the session.

**Nobody to ask** — a one-shot run, `--json` and the stream flags, the Hall, ACP (whose runs
are one-shot raider processes of the hall), a REPL whose input is not a terminal: pending
servers stay off and one line per server says so and how to approve it (`mcp: server NAME
(.mcp.json) is not approved and stays off; approve it in an interactive raider, or add it to
enabledMcpjsonServers in .claude/settings.local.json` — or `mcp_approvals of
~/.raider/config.yml`). The command line prints these lines on stderr, so machine output on
stdout stays one document or one event stream; the REPL prints them as meta lines;
`config explain` and `/mcp` show `pending approval`. **Deliberate difference:** Claude Code
starts unapproved project servers in `-p` runs; raider does not — a repository's servers do
not run in a script nobody watches.

### 8. Disabled servers

`disabledMcpServers` of the project's entry in Claude's global config (Claude Code's `/mcp`
toggle) turns off `local`, `user` and `plugin` servers by name (Claude layout): status
`disabled`. Raider has no toggle of its own and does not write that list.

### 9. Statuses

Of the configuration (slice 1): `configured` (will be started), `pending` (approval),
`rejected`, `disabled`, `unsupported`, `not_configured`, `invalid`; of a started server
`starting`, then `connected` or `failed`, and `stopped` after the end — each with a reason
and the warnings (`MCP->report` merges both). In Claude Code's words:
`✔ Connected`, `✘ Failed to connect`, `⏸ Pending approval`, `✘ Rejected`, `⊘ Disabled`.

### 10. Connection and mounting (slice 2)

**Protocol: raider's own client, the `initialize` handshake.** The installed
`Net::Async::MCP` (0.006) speaks only the stateless revision 2026-07-28: it opens with
`server/discover`, puts `io.modelcontextprotocol/*` `_meta` on every request, and never falls
back. A server of any earlier revision — every third-party server today (Node and Python
SDKs: 2025-03-26, 2025-06-18) — answers "Method not found", and the client gives up (its
renegotiation only follows `-32022` to versions it speaks). Its HTTP transport sends
`MCP-Protocol-Version: 2026-07-28` and no `Mcp-Session-Id`, which such servers refuse; its
stdio transport takes only a `command` (no environment, no working directory) and throws
stderr away. So raider talks to configured servers itself:

**Why not `Net::Async::MCP`, and when raider goes back to it.** Raider depends on
`Net::Async::MCP` for its own in-process tool servers, and a second MCP client in this
distribution is a cost: two code paths for one protocol. It is paid because the alternative
does not work: with 0.006 raider could reach no server that exists outside Getty's own
2026-07-28 stack — not one `npx`/`uvx` server, not one hosted HTTP server — and the gaps are
in its protocol choice, not in options raider could set (no `initialize` fallback, a fixed
`MCP-Protocol-Version`, no session id, no environment or working directory for a process,
stderr thrown away). Patching it from raider (subclassing private transport methods) would
couple raider to its internals. Raider's own client is small (`MCP::Server`, `MCP::Stdio`,
`MCP::HTTP`), speaks only what raider uses (handshake, `tools/list`, `tools/call`), and keeps
the duck-typed interface of `Net::Async::MCP` (`initialize`, `list_tools`, `call_tool`), so
nothing else in raider knows which client a server has. **Raider switches back** — replacing
`MCP::Stdio`/`MCP::HTTP` and the handshake in `MCP::Server` by a `Net::Async::MCP` client,
keeping `MCP::Server` as the status/prefix/timeout layer — once a released `Net::Async::MCP`
(1) falls back to the `initialize` handshake when `server/discover` is refused and accepts the
revision the server answers with, (2) sends the negotiated `MCP-Protocol-Version` and the
`Mcp-Session-Id` over HTTP, and (3) lets the stdio transport set the environment and the
working directory and hand on stderr — and raider's tests (t/254, t/255, the scenarios) pass
against it. That is a ticket on the p5-net-async-mcp board, not a change raider makes there.

- `initialize` with `protocolVersion` 2025-11-25, `capabilities` `{}`, `clientInfo`
  `raider`; any of 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 in the answer is accepted
  (the handshake, `tools/list` with its cursor and `tools/call` are the same in all), any
  other revision fails with a reason; then `notifications/initialized`, then the tools,
  listed once at the start. A server that answers `initialize` with "Method not found"
  (2026-07-28 only) fails with a reason that says so. The installed Perl `MCP::Server`
  (0.15) still answers this handshake (`MCP::Server::Legacy`), so raider's own Perl servers
  work too (tested).
- Requests the server sends (`ping`, `roots/list`, …) get `{}` for `ping` and "Method not
  found" otherwise; notifications from the server (`list_changed`, logging) are ignored.
- **stdio** (`MCP::Stdio`): the process runs in its own session (`setsid`, as hooks do, so a
  Ctrl-C of the REPL does not reach it), in the root, with raider's environment minus an
  inherited `CLAUDE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_DATA`, plus the entry's `env`, plus
  `CLAUDE_PROJECT_DIR` (the project dir, as Claude Code sets it) and, for a plugin's server,
  its `CLAUDE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_DATA` (the data directory is created when the
  entry names it). A program that cannot be run exits 127 with `cannot run X: …` on stderr.
  Stderr never reaches raider's terminal: the last 20 lines are kept for the status. Stop:
  stdin closed, `TERM` to the process group after 2 s, `KILL` after 2 more (the MCP
  specification's order); an application that goes away kills what is left.
- **http** (`MCP::HTTP`): one JSON-RPC message per `POST` with `Accept: application/json,
  text/event-stream`; a JSON body or an event stream (events handled on the next loop turn,
  never inside the HTTP client's read callback); the `Mcp-Session-Id` of the `initialize`
  answer and `MCP-Protocol-Version` on every later request (a configured header of either
  name is dropped); `DELETE` with the session id when stopping. **Every request has a
  `Net::Async::HTTP` client and a connection of its own:** with one shared client (0.50),
  two connections opened at once to the same host could leave a request waiting forever
  (seen in the tests), and a single connection would queue every call behind a slow one.
  No standalone `GET` stream, no resumption.
- **Start**: every `configured` server in parallel (`MCP->start_f` of the application's
  `configured_mcp` — not `mcp`, a name a subclass may well use for something of its own —
  awaited at the start of `Application->raid_f`), each bounded by `MCP_TIMEOUT`; one that fails, hangs or exits is
  `failed` with the reason (`exited with code 3 (stderr: …)`, `did not start within 30 s
  (MCP_TIMEOUT)`, …) and never aborts the run. Each start that ends emits `mcp.server`
  (name, scope, transport, status, reason, tools) to `on_event` — not into the journal yet:
  its event list is being changed by the parallel stream A2 (follow-up).
- **Mounting**: the servers' clients **lead** the engine's `mcp_servers`, ahead of raider's
  own servers, so their `engine:N` stay the same whatever raider remounts
  (`_remount_tool_servers` keeps them in front); `MCP->source_servers` maps those `engine:N`
  to the server part of the names, the policy's `source_servers` (ADR 0021). Their tools all
  start with `mcp__`, so they never shadow one of raider's.
- **Calls**: the original tool name, bounded by the server's `timeout` / `MCP_TOOL_TIMEOUT`;
  a call that runs out is cancelled (`notifications/cancelled`) and fails (`MCP tool call
  timed out after N s`), a JSON-RPC error fails the call (`MCP error CODE: MESSAGE`), an
  `isError` result stays a result. `_meta` keys under `raider/` are removed from every
  result: `Langertha::Raider` takes user messages from `_meta.raider/messages` of its own
  (`engine:N`) sources, and a foreign server must not put words in the user's mouth.
- **Policy and hooks**: a foreign tool is unknown to `ToolEffects`, so the mode asks for it
  (ADR 0021 §3), plan mode too. `mcp__server__tool` rules compare their tool part with the
  part of the call's name after `mcp__server__`; `mcp__server` and `mcp__server__*` cover the
  whole server; "yes, for this session" offers the tool's own name. Hook matchers see the
  `mcp__…` name unchanged (`PreToolUse:mcp__t__fail hook error: …`).

### 11. Surfaces, subagents, lifecycle (slice 3)

- `raider config explain` (and `/config`) lists every server (`Application->mcp_report`):
  name, status in Claude Code's words, scope, transport, source, reason, approval with its
  source, warnings, shadowed entries; the files that could not be read, the timeouts, trust
  and where answers are written. Before a start the status is the configuration's
  (`configured`, `pending approval`, …). `config explain` has text output only.
- REPL `/mcp`: the servers are started first when they are not yet (in parallel, each within
  `MCP_TIMEOUT` — as `claude mcp list` checks them), then the same per server, plus its tools
  and, for a failed one, the last three stderr lines; `/mcp reconnect [NAME|all]` stops a
  server and starts it again at once, in the same place (same `engine:N`), and waits for the
  start. A built-in of ADR 0030 (`cmd_mcp`): in `/help` and the slash command table of the
  generated skill, and like every built-in replaced by a user-invocable skill or custom
  command named `mcp` (ADR 0030 §3).
- **One-shot `raider -p /mcp`** is a reporting built-in (ADR 0030 §4): it connects, prints
  the report, stops the servers and exits 0. `/mcp reconnect` in a one-shot run is a usage
  error (exit 2) — it would restart a server of a run that is ending. Every early end of a
  one-shot `/command` stops the configured servers.
- Subagents use the same connections (no second process), filtered by their `tools:` /
  `disallowedTools:` like every other tool. **Built in slice 2**, because the subagent's
  policy (`for_subrun`) keeps the caller's `source_servers`: a subagent engine without the
  configured servers in front would have numbered raider's own servers `engine:1…` and the
  gate would have taken them for foreign ones. `MCP->views` gives one
  `MCP::View` per configured server, in the same order and so with the same `engine:N` —
  a view that hides every tool keeps its place. An entry of the agent's lists names a tool
  (`mcp__server__tool`) or a whole server (`mcp__server`, `mcp__server__*`); without
  `tools:` every tool passes; `disallowedTools:` wins.
- **Lifecycle.** The one-shot run and the REPL stop every server when they end
  (`shutdown_mcp`: stdin closed, `TERM`, `KILL`). A cancelled run (the first Ctrl-C, the
  hall's `SIGINT`) leaves them alone — they belong to the session, like the background
  shells of `bash` (`Runner->cancel_run` keeps `mcp_pids`); a `SIGTERM`, the REPL's second
  Ctrl-C and the end of the process end them with every other child (`terminate_children`,
  and `MCP` kills what is left when it is destroyed). A server is in its own session, so
  only raider ends it. Hall and ACP runs are one-shot raider processes and end the same way.
- **`/reload`** (`reload_context` → `reload_mcp`, after the config files and settings were
  read again): a new set is built from the new configuration; a server configured exactly as
  before (`MCP::Server->fingerprint`: transport, command, arguments, the whole environment,
  directories, URL, headers, prefix, timeout) that is starting or connected keeps its
  connection; the others are stopped (and waited for), new ones start with the next raid. The
  front of the engine's `mcp_servers` and the policy's `source_servers` are changed in place.
- **`mcp.server` events** reach `on_event` (and with `--stream-json` the event stream, as any
  event of a run, ADR 0013), but not the session journal: its list of journal types is being
  changed by the parallel stream A2. Follow-up once both are merged.

## Not supported

`sse` and `ws` transports, `type: sdk`, `headersHelper`, `oauth` and every OAuth flow,
`managedMcpServers` and managed settings (`allowedMcpServers`, `deniedMcpServers`,
`allowManagedMcpServersOnly`), claude.ai connectors and their deduplication by endpoint,
`--mcp-config` / `--strict-mcp-config`, `enabledMcpServers` (built-in default-off servers),
`MAX_MCP_OUTPUT_TOKENS` and the spill file, MCP resources and prompts (only tools), the
approval lists Claude Code's older versions kept in the `projects` entries of
`~/.claude.json`, `claude mcp reset-project-choices`, the stateless revision 2026-07-28
(`server/discover`), the standalone `GET` event stream and resuming streams of streamable
HTTP, `notifications/tools/list_changed`, sampling / elicitation / roots requests from a
server.

## Consequences

- In a Claude Code project raider now starts the person's MCP servers. A repository's
  `.mcp.json` servers wait for an approval; tests must isolate `$HOME` /
  `$CLAUDE_CONFIG_DIR` (already the rule, ADR 0019).
- Running servers means running external programs from the packed binary (stdio: fork,
  `setsid`, `exec` through `IO::Async::Process`, as hooks do) and speaking HTTP
  (`Net::Async::HTTP`, `HTTP::Request`, already packed for the web tools;
  `Langertha::Raider::ConnectCheck` before every request). Nothing new is loaded by name and
  there is no new dependency; the packed binary still needs a check (stream B).
- Follow-ups: for `Net::Async::MCP` (its repository): fall back to the `initialize`
  handshake for servers before 2026-07-28, `Mcp-Session-Id` and the negotiated
  `MCP-Protocol-Version` in the HTTP transport, `env`/`cwd` and stderr in the stdio
  transport — then raider could use it again. Raider: `mcp.server` into the journal;
  `notifications/tools/list_changed` (raider lists the tools once); ADR 0004's trust
  replaces Claude Code's trust record as the decision once it exists.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream M1); the coordinator's design brief for k164 (design questions decided by the
stream). Complements ADR 0004 (trust), ADR 0005 (tool sources), ADR 0011 (home config),
ADR 0019 (layout, settings, plugins), ADR 0021 (permissions) and ADR 0022 (hooks).
