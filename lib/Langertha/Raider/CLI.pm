# ABSTRACT: Autonomous CLI agent that can browse directories, edit files, and run bash commands

package Langertha::Raider::CLI;
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Run::Bash;
use Module::Runtime ();
use Path::Tiny;
use Langertha::Raider::HallTools qw( build_hall_tools_server );

use Langertha::Raider::FileTools qw( build_file_tools_server );
use Langertha::Raider::WebTools  qw( build_web_tools_server );
use Langertha::Raider::PerlTools qw( build_perl_tools_server );
use Langertha::Raider::Packs     qw( build_packs );
use Langertha::Raider::Config;
use Langertha::Raider::Detect;
use Langertha::Raider;

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

=item * Local filesystem access, confined to L</root>
(L<Langertha::Raider::FileTools>).

=item * Full shell via L<MCP::Run::Bash> (the C<bash> tool).

=item * Web search + fetch via L<Net::Async::WebSearch> and
L<Net::Async::HTTP> (L<Langertha::Raider::WebTools>).

=item * Optional Perl-native tools via L<Langertha::Raider::PerlTools>.

=item * Persona and power packs via L<Langertha::Raider::Packs>.

=item * Per-engine cheap-model defaults and automatic engine selection from
the first C<*_API_KEY> env var found.

