package Langertha::Raider::CLI;
# ABSTRACT: Autonomous CLI agent that can browse directories, edit files, and run bash commands
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Path::Tiny;
use Langertha::Raider::Application;

extends 'Langertha::Raider::Application';

=head1 SYNOPSIS

    use Langertha::Raider::CLI;

    my $app = Langertha::Raider::CLI->new(
        # engine/model/api_key auto-detected from *_API_KEY env vars
        root           => '/path/to/project',
        claude         => 1,                      # read the Claude Code layout
        skill_sources  => [ { type => 'dir', path => 'my-skills' } ],
        engine_options => { temperature => 0.2 },
    );

    my $result = $app->run('Explore the repo and summarize it.');
    print $result;

=head1 DESCRIPTION

L<Langertha::Raider::CLI> wraps L<Langertha::Raider> with a standard toolbox for a
working coding/system agent:

=over

=item * Local filesystem access, confined to L<Langertha::Raider::Application/root>
(L<Langertha::Raider::FileTools>).

=item * Full shell via L<Langertha::Raider::BashTools> (the C<bash> tool, with
C<bash_output> and C<kill_shell> for background commands), started in the
root but not confined to it.

=item * Web search + fetch via L<Net::Async::WebSearch> and
L<Net::Async::HTTP> (L<Langertha::Raider::WebTools>).

=item * Optional Perl-native tools via L<Langertha::Raider::PerlTools>,
and the Hall tools (L<Langertha::Raider::HallTools>) when a Hall started
the raider. The tool list in the prompt is generated from the tools the
engine is offered (L<Langertha::Raider::Application/mission>).

=item * Persona and power packs via L<Langertha::Raider::Packs>.

=item * Per-engine cheap-model defaults and automatic engine selection from
the first C<*_API_KEY> env var found (L<Langertha::Raider::EngineResolver>).

=item * The Claude Code layout (ADR 0019): C<CLAUDE.md> memory with
imports and nested files, C<.claude/settings*.json>, plugin skills --
automatic in a project set up only for Claude Code, by C<--claude> or
C<claude: true> elsewhere; C<AGENTS.md> by C<--openai>.

=item * Skills from C<.raider/skills>, C<~/.raider/skills>, the Claude
skill directories and C<--skills DIR>, listed in the prompt and loaded on
demand with the C<skill> tool.

=item * Engine-attribute config via C<.raider.yml> in the root plus
C<engine_options> merge.

=item * Live trace plugin (L<Langertha::Raider::Plugin::Trace>) and
situation-injection plugin (L<Langertha::Raider::Plugin::Situation>).

=item * On-the-fly how-to-use-raider documentation generator
(L<Langertha::Raider::Skill>).

=back

It is the command line's L<Langertha::Raider::Application>: all the
attributes and methods documented there (C<root>, C<engine_name>,
C<model>, C<mission>, C<packs>, C<raid_f>, C<run>, C<explain_config>, ...)
apply here, and this class adds what belongs to the terminal -- the live
L</trace>, the agent files of C<--claude> / C<--openai> it reports as
ignored (L</ignored_agent_files>) and L</token_stats>. The command line
itself is L<raider>.

Of the names the Application gained after the inventory of ADR 0017, only
the constructor arguments that mirror an option or config key apply here
as public: C<claude>, C<permission_mode>, C<skip_permissions>,
C<max_agent_depth> and C<agent_models>. The others (C<context>,
C<permissions>, C<hooks>, C<tool_gate>, C<todos>, ...) are internal and may
change without notice (ADR 0017, Addendum 1).

=cut

=func default_model_for_engine

    my $model = Langertha::Raider::CLI::default_model_for_engine('openai');   # 'gpt-4o-mini'

A plain function, not a method: the model an engine uses when no model is
set (L<Langertha::Raider::Application/model>) -- raider's cheap default
for the engine, else the engine class's own default, C<undef> for an
engine that needs an explicit model (C<openrouter>) or an unknown one.

=cut

# Plain functions, kept for callers of the former tables here; the tables
# are the resolver's.
sub env_var_for_engine {
  my ($engine) = @_;
  return __PACKAGE__->engine_resolver_class->env_var_for_engine($engine);
}

sub default_model_for_engine {
  my ($engine) = @_;
  return __PACKAGE__->engine_resolver_class->default_model_for_engine($engine);
}

=attr trace

Emit live ANSI-colored progress output (iteration markers, tool calls, tool
results) via L<Langertha::Raider::Plugin::Trace>. Defaults to on when STDOUT is a
terminal.

