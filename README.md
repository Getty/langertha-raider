# Langertha::Raider

> **Target-state draft (2026-09-24).** This README describes Raider as the redesign plan
> (`CONTEXT.md`, `docs/adr/`) intends it to work — **not** what the code does today. It
> exists to be argued with; every design point in it is backed by an ADR in `docs/adr/`. The README of the
> current code is in git (`git show b9196ce:README.md`).

**Perl is the glue of the internet — Raider is the glue for AI.**

`raider` is a Perl-native agent runtime. It brings models, tools and other agents together
— any provider Langertha speaks, your own Perl, MCP servers, Codex and Claude Code — and
keeps track of what it knows, where it knows it from, and what it actually did.

```
             __     __
.----.---.-.|__|.--|  |.-----.----.
|   _|  _  ||  ||  _  ||  -__|   _|
|__| |___._||__||_____||_____|__|
 perl agent - powered by Langertha
```

## One tool, two jobs

Raider is two things, from one kernel:

|             | **Project agent**                              | **Assistant**                                     |
| ----------- | ---------------------------------------------- | ------------------------------------------------- |
| Lives in    | a project directory                            | your home (`~/.raider/`)                          |
| Knows       | that project's instructions, code and sessions | you: preferences, long-term memory, your services |
| Reached via | `raider` in the project, your editor (ACP)     | `raider` anywhere, Telegram, cron, the Hall       |
| Like        | Claude Code                                    | Hermes Agent                                      |

They don't bleed into each other. A project never sees your private notes or other
projects' memory unless you allow it; the assistant only touches a project when you point
it there. Which profile runs is decided by where you are, not by which prompt you wrote.

## Quick start

```bash
cpanm Langertha::Raider
cd ~/dev/my-project
raider
```

The first time Raider sees a project it shows what it found and asks once:

```
raider: new workspace ~/dev/my-project
  instructions:  CLAUDE.md, AGENTS.md, .raider/instructions.md
  mcp servers:   .raider/config.yml → github (wants: network)
  trust instructions for this workspace? [y/N/show]
  start mcp server 'github'?             [y/N]
```

After that, `CLAUDE.md`, `AGENTS.md` and `.raider/` apply automatically — no flags. New
executable things (an MCP server, a hook) always ask again.

```
raider> lies die Changes und schreib mir ne kurze summary
raider> prove -l t/ laufen, falls was rot ist report zurück
```

One-shot:

```bash
raider "check git status and summarize"
raider --json "count the .pm files in lib" | jq .
```

Every surface shows where you are:

```
[project my-project · session 3f2a · anthropic/claude-haiku-4-5 · trusted]
```

## Where things live

```
~/.raider/
  config.yml              your profile: providers, aliases, defaults, mounted services
  instructions.md         personal instructions (only portable preferences reach projects)
  skills/                 skills you installed on purpose
  raiders/<name>.yml      named agents (role, persona, packs, tools) you can start anywhere
  sessions/<id>.jsonl     assistant sessions
  memory/                 long-term memory (reviewed entries only)

<project>/.raider/
  config.yml              shareable project config (commit it if you like)
  instructions.md         native project instructions
  skills/                 project skills (trusted with the workspace)
  raiders/<name>.yml      the project's named agents (e.g. reviewer, tester)
  sessions/<id>.jsonl     project sessions — move the project, they move along
  lib/                    private local::lib for the Perl tools
  .gitignore              written by Raider: ignores sessions/ and lib/
```

Secrets never live in project files; a project config can only *refer* to a credential you
bound locally.

Everything of Raider's lives in `~/.raider/` — one dedicated directory, no XDG split
(ADR 0011).

Legacy `.raider.yml` and `.raider.md` keep working. `raider config migrate --dry-run` shows
how they map; writing needs an explicit call and keeps a backup. If both old and new files
exist, Raider tells you instead of silently loading both.

## Sessions

A session is a file, not a process. Quit, reboot, come back:

```bash
raider session list
raider session resume 3f2a
raider session fork 3f2a        # new branch of the conversation, same workspace
```

One session has one writer at a time; a second client can watch, and new messages queue up.
Two sessions in the same project either take turns writing or work in separate worktrees.

