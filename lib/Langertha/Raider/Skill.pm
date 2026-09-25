package Langertha::Raider::Skill;
our $VERSION = '0.503';
# ABSTRACT: Generate a "how to use raider" documentation file from a live Langertha::Raider::CLI configuration

use Moose;
use namespace::autoclean;
use Path::Tiny;

=head1 SYNOPSIS

    my $skill = Langertha::Raider::Skill->new(app => $app);

    # Plain markdown for any AI tool / human
    my $md = $skill->markdown;

    # Claude Code SKILL.md with frontmatter, written to .claude/skills/...
    $skill->write_claude_skill('.claude/skills/raider/SKILL.md');

=head1 DESCRIPTION

Builds a self-describing how-to-use-raider document from a running
L<Langertha::Raider::CLI> instance. The generated text reflects the actual live
configuration: selected engine and model, which web-search providers are
currently enabled based on environment variables, which persona layer is
active (default Langertha, a custom C<.raider.md>, or a C<-M> mission),
and so on.

Two output variants are supported:

=over

=item * L</markdown> — engine-agnostic markdown (no frontmatter). Drop into
any README-ish place or feed it to a non-Claude agent.

=item * L</claude_skill> — Claude Code SKILL.md with a proper YAML
frontmatter block. Write to C<.claude/skills/raider/SKILL.md> (or
wherever your skill directory lives) with L</write_claude_skill>.

=back

=attr app

The L<Langertha::Raider::CLI> instance to describe. Required.

=cut

has app => (
  is       => 'ro',
  isa      => 'Langertha::Raider::CLI',
  required => 1,
);

=attr name

Skill name used in the Claude frontmatter. Defaults to C<raider>.

=cut

has name => (
  is      => 'ro',
  isa     => 'Str',
  default => 'raider',
);

=attr description

One-line description used in the Claude frontmatter.

=cut

has description => (
  is      => 'ro',
  isa     => 'Str',
  default => 'How to drive the `raider` CLI — an autonomous Perl command-line agent (Langertha::Raider::CLI) with filesystem, bash, and web tools.',
);

sub _active_web_providers {
  my @p = ('DuckDuckGo (keyless)');
  push @p, 'Brave'  if $ENV{BRAVE_API_KEY};
  push @p, 'Serper' if $ENV{SERPER_API_KEY};
  push @p, 'Google CSE' if $ENV{GOOGLE_API_KEY} && $ENV{GOOGLE_CSE_ID};
  return join(', ', @p);
}

=method markdown

Returns the plain markdown document (no frontmatter).

=cut

