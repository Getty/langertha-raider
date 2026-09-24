package Langertha::Raider::CLI::Main;
# ABSTRACT: Internal command-line entry point behind bin/raider
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use utf8;
use Getopt::Long ();
use IO::Prompt::Tiny qw( prompt );
use Path::Tiny;
use Langertha::Raider::ACP::CLI;
use Langertha::Raider::CLI;
use Langertha::Raider::CLI::Output;
use Langertha::Raider::CLI::REPL;
use Langertha::Raider::CLI::Runner;
use Langertha::Raider::Config;
use Langertha::Raider::Hall::CLI;
use Langertha::Raider::Skill;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    exit Langertha::Raider::CLI::Main->new->run(@ARGV);

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Everything F<raider> does with its command line: the C<hall>, C<acp> and
C<config explain> subcommands, option parsing, the skill exports, and
then either the REPL (L<Langertha::Raider::CLI::REPL>) or one prompt
(L<Langertha::Raider::CLI::Runner>). L</run> returns the exit status.

=head2 Exit status

=over

=item C<0> -- success, including C<--help>, the exports, C<config explain>
and leaving the REPL.

=item C<1> -- the run failed: the engine, a tool or the network raised an
error (with C<--json>, the output is the C<{error, elapsed}> document).

=item C<2> -- usage error: unknown option, a C<-o> that is not
C<KEY=VALUE>, an unknown C<config> subcommand, or no prompt.

=item C<3> -- configuration error: F<.raider.yml> cannot be read, the
engine is unknown, or a pack detection rule is invalid.

=back

The C<hall> and C<acp> subcommands keep their own exit statuses. An
interrupted one-shot run dies of the signal as usual. The REPL's
two-strike Ctrl-C leaves with C<0>.

=cut

use constant {
  EXIT_OK        => 0,
  EXIT_RUN_ERROR => 1,
  EXIT_USAGE     => 2,
  EXIT_CONFIG    => 3,
};

=attr output

The L<Langertha::Raider::CLI::Output> for everything but diagnostics.
Defaults to one on C<STDOUT>.

=attr err

Filehandle for diagnostics. Defaults to C<STDERR>.

=attr in

Filehandle a prompt or the REPL input is read from. Defaults to C<STDIN>.

=cut

has output => (
  is      => 'ro',
  isa     => 'Langertha::Raider::CLI::Output',
  lazy    => 1,
  default => sub { Langertha::Raider::CLI::Output->new },
);

has err => (
  is      => 'ro',
  default => sub { \*STDERR },
);

has in => (
  is      => 'ro',
  default => sub { \*STDIN },
);

sub app_class    { 'Langertha::Raider::CLI' }
sub config_class { 'Langertha::Raider::Config' }
sub repl_class   { 'Langertha::Raider::CLI::REPL' }
sub runner_class { 'Langertha::Raider::CLI::Runner' }
sub skill_class  { 'Langertha::Raider::Skill' }

sub _warn {
  my ( $self, @text ) = @_;
  print { $self->err } @text;
  return;
}

# A configuration error as the user reads it: one line, without the Perl
# source location croak appended (also the Moose accessor form).
sub _config_error {
  my ( $self, $error ) = @_;
  $error =~ s/ at (?:reader \S+ \(defined at .+ line \d+\)|(?:(?! at ).)+) line \d+\.\n\z/\n/s;
  $self->_warn($error =~ /\n\z/ ? $error : $error."\n");
  return;
}

=method usage

The C<--help> text.

=cut

sub usage { <<'USAGE' }
Usage: raider [options] [prompt...]
       raider config explain [options]   show each setting and its source