=item * Optional skill-loading from C<.claude/skills/*/SKILL.md>,
C<AGENTS.md>, plain markdown directories, or any mix.

=item * Engine-attribute config via C<.raider.yml> in L</root> plus
L</engine_options> merge.

=item * Live trace plugin (L<Langertha::Raider::Plugin::Trace>) and
situation-injection plugin (L<Langertha::Raider::Plugin::Situation>).

=item * On-the-fly how-to-use-raider documentation generator
(L<Langertha::Raider::Skill>).

=back

The distribution intentionally stays small. It is the thin CLI-oriented
layer on top of Langertha's engine/agent machinery. The CLI front-end is
L<raider>.

=cut

=attr engine_name

Langertha engine class shortcut (e.g. C<'anthropic'>, C<'openai'>,
C<'deepseek'>, C<'groq'>, C<'mistral'>, C<'gemini'>, C<'ollama'>), passed as
C<engine>. Defaults to C<engine:> in F<.raider.yml>, then to the first
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
  my $opt = $self->_cli_app_options->{engine};
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

=attr default_model_for_engine

Per-engine default model when L</model> is not explicitly set.

=cut

my %DEFAULT_MODEL = (
  anthropic => 'claude-haiku-4-5',
  openai    => 'gpt-4o-mini',
  deepseek  => 'deepseek-chat',
  groq      => 'llama-3.3-70b-versatile',
  mistral   => 'mistral-small-latest',
  gemini    => 'gemini-2.5-flash',
  cerebras  => 'llama3.1-8b',
);

sub env_var_for_engine {
  my ($engine) = @_;
  my %map = (
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
  return $map{$engine};
}

sub default_model_for_engine {
  my ($engine) = @_;
  return $DEFAULT_MODEL{$engine};
}

=attr model

Model identifier to pass to the engine. Defaults to C<model> in
L</engine_options>, then C<model:> in F<.raider.yml>, then the per-engine
cheap default. An explicit C<model> always wins; this is the model the
engine is built with.

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
    // $self->_engine_yml_options->{model}
    // default_model_for_engine($self->engine_name)
    // '';
}

sub has_model {
  my ($self) = @_;
  return 1 if $self->has_explicit_model;
  return length($self->model) ? 1 : 0;
}

=attr api_key_env

Name of the environment variable used for the current engine's API key
(for display / debugging). Returns undef for engines that don't use an API
key (e.g. ollama).

=cut

sub api_key_env {
  my ($self) = @_;
  return env_var_for_engine($self->engine_name);
}

=attr api_key

API key for the engine. Defaults to C<api_key> in L</engine_options>, then
C<api_key:> in F<.raider.yml>, then an engine-appropriate environment
variable. An explicit C<api_key> always wins.

=cut

has api_key => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_api_key',
);

=attr mission

System prompt of the Raider, compiled from separate items (ADR 0004,
ADR 0014): the instructions (a generic assistant persona plus
F<.raider.md>), the tool description, the loaded skills and the active
packs. A C<mission> passed to the constructor (C<-M>) replaces the
instructions item only, also across L</reload_mission>; the other items
still apply. With L</bare> the skills, F<.raider.md> and all packs not
switched on by C<--pack> or C</pack> are left out.

=cut

has mission => (
  is       => 'ro',
  isa      => 'Str',
  lazy     => 1,
  init_arg => undef,
  builder  => '_build_mission',
);

has _explicit_mission => (
  is        => 'ro',
  isa       => 'Str',
  init_arg  => 'mission',
  predicate => '_has_explicit_mission',
);

=attr bare

C<--bare>: an isolated context. No F<.raider.md>, no skills, no pack
detection, and no packs from C<packs:> or C<enabled_by_default>;
C<--pack NAME> and C</pack NAME> still switch a pack on explicitly. What
remains is the instructions (the default persona, or the C<-M> text) and
the tool description.

=cut

has bare => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

sub _build_mission {
  my ($self) = @_;
  my @items = ( $self->_instructions_text, $self->_tools_text );

  my @skills = $self->_load_skill_texts;
  push @items, "Loaded skills (domain knowledge the user enabled for this session):\n\n"
    .join("\n\n", @skills)."\n" if @skills;

  my @pack_texts = $self->packs->skill_texts;
  push @items, "Active packs:\n\n".join("\n\n", @pack_texts)."\n" if @pack_texts;

  return join "\n\n---\n", @items;
}

# The instructions item: the -M text, or the default persona with
# .raider.md.
sub _instructions_text {
  my ($self) = @_;
  return $self->_explicit_mission if $self->_has_explicit_mission;
  my $base = $self->_persona_text;
  return $base if $self->bare;
  my $custom_file = path($self->root)->child('.raider.md');
  if (-f $custom_file) {
    my $custom = eval { $custom_file->slurp_utf8 };
    if (defined $custom && length $custom) {
      $base .= "\n\n---\nUser's custom instructions (from $custom_file):\n\n$custom\n";
    }
  }
  return $base;
}

# The tool description item. Hand-written until ADR 0005 derives it from
# the active tool set; -M never replaces it.
sub _tools_text {
  my ($self) = @_;
  return 'Working directory: '.$self->root."\n\n".<<'EOM';
Tools (MCP):
  - list_files(path)
  - read_file(path)
  - write_file(path, content)
  - edit_file(path, old_string, new_string)
  - bash(command, [working_directory], [timeout])
  - web_search(query, [limit])
  - web_fetch(url, [as_html])
EOM
}

sub _persona_text { <<'EOM' }
You are Langertha, viking shield-maiden. Autonomous CLI agent on user's
local machine. CLI name: "raider". Just CLI. No pause, no abort, no ask
to stop. You do things.

Name, persona, tone are defaults. User can rename you, rewrite your
background, or change persona entirely via C<.raider.md> in working dir.
If present, its content appended below as user's custom instructions.
User's custom instructions override this default where they conflict.

How you work:
  - User turn = task. Pursue with tools until done. Unlimited iterations.
  - Read before write. No guessing file contents.
  - After write_file / edit_file: verify. Re-read, or run check (perl -c,
    tests, etc.).
  - Small targeted edits > full rewrites.
  - bash is full shell, not sandbox. Use freely.
  - Skip irreversible ops (rm -rf, git reset --hard, force pushes) unless
    user explicit ask.

You have no yield / ask / abort tool. Task done: plain text reply. CLI
loops back to user.
EOM

=attr root

Working directory for tool operations. Defaults to the current process cwd.
File tools are confined to this directory, including realpath checks for
symlink escapes; bash commands inherit it as their default working directory.

=cut

has root => (
  is      => 'ro',
  isa     => 'Str',
  default => sub { Path::Tiny->cwd->stringify },
);

=attr allowed_commands

Optional arrayref restricting which bash commands may run (first word match).
When undef, any command is allowed.

=cut

has allowed_commands => (
  is        => 'ro',
  isa       => 'ArrayRef[Str]',
  predicate => 'has_allowed_commands',
);

=attr max_iterations

Maximum tool-calling iterations per raid. Defaults to 10_000 — effectively
unlimited, so a raid only ends when the model itself stops emitting tool
calls. The conversation history is preserved between raids, so the next user
message in the REPL simply continues the same thread.

Set this to a smaller number if you want a hard safety cap.

=cut

has max_iterations => (
  is      => 'ro',
  isa     => 'Int',
  default => 10_000,
);

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

=attr perl

Enable the PerlTools MCP server (perl_eval, perl_check, perl_cpanm).
Off by default; set via C<--perl> CLI flag or C<perl: true> in F<.raider.yml>.
Without either, the tools also come with the C<perl> pack, which is
detected in a Perl workspace; see L</perl_tools_enabled>.

=cut

has perl => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=method perl_tools_enabled

Whether the PerlTools server is mounted: C<--perl> turns it on; else an
explicit C<perl:> (in F<.raider.yml> or C<-o perl=>) decides either way;
else it is on when an active pack requests the C<perl> tools (the bundled
C<perl> pack, detected by F<cpanfile>, F<dist.ini>, F<Makefile.PL> or
F<lib/**/*.pm>). Granting a pack's request here stands in for the local
tool policy of ADR 0005, which does not exist yet; C<perl: false> is the
local denial.