=cut

has trace => (
  is      => 'ro',
  isa     => 'Bool',
  default => sub { -t STDOUT ? 1 : 0 },
);

=attr trace_out

Filehandle the L</trace> is printed to. Defaults to C<STDOUT>.

=cut

has trace_out => (
  is      => 'ro',
  default => sub { \*STDOUT },
);

# The agent file in the root that each profile flag (--claude, --openai)
# makes raider read, for the "seeing ..., ignoring" notice.
our %AGENT_PROFILES = (
  claude => 'CLAUDE.md',
  openai => 'AGENTS.md',
);

around _raider_plugins => sub {
  my ( $orig, $self ) = @_;
  my @plugins = $self->$orig;
  # Pass as name + {args}; PluginHost still injects `host`. The `loop` arg
  # lets the plugin drive a spinner during LLM HTTP calls.
  unshift @plugins, '+Langertha::Raider::Plugin::Trace', { loop => $self->loop, out => $self->trace_out }
    if $self->trace;
  return @plugins;
};

=method source_labels

The command-line flags that set what
L<Langertha::Raider::Application/explain_config> and the other reports
name (L<Langertha::Raider::Application/source_label>): C<-e>, C<-m>,
C<-k>, C<-o>, C<--pack>, C<--perl>, C<--bare>, C<-M>, ...

=cut

sub source_labels {
  return {
    engine                 => '-e',
    model                  => '-m',
    api_key                => '-k',
    engine_options         => '-o',
    'engine_options packs' => '-o packs',
    pack_names             => '--pack',
    no_pack_names          => '--no-pack',
    perl                   => '--perl',
    detect                 => '--detect',
    no_detect              => '--no-detect',
    bare                   => '--bare',
    mission                => '-M',
    claude                 => '--claude',
    cli_skill_sources      => '--openai/--skills',
    permission_mode        => '--permission-mode',
    skip_permissions       => '--dangerously-skip-permissions',
  };
}

=method persona_intro

The default persona's opening names the CLI.

=method persona_turn_end

The CLI loops back to the user.

=cut

sub persona_intro { <<'EOM' }
You are Langertha, viking shield-maiden. Autonomous CLI agent on user's
local machine. CLI name: "raider". Just CLI. No pause, no abort, no ask
to stop. You do things.
EOM

sub persona_turn_end { <<'EOM' }
You have no yield / ask / abort tool. Task done: plain text reply. CLI
loops back to user.
EOM

=method ignored_agent_files

    for my $ign ($app->ignored_agent_files) {
      say 'seeing '.$ign->{path}.', ignoring (use --'.$ign->{profile}.' to load)';
    }

The agent files (F<CLAUDE.md>, F<AGENTS.md>) in the working root that the
prompt does not hold (L<Langertha::Raider::Context/instruction_items>),
each with C<path> and the C<profile> flag that would load it. In the
Claude layout F<CLAUDE.md> is loaded, so never listed. Nothing with
L<Langertha::Raider::Application/bare>. Powers the banner's "seeing
AGENTS.md, ignoring" notice.

=cut

sub ignored_agent_files {
  my ($self) = @_;
  return if $self->bare;
  my %loaded = map { $_->{file} => 1 } $self->context->instruction_items;
  my @out;
  for my $profile (sort keys %AGENT_PROFILES) {
    my $p = Path::Tiny::path($self->root)->child($AGENT_PROFILES{$profile});
    next unless -f $p;
    my $real = eval { $p->realpath->stringify } // $p->absolute->stringify;
    next if $loaded{$real};
    push @out, { path => $p->basename, profile => $profile };
  }
  return @out;
}

=method trace_plugin

Returns the loaded L<Langertha::Raider::Plugin::Trace> instance, or undef if trace
is disabled.

=cut

sub trace_plugin {
  my ($self) = @_;
  return unless $self->trace;
  for my $p (@{$self->_raider->plugin_instances}) {
    return $p if $p->isa('Langertha::Raider::Plugin::Trace');
  }
  return;
}

=method token_stats

Cumulative token counts for this session (hashref with C<prompt>,
C<completion>, C<total>, C<calls>) — available when trace is enabled,
nothing otherwise.

=cut

sub token_stats {
  my ($self) = @_;
  my $t = $self->trace_plugin or return;
  return $t->token_stats;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider>

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::FileTools>

=item * L<Langertha::Raider::BashTools>

=item * L<raider> — the CLI entry point

=back

=cut

