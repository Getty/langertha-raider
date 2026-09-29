# Langertha::Raider

The autonomous agent engine of [Langertha](https://metacpan.org/dist/Langertha)
(`Langertha::Raider`, plus the `Langertha::Raid` orchestration layer) together with
the `raider` command-line agent built on it (`Langertha::Raider::CLI`).

`raider` is an autonomous command-line agent in Perl. It wraps `Langertha::Raider`
with a practical toolbox — filesystem, bash, web search, web fetch, optional
Perl-native tools — and drops you into a REPL (or a one-shot run) where a viking
shield-maiden named **Langertha** does the work, against any of the 15+ LLM
providers Langertha speaks.

```
             __     __
.----.---.-.|__|.--|  |.-----.----.
|   _|  _  ||  ||  _  ||  -__|   _|
|__| |___._||__||_____||_____|__|
 perl agent - powered by Langertha
```

> This README describes what `raider` **does today**. The wider vision — the
> home-directory assistant, provider discovery, delegates, reviewed long-term
> memory, editor integration over stdio — lives in
> [`CONTEXT.md`](CONTEXT.md) and the ADRs under [`docs/adr/`](docs/adr/), and is
> collected under [Roadmap / Planned](#roadmap--planned) below so you can tell
> the two apart.

## One tool, two jobs

Raider is designed to be two things from one kernel: a **project agent** that works
inside a directory (like Claude Code), and a personal **assistant** that lives in
your home and is reachable everywhere (like a Hermes agent).

Today the **project-agent** side is what ships: you run `raider` in a project, it
reads that project's instructions and tools, and records its work in per-project
sessions. The **assistant** side (the `~/.raider/` home profile, reviewed long-term
memory, home-mounted services) is largely on the [roadmap](#roadmap--planned); the
Hall already covers the always-reachable, long-lived, Telegram/cron part of it.

## Quick start

From CPAN:

```bash
cpanm Langertha::Raider
export ANTHROPIC_API_KEY=...     # or OPENAI_API_KEY, GROQ_API_KEY, ...
cd ~/dev/my-project
raider                           # REPL opens in the current directory
```

From a git checkout:

```bash
cpanm --installdeps .
perl -Ilib bin/raider
```

Or via Docker — no Perl toolchain required (see [Docker](#docker)):

```bash
docker run --rm -it -v "$PWD:/work" -e ANTHROPIC_API_KEY raudssus/raider
```

Then tell Langertha what to do:

```
raider> lies die Changes und schreib mir ne kurze summary
raider> such im web nach "Perl 5.40 release notes", dann hol den ersten treffer
raider> prove -l t/ laufen, falls was rot ist report zurück
```

One-shot usage (no REPL):

```bash
raider "check git status and summarize"
raider --json "count the .pm files in lib" | jq .
```

When stdin is a terminal and you give no prompt on the command line, `raider` drops
into the REPL automatically. With [`Term::ReadLine::Gnu`](https://metacpan.org/pod/Term::ReadLine::Gnu)
installed, line editing and persistent input history (`~/.raider_history`) are on.

## How it picks an engine

Zero configuration: the first `*_API_KEY` found in the environment decides the
engine (in the order below), and a cheap model is used by default.

| Engine     | Env var                              | Default model             |
|------------|--------------------------------------|---------------------------|
| anthropic  | `ANTHROPIC_API_KEY`                  | `claude-haiku-4-5`        |
| openai     | `OPENAI_API_KEY`                     | `gpt-4o-mini`             |
| deepseek   | `DEEPSEEK_API_KEY`                   | `deepseek-chat`           |
| groq       | `GROQ_API_KEY`                       | `llama-3.3-70b-versatile` |
| mistral    | `MISTRAL_API_KEY`                    | `mistral-small-latest`    |
| gemini     | `GEMINI_API_KEY`                     | `gemini-2.5-flash`        |
| minimax    | `MINIMAX_API_KEY`                    | `MiniMax-M3`              |
| cerebras   | `CEREBRAS_API_KEY`                   | `llama3.1-8b`             |
| openrouter | `OPENROUTER_API_KEY`                 | *(set `-m`)*              |
| ollama     | *(none — local)*                     | `llama3.3`                |

Auto-detection tries `anthropic`, `openai`, `deepseek`, `groq`, `mistral`, `gemini`
in that order, and falls back to `anthropic`. Override with `-e <engine>`,
`-m <model>` or `-k <key>`.

`raider` uses provider API keys only. Claude Code subscription / OAuth credentials
from `~/.claude` are not read or reused as Anthropic API credentials.

## Commands and options

```
raider [options] [prompt...]        run a prompt (or open the REPL)
raider config explain [options]     show each effective setting and its source
raider session list | show | resume | fork | rm     see Sessions
raider hall <subcommand>            the optional Raider Hall daemon
raider acp <subcommand>             the bundled ACP client
```

Options:

```
  -e, --engine NAME        anthropic, openai, deepseek, groq, mistral, gemini,
                           minimax, cerebras, openrouter, ollama (default: auto)
  -m, --model NAME         Model identifier (engine-specific cheap default)
  -k, --api-key KEY        API key (overrides *_API_KEY env var)
  -o, --option KEY=VALUE   Engine attribute (repeatable), e.g. -o temperature=0.2
  -r, --root DIR           Working directory (default: cwd). File tools are
                           confined to this directory.
  -M, --mission TEXT       Replace the persona / .raider.md instructions
                           (skills, packs and the tool descriptions still apply)
      --bare               Isolated context: no .raider.md, skills or detection
                           (--pack NAME and /pack still work)
  -i, --interactive        REPL mode (default on a TTY with no prompt / pipe)
      --json[=N]           Print one JSON document for the run and exit
      --msgpack[=N]        The same document as MessagePack
      --yaml[=N]           The same document as YAML
      --stream-json[=N]    Print the run as JSON Lines events as it happens
      --stream-msgpack[=N] The same events as MessagePack objects
      --stream-yaml[=N]    The same events as YAML documents
      --no-session         Do not record the run(s) in a session journal
      --session ID         Continue session ID (replay + record)
      --continue           The same, with the newest session of the project
      --max-iterations N   Hard safety cap on tool rounds per raid (default 10000)
      --no-color           Disable ANSI colors
      --no-trace           Hide live tool-call progress output
      --perl               Enable perl_eval / perl_check / perl_cpanm tools
      --pack NAME          Enable a bundled pack (repeatable)
      --no-pack NAME       Switch a pack off (also a detected/default one)
      --no-detect          Do not activate packs by workspace detection
      --claude             Load CLAUDE.md + .claude/skills/*/SKILL.md
      --openai / --codex   Load AGENTS.md
      --skills DIR         Load *.md from DIR as skills (repeatable)
      --customize-prompt   Launch the prompt-builder at startup
      --export-skill [PATH]        Write a "how to use raider" markdown doc, exit
      --export-claude-skill [PATH] Write a Claude Code SKILL.md, exit
  -h, --help               Show help
```

REPL slash commands:

| Command                | Does                                                |
|------------------------|-----------------------------------------------------|
| `/help`                | Command list                                        |
| `/clear`               | Reset conversation history and token counters       |
| `/metrics`             | Cumulative raid metrics                             |
| `/stats`               | Tokens in / out / total (when trace is on)          |
| `/reload`              | Re-read `.raider.md`, re-detect packs               |
| `/prompt`              | Launch the prompt-builder (edits `.raider.md`)      |
| `/skill [PATH]`        | Export the plain-markdown how-to-use doc            |
| `/skill-claude [PATH]` | Export a Claude Code `SKILL.md` with frontmatter    |
| `/config`              | Show each setting and where it came from            |
| `/model [NAME]`        | Show or save the model for the next run             |
| `/model list [FILTER]` | List models reported by the active engine           |
| `/packs`               | List available packs and whether they are active    |
| `/pack on/off NAME`    | Enable or disable a pack (`/pack NAME` toggles)     |
| `/quit` `/exit` `:q`   | Leave                                               |

Full detail — including the machine-output document schema and every exit status —
is in `perldoc raider`.

## Configuration — `.raider.yml`

Configuration is per-project: a `.raider.yml` in the working root (see
[Roadmap](#roadmap--planned) for the planned `~/.raider/` home model). It is read in
layers, later ones winning:

```
built-in defaults
  < .raider.yml top-level keys
    < .raider.yml default: section
      < .raider.yml <engine>: section (openai:, anthropic:, ...)
        < command-line -o / flags
```

Flat form, or per-engine with a shared `default:` layer:

```yaml
# .raider.yml
default:
  temperature: 0.3
anthropic:
  temperature: 0.7
  response_size: 8192
openai:
  temperature: 0.5
```

Two kinds of keys live in the file:

- **Engine attributes** (`temperature`, `response_size`, `seed`, `model`, ...) go to
  the engine constructor. `-o key=value` on the command line overrides them (values
  are auto-coerced: `0.2` → Float, `4096` → Int, `true`/`false` → 1/0).
- **Raider's own keys** — `engine`, `perl`, `packs`, `skills`, `detect`,
  `no_detect`, `preferred_lib_target` — configure raider itself and never reach the
  engine. `skills` is merged across layers instead of replaced.

A file that does not parse, whose top level is not a mapping, or that puts a mapping
under one of raider's own keys is a hard error naming the offending key — raider
stops instead of loading half of it.

`.raider.md` in the working root is the **persona / mission** file: drop one in to
rename Langertha, reshape her, or replace her entirely; `/prompt` builds one
interactively and `/reload` hot-swaps it. `-M TEXT` replaces the instructions for
one run without touching the file.

To see where every effective value came from — a flag, a `.raider.yml` layer, an
environment variable or the built-in default — without writing anything or calling a
model:

```bash
raider config explain            # or /config inside the REPL
raider -e openai config explain  # options may come first
```

## Sessions

Every run is recorded in a session journal (JSONL) under the working directory:
`.raider/sessions/<id>.jsonl`, one JSON object per line. A one-shot run starts a new
session and names it on stderr; the REPL starts one with its first prompt.
`--no-session` records nothing. Creating `.raider/` also writes a `.raider/.gitignore`
that excludes `sessions/` and `lib/` — a journal holds the full output of every tool,
so it is not committed by default. API keys never enter it.

```bash
raider session list                  # the project's sessions, newest first
raider session show ID               # one session, event by event
raider session show ID --json        # the whole journal as one document
raider session resume ID             # the REPL, continuing session ID
raider --session ID "and now ..."    # one more run in session ID
raider --continue "and now ..."      # the same, newest session
raider -i --continue                 # the REPL on the newest session
raider session fork ID               # a new session with ID's history
raider session rm ID                 # delete session ID
```

A session ID can be shortened to a unique start of it (`20260925-08`) or its last
four hex digits (`3f2a`); an ambiguous form is refused with the candidates listed.

One session has one writer at a time: while a raider writes a session it holds a
lock, and a second writer fails at once (exit status `4`) instead of waiting.
Continuing a session replays the conversation — nothing recorded is executed again —
and reports what the crash rules found: damaged lines, runs that never ended
(counted as `interrupted`), and tool calls without a result, whose outcome is
`unknown` and which are **never** re-run.

## Tools

Every run assembles one toolbox. The built-ins:

| Tool                                            | Notes                                       |
|-------------------------------------------------|---------------------------------------------|
| `list_files(path)`                              | Directory listing, dirs suffixed with `/`   |
| `read_file(path)`                               | Full text file                              |
| `write_file(path, content)`                     | Creates parents, overwrites                 |
| `edit_file(path, old_string, new_string)`       | Exact unique-match substitution             |
| `bash(command, [working_directory], [timeout])` | Real shell; captures stdout/stderr/exit     |
| `web_search(query, [limit])`                    | Multi-provider, rank-fused                  |
| `web_fetch(url, [as_html])`                     | HTML flattened to text by default           |

Filesystem tools are confined to the `-r`/`--root` directory; `bash` inherits it as
its working directory. `web_search` always has DuckDuckGo (keyless); Brave, Serper
and Google are added automatically when `BRAVE_API_KEY`, `SERPER_API_KEY`, or both
`GOOGLE_API_KEY` + `GOOGLE_CSE_ID` are set.

You can add MCP tools from Perl (see [Using the engine from Perl](#using-the-engine-from-perl)).
A fine-grained permission/policy layer over these tools is on the
[roadmap](#roadmap--planned); today the confinement above is the boundary.

### Perl-native tools

`--perl` (or `perl: true` in `.raider.yml`) adds three tools:

| Tool                            | Notes                                              |
|---------------------------------|----------------------------------------------------|
| `perl_eval(code, [stdin])`      | Ephemeral interpreter; captures stdout/stderr/exit |
| `perl_check(code)`              | `perl -c` — syntax check without executing         |
| `perl_cpanm(module, [options])` | Install into the raider's private `local::lib`     |

Installs land in a `local::lib` the raider owns — `.raider/lib/` next to the working
directory by default — which the process imports at startup, so freshly-installed
modules are visible to later `perl_eval` calls without a restart. `perl_eval` also
auto-recovers from `Can't locate X/Y.pm in @INC`: it installs the missing module
once, retries the eval, and reports what it installed. It never loops. (Note that
`perl -c` runs `BEGIN`/`use`, so `perl_check` is code execution too.)

## Personas, packs and skills

- A **persona** is tone and style; the default is Langertha in a terse "caveman"
  register. Replace it with a `.raider.md` file or `-M`.
- A **pack** is a small, toggleable bundle (a `SKILL.md` plus an optional `pack.yml`)
  stacked on top of the mission. Bundled packs: **caveman**, **polite**, **teacher**
  (persona group, one active at a time) and **git-guru**, **testing-fu**,
  **perl-hacker**, **perl** (power group, stackable). Enable with `--pack NAME`,
  toggle in the REPL with `/pack`, persist under `packs:` in `.raider.yml`, or drop
  your own under `share/packs/<name>/`.
- A **skill** is know-how — instructions and maybe resources — loaded into the
  mission. `--claude` loads `CLAUDE.md` and `.claude/skills/*/SKILL.md`,
  `--openai`/`--codex` loads `AGENTS.md`, and `--skills DIR` loads plain markdown
  from a directory. These persist to `.raider.yml` on first use (the banner shows
  `(saved)`), so they load automatically next time.

Packs can also **activate by workspace detection** (ADR 0012): the bundled `perl`
pack turns its Perl tools on when it detects a Perl workspace (`cpanfile`,
`dist.ini`, `Makefile.PL` or `lib/**/*.pm`). `--no-detect` / `detect: false` turns
detection off; `raider config explain` shows what activated and why.

## Machine interface

For scripting, six mutually-exclusive flags replace the human output with one
format-independent model, written in three encodings:

- `--json` / `--msgpack` / `--yaml` — one document, printed once when the run ends.
- `--stream-json` / `--stream-msgpack` / `--stream-yaml` — an event stream
  (`run.started`, `tool.call`, `tool.result`, `message`, ...), the last event
  (`run.finished`) carrying that same document.

The document is versioned (`--json=N`; version `1` is the only one), and within a
version fields are only ever added — a consumer must ignore fields it does not know.
With a machine flag, stdout carries only the machine output; the live trace, if
asked for, goes to stderr. Exit status distinguishes success (`0`), a failed run
(`1`), usage errors (`2`), configuration errors (`3`), a session in use (`4`) and
signal cancellation/interruption (`130`/`143`). The full schema is in
`perldoc raider` (ADR 0013).

## Raider Hall

You don't need a daemon to use Raider. **Raider Hall** is the optional daemon for
being reachable: it runs raiders on demand, on cron, on a Telegram message, or over
the Agent Client Protocol, and supervises long-lived work.

```bash
raider hall init --name bjorn --engine anthropic --persona caveman
raider hall add-raider lagertha --engine openai --persona polite --pack git-guru
raider hall start --daemon          # foreground: omit --daemon
raider hall ps
raider hall spawn bjorn "summarise yesterday's git log"
raider hall logs <id> --follow
raider hall kill <id>
raider hall stop
```

Subcommands: `init`, `add-raider`, `start`, `stop`, `status`, `ps`, `spawn`,
`attach`, `logs`, `kill`, `session reset` and `install` (systemd user unit, native
or Docker). Run `raider hall <subcommand> --help` for per-command options.

A hall is configured by a `.raider-hall.yml` in its directory:

```yaml
longhouse: false                 # true: share one local::lib across raiders
raiders:
  bjorn:    { engine: anthropic, persona: caveman, packs: [git-guru] }
  lagertha: { engine: openai, model: gpt-4o-mini, persona: polite, packs: [testing-fu] }
cron:
  - { name: 1bjorn, cron: '*/15 * * * *', mission: 'check CI, ping #eng-alerts if red' }
telegram:
  bots:
    ops: { token: '123456:ABC...', allowlist: [42, 99], routing: { 42: bjorn, '*': lagertha } }
acp:
  port: 38421
```

Named raiders spawn as child processes; a `1name` prefix (e.g. `spawn 1bjorn`)
forces at most one instance, queuing overlapping missions FIFO. Cron entries fire
non-blocking; Telegram bots long-poll with a per-bot allowlist and routing map, and
answer through the hall. There is a fuller walkthrough under
[`examples/multi-raider-hall/`](examples/multi-raider-hall/).

## ACP (editors)

`raider` speaks the Agent Client Protocol (Zed's editor protocol), in two directions.

**As a server**, the Hall exposes ACP over TCP — start it with an ACP port:

```bash
raider hall start --acp-port 38421
```

The server implements `initialize`, `session/new`, `session/prompt` (text) and
`session/cancel`. A failed run ends `session/prompt` as a JSON-RPC error (code
`-32000`), so a client tells a broken run from a reply.

**As a client**, the bundled dispatcher drives any conforming ACP agent:

```bash
raider acp ping 127.0.0.1:38421                         # handshake / capabilities
raider acp prompt 127.0.0.1:38421 --raider bjorn "..."  # one-shot
raider acp connect 127.0.0.1:38421 --raider lagertha    # interactive REPL
```

`--json` streams the raw JSON-RPC frames to stderr for debugging. Under the hood
this is `Langertha::Raider::ACP::Client`, a small blocking JSON-RPC 2.0 client you
can embed in your own Perl.

> The stdio ACP server an editor starts directly (`raider acp` as the agent
> command), and driving remote raiders as `raider NAME@HOST`, are on the
> [roadmap](#roadmap--planned) (ADR 0010).

## Using the engine from Perl

```perl
use Langertha::Raider;
use Langertha::Engine::Anthropic;
use Future::AsyncAwait;

my $engine = Langertha::Engine::Anthropic->new(
  api_key     => $ENV{ANTHROPIC_API_KEY},
  mcp_servers => [ $mcp ],          # any Langertha engine with tool calling
);
my $raider = Langertha::Raider->new(
  engine  => $engine,
  mission => 'You are a code reviewer.',
);
my $result = await $raider->raid_f('What files are in lib/?');
say $result;
```

`raid_f` runs one turn's worth of the agent loop and returns a
`Langertha::Raider::Result` (`is_final`, `is_question`, `is_pause`, `is_abort`);
`respond_f` answers back into the same conversation. `Langertha::Raid` orchestrates
several runnables (`Raid::Sequential`, `Raid::Parallel`, `Raid::Loop`). Attaching
MCP tools is covered in the [Langertha](https://metacpan.org/dist/Langertha) docs.

## Docker

A prebuilt image is on Docker Hub as
[**`raudssus/raider`**](https://hub.docker.com/r/raudssus/raider). The bundled
`Dockerfile` is multi-stage with two runtime targets: `runtime-root` (the Docker Hub
default, tag `:latest` / `:<version>`) and `runtime-user` (non-root, uid/gid
matchable to the host for interactive use in real project trees).

```bash
docker pull raudssus/raider
docker run --rm -it -v "$PWD:/work" -e ANTHROPIC_API_KEY raudssus/raider
```

A convenient shell alias mounts `$PWD` into `/work`, keeps REPL history, and forwards
the API-key env vars:

```bash
raider() {
  docker run --rm -it \
    -v "$PWD:/work" \
    -v "$HOME/.raider_history:/root/.raider_history" \
    -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e DEEPSEEK_API_KEY \
    -e GROQ_API_KEY -e MISTRAL_API_KEY -e GEMINI_API_KEY \
    -e MINIMAX_API_KEY -e CEREBRAS_API_KEY -e OPENROUTER_API_KEY \
    -e BRAVE_API_KEY -e SERPER_API_KEY -e GOOGLE_API_KEY -e GOOGLE_CSE_ID \
    raudssus/raider "$@"
}
```

### Build locally

The Dockerfile installs from the Dist::Zilla-built distribution directory (via
[`cpm`](https://metacpan.org/dist/App-cpm) with the MetaCPAN resolver), not from a
tarball in the build context. Build the dist directory first and use it as the
context:

```bash
dzil build
VERSION=$(perl -Ilib -MLangertha::Raider::CLI -E 'say $Langertha::Raider::CLI::VERSION')
docker build \
  --build-arg RAIDER_VERSION=$VERSION \
  --target runtime-user \
  --build-arg RAIDER_UID=$(id -u) \
  --build-arg RAIDER_GID=$(id -g) \
  -t raider:local Langertha-Raider-$VERSION
```

Use `--target runtime-root` for a root image. On release, `dist.ini`'s
`run_after_release` hook publishes the GitHub release and pushes the Docker Hub
image; that is the maintainer's step (`dzil release`).

## Roadmap / Planned

The items below are **not yet implemented** — they are the decided direction, each
backed by an ADR in [`docs/adr/`](docs/adr/). The full target-state vision and
vocabulary live in [`CONTEXT.md`](CONTEXT.md); it lands in small vertical slices.

- **The home assistant profile & directory model** (ADR 0011) — a dedicated
  `~/.raider/` home (`config.yml`, `instructions.md`, `skills/`, `raiders/<name>.yml`,
  `sessions/`, `memory/`) that never bleeds into projects, a `<project>/.raider/`
  config layer, and a `raider config migrate` from today's `.raider.yml` / `.raider.md`.
  *Today: per-project `.raider.yml` and `.raider.md` only.*
- **Inspectable context & diagnostics** (ADR 0004) — a per-call, itemized
  `ContextPlan` you can read with `raider context explain`, a `raider doctor`
  health check, per-directory instruction walking, and an explicit workspace-trust
  decision. *Today: `raider config explain`.*
- **Permissions & policy** (ADR 0005) — one active tool set with real capability
  grants, `raider policy check` / `raider tools explain`, approvals tied to the
  exact call, a "headless never allows all" rule, and a home-service `project_tools`
  mapping. *Today: filesystem tools confined to `--root`, `bash` unrestricted within it.*
- **Provider discovery** (ADR 0007) — `raider --provider host.tld`,
  `raider provider add/inspect`, and a declarative `.well-known/langertha.json`
  manifest. *Today: any Langertha provider via API key and `-e`.*
- **Delegates: Codex & Claude Code** (ADR 0006) — `--use-codex` / `--use-claude`
  adding `ask_codex` / `ask_claude` tools driven through a narrow task contract, and
  `raider delegate inspect`; the official binaries own their own login.
- **Remote raiders & editor stdio** (ADR 0010) — `raider NAME@HOST ...` over SSH
  with ACP as the conversation, and `raider acp` as the stdio ACP server an editor
  starts directly. *Today: ACP server via the Hall over TCP, ACP client via `raider acp`.*
- **Reviewed long-term memory** (ADR 0008) — memory and lesson candidates proposed
  after a session that only become active on review, with
  `raider memory list/explain/approve/forget`. *Today: the per-session journal plus
  automatic context compression.*

## License

This software is copyright (c) 2026 by Torsten Raudssus.

It is free software; you can redistribute it and/or modify it under the same terms as
the Perl 5 programming language system itself.