=cut

sub perl_tools_enabled { $_[0]->perl_tools_grant->{enabled} }

=method perl_tools_grant

    my $grant = $app->perl_tools_grant;
    # { enabled => 1, reason => 'pack perl (detected)' }

L</perl_tools_enabled> with the reason: C<--perl>, C<perl: true> or
C<perl: false> with where it was set (C<.raider.yml> or C<-o>), the active
packs requesting the tools with their activation source, or
C<not requested>.

=cut

sub perl_tools_grant {
  my ($self) = @_;
  return { enabled => 1, reason => '--perl' } if $self->perl;
  my $yml = $self->_load_yml_options->{perl};
  if (defined $yml) {
    my $where = exists $self->_cli_app_options->{perl} ? '-o' : '.raider.yml';
    return { enabled => $yml ? 1 : 0, reason => 'perl: '.( $yml ? 'true' : 'false' ).' ('.$where.')' };
  }
  my $packs = $self->packs;
  my @by = map { 'pack '.$_.' ('.$packs->sources->{$_}{source}.')' }
    grep { grep { $_ eq 'perl' } @{ $packs->packs_by_name->{$_}->tools } }
    @{ $packs->enabled_pack_names };
  return @by ? { enabled => 1, reason => join(', ', @by) } : { enabled => 0, reason => 'not requested' };
}

=attr preferred_lib_target

Override the default local::lib target for perl_cpanm. When unset,
defaults to F<.raider/lib/> for standalone raiders. Can be set via
C<preferred_lib_target> in F<.raider.yml>.

=cut

has preferred_lib_target => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_preferred_lib_target',
);

=attr pack_names

Optional list of pack names supplied by the CLI, usually from repeatable
C<--pack NAME>. When present, these override the C<packs:> list in
F<.raider.yml>.

=cut

has pack_names => (
  is        => 'ro',
  isa       => 'ArrayRef[Str]',
  predicate => 'has_pack_names',
);

=attr no_pack_names

Pack names switched off from the command line (repeatable C<--no-pack
NAME>). They win over C<--pack>, C<packs:>, the bundled defaults and
detection.

=cut

has no_pack_names => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub { [] },
);

=attr detect

Pack detection from the command line: C<0> for C<--no-detect>, C<1> for
C<--detect>. When not given, C<detect:> in F<.raider.yml> decides; the
default is on.

=cut

has detect => (
  is        => 'ro',
  isa       => 'Bool',
  predicate => 'has_detect_flag',
);

=attr packs

L<Langertha::Raider::Packs::Collection> of the installed packs. Defaults
come from the bundled C<share/packs/> plus C<$RAIDER_PACK_DIRS>. Which are
enabled, highest priority first (ADR 0012); with L</bare> only
C<--pack NAME> applies:

=over

=item 1. C<--no-pack NAME> switches a pack off; C<--pack NAME> (or
C<-o packs=a,b>) enables the listed ones exclusively; C<--no-detect> /
C<--detect> switch detection off or on.

=item 2. C<packs:> in F<.raider.yml> (C<[caveman, git-guru]>) enables the
listed ones exclusively when no flag named packs; C<detect: false> and
C<no_detect: [NAME]> switch detection off entirely or per pack.

=item 3. Packs whose detection rule matches L</root> are added.

=back

Without explicit packs the bundled defaults (C<enabled_by_default>) are
on.

Detection rules come from a pack's F<pack.yml> (C<detect:>, the pack
default) and from C<detect:> in F<.raider.yml>, which replaces the pack
default per pack name. Each rule is evaluated against L</root> with
L<Langertha::Raider::Detect> when L</packs> is built and on
L</redetect_packs> (C</reload>), never per model call. A detected pack is
added to the enabled ones; in an exclusive group it gives way to an
explicit pack and replaces a bundled default. The outcome per pack is in
L<Langertha::Raider::Packs::Collection/activation_report>. An invalid rule
croaks.

Detection only decides which packs are active, it grants nothing (ADR
0005). Rules from the project's F<.raider.yml> are evaluated right away:
the workspace trust decision of ADR 0004, which is meant to gate them, does
not exist yet.

=cut

has packs => (
  is      => 'ro',
  isa     => 'Langertha::Raider::Packs::Collection',
  lazy    => 1,
  builder => '_build_packs',
);

sub detect_class { 'Langertha::Raider::Detect' }

