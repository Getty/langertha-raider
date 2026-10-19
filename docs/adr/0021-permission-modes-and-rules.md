# ADR 0021 — Permission modes and rules like Claude Code

- Status: accepted
- Date: 2026-10-19
- Tags: tools, policy, security, claude-code, cli
- karr: #154 (stream P of the Claude Code flow plan)

## Context

ADR 0005 decided the one execution path (validate → resolve → check policy → ask for
approval → execute) and that permissions never come from prompts. Its parts existed
without a policy: the gate `_tool_gate` of `Langertha::Raider` (k121) answered
allow/deny/ask for every tool call, but the application set no gate, so every call ran;
`Langertha::Raider::Approval` (k124) bound an approval to session, run, tool, arguments and
policy revision, but nothing created or consulted one; an `ask` was refused like `deny`
("this raid has no way to ask for it"). Claude Code, which raider is to behave like in a
Claude Code project (plan "raider wie Claude Code", ADR 0019), has permission modes
(`default`, `acceptEdits`, `plan`, `bypassPermissions`), allow/ask/deny rules in its
settings (`Bash(npm run test:*)`, `Edit(src/**)`, `Read(~/.ssh/**)`,
`WebFetch(domain:x)`, `mcp__server__tool`) and asks at the terminal ("yes" / "yes, for
this session" / "no"). ADR 0019 already reads `permissions` from the settings but only
stores them.

## Decision

### 1. Two internal modules

`Langertha::Raider::Permissions::Rule` is one parsed rule: its text, source, kind
(allow/ask/deny), the tools it applies to and its specifier, with `matches($call, $ctx)`.
`Langertha::Raider::Permissions` is the policy of one session: the mode with its source,
the rules with their sources, the session rules and the additional directories;
`decide($call)` answers the canonical call of the gate with
`{ verdict, by, reason, rule, source, mode }`; `policy_revision` is a SHA-256 over the mode,
every rule with its source, the session rules and the directories, so a mode switch or a
new session rule invalidates approvals given before. Both carry the internal marker
(ADR 0017).

**Sub-runs** (stream A, sub-agents) take `for_subrun`: a new policy with the parent's
current mode and its rules, directories and source servers, sharing the *same* session
rules array. A mode change stays with the policy that made it (a sub-agent leaving plan
mode does not take the session along); a rule allowed for the session in either holds in
both; nothing widens a sub-run beyond its parent. The agent tool uses it for every
subagent (ADR 0020 §4).

### 2. Rule syntax: Claude Code's

- Tool names go through `Langertha::Raider::ToolNames` (ADR 0018); raider names are
  accepted too. `Read` stands for every reading file tool (`read_file`, `list_files`,
  `glob`, `grep`), `Edit` / `Write` / `MultiEdit` for every writing one (`write_file`,
  `edit_file`). `Agent(name)` / `Task(name)` match the `subagent_type` of an `agent` call,
  `Skill(name)` the skill name.
- `Tool` alone: every call of the tool.
- `Bash(cmd)` exact, `Bash(prefix:*)` prefix at a word boundary (`npm run test:*` covers
  `npm run test` and `npm run test -- x`, not `npm run tests`), `*` as a glob anywhere
  (`Bash(git * --dry-run)`). The command is split, outside quotes, at `&&`, `||`, `;`, `|`,
  `&`, newlines and parentheses; `$(…)`, backticks and `<(…)`/`>(…)` are searched as
  commands of their own, inside double quotes too.
  - **deny / ask match when any part matches**, also with leading `if/then/do/…`, plain
    wrappers (`sudo`, `env`, `nohup`, `exec`, `command`) and `VAR=value` taken off.
  - **allow covers a command only when every part is covered by some allow rule**, each
    part as written; a command with a substitution, a heredoc, a redirection into a file
    (not `/dev/null`, not `>&2`) or unbalanced quotes is never covered by a rule with a
    specifier and falls back to the mode. A bare `Bash` allows everything. An exact rule may
    name a whole command of several parts (`Bash(make && make test)`) — this is what "yes,
    for this session" adds.
  - **A deny rule on bash is not a security boundary.** Bash can do anything; a wrapper
    with options (`nice -n`, `xargs`, `find -exec`, `bash -c`) or an alias escapes any
    pattern. Deny rules on bash catch the plain cases; the boundary is the allow side and
    the mode.
- `Read(path)` / `Edit(path)`: `//abs` absolute, `~/x` under the home, `/x`, `./x` and
  `x/y` under the project root, gitignore-style globs (`*`, `**`, `?`). A pattern without a
  slash matches at any depth under the root; `dir/**` also names `dir`; a pattern that
  matches a directory covers everything below it. The path of the call is resolved as the
  file tools resolve it (relative to the root, `..` taken out, symbolic links followed);
  deny/ask match when the written or the real path matches, allow only when both do — a
  `../` or a symlink cannot get around a deny rule.
- `glob` / `grep`: the rule is held against the search root. When a deny or ask rule names
  the root (or a directory above it), the search is refused. Otherwise the search tools
  leave the files such a rule names out of their results and say
  `(N paths hidden by permission rules)` (`SearchTools` `hider`; while it is in force grep
  runs the Perl code). Refusing every search of a tree that might contain a denied path
  made `Read(./.env)` block every project-wide grep.
- `WebFetch(domain:host)` matches the host of `url`; `domain:*.host` its subdomains.
  `WebSearch` only as a name.
- `mcp__server`, `mcp__server__*`, `mcp__server__tool` match tools of a foreign MCP server:
  a `catalog:NAME` source is server `NAME`; an `engine:N` source is raider's own unless the
  policy's `source_servers` names it (the application mounts only its own servers today).
- **A rule with a raider tool name applies to a foreign tool of that name only as deny or
  ask**: `Bash` allows raider's `bash`, never another server's `bash`.
- A rule that cannot be parsed or names an unknown tool is ignored (it never widens
  anything) and shown, with its source, by `config explain` and `/permissions`.
- Order across all sources: deny before ask before allow, then the mode. A deny rule from
  any file wins over an allow rule from any other.

### 3. Modes

Without a matching rule:

| Mode | allowed | asks | refused |
|---|---|---|---|
| `default` | tools that only read or have no effects; `ask_user`, `raider_ask_user`, `todo_write`, `skill`, `exit_plan_mode` | write, code, network, message; every foreign or unknown tool | — |
| `acceptEdits` | as default, plus `write_file` / `edit_file` inside the root or an additional directory | the rest as default (bash too) | — |
| `auto` (Nachtrag P2) | as `acceptEdits`, plus bash commands from the fixed read-only allowlist | the rest | — |
| `plan` | as default for reading and control tools | network; foreign and unknown tools | write, code, message — "plan mode: … present your plan with exit_plan_mode first"; **allow rules do not lift it** |
| `bypassPermissions` | everything | — | **only what a deny rule names** |

Effects are those of `Langertha::Raider::ToolEffects`, only for raider's own tools. In plan
mode a foreign or unknown tool asks rather than being refused: a person decides, and an
MCP tool that only reads stays usable.

The mode, first that is set: `--dangerously-skip-permissions` (= `bypassPermissions`) or
`--permission-mode MODE` > `permissions.default_mode` of `.raider/config.yml`, then of
`~/.raider/config.yml` > `defaultMode` of the Claude settings (local > project > user) >
`default`. An unknown mode on the command line is a usage error; from a file it is
skipped, falls through to the next source and is reported by `config explain`.

### 4. Rule sources

The Claude settings in the Claude layout (ADR 0019 §3), and `permissions:` of
`.raider/config.yml` and `~/.raider/config.yml` — snake_case like the rest of the raider
config (`allow`, `ask`, `deny`, `default_mode`, `additional_directories`), rules as strings
in Claude Code syntax. Every source's lists are concatenated with the source kept. Only the
top level of a config file is read; a `permissions:` inside an engine section is reported.
A wrong shape is a configuration error (exit 3), camelCase keys get a hint. `--bare` reads
no Claude layout but keeps the rules of the raider config files: they are local policy, not
context.

### 5. The gate is always on in the application

The application builds the policy (`permissions`) and hands `tool_gate` to every raider it
builds — the main raider and the prompt builder's. `Langertha::Raider` on its own still has
no gate, and everything runs (library behaviour unchanged).

### 6. Asking

A surface that has a person sets `on_permission_request` (the REPL does when its input is a
terminal, as for `ask_user`). It is asked synchronously, like `ask_user`, with the tool, its
arguments, the reason and the rule "for this session" would add — shown before the choice:
`Bash(<exact command>)`, `Edit(<directory relative to the root>/**)` (`Edit(/**)` in the
root), `WebFetch(domain:<host>)`, `mcp__server__tool`, else the tool name. No rule is
offered for a command with a substitution, a redirection into a file or a heredoc.

- **once**: an `Approval->for_call` of exactly this call (session, run, tool, source,
  canonical arguments, policy revision), checked with `covers` as the call is about to
  run; nothing is kept. A run without a session uses a stable stand-in id per application,
  so `for_call` never croaks.
- **for this session**: the rule becomes a session rule (memory only), then the call is
  decided again.
- **no** (with an optional reason): an error result "The user refused this call: <reason>.
  Do not try the same call again; ask the user what they want or change your plan."

With nobody to ask — a one-shot run, `--json`, the Hall (ACP sessions excepted, Nachtrag P2), a library without the
callback — an ask is refused with the reason, the rule that would allow the call, where to
put it (`.raider/config.yml`, `.claude/settings.json` in the Claude layout) and the
`--permission-mode` that would. The raider's own text for an ask that reaches it ("this
raid has no way to ask for it") became "nobody can approve it in this raid. Do not retry
the same call; …".

The prompt builder (`/prompt`, `--customize-prompt`) uses the same gate and so the same
question: it runs in the REPL with the same person at the keyboard, and its job — writing
the instructions file — is exactly what default mode asks about.

### 7. Events

`permission.asked` (tool, reason, `suggested_rule`), `permission.granted` (scope `once` or
`session`, rule), `permission.denied` (`by`: `rule`, `mode`, `user` or `noninteractive`;
rule, source, reason), `permission.mode` (from, to, why). All four go into the session
journal (ADR 0015) and to every `on_event`; per ADR 0013/0015 new event types need no new
version. Calls allowed by a rule or the mode emit nothing.

### 8. `exit_plan_mode`

An internal tool module (`Langertha::Raider::PlanTools`, the `AskTools` pattern) with one
argument `plan`; empty effect list. It is mounted once the application has been in plan
mode — at the start, or after `/permissions mode plan` — and stays mounted. With a person
(`on_plan_review`, the REPL) the plan is shown and accepted (mode `default`,
`permission.mode` why `exit_plan_mode`, "User approved the plan. You can now start editing
files and running commands") or refused with feedback (stays in plan). With nobody: "Nobody
can approve the plan in this run. Stay in plan mode and give the plan as your final
answer." Outside plan mode it is an error result "not in plan mode".

### 9. Additional directories

`additionalDirectories` of the settings and `additional_directories` of the raider config,
relative entries against the root and `~/` against the home. The file tools
(`build_file_tools_server` `extra_roots`) and the search tools (`extra_roots`) work in them as
in the root (symlink escapes still refused; search results there are absolute paths); their
calls follow the same modes and rules.

### 10. Command line and REPL

`--permission-mode MODE`, `--dangerously-skip-permissions` (not together). REPL:
`/permissions` (mode with source, every rule with source, session rules, invalid rules,
additional directories), `/permissions mode NAME` (`permission.mode`). The question shows
the tool, a one-line summary (bash: the command; files: the path; web: the URL), the
reason and `1) yes, once`, `2) yes, for this session: RULE`, `3) no`; `3` or `n` asks for
an optional reason. `/reload` reads the permission sources again and keeps the session
rules and a mode switched during the session.

### 11. Hall and ACP

A hall raider entry may set `permission_mode`, passed as
`--permission-mode`; without it the project decides as in §3 (the hall does not validate
the name — the raider refuses an unknown one). ACP runs through the hall. A run that
belongs to no ACP session (control socket, cron, Telegram) is non-interactive: an ask is
refused. A run of an ACP session asks the ACP client (Nachtrag P2, below).

### 12. `config explain`

A `permissions` section: the mode and its source, ignored mode names, the rule counts per
kind by source (all rules in `/permissions`), invalid rules with source and error, the
additional directories.

### Deliberate differences from Claude Code

- **Deny rules hold in `bypassPermissions`.** Claude Code skips every check there; raider
  keeps local policy above a mode, so a user's `~/.raider/config.yml` deny cannot be
  switched off by a flag in a script.
- **Strict composition for allow.** Every part of a command must be covered, and a
  substitution or a redirection into a file is never covered by a specifier rule.
- **Search instead of block.** grep/glob hide denied files and say how many, instead of
  Claude Code's best effort.
- Rules with raider names never allow a foreign tool of that name; plan mode asks for
  foreign tools; `/x` in a rule is relative to the project root (Claude Code: to the
  settings file).

## Consequences

- **Incompatible:** a run nobody can approve (one-shot, `--json`, Hall, ACP) in the
  `default` mode without rules now refuses writing, bash, the network and messages. Remedy:
  allow rules, `default_mode` / `defaultMode`, `--permission-mode acceptEdits` or
  `bypassPermissions`, or `permission_mode` on a hall raider. Tests and scenarios that test
  tools, not approvals, run in `bypassPermissions` (scenario harness default).
- Follow-ups (not built): no scenario for `mcp__` rules, because the harness cannot mount
  a foreign MCP server. ACP's `session/request_permission` and live additional directories
  after `/reload` are built, see Nachtrag P2. (The inheritance of the policy into sub-agents
  through `for_subrun` is built: ADR 0020 §4.)

## Nachtrag P2 (k158)

Three follow-ups of the first slice.

### P2.1 `/reload` reaches the additional directories of the mounted tools

§9 said the file and search tools keep the directories they were built with. That is
withdrawn. `extra_roots` of `build_file_tools_server` and of `SearchTools` may be a CodeRef
returning the list; it is called on every tool call. The application passes one that reads
`permissions->additional_directory_paths`, so `reload_permissions` (which replaces the policy)
is enough: a directory added is reachable and one removed refused from the next call on. An
ArrayRef still works for libraries. Each call resolves the roots with `realpath` again, so
the symlink-escape check is unchanged.

### P2.2 `defaultMode: "auto"`

Claude Code's `auto` mode (a classifier decides) has no counterpart in raider and was skipped
as an unknown mode. It now maps, strictly, to **`auto`: acceptEdits plus a fixed allowlist of
read-only bash commands**; everything else asks. `auto` is a fifth mode name
(`default acceptEdits auto plan bypassPermissions`), resolved at one place
(`Permissions::decide`) and therefore valid wherever a mode is: `--permission-mode auto`,
`permissions.default_mode: auto` of the raider config, `defaultMode: "auto"` of the Claude
settings, `/permissions mode auto`, `permission_mode: auto` on a hall raider. Other Claude names
(`dontAsk`, ...) are still skipped and reported. The mode is part of `policy_revision`
(approvals given in another mode are void).

- Order is unchanged: deny rules first (they hold in `auto`), then ask rules, then allow
  rules, then the mode. Allow rules of the person add to the allowlist.
- The allowlist lives in `Langertha::Raider::Permissions::ReadOnlyBash`, fixed and not
  configurable (more commands = allow rules). The command is split by `Rule->shell_parts` and
  **every part** must be on the list, written as a plain command word without path, wrapper or
  `VAR=value`; the whole command must be free of substitutions, heredocs, redirections into a
  file (`/dev/null` and `2>&1` are fine) and open quotes; every argument is a plain word or a
  quote without `$`, backtick or backslash. So `git status && ls` runs, `git status; rm x`,
  `cat $(x)` and `ls > f` ask.
- Commands: `ls pwd cat head tail wc echo which uname whoami id basename dirname realpath
  readlink stat du df cut tr nl diff sha256sum sha1sum md5sum cksum jq ps uptime nproc cd true
  false`; `date` only to show a time; `uniq` with at most one file; `sort` without `-o` /
  `--output`; `grep egrep fgrep rg` without `--pre`, `--pre-glob`, `--hostname-bin`, `-z`,
  `--search-zip`; `find` without `-exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf
  -fls`; `git` directly followed by `status diff log show blame describe shortlog rev-parse
  ls-files ls-tree cat-file` (no global options, none of `--output`, `--ext-diff`,
  `--open-files-in-pager`, `--textconv`, `--exec-path`, also not abbreviated) and `git
  branch/remote/tag` only to list.
- Known residue: git runs what the repository's own config names (pager, `core.fsmonitor`,
  textconv drivers). `auto` trusts the repository like `acceptEdits` trusts the root.
- `config explain` and `/permissions` show the mode with its source and the mapping line
  `claude auto -> raider acceptEdits + read-only bash allowlist` (for a mode from the Claude
  settings; `auto -> acceptEdits + read-only bash allowlist` otherwise).

### P2.3 ACP `session/request_permission`

Read: <https://agentclientprotocol.com/protocol/tool-calls> (ACP protocol version 1): the
agent MAY send `session/request_permission` with `sessionId`, `toolCall` (a ToolCallUpdate;
`toolCallId` required) and `options` (`optionId`, `name`, `kind` in `allow_once`,
`allow_always`, `reject_once`, `reject_always`); the client answers with `result.outcome`
either `{ outcome: "cancelled" }` or `{ outcome: "selected", optionId }`, and MUST answer
`cancelled` when the prompt turn is cancelled.

The hall starts every run as a separate raider process with no stdin, so the question needs a
channel back:

- **Channel.** For a run bound to an ACP session, `Hall::_spawn_raider` creates a
  `Hall::PermissionChannel` (a Unix socket in a private 0700 temp directory, removed when
  the run is reaped) and passes its path as the hidden option `--permission-channel PATH`.
  The raider process sets `Langertha::Raider::PermissionChannel` as `on_permission_request`
  (not in the REPL). JSON Lines: `{id, tool, source, arguments, reason, rule}` →
  `{id, answer: once|session|no, reason}`. The raider blocks synchronously like the REPL's ask.
- **Who asks.** The ACP adapter registers per session a handler
  (`Hall::register_permission_handler(binding, cb)`; dropped with the session). Runs of a
  binding without a handler (control socket, cron, Telegram) get no channel and no option and
  are refused as before. The adapter sends `session/request_permission` on the session's
  stream and matches the client's response by `id` in `_dispatch` (until now it ignored all
  responses).