Raider remembers what it *did*, not only what it said: every tool call is recorded as
planned, authorised, dispatched and then succeeded, failed, cancelled — or **unknown** if
Raider crashed mid-way. Unknown side effects are shown to you, never blindly retried.

## Context you can inspect

Raider doesn't paste everything into one giant prompt. For every model call it builds a
context plan — each piece with its source, scope, trust and token share — and you can look
at it:

```bash
raider context explain --session 3f2a
raider config explain            # every effective setting and which file it came from
raider doctor
```

Instruction files are found by walking up to the workspace root, never beyond. A
`CLAUDE.md` in `lib/Foo/` only applies when working on files below `lib/Foo/`. If the
mandatory part of the context doesn't fit the model's window, you get an explained error —
never a silently dropped constraint.

## Configuration

```
built-in defaults < ~/.raider/config.yml < <project>/.raider/config.yml < command-line flags
```

…for ordinary options. Some fields don't simply override:

- **Credentials** only come from your local bindings, never from a project file.
- **Permissions** from a later layer can only narrow, never widen, what you allowed.
- **Provider choice** in a project is a wish; sending data there still needs your approval.
- **Unknown fields** are an error (or a warning in `raider doctor`), not silently ignored.

With several API keys set and no stored choice, Raider asks which provider to use instead
of picking the first key it finds.

## Tools and permissions

Tools come from many places — built-ins, `bash`, Perl tools, packs, MCP servers, and
services running once in your home — but each run has **one** active tool set. The model's
tool list, the prompt and the permission check all come from that one set.

| Built-in                                             |                                                                                                     |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `list_files`, `read_file`, `write_file`, `edit_file` | inside the workspace; edits check the file hash first and fail on a conflict instead of overwriting |
| `bash`                                               | a real shell — treated as arbitrary code execution                                                  |
| `web_search`, `web_fetch`                            | DuckDuckGo by default, more providers when keys are present                                         |
| `perl_eval`, `perl_check`, `perl_cpanm`              | with `--perl`; see below                                                                            |

**Home services in projects.** Your home config decides what gets mounted into which project
raiders — e.g. the Telegram bot runs once in the Hall and every project raider can send you
a message through it:

```yaml
# ~/.raider/config.yml
project_tools:
  "*":                 [telegram, web]   # every project
  "~/dev/customer-*":  [jira]            # path glob
  langertha-raider:    [cpan]            # workspace name
```

All matching entries add up. A project's own config can *ask* for a home tool, but only
this map grants it.

**Nothing grants itself rights.** A pack, skill, project file, provider manifest, model
answer or sub-agent can *ask* for a capability; only your policy grants it:

```bash
raider policy check --tool write_file --path lib/Foo.pm
raider tools explain bash
```

Approvals are tied to the exact tool call; if the arguments change, the approval is gone.
Headless runs (cron, Telegram) never fall back to "allow all" — a missing approval pauses
the run and tells you.

### Perl-native tools

`--perl` unlocks `perl_eval`, `perl_check` and `perl_cpanm` with a private `local::lib`
under `.raider/lib/`. Missing modules can be installed automatically — within a policy you
set up beforehand (allowed sources, target, network). Note that `perl -c` runs `BEGIN` and
`use`, so `perl_check` is code execution too and goes through the same limits as
`perl_eval`.

## Other agents: Codex, Claude Code, remote raiders

```bash
raider --use-codex --use-claude
```

adds tools like `ask_codex` and `ask_claude`. Your main model stays in charge; it can ask
Codex for a second opinion or have Claude review a diff. The official `codex` and `claude`
binaries do the work and own their login — your subscription stays with them, Raider never
touches their credentials.

A delegate gets a small task package (goal, the diff or files it needs, limits, budget) —
not your whole session. By default it reads and reviews; it doesn't edit. Its findings come
back as a report or a patch you can accept.

```bash
raider delegate inspect codex    # binary, version, what isolation it can guarantee
```

**Remote raiders** use the same command line, prefixed with `name@host`:

```bash
raider bjorn@buildbox "run the test suite and report"
raider bjorn@buildbox session list
raider bjorn@buildbox                      # REPL, talking to the raider over there
```

Everything after `name@host` is exactly what you would type locally; it runs as the raider
`bjorn` on `buildbox`. Under the hood it is SSH as transport and ACP as the conversation:
hosts you approved, host key checking, no agent forwarding, prompts on stdin — never a shell
line built from model text. Your main raider can use the same remote raiders as delegates.