sub _build_packs {
  my ($self) = @_;
  # --bare: only --pack counts, not packs:, defaults or detection.
  my ( $list, $source, $reason ) = !$self->bare ? $self->_explicit_packs
    : $self->has_pack_names ? ( $self->pack_names, flag => '--pack' )
    :                         ( [] );

  my $collection = build_packs(root => $self->root);

  if ($list && ref $list eq 'ARRAY' && ( @$list || $self->bare )) {
    # Explicit packs — enable exactly those
    for my $name (@{$collection->all_pack_names}) {
      $collection->disable($name);
    }
    for my $name (@$list) {
      $collection->enable($name, $source, $reason);
    }
  }
  $collection->disable($_, flag => '--no-pack') for @{$self->no_pack_names};
  $self->_detect_packs($collection);

  return $collection;
}

# The explicit pack list with its source: --pack, then -o packs=, then
# packs: in .raider.yml.
sub _explicit_packs {
  my ($self) = @_;
  return ( $self->pack_names, flag => '--pack' ) if $self->has_pack_names;
  my $opt = $self->_cli_app_options->{packs};
  return ( $opt, flag => '-o packs' ) if defined $opt;
  return ( $self->config->options($self->engine_name)->{packs}, config => '.raider.yml packs:' );
}

=method detection_state

    my ( $on, $why ) = $app->detection_state;

Whether pack detection runs, and what decided it: C<--detect>,
C<--no-detect>, C<detect: false> or C<default>.

=cut

sub detection_state {
  my ($self) = @_;
  return ( 0, '--bare' ) if $self->bare;
  return ( $self->detect ? ( 1, '--detect' ) : ( 0, '--no-detect' ) ) if $self->has_detect_flag;
  return ( 0, 'detect: false' ) unless $self->_detect_settings->{enabled};
  return ( 1, 'default' );
}

# detect: and no_detect: from .raider.yml, -o on top.
sub _detect_settings {
  my ($self) = @_;
  my $yml = $self->_load_yml_options;
  return $self->config->normalize_detect($yml->{detect}, $yml->{no_detect});
}