- **Options.** `allow_once` ("Allow once") → `once`; `allow_always` ("Allow for this session:
  RULE") → `session` (a session rule in the raider, exactly as in the REPL; offered only when
  a rule can name the call); `reject_once` ("Reject"). `reject_once`, `reject_always`, a
  `cancelled` outcome, an unknown or missing `optionId`, an error response → `no`. The title
  is `tool: command|path|url`, `kind` is `execute|edit|fetch|read|search|other`, `rawInput` the
  arguments, the reason the text content.
- **Deny by default.** No answer within `permission_timeout` of `.raider-hall.yml` (default
  120 s), a closed client connection, an ended ACP session, `session/cancel` while a question
  is open (the adapter answers `no`, then the hall cancels the run as before), a handler that
  fails, an unreachable or closed channel, a channel answer that is not `once`/`session`, a
  raider-side wait of 300 s, or a cancel of the run (the raider polls
  `Application::run_cancelled` every 0.25 s) all give `no`: the model is told the user refused,
  the run goes on. Nothing in the chain defaults to allow.
- **Hang.** The hall has no hang detection for runs; a run waiting for an answer is never
  killed for that. Cancel works as before (SIGINT, escalation) and also ends a blocked ask.
- **Events.** `permission.asked/granted/denied` are emitted by the raider as before (and are
  in the run's events file); the adapter forwards nothing extra.
- **Capabilities.** `initialize` announces nothing new; asking is the agent's right in ACP.
- **Client side.** `Langertha::Raider::ACP::Client` takes `on_permission`; without one, or
  with one that picks no offered option, it rejects (`reject_once`, else `cancelled`). It
  also no longer mistakes an agent request with the same `id` for the response to its own call.
  `raider acp connect` asks at the terminal (a number picks, anything else rejects);
  `raider acp prompt` rejects (a `--allow` flag was not built: it would be a standing
  allow on a command line).
- **Packing.** New modules loaded by `use` only; `IO::Socket::UNIX` and `IO::Select` are core
  Perl. No new by-name loads, no new dependency.

## Source

Plan `perl-developer/docs/superpowers/specs/2026-10-19-raider-claude-code-flow.md`
(stream P, decision 4 by the maintainer; the decisions of the coordinator for k154).
Complements ADR 0005 (gate, approval), ADR 0018 (tool names, effects) and ADR 0019
(settings).