Options:
  -e, --engine NAME        anthropic, openai, deepseek, groq, mistral, gemini,
                           minimax, cerebras, openrouter, ollama
                           (default: auto-detected from available *_API_KEY
                           env var — anthropic > openai > deepseek > ...)
  -m, --model NAME         Model identifier (engine-specific cheap default)
  -k, --api-key KEY        API key (overrides *_API_KEY env var)
  -o, --option KEY=VALUE   Engine attribute (repeatable), e.g.
                           -o temperature=0.2 -o response_size=4096
                           Merged over .raider.yml; CLI wins. raider's own
                           .raider.yml keys (perl, packs=a,b, skills=a,b,
                           no_detect=a,b, detect=false,
                           preferred_lib_target, engine) configure raider.
  -r, --root DIR           Working directory (default: cwd). File tools are
                           confined to this directory.
  -M, --mission TEXT       System prompt / mission
  -i, --interactive        REPL mode (default when stdin is a TTY with no
                           prompt argv and no pipe; forces it otherwise)
      --json               Emit JSON ({response, metrics, elapsed}) and exit
      --max-iterations N   Hard safety cap on tool rounds per raid
                           (default: 10000 — effectively unlimited)
      --no-color           Disable ANSI colors
      --no-trace           Hide live tool-call progress output
      --perl               Enable perl_eval / perl_check / perl_cpanm tools
      --pack NAME          Enable a bundled pack (repeatable)
      --no-pack NAME       Switch a pack off, also a detected or default
                           one (repeatable)
      --no-detect          Do not activate packs by workspace detection
                           (--detect forces it on over detect: false)
      --customize-prompt   Launch the prompt-builder at startup
      --claude             Load Claude Code layout: CLAUDE.md +
                           .claude/skills/*/SKILL.md.
      --openai / --codex   Load AGENTS.md (the OpenAI Codex / cross-tool
                           convention).
      --skills DIR         Load *.md files from DIR as skills (repeatable).
      --export-skill [PATH]
                           Write a plain-markdown "how to use raider" doc
                           (default: ./RAIDER-SKILL.md) and exit.
      --export-claude-skill [PATH]
                           Write a Claude Code SKILL.md with frontmatter
                           (default: .claude/skills/raider/SKILL.md)
                           and exit.
  -h, --help               Show this help

If no prompt is given and not interactive, reads the prompt from STDIN.

Exit status: 0 success, 1 the run failed, 2 usage error,
3 configuration error.
USAGE

=method parse_options

    my ( $opt, @prompt ) = $main->parse_options(@argv);

Parses the options; returns the option hash (with C<-o> pairs in
C<engine_options>) and the remaining words, or nothing after reporting a
usage error.

=cut

sub parse_options {
  my ( $self, @argv ) = @_;
  my %opt = ( packs => [], no_packs => [], skill_dirs => [] );
  my @raw_engine_opts;
  my $parser = Getopt::Long::Parser->new(config => [qw( no_ignore_case bundling )]);
  my $ok = do {
    local $SIG{__WARN__} = sub { $self->_warn(@_) };
    $parser->getoptionsfromarray(\@argv,
      'e|engine=s'            => \$opt{engine},
      'm|model=s'             => \$opt{model},
      'r|root=s'              => \$opt{root},
      'M|mission=s'           => \$opt{mission},
      'k|api-key=s'           => \$opt{api_key},
      'o|option=s@'           => \@raw_engine_opts,
      'i|interactive'         => \$opt{interactive},
      'json'                  => \$opt{json},
      'max-iterations=i'      => \$opt{max_iterations},
      'no-color'              => \$opt{no_color},
      'trace!'                => \$opt{trace},
      'perl'                  => \$opt{perl},
      'pack=s@'               => $opt{packs},
      'no-pack=s@'            => $opt{no_packs},
      'detect!'               => \$opt{detect},
      'customize-prompt'      => \$opt{customize_prompt},
      'claude'                => \$opt{profile_claude},
      'openai|codex'          => \$opt{profile_openai},
      'skills=s@'             => $opt{skill_dirs},
      'export-skill:s'        => \$opt{export_skill},
      'export-claude-skill:s' => \$opt{export_claude_skill},
      'h|help'                => \$opt{help},
    );
  };
  unless ($ok) {
    $self->_warn("Bad options. Try --help.\n");
    return;
  }

  my %engine_opts;
  for my $pair (@raw_engine_opts) {
    my ( $k, $v ) = split /=/, $pair, 2;
    unless (defined $k && defined $v) {
      $self->_warn("bad -o spec '".$pair."' (expected key=value)\n");
      return;
    }
    # Auto-coerce simple numerics so temperature=0.2 lands as a number.
    if    ($v =~ /\A-?\d+\z/)                    { $v = 0 + $v }
    elsif ($v =~ /\A-?\d*\.\d+(?:[eE]-?\d+)?\z/) { $v = 0 + $v }
    elsif ($v eq 'true')                         { $v = 1 }
    elsif ($v eq 'false')                        { $v = 0 }
    $engine_opts{$k} = $v;
  }
  $opt{engine_options} = \%engine_opts;
  return ( \%opt, @argv );
}

=method app_args

    my %args = $main->app_args($opt);

Constructor arguments for L<Langertha::Raider::CLI> from the parsed
options, without C<config> and the skill sources. With C<--json> the live
trace is off unless C<--trace> asks for it, so stdout carries only the
JSON document.

=cut

sub app_args {
  my ( $self, $opt ) = @_;
  my %args;
  for my $key (qw( engine model root mission api_key trace perl detect max_iterations )) {
    $args{$key} = $opt->{$key} if defined $opt->{$key};
  }
  $args{trace}          = 0                        if $opt->{json} && !defined $opt->{trace};
  $args{pack_names}     = $opt->{packs}            if @{ $opt->{packs} // [] };
  $args{no_pack_names}  = $opt->{no_packs}         if @{ $opt->{no_packs} // [] };
  $args{engine_options} = $opt->{engine_options}   if %{ $opt->{engine_options} // {} };
  return %args;
}

=method run

    my $exit = $main->run(@argv);

Does what the command line says and returns the exit status.

=cut

sub run {
  my ( $self, @argv ) = @_;

  if (@argv && $argv[0] eq 'hall') {
    shift @argv;
    Langertha::Raider::Hall::CLI->main(@argv);
    return EXIT_OK;
  }
  if (@argv && $argv[0] eq 'acp') {
    shift @argv;
    Langertha::Raider::ACP::CLI->main(@argv);
    return EXIT_OK;
  }

  # raider config explain [options]: prints where each setting comes from
  # and exits without writing .raider.yml or building an engine.
  my $config_cmd;
  if (@argv && $argv[0] eq 'config') {
    shift @argv;
    $config_cmd = shift(@argv) // '';
    unless ($config_cmd eq 'explain') {
      $self->_warn("Usage: raider config explain [options]\n");
      return EXIT_USAGE;
    }
  }

  my ( $opt, @prompt ) = $self->parse_options(@argv) or return EXIT_USAGE;

  # Behind options (raider -e openai config explain) only the exact words
  # "config explain" are the subcommand; any other prompt starting with
  # "config" stays a prompt.
  if (!$config_cmd && @prompt == 2 && $prompt[0] eq 'config' && $prompt[1] eq 'explain') {
    $config_cmd = 'explain';
    @prompt = ();
  }

  $ENV{ANSI_COLORS_DISABLED} = 1 if $opt->{no_color} || $opt->{json};

  if ($opt->{help}) {
    $self->output->emit($self->usage);
    return EXIT_OK;
  }

  my %args = $self->app_args($opt);

  # The one reader/writer of .raider.yml. Parsed up front so a broken file
  # stops raider here, with its path in the message.
  my $config = $self->config_class->new(root => $opt->{root} // Path::Tiny->cwd->stringify);
  unless (eval { $config->data; 1 }) {
    $self->_config_error($@);
    return EXIT_CONFIG;
  }
  $args{config} = $config;

  my ( @skill_specs, @cli_profiles );
  if ($opt->{profile_claude}) {
    push @skill_specs, @{ $Langertha::Raider::CLI::AGENT_PROFILES{claude} };
    push @cli_profiles, 'claude';
  }
  if ($opt->{profile_openai}) {
    push @skill_specs, @{ $Langertha::Raider::CLI::AGENT_PROFILES{openai} };
    push @cli_profiles, 'openai';
  }
  my @persist_skills = @cli_profiles;
  for my $dir (@{ $opt->{skill_dirs} }) {
    my $spec = { type => 'dir', path => $dir };
    push @skill_specs, $spec;
    # A directory named like a profile keyword is saved as a spec, so it is
    # not read back as that profile.
    push @persist_skills, ($dir =~ /\A(?:claude|openai|codex|agents)\z/ ? $spec : $dir);
  }
  $args{cli_skill_sources} = \@skill_specs if @skill_specs;

  # Persist --claude / --openai / --skills to .raider.yml so the user doesn't
  # need to retype them every invocation. Track which profiles were freshly
  # persisted this run for the banner "(saved)" hint.
  my %saved_now = $config_cmd ? ()
    : map { $_ => 1 } grep { !ref } $config->add_skills(@persist_skills);

  # Unknown engine or an invalid detection rule: stop before anything runs.
  my $app = $self->app_class->new(%args);
  unless (eval { $app->_engine_class; $app->packs; 1 }) {
    $self->_config_error($@);
    return EXIT_CONFIG;
  }

  if ($config_cmd) {
    $self->output->config_report($app->explain_config);
    return EXIT_OK;
  }

  # One-shot skill export paths. Empty string means "use default path".
  if (defined $opt->{export_skill}) {
    my $path = length $opt->{export_skill}
      ? $opt->{export_skill}
      : path($app->root)->child('RAIDER-SKILL.md')->stringify;
    my $p = $self->skill_class->new(app => $app)->write_markdown($path);
    $self->_warn('wrote '.$p."\n");
    return EXIT_OK;
  }
  if (defined $opt->{export_claude_skill}) {
    my $skill = $self->skill_class->new(app => $app);
    my $p = $skill->write_claude_skill(length $opt->{export_claude_skill} ? $opt->{export_claude_skill} : undef);
    $self->_warn('wrote '.$p."\n");
    if (my $old = $skill->legacy_claude_skill) {
      $self->_warn('note: '.$old." is left over from an older raider, remove it\n");
    }
    return EXIT_OK;
  }

  # Default to interactive REPL when stdin is a terminal and no prompt was
  # given on argv / piped in / requested as one-shot JSON.
  my $in = $self->in;
  my $interactive = $opt->{interactive} || (!$opt->{json} && !@prompt && -t $in);

  if ($interactive) {
    my %seen;
    $self->repl_class->new(
      app              => $app,
      output           => $self->output,
      in               => $in,
      active_profiles  => [ grep { !$seen{$_}++ } @cli_profiles, $config->profiles($app->engine_name) ],
      saved_profiles   => \%saved_now,
      customize_prompt => $opt->{customize_prompt} ? 1 : 0,
    )->run(@prompt);
    return EXIT_OK;
  }

  my $text;
  if (@prompt) {
    $text = join ' ', @prompt;
  }
  elsif (-t $in) {
    # Interactive terminal but no -i and no argv: ask once.
    $text = prompt($self->output->c(prompt => 'raider>'));
  }
  else {
    local $/;
    $text = <$in>;
  }
  unless (defined $text && length $text) {
    $self->_warn("No prompt given.\n");
    return EXIT_USAGE;
  }
  my $runner = $self->runner_class->new(app => $app, output => $self->output);
  return $runner->run_prompt($text, json => $opt->{json}) ? EXIT_OK : EXIT_RUN_ERROR;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<raider>

=item * L<Langertha::Raider::CLI>

=back

=cut