sub _detect_packs {
  my ($self, $collection) = @_;
  my %detections;
  $collection->detections(\%detections);
  my ( $enabled ) = $self->detection_state;
  return unless $enabled;

  my $settings = $self->_detect_settings;
  my %rules;
  for my $name (@{$collection->all_pack_names}) {
    my $pack = $collection->packs_by_name->{$name};
    next unless $pack->has_detect;
    $rules{$name} = [ 'pack default', $pack->detect, $pack->path.'/pack.yml detect' ];
  }
  $rules{$_} = [ '.raider.yml detect:', $settings->{rules}{$_}, 'detect.'.$_ ] for keys %{$settings->{rules}};

  my %no_pack = map { $_ => 1 } @{$self->no_pack_names};
  my $detect = $self->detect_class->new(root => $self->root);
  for my $name (sort keys %rules) {
    my ( $from, $rule, $label ) = @{$rules{$name}};
    $self->detect_class->validate_rule($rule, $label);
    my $record = sub {
      my ( $result, $reason, $notes ) = @_;
      $detections{$name} = { rule_from => $from, result => $result, reason => $reason, notes => $notes // [] };
    };
    my $skip = !$collection->packs_by_name->{$name} ? 'unknown pack'
             : $no_pack{$name}                     ? '--no-pack'
             : $settings->{off}{$name}             ? $settings->{off}{$name}
             : $collection->is_active($name)       ? 'already active'
             :                                        undef;
    if ($skip) {
      $record->(skipped => $skip);
      next;
    }
    my $result = $detect->evaluate($rule, $label);
    unless ($result->{matched}) {
      $record->('not matched', $result->{reason}, $result->{notes});
      next;
    }
    if (my $holder = $collection->enable_detected($name, $result->{reason})) {
      my $kind = $collection->sources->{$holder}{source} eq 'detected' ? 'detected' : 'explicit';
      $record->(skipped => $kind.' '.$holder.' holds exclusive group '.$collection->packs_by_name->{$name}->exclusive_group);
      next;
    }
    $record->(matched => $result->{reason});
  }
  return;
}

=method redetect_packs

    my @detected = $app->redetect_packs;

Drops the packs that were enabled by detection, evaluates the rules again
against L</root> and returns the names of the packs detected now. Packs
enabled any other way stay as they are. C</reload> calls it.

=cut

sub redetect_packs {
  my ($self) = @_;
  my $collection = $self->packs;
  for my $name (@{ [ @{$collection->active_pack_names} ] }) {
    $collection->disable($name) if ($collection->sources->{$name}{source} // '') eq 'detected';
  }
  $self->_detect_packs($collection);
  return grep { ($collection->sources->{$_}{source} // '') eq 'detected' } @{$collection->active_pack_names};
}

=attr max_context_tokens

Trigger history auto-compression once the last prompt exceeds
C<context_compress_threshold * max_context_tokens>. Defaults to 40_000, which
keeps the running session comfortably under typical per-minute rate limits
(Anthropic org default: 50k input tokens/min on Haiku).

=cut

has max_context_tokens => (
  is      => 'ro',
  isa     => 'Int',
  default => 40_000,
);

=attr context_compress_threshold

Fraction of L</max_context_tokens> at which compression kicks in. Defaults to
C<0.7>.

=cut

has context_compress_threshold => (
  is      => 'ro',
  isa     => 'Num',
  default => 0.7,
);

=attr skill_sources

ArrayRef of skill-source specs to load and append to the mission. Each spec
is a hashref:

    { type => 'claude', path => '.claude/skills' }  # Claude Code SKILL.md tree
    { type => 'dir',    path => 'my-skills', glob => '*.md' }

Defaults to the C<skills> entries of F<.raider.yml> (see
L<Langertha::Raider::Config>) followed by L</cli_skill_sources>. Passing
C<skill_sources> explicitly replaces both. With L</bare> there are none.

=cut

has skill_sources => (
  is      => 'ro',
  isa     => 'ArrayRef[HashRef]',
  lazy    => 1,
  builder => '_build_skill_sources',
);

=attr cli_skill_sources

ArrayRef of skill-source specs from the command line (C<--claude>,
C<--openai>, C<--skills DIR>). They are added to the F<.raider.yml> skills,
duplicates dropped.

=cut

has cli_skill_sources => (
  is        => 'ro',
  isa       => 'ArrayRef[HashRef]',
  predicate => 'has_cli_skill_sources',
);

=attr config

The L<Langertha::Raider::Config> for F<.raider.yml> in L</root>.

=cut

has config => (
  is         => 'ro',
  isa        => 'Langertha::Raider::Config',
  lazy_build => 1,
);

sub _build_config {
  my ($self) = @_;
  return Langertha::Raider::Config->new(root => $self->root);
}

# Which settings were passed to the constructor (the command-line flags), for
# explain_config. Lazy attributes cannot tell that apart once built.
has _explicit => (
  is       => 'ro',
  isa      => 'HashRef',
  init_arg => undef,
  default  => sub { {} },
);

sub BUILD {
  my ($self, $args) = @_;
  $self->_explicit->{$_} = 1 for grep { exists $args->{$_} } qw( engine model api_key perl );
}

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

sub _build_skill_sources {
  my ($self) = @_;
  return [] if $self->bare;
  return [ $self->config->skill_specs(
    $self->engine_name,
    @{ $self->_cli_app_options->{skills} // [] },
    $self->has_cli_skill_sources ? @{$self->cli_skill_sources} : (),
  ) ];
}

sub _load_skill_texts {
  my ($self) = @_;
  my @out;
  for my $spec (@{$self->skill_sources}) {
    my $type = $spec->{type} // 'dir';
    my $rel  = $spec->{path};
    next unless defined $rel && length $rel;
    my $base = Path::Tiny::path($rel);
    $base = Path::Tiny::path($self->root)->child($rel) unless $base->is_absolute;
    next unless $type eq 'file' || -d $base;

    my @files;
    if ($type eq 'file') {
      # Single markdown file — $base is that file, not a directory.
      my $f = Path::Tiny::path($rel);
      $f = Path::Tiny::path($self->root)->child($rel) unless $f->is_absolute;
      next unless -f $f;
      @files = ($f);
    }
    elsif ($type eq 'claude') {
      # Claude layout: $base/<skill>/SKILL.md
      for my $dir ($base->children) {
        next unless -d $dir;
        my $f = $dir->child('SKILL.md');
        push @files, $f if -f $f;
      }
    }
    else {
      my $glob = $spec->{glob} // '*.md';
      push @files, $base->children(qr/\Q$glob\E$/);
      # Fallback: recurse if nothing matched at the top level
      if (!@files) {
        @files = grep { -f $_ && /\.md$/ } $base->children;
      }
    }

    for my $f (sort @files) {
      my $name = $type eq 'claude' ? $f->parent->basename : $f->basename;
      my $body = eval { $f->slurp_utf8 } // next;
      # Strip YAML frontmatter if present.
      $body =~ s/\A---\s*\n.*?\n---\s*\n//s;
      push @out, "### Skill: $name\n\n$body";
    }
  }
  return @out;
}

=attr engine_options

HashRef of the C<-o KEY=VALUE> options. Engine attributes (e.g.
C<temperature>, C<response_size>, C<seed>) are forwarded to the engine
constructor, merged on top of values loaded from C<.raider.yml> in the
working directory. Raider's own keys (see
L<Langertha::Raider::Config/is_app_key>) configure raider like their
F<.raider.yml> counterparts and override them; C<packs> and C<skills> take
a comma-separated list.

=cut

has engine_options => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

# The -o pairs that configure raider itself, the list keys split on commas
# as they would read from .raider.yml.
sub _cli_app_options {
  my ($self) = @_;
  my $opts = $self->engine_options;
  my %app;
  for my $key (grep { $self->config->is_app_key($_) } keys %$opts) {
    my $value = $opts->{$key};
    $value = [ split /,/, $value ] if ($key eq 'packs' || $key eq 'skills') && !ref $value;
    $app{$key} = $value;
  }
  return \%app;
}

sub _cli_engine_options {
  my ($self) = @_;
  my $opts = $self->engine_options;
  return { map { $_ => $opts->{$_} } grep { !$self->config->is_app_key($_) } keys %$opts };
}

sub _load_yml_options {
  my ($self) = @_;
  my %app = %{ $self->_cli_app_options };
  delete $app{skills};
  return { %{ $self->config->options($self->engine_name) }, %app };
}

sub _engine_yml_options {
  my ($self) = @_;
  return $self->config->engine_options($self->engine_name);
}

has loop => (
  is      => 'ro',
  isa     => 'IO::Async::Loop',
  lazy    => 1,
  default => sub { IO::Async::Loop->new },
);

has _engine => (is => 'ro', lazy => 1, builder => '_build_engine');
has _raider => (is => 'ro', lazy => 1, builder => '_build_raider');
has _mcps   => (is => 'ro', lazy => 1, builder => '_build_mcps');

sub _build_api_key {
  my ($self) = @_;
  my $configured = $self->engine_options->{api_key} // $self->_engine_yml_options->{api_key};
  return $configured if defined $configured;
  my $var = env_var_for_engine($self->engine_name);
  return '' unless $var;
  return $ENV{$var} // '';
}

sub _engine_class {
  my ($self) = @_;
  my %map = (
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
  my $class = $map{$self->engine_name}
    or die "Unknown engine: " . $self->engine_name . "\n";
  return $class;
}

sub _build_mcps {
  my ($self) = @_;

  my $yml = $self->_load_yml_options;

  my $files = build_file_tools_server(root => $self->root);

  my $bash = MCP::Run::Bash->new(
    tool_name         => 'bash',
    tool_description  => 'Run a shell command with bash -c. Returns exit code, stdout, and stderr. Use this for ls, grep, find, git, cat, running tests, any shell pipeline — anything you would type at a terminal.',
    working_directory => $self->root,
    ($self->has_allowed_commands ? (allowed_commands => $self->allowed_commands) : ()),
    timeout => 120,
  );

  my $web = build_web_tools_server(loop => $self->loop);

  my @clients;
  for my $server ($files, $bash, $web) {
    my $client = Net::Async::MCP->new(server => $server);
    $self->loop->add($client);
    push @clients, $client;
  }

  if ($self->perl_tools_enabled) {
    my $lib_target = $self->has_preferred_lib_target
      ? $self->preferred_lib_target
      : ($yml->{preferred_lib_target} // undef);
    my $perl = build_perl_tools_server(
      root       => $self->root,
      loop       => $self->loop,
      lib_target => $lib_target,
    );
    my $client = Net::Async::MCP->new(server => $perl);
    $self->loop->add($client);
    push @clients, $client;
  }

  # Hall-side tools: when we were spawned by raider-hall, expose
  # telegram_reply / hall_status / hall_spawn so the agent can talk back.
  if ($ENV{RAIDER_HALL_SOCKET} && -S $ENV{RAIDER_HALL_SOCKET}) {
    my $hall_srv = build_hall_tools_server(
      socket => $ENV{RAIDER_HALL_SOCKET},
    );
    my $client = Net::Async::MCP->new(server => $hall_srv);
    $self->loop->add($client);
    push @clients, $client;
  }

  return \@clients;
}

sub _build_engine {
  my ($self) = @_;
  my $class = $self->_engine_class;
  Module::Runtime::require_module($class);
  return $class->new($self->_engine_args);
}

# Engine constructor arguments: .raider.yml then -o (CLI wins), raider's
# own keys left out. model and api_key go last: their accessors already
# resolve flag over -o over .raider.yml, so an explicit -m / -k is never
# overwritten.
sub _engine_args {
  my ($self) = @_;
  my %args = (
    %{$self->_engine_yml_options},
    %{$self->_cli_engine_options},
    mcp_servers => $self->_mcps,
  );
  delete @args{qw( model api_key )};
  $args{api_key} = $self->api_key if length $self->api_key;
  $args{model}   = $self->model   if $self->has_model;
  return %args;
}

sub _build_raider {
  my ($self) = @_;
  my @plugins;
  if ($self->trace) {
    # Pass as name + {args}; PluginHost still injects `host`. The `loop` arg
    # lets the plugin drive a spinner during LLM HTTP calls.
    push @plugins, '+Langertha::Raider::Plugin::Trace', { loop => $self->loop, out => $self->trace_out };
  }
  push @plugins, '+Langertha::Raider::Plugin::Situation';
  return Langertha::Raider->new(
    engine                     => $self->_engine,
    mission                    => $self->mission,
    max_iterations             => $self->max_iterations,
    max_context_tokens         => $self->max_context_tokens,
    context_compress_threshold => $self->context_compress_threshold,
    (@plugins ? (plugins => \@plugins) : ()),
  );
}

=method raid_f

    my $result = await $app->raid_f($prompt);

Async variant: drives one raid iteration and returns the
L<Langertha::Raider::Result>.

=cut

async sub raid_f {
  my ($self, @messages) = @_;
  for my $mcp (@{$self->_mcps}) {
    await $mcp->initialize;
  }
  return await $self->_raider->raid_f(@messages);
}

=method run

    my $result = $app->run($prompt);

Synchronous convenience wrapper around L</raid_f>. Runs the I/O loop until the
raid completes and returns the result (which stringifies to the final text).

=cut

sub run {
  my ($self, @messages) = @_;
  my $f = $self->raid_f(@messages);
  $self->loop->await($f);
  return $f->get;
}

=method raider

Returns the underlying L<Langertha::Raider> instance (lazily built).

=cut

sub raider { $_[0]->_raider }

=method trace_plugin

Returns the loaded L<Langertha::Raider::Plugin::Trace> instance, or undef if trace
is disabled.

=cut

=method loaded_skill_names

Returns a list of skill names currently discoverable from the configured
L</skill_sources>. Intended for banner/status display.

=cut

sub loaded_skill_names {
  my ($self) = @_;
  my @names;
  for my $spec (@{$self->skill_sources}) {
    my $type = $spec->{type} // 'dir';
    my $rel  = $spec->{path};
    next unless defined $rel && length $rel;
    my $base = Path::Tiny::path($rel);
    $base = Path::Tiny::path($self->root)->child($rel) unless $base->is_absolute;
    if ($type eq 'file') {
      push @names, $base->basename if -f $base;
      next;
    }
    next unless -d $base;
    if ($type eq 'claude') {
      for my $dir (sort $base->children) {
        next unless -d $dir;
        push @names, $dir->basename if -f $dir->child('SKILL.md');
      }
    }
    else {
      for my $f (sort $base->children) {
        push @names, $f->basename if -f $f && $f =~ /\.md$/;
      }
    }
  }
  return @names;
}

=method ignored_agent_files

Returns a list of per-tool agent files that exist in the working root but
are NOT covered by the current L</skill_sources>. Intended to power the
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

=method reload_mission

Rebuilds the mission (e.g. after C<.raider.md> has been edited) and swaps it
into the underlying L<Langertha::Raider>. An explicit L</mission> is kept.

=cut

sub reload_mission {
  my ($self) = @_;
  my $new = $self->_build_mission;
  # Hot-swap on the running raider, history and metrics stay.
  $self->_raider->_set_mission($new);
  return $new;
}

=method mission_source

Where the instructions item of L</mission> comes from: C<-M> for a
mission passed to the constructor, C<.raider.md> when that file customizes
the default persona (never with L</bare>), C<default> otherwise.

=cut

sub mission_source {
  my ($self) = @_;
  return '-M' if $self->_has_explicit_mission;
  return !$self->bare && -f Path::Tiny::path($self->root)->child('.raider.md') ? '.raider.md' : 'default';
}

=method explain_config

    my $report = $app->explain_config;

Where each effective setting came from, command-line flags included. The
shape of L<Langertha::Raider::Config/explain>, with C<source> (and
C<shadowed>) naming a flag (C<-e>, C<-m>, C<-k>, C<-o>, C<--pack>,
C<--perl>, C<--claude/--openai/--skills>), a F<.raider.yml> layer
(C<.raider.yml>, C<.raider.yml default:>, C<.raider.yml openai:>), an
environment variable (C<env OPENAI_API_KEY>) or C<default>. API key values
are never included. Builds no engine.

C<detection> says whether pack detection runs (C<on>, or C<off> with what
switched it off) and C<packs> is the
L<Langertha::Raider::Packs::Collection/activation_report>: each pack with
its source (C<flag>, C<config>, C<default>, C<detected>, C<manual>) and,
for detection rules, the clause that matched or failed. C<perl_tools> is
L</perl_tools_grant>: whether the Perl tools are mounted, and why.

C<instructions> is L</mission_source> and C<bare> is L</bare>.

=cut

sub explain_config {
  my ($self) = @_;
  my $engine   = $self->engine_name;
  my $report   = $self->config->explain($engine);
  my $explicit = $self->_explicit;
  my $app_opts = $self->_cli_app_options;
  my $opts     = { %{ $self->_cli_engine_options }, %$app_opts };

  # .raider.yml values as candidates: [ source, value, shadowed ]
  my ( %yml, @yml_skills );
  for my $v (@{ $report->{values} }) {
    my $candidate = [
      $self->_yml_source($v->{source}),
      $v->{value},
      [ map { $self->_yml_source($_) } @{ $v->{shadowed} } ],
    ];
    if ($v->{merged}) {
      push @yml_skills, { %$v, source => $candidate->[0], shadowed => [] };
      next;
    }
    $yml{ $v->{key} } = { applies_to => $v->{applies_to}, candidate => $candidate };
  }
  my %from_yml = map { $_ => $yml{$_}{candidate} } keys %yml;

  my $env_var = env_var_for_engine($engine);
  my $env_key = defined $env_var && length($ENV{$env_var} // '') ? $env_var : undef;
  my $default_model = default_model_for_engine($engine);
  my $yml_key = $from_yml{api_key};

  my @values = (
    $self->_explain_entry(engine => 'raider', [
      $explicit->{engine} ? [ '-e', $engine ] : undef,
      defined $opts->{engine} ? [ '-o', $opts->{engine} ] : undef,
      $from_yml{engine},
    ], [ $env_key ? 'env '.$env_key : 'default', $engine ]),
    $self->_explain_entry(model => 'engine', [
      $explicit->{model} ? [ '-m', $self->model ] : undef,
      defined $opts->{model} ? [ '-o', $opts->{model} ] : undef,
      $from_yml{model},
    ], defined $default_model ? [ 'default', $default_model ] : undef),
    $self->_explain_entry(api_key => 'engine', [
      $explicit->{api_key} ? [ '-k', '(set)' ] : undef,
      defined $opts->{api_key} ? [ '-o', '(set)' ] : undef,
      $yml_key ? [ $yml_key->[0], '(set)', $yml_key->[2] ] : undef,
    ], $env_key ? [ 'env '.$env_key, '(set)' ] : undef),
  );

  my %flag = (
    ( $self->has_pack_names ? ( packs => [ '--pack', $self->pack_names ] ) : () ),
    ( $explicit->{perl} && $self->perl ? ( perl => [ '--perl', 1 ] ) : () ),
    ( $self->has_detect_flag
      ? ( detect => [ $self->detect ? '--detect' : '--no-detect', $self->detect ? 1 : 0 ] ) : () ),
  );
  my %key = map { $_ => 1 } keys %$opts, keys %yml, keys %flag;
  delete @key{qw( engine model api_key skills )};
  for my $key (sort keys %key) {
    my $applies_to = $self->config->is_app_key($key) ? 'raider' : 'engine';
    push @values, $self->_explain_entry($key, $applies_to, [
      $flag{$key} // ( exists $opts->{$key} ? [ '-o', $opts->{$key} ] : undef ),
      $from_yml{$key},
    ]);
  }

  push @values, @yml_skills;
  push @values, {
    key        => 'skills',
    value      => $app_opts->{skills},
    source     => '-o',
    shadowed   => [],
    merged     => 1,
    applies_to => 'raider',
  } if $app_opts->{skills};
  push @values, {
    key        => 'skills',
    value      => $self->cli_skill_sources,
    source     => '--claude/--openai/--skills',
    shadowed   => [],
    merged     => 1,
    applies_to => 'raider',
  } if $self->has_cli_skill_sources;

  my ( $detecting, $why ) = $self->detection_state;
  return {
    %$report,
    values       => \@values,
    detection    => $detecting ? 'on' : 'off ('.$why.')',
    instructions => $self->mission_source,
    bare         => $self->bare ? 1 : 0,
    packs        => $self->packs->activation_report,
    perl_tools   => $self->perl_tools_grant,
  };
}

sub _yml_source {
  my ($self, $layer) = @_;
  return $layer eq 'top' ? '.raider.yml' : '.raider.yml '.$layer.':';
}

# One explain entry from candidates [ source, value, shadowed ], highest
# priority first; the fallback counts only when no candidate is set.
sub _explain_entry {
  my ($self, $key, $applies_to, $candidates, $fallback) = @_;
  my @have = grep { defined } @$candidates;
  @have = ($fallback) if !@have && $fallback;
  return unless @have;
  my ($win, @rest) = @have;
  return {
    key        => $key,
    value      => $win->[1],
    source     => $win->[0],
    shadowed   => [ @{ $win->[2] // [] }, map { ( $_->[0], @{ $_->[2] // [] } ) } @rest ],
    applies_to => $applies_to,
  };
}


__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider>

=item * L<Langertha::Raider::FileTools>

=item * L<MCP::Run::Bash>

=item * L<raider> — the CLI entry point

=back

=cut