sub markdown {
  my ($self) = @_;
  my $app = $self->app;
  my $source  = $app->mission_source;
  my $persona = $source eq '-M'         ? 'from -M (.raider.md not used)'
              : $source eq '.raider.md' ? 'custom (loaded from '.path($app->root)->child('.raider.md').')'
              :                           'Langertha (default viking persona)';
  $persona .= ', bare (no .raider.md, skills or packs)' if $app->bare;
  my $config  = $app->config;
  my $yml_loaded = $config->file_exists && $config->data ? 'yes ('.$config->file.')' : 'no';
  my $model   = $app->has_model ? $app->model : '(engine default)';
  my $env     = $app->api_key_env // '(none)';
  my $web     = _active_web_providers();

  return <<"MD";
# Using `raider`

`raider` is a Perl CLI that wraps L<Langertha::Raider> with a fixed toolbox
and keeps a persistent conversation with an LLM. This is how to drive it.

## Current live configuration

- Engine: **@{[ $app->engine_name ]}** (env: `$env`)
- Model: **$model**
- Persona: $persona
- Working root: `@{[ $app->root ]}`
- `.raider.yml` loaded: $yml_loaded
- Web-search providers active: $web

## Minimal usage

```bash
raider                           # REPL in the current directory
raider "do this task"            # one-shot
echo "task" | raider             # from a pipe
raider --json "task" | jq .      # script-friendly output
```

Engine/model/api-key can be set via CLI:

```bash
raider -e openai -m gpt-4o-mini -k sk-...
raider -o temperature=0.1 -o response_size=4096
```

Otherwise the first `*_API_KEY` in the environment picks the engine, and a
cheap model is selected automatically.

## Tools the agent has

| Tool                                            | Purpose                                  |
|-------------------------------------------------|------------------------------------------|
| `list_files(path)`                              | Directory listing                        |
| `read_file(path)`                               | Full text file                           |
| `write_file(path, content)`                     | Overwrite, creates parents               |
| `edit_file(path, old_string, new_string)`       | Exact unique-match substitution          |
| `bash(command, [working_directory], [timeout])` | `bash -c \$command`                      |
| `web_search(query, [limit])`                    | Rank-fused multi-provider search         |
| `web_fetch(url, [as_html])`                     | HTTP GET, HTML flattened to text         |

Filesystem tools are confined to the working root. `bash` inherits it.

## Telling the agent what to do

The agent runs until it stops emitting tool calls; then control returns to
the REPL prompt, where your next line continues the same conversation.
There is **no** ask/pause/abort tool — the agent just does things and
reports when done.

The default persona speaks in terse caveman style (no articles, no filler,
technical terms exact). Say "normal mode" to switch to prose.

Customize the persona and the rules by dropping a `.raider.md` file in the
working directory, or by running `/prompt` in the REPL (launches a sub-agent
that edits `.raider.md` for you).

## Slash commands inside the REPL

| Command                  | Does                                                 |
|--------------------------|------------------------------------------------------|
| `/help`                  | Command list                                         |
| `/clear`                 | Reset conversation history and token counters        |
| `/metrics`               | Cumulative raid metrics                              |
| `/stats`                 | Tokens in / out / total this session                 |
| `/reload`                | Re-read `.raider.md`, hot-swap the mission           |
| `/prompt`                | Launch the prompt-builder (edits `.raider.md`)       |
| `/skill [PATH]`          | Export plain-markdown how-to-use doc                 |
| `/skill-claude [PATH]`   | Export Claude Code SKILL.md with YAML frontmatter    |
| `/config`                | Show each setting and where it came from             |
| `/model [NAME]`          | Save NAME as model to `.raider.yml` (next start)     |
| `/model list [FILTER]`   | List the engine's models                             |
| `/packs`                 | List the packs and which are active                  |
| `/pack on NAME`          | Enable a pack, reloads the mission                   |
| `/pack off NAME`         | Disable a pack, reloads the mission                  |
| `/pack NAME`             | Toggle a pack                                        |
| `/quit` `/exit` `:q`     | Leave                                                |

## Loading project skills

Profile flags preload per-tool agent files into the mission and persist
themselves to `.raider.yml` after first use:

- `--claude` — loads `CLAUDE.md` and any `.claude/skills/*/SKILL.md`.
- `--openai` / `--codex` — loads `AGENTS.md`.
- `--skills DIR` — extra plain-markdown directory (repeatable).

When a well-known file is present but its profile isn't active, the startup
banner shows a `seeing FILE, ignoring (use --<profile> to load)` hint.

## Engine options via `.raider.yml`

Flat form:

```yaml
temperature: 0.2
response_size: 2048
```

Per-engine with a shared default:

```yaml
default:
  temperature: 0.3
anthropic:
  temperature: 0.7
  response_size: 8192
```

CLI `-o key=value` overrides the file.

## Context window and rate limits

- `max_context_tokens = 40000`
- `context_compress_threshold = 0.7`
- `max_iterations = 10000`

At 70% of the token budget, `Langertha::Raider` compresses the history
automatically. Each raid prints `history N msgs, X/Y tok (Z%)` so you can
see how close you are.

## Environment variables for API keys

`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`,
`MISTRAL_API_KEY`, `GEMINI_API_KEY`, `MINIMAX_API_KEY`, `CEREBRAS_API_KEY`,
`OPENROUTER_API_KEY`.

Web-search extras: `BRAVE_API_KEY`, `SERPER_API_KEY`,
`GOOGLE_API_KEY` + `GOOGLE_CSE_ID`.
MD
}

=method claude_skill

Returns the markdown with a Claude Code YAML frontmatter block prepended.

=cut

sub claude_skill {
  my ($self) = @_;
  my $name = $self->name;
  my $desc = $self->description;
  $desc =~ s/"/\\"/g;
  my $frontmatter = <<"FM";
---
name: $name
description: |
  $desc
  Use this skill whenever the user invokes `raider`, asks about the
  `Langertha::Raider::CLI` CLI, wants to customize its persona via `.raider.md`,
  or is reading a transcript that contains `raider>` prompts and
  `bash`/`read_file`/`web_search` tool calls.
---

FM
  return $frontmatter . $self->markdown;
}

=method write_markdown

    $skill->write_markdown('/path/to/SKILL.md');

Writes the plain markdown to a file (creates parent dirs).

=cut

sub write_markdown {
  my ($self, $file) = @_;
  my $p = path($file);
  $p->parent->mkpath unless -d $p->parent;
  $p->spew_utf8($self->markdown);
  return $p;
}

=method write_claude_skill

    $skill->write_claude_skill;                 # default path
    $skill->write_claude_skill('path/to/SKILL.md');

Writes the Claude SKILL.md (with frontmatter) to C<$path>. The default path
is C<.claude/skills/<name>/SKILL.md> relative to the app's working root.

=cut

sub write_claude_skill {
  my ($self, $file) = @_;
  $file //= path($self->app->root)->child('.claude/skills', $self->name, 'SKILL.md');
  my $p = path($file);
  $p->parent->mkpath unless -d $p->parent;
  $p->spew_utf8($self->claude_skill);
  return $p;
}

=method legacy_claude_skill

Returns the L<Path::Tiny> of a Claude skill exported by an older release
under the former default name (C<.claude/skills/app-raider/SKILL.md> below
the working root), or nothing when there is none. The C<--claude> profile
would load it next to the current one, so the CLI points it out after an
export.

=cut

sub legacy_claude_skill {
  my ($self) = @_;
  my $p = path($self->app->root)->child('.claude/skills/app-raider/SKILL.md');
  return -f $p ? $p : ();
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI>

=item * L<Langertha::Raider>

=back

=cut
