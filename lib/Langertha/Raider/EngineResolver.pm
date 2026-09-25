package Langertha::Raider::EngineResolver;
# ABSTRACT: Internal choice of engine, model and API key for a raider
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Module::Runtime ();

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $resolver = Langertha::Raider::EngineResolver->new(
      config         => $config,                 # Langertha::Raider::Config
      engine_options => { temperature => 0.2 },  # the -o pairs
      engine         => 'openai',                # optional, -e
    );

    my $name  = $resolver->engine_name;          # 'openai'
    my $class = $resolver->engine_class;         # 'Langertha::Engine::OpenAI'
    my %args  = $resolver->engine_args(mcp_servers => \@clients);
    my $engine = $resolver->build_engine(mcp_servers => \@clients);

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The provider choice of L<Langertha::Raider::Application>: which engine
(flag, C<-o engine=>, C<engine:> in F<.raider.yml>, the first C<*_API_KEY>
in the environment, C<anthropic>), which model and API key it is built
with, and the constructor arguments of the L<Langertha> engine class --
the F<.raider.yml> engine options, the C<-o> engine options on top, and
the model and key. Builds nothing but the engine itself.

=cut

=attr config

The L<Langertha::Raider::Config> of the workspace. Required.

=cut

has config => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Config',
  required => 1,
);

=attr engine_options

HashRef of the C<-o KEY=VALUE> options, raider's own keys (see
L<Langertha::Raider::Config/is_app_key>) included; only C<engine> of
those is read here.

=cut

has engine_options => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr engine_name

Langertha engine class shortcut, passed as C<engine>. Defaults to
C<-o engine=>, then to C<engine:> in F<.raider.yml>, then to the first
C<*_API_KEY> environment variable found, then to C<'anthropic'>.

=cut

has engine_name => (
  is       => 'ro',
  isa      => 'Str',
  lazy     => 1,
  builder  => '_build_engine_name',
  init_arg => 'engine',
);

sub _build_engine_name {
  my ($self) = @_;
  my $opt = $self->engine_options->{engine};
  return $opt if defined $opt && length $opt;
  my $yml = $self->config->engine;
  return $yml if defined $yml;
  return 'anthropic' if $ENV{ANTHROPIC_API_KEY};
  return 'openai'    if $ENV{OPENAI_API_KEY};
  return 'deepseek'  if $ENV{DEEPSEEK_API_KEY};
  return 'groq'      if $ENV{GROQ_API_KEY};
  return 'mistral'   if $ENV{MISTRAL_API_KEY};
  return 'gemini'    if $ENV{GEMINI_API_KEY};
  return 'anthropic';
}

my %DEFAULT_MODEL = (
  anthropic => 'claude-haiku-4-5',
  openai    => 'gpt-4o-mini',
  deepseek  => 'deepseek-chat',
  groq      => 'llama-3.3-70b-versatile',
  mistral   => 'mistral-small-latest',
  gemini    => 'gemini-2.5-flash',
  cerebras  => 'llama3.1-8b',
);

my %ENV_VAR = (
  anthropic  => 'ANTHROPIC_API_KEY',
  openai     => 'OPENAI_API_KEY',
  deepseek   => 'DEEPSEEK_API_KEY',
  groq       => 'GROQ_API_KEY',
  mistral    => 'MISTRAL_API_KEY',
  gemini     => 'GEMINI_API_KEY',
  minimax    => 'MINIMAX_API_KEY',
  cerebras   => 'CEREBRAS_API_KEY',
  openrouter => 'OPENROUTER_API_KEY',
  ollama     => undef,
);

my %ENGINE_CLASS = (
  anthropic  => 'Langertha::Engine::Anthropic',
  openai     => 'Langertha::Engine::OpenAI',
  deepseek   => 'Langertha::Engine::DeepSeek',
  groq       => 'Langertha::Engine::Groq',
  mistral    => 'Langertha::Engine::Mistral',
  gemini     => 'Langertha::Engine::Gemini',
  minimax    => 'Langertha::Engine::MiniMax',
  cerebras   => 'Langertha::Engine::Cerebras',
  openrouter => 'Langertha::Engine::OpenRouter',
  ollama     => 'Langertha::Engine::Ollama',
);

my @ENGINE_NAMES = qw(
  anthropic openai deepseek groq mistral gemini minimax cerebras openrouter ollama
);

=method engine_names

    my @names = $resolver->engine_names;   # ('anthropic', 'openai', ...)

Every engine name L</engine_class> knows, always in the same order. Also
callable on the class.

=cut

sub engine_names {
  my ($self) = @_;
  return @ENGINE_NAMES;
}

=method api_key_env_vars

    my @vars = $resolver->api_key_env_vars;   # ('ANTHROPIC_API_KEY', ...)

