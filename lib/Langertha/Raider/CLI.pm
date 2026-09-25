# ABSTRACT: Autonomous CLI agent that can browse directories, edit files, and run bash commands

package Langertha::Raider::CLI;
our $VERSION = '0.503';
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
        skill_sources  => [
            { type => 'file',   path => 'CLAUDE.md' },
            { type => 'claude', path => '.claude/skills' },
        ],
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

=item * Full shell via L<MCP::Run::Bash> (the C<bash> tool).

=item * Web search + fetch via L<Net::Async::WebSearch> and
L<Net::Async::HTTP> (L<Langertha::Raider::WebTools>).

=item * Optional Perl-native tools via L<Langertha::Raider::PerlTools>.

=item * Persona and power packs via L<Langertha::Raider::Packs>.

=item * Per-engine cheap-model defaults and automatic engine selection from
the first C<*_API_KEY> env var found (L<Langertha::Raider::EngineResolver>).

=item * Optional skill-loading from C<.claude/skills/*/SKILL.md>,
C<AGENTS.md>, plain markdown directories, or any mix.

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
L</trace>, the per-tool agent profiles of C<--claude> / C<--openai> and
L</token_stats>. The CLI front-end is L<raider>.

=cut

=attr default_model_for_engine

Per-engine default model when L<Langertha::Raider::Application/model> is not explicitly set.

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

# Well-known per-tool files + source dirs. Used both for loading (when the
# matching profile flag is set) and for the "ignored but present" notice.
our %AGENT_PROFILES = (
  claude => [
    { type => 'file',   path => 'CLAUDE.md' },
    { type => 'claude', path => '.claude/skills' },
  ],
  openai => [
    { type => 'file',   path => 'AGENTS.md' },
  ],
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

=method ignored_agent_files

Returns a list of per-tool agent files that exist in the working root but
are NOT covered by the current L<Langertha::Raider::Application/skill_sources>. Intended to power the
banner's "seeing AGENTS.md, ignoring" notice.

=cut

sub ignored_agent_files {
  my ($self) = @_;
  return if $self->bare;

  my %loaded;
  for my $s (@{$self->skill_sources}) {
    next unless ($s->{type} // '') eq 'file';
    my $p = Path::Tiny::path($s->{path});
    $p = Path::Tiny::path($self->root)->child($s->{path}) unless $p->is_absolute;
    $loaded{ $p->canonpath }++;
  }

  my @out;
  for my $profile (sort keys %AGENT_PROFILES) {
    for my $spec (@{$AGENT_PROFILES{$profile}}) {
      next unless $spec->{type} eq 'file';
      my $p = Path::Tiny::path($self->root)->child($spec->{path});
      next unless -f $p;
      next if $loaded{ $p->canonpath };
      push @out, { path => $p->basename, profile => $profile };
    }
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
  for my $p (@{$self->_raider->_plugin_instances}) {
    return $p if $p->isa('Langertha::Raider::Plugin::Trace');
  }
  return;
}

=method token_stats

Cumulative token counts for this session (hashref with C<prompt>,
C<completion>, C<total>, C<calls>) — available when trace is enabled.

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

=item * L<MCP::Run::Bash>

=item * L<raider> — the CLI entry point

=back

=cut