## Providers

Everything Langertha speaks works with an API key (Anthropic, OpenAI, DeepSeek, Groq,
Mistral, Gemini, Cerebras, OpenRouter, Ollama, vLLM, …). Beyond that, a provider can
describe itself:

```bash
raider --provider llm.example.com          # try it once
raider provider add work llm.example.com   # keep it as alias 'work'
raider provider inspect work
```

Raider fetches `https://llm.example.com/.well-known/langertha.json`, shows endpoints, models
and the auth method, and asks you to bind a credential. A Knarr instance serves this
manifest automatically; Skeid serves what its config exposes for your key. The manifest only
describes endpoints and models — it can't install tools, start processes or inject prompts.
If the provider later changes its origin or auth method, Raider asks again.

## Memory

Three different things, three different places:

- **Session journal** — everything that happened, per session, never compressed.
- **Working state** — what the next model call needs; a compact, rebuildable view of the
  journal.
- **Long-term memory** — reviewed facts, preferences and lessons, each with scope and
  evidence.

Raider can *propose* memories and lessons after a session; they only become active once you
(or a configured review step) approve them. Project knowledge never quietly becomes a
global preference.

```bash
raider memory list
raider memory explain mem-17
raider memory approve mem-17
raider memory forget mem-12
```

## Skills, personas, packs

- A **skill** is know-how: instructions plus maybe resources. Raider shows skill summaries
  first and loads the full text only when needed.
- A **persona** is tone and style (`caveman`, `polite`, `teacher`, or your own).
- A **pack** bundles skills, a persona and requested capabilities (`git-guru`,
  `testing-fu`, `perl-hacker`).

Home skills live in `~/.raider/skills/`, project skills in `.raider/skills/`. Scripts in
skills are code and run under the same policy as everything else. Skills Raider writes
itself start as drafts you review.

## Raider Hall (optional)

You don't need a daemon to use Raider. The Hall is for being reachable: it runs the same
kernel for long-lived sessions, Telegram, cron and supervision.

```bash
raider hall start
raider hall status
raider hall logs --follow 3f2a
```

- **Telegram:** each bot/chat/thread is bound to a session and to the people allowed to use
  it. An empty allowlist means nobody. The reply to your message is delivered by the Hall —
  the model doesn't have to remember to call a reply tool.
- **Cron:** jobs have a time zone, a policy for missed runs and overlaps, and their own
  session (or one you configure) — never the whole Hall's context.

## Editors (ACP)

Raider speaks the Agent Client Protocol (the Zed editor protocol) over stdio, so an editor
can start it like any other agent: create a session, prompt, stream updates, cancel. It only
advertises what it implements.

```json
{ "agent_servers": { "Raider": { "command": "raider", "args": ["acp"] } } }
```

The client side is `raider name@host …` (see above). For local debugging,
`raider acp connect …` talks to any ACP agent directly.

## Machine interface

- `--json` — one result object, format versioned. No banners or spinners on stdout.
- `--stream-json` — event stream.
- Exit codes distinguish success, refusal, missing configuration, cancellation and internal
  error.

## Using the engine from Perl

```perl
use Langertha::Raider;

my $engine = Langertha::Engine::Anthropic->new(
  api_key     => $ENV{ANTHROPIC_API_KEY},
  mcp_servers => [ $mcp ],          # any Langertha engine with tool calling
);
my $raider = Langertha::Raider->new( engine => $engine );
my $result = await $raider->raid_f('What files are in lib/?');
```

`Langertha::Raid` orchestrates several runnables (sequential, parallel, loop). The engine,
`Langertha::Raid*` and the plugin interface are the public API; everything else is internal.

> **Later:** the public Perl API gets settled once the redesign has progressed further.

## Docker

```bash
docker run --rm -it -v "$PWD:/work" -e ANTHROPIC_API_KEY raudssus/raider
```

### Build locally

The Dockerfile installs from the Dist::Zilla-built distribution directory,
not from a tarball in the build context. Build the dist directory first and
use that as the Docker context:

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

Use `--target runtime-root` for a root image.

## License

This is free software; you can redistribute it and/or modify it under the same terms as the
Perl 5 programming language system itself.