The API key environment variables of all L</engine_names>, in that
order; engines without one are left out. Also callable on the class.

=cut

sub api_key_env_vars {
  my ($self) = @_;
  return grep { defined } map { $self->env_var_for_engine($_) } $self->engine_names;
}

=method env_var_for_engine

    my $var = $resolver->env_var_for_engine('openai');   # 'OPENAI_API_KEY'

The environment variable holding the API key of an engine; C<undef> for
engines without one (C<ollama>) and unknown ones. Also callable on the
class.

=cut

sub env_var_for_engine {
  my ( $self, $engine ) = @_;
  return $ENV_VAR{$engine};
}

=method default_model_for_engine

    my $model = $resolver->default_model_for_engine('openai');   # 'gpt-4o-mini'

The cheap default model of an engine, C<undef> when it has none. Also
callable on the class.

=cut

sub default_model_for_engine {
  my ( $self, $engine ) = @_;
  return $DEFAULT_MODEL{$engine};
}

=attr model

Model identifier the engine is built with. Defaults to C<model> in
L</engine_options>, then C<model:> in F<.raider.yml>, then the per-engine
cheap default. An explicit C<model> always wins.

=cut

has model => (
  is        => 'ro',
  isa       => 'Str',
  lazy      => 1,
  predicate => 'has_explicit_model',
  builder   => '_build_model',
);

sub _build_model {
  my ($self) = @_;
  return $self->engine_options->{model}
    // $self->engine_yml_options->{model}
    // $self->default_model_for_engine($self->engine_name)
    // '';
}

=method has_model

True when a model was given or one resolves to a non-empty name.

=cut

sub has_model {
  my ($self) = @_;
  return 1 if $self->has_explicit_model;
  return length($self->model) ? 1 : 0;
}

=attr api_key

API key for the engine. Defaults to C<api_key> in L</engine_options>, then
C<api_key:> in F<.raider.yml>, then the engine's environment variable
(L</env_var_for_engine>). An explicit C<api_key> always wins.

=cut

has api_key => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_api_key',
);

sub _build_api_key {
  my ($self) = @_;
  my $configured = $self->engine_options->{api_key} // $self->engine_yml_options->{api_key};
  return $configured if defined $configured;
  my $var = $self->env_var_for_engine($self->engine_name);
  return '' unless $var;
  return $ENV{$var} // '';
}

=method api_key_env

Name of the environment variable of the current engine's API key, for
display; C<undef> for engines without one.

=cut

sub api_key_env {
  my ($self) = @_;
  return $self->env_var_for_engine($self->engine_name);
}

=method engine_class

The L<Langertha> engine class of L</engine_name>. Dies with C<Unknown
engine: NAME> for a name it does not know.

=cut

sub engine_class {
  my ($self) = @_;
  my $class = $ENGINE_CLASS{$self->engine_name}
    or die "Unknown engine: ".$self->engine_name."\n";   # die: the message is shown as is
  return $class;
}

=method engine_yml_options

The engine options of F<.raider.yml> for L</engine_name>
(L<Langertha::Raider::Config/engine_options>).

=cut

sub engine_yml_options {
  my ($self) = @_;
  return $self->config->engine_options($self->engine_name);
}

=method cli_engine_options

The C<-o> pairs that go to the engine: L</engine_options> without
raider's own keys.

=cut

sub cli_engine_options {
  my ($self) = @_;
  my $opts = $self->engine_options;
  return { map { $_ => $opts->{$_} } grep { !$self->config->is_app_key($_) } keys %$opts };
}

=method engine_args

    my %args = $resolver->engine_args(mcp_servers => \@clients);

Engine constructor arguments: F<.raider.yml> then C<-o> (C<-o> wins),
raider's own keys left out, then C<%extra>. C<model> and C<api_key> go
last: L</model> and L</api_key> already resolve flag over C<-o> over
F<.raider.yml>, so an explicit C<-m> / C<-k> is never overwritten.

=cut

sub engine_args {
  my ( $self, %extra ) = @_;
  my %args = (
    %{$self->engine_yml_options},
    %{$self->cli_engine_options},
    %extra,
  );
  delete @args{qw( model api_key )};
  $args{api_key} = $self->api_key if length $self->api_key;
  $args{model}   = $self->model   if $self->has_model;
  return %args;
}

=method build_engine

    my $engine = $resolver->build_engine(mcp_servers => \@clients);

Loads L</engine_class> and builds it with L</engine_args>.

=cut

sub build_engine {
  my ( $self, %extra ) = @_;
  my $class = $self->engine_class;
  Module::Runtime::require_module($class);
  return $class->new($self->engine_args(%extra));
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::Config>

=back

=cut
