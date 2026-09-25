package Langertha::Raider::CLI::REPL;
# ABSTRACT: Internal interactive loop of the raider CLI
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Path::Tiny;
use Term::ANSIColor qw( color );
use Term::ReadLine;                   # Core; upgrades to Gnu if installed
use IO::Prompt::Tiny qw( prompt );    # Fallback when Gnu is not available
use Langertha::Raider::CLI::Commands;
use Langertha::Raider::CLI::Runner;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    Langertha::Raider::CLI::REPL->new(app => $app, output => $out)->run(@first_prompt);

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The F<raider> REPL: banner, line reading, slash commands via
L<Langertha::Raider::CLI::Commands>, every other line a prompt via
L<Langertha::Raider::CLI::Runner>, until C</quit>, C</exit>, C<:q>,
C<quit>, C<exit> or the end of input.

On a terminal, lines come from L<Term::ReadLine::Gnu> (line editing,
F<~/.raider_history>, two-strike Ctrl-C) or L<IO::Prompt::Tiny>. When L</in>
is not a terminal, lines are read from it as they are, without prompt, so
piped input ends the REPL at its end.

=attr app

The L<Langertha::Raider::CLI>. Required.

=attr output

The L<Langertha::Raider::CLI::Output> to print to. Required.

=attr in

Filehandle lines are read from when it is not a terminal. Defaults to
C<STDIN>.

=attr active_profiles

Agent profiles to show in the banner (C<claude>, C<openai>).

=attr saved_profiles

Profiles saved to F<.raider.yml> by this start, marked C<(saved)>.

=attr customize_prompt

Start with the prompt-builder (C<--customize-prompt>).

=cut

has app => (
  is       => 'ro',
  isa      => 'Langertha::Raider::CLI',
  required => 1,
);

has output => (
  is       => 'ro',
  isa      => 'Langertha::Raider::CLI::Output',
  required => 1,
);

has in => (
  is      => 'ro',
  default => sub { \*STDIN },
);

has active_profiles => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub { [] },
);

has saved_profiles => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

has customize_prompt => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has commands => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_commands',
);

sub _build_commands {
  my ($self) = @_;
  return Langertha::Raider::CLI::Commands->new(app => $self->app, output => $self->output, in => $self->in);
}

has runner => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_runner',
);

sub _build_runner {
  my ($self) = @_;
  return Langertha::Raider::CLI::Runner->new(app => $self->app, output => $self->output);
}

my $LOGO = <<'LOGO';
             __     __
.----.---.-.|__|.--|  |.-----.----.
|   _|  _  ||  ||  _  ||  -__|   _|
|__| |___._||__||_____||_____|__|
LOGO

=method banner

    $repl->banner($readline_impl);

Prints the logo and the live configuration: mission source, profiles,
skills, packs, ignored agent files, engine, model, API key, root.

=cut

sub banner {
  my ( $self, $rl_impl ) = @_;
  my $app = $self->app;
  my $out = $self->output;
  my $line = sub { $out->emit($out->c(meta => $_[0]), $out->c(title => $_[1]), "\n") };

  my $env = $app->api_key_env;
  my $env_display = defined $env
    ? ($ENV{$env} ? $env.' (set)' : $env.' (missing)')
    : '(no API key required)';
  my $model = $app->has_model ? $app->model : '(engine default)';
  my $source = $app->mission_source;
  my $persona = $source eq '-M'         ? 'from -M (.raider.md not used)'
              : $source eq '.raider.md' ? 'custom (.raider.md loaded)'
              :                           'Langertha (default)';
  $persona .= ', bare (no .raider.md or skills, only explicit packs)' if $app->bare;

  $out->emit($out->c(brand => $LOGO));
  $out->emit($out->c(accent => ' perl agent - powered by Langertha'), "\n\n");
  $line->('persona:  ', $persona);

  if (my @profiles = @{ $self->active_profiles }) {
    $line->('profiles: ', join(', ', map { $_.($self->saved_profiles->{$_} ? ' (saved)' : '') } @profiles));
  }

  my @skills = $app->loaded_skill_names;
  $line->('skills:   ', @skills
    ? sprintf('%d loaded (%s)', scalar @skills, join(', ', @skills))
    : 'none');

  my @active_packs = @{$app->packs->active_pack_names};
  $line->('packs:    ', join(', ', @active_packs)) if @active_packs;

  for my $ign ($app->ignored_agent_files) {
    $out->emit($out->c(meta => '          '),
      $out->c(warn => 'seeing '.$ign->{path}.', ignoring (use --'.$ign->{profile}.' to load)'), "\n");
  }
  $line->('engine:   ', $app->engine_name);
  $line->('model:    ', $model);
  $line->('api key:  ', $env_display);
  $line->('root:     ', $app->root);
  $line->('readline: ', $rl_impl);
  $out->emit($out->c(meta => 'type '), $out->c(accent => '/help'), $out->c(meta => ' for commands, '),
    $out->c(accent => '/quit'), $out->c(meta => ' to leave'), "\n\n");
  return;
}

=method run

    $repl->run(@first_prompt);

Runs the REPL; C<@first_prompt> (the words given on the command line) is
sent first. Returns when the user leaves.

=cut

sub run {
  my ( $self, @first ) = @_;
  my $out = $self->output;
  my $in  = $self->in;

  my $rl = -t $in ? $self->_terminal_reader : {
    read => sub { my $l = <$in>; $l },
    impl => 'none (input is not a terminal)',
  };
  my $call = sub { my $cb = $rl->{ $_[0] }; $cb->(@_[ 1 .. $#_ ]) if $cb };

  # Two-strike Ctrl-C: first press warns, second within 2s exits. Saves the
  # user from accidentally killing a running raid and removes the old
  # "Ctrl-C + Return" Docker quirk.
  my $last_sigint = 0;
  local $SIG{INT} = sub {
    my $now = time;
    if ($last_sigint && $now - $last_sigint <= 2) {
      $call->('save');
      $out->emit($out->c(meta => "\nbye."), "\n");
      exit 0;
    }
    $last_sigint = $now;
    $out->emit($out->c(meta => "\n(press Ctrl-C again within 2s to quit)"), "\n");
    $call->('redisplay');
  };
  local $SIG{TERM} = sub {
    $call->('save');
    $out->emit($out->c(meta => "\nbye."), "\n");
    exit 0;
  };

  $self->banner($rl->{impl});
  $self->commands->cmd_prompt if $self->customize_prompt;
  $self->runner->run_prompt(join ' ', @first) if @first;

  while (defined(my $line = $rl->{read}->())) {
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;

    if ($line =~ m{^(?:/quit|/exit|:q|quit|exit)$}i) {
      $out->emit($out->c(meta => 'bye.'), "\n");
      last;
    }
    $call->(add => $line);
    if ($line =~ m{^/}) {
      $self->commands->dispatch($line);
      next;
    }
    $self->runner->run_prompt($line);
  }

  $call->('save');
  return;
}

# Line reader on a terminal: { read, impl, add, save, redisplay }.
sub _terminal_reader {
  my ($self) = @_;
  # Prefer Term::ReadLine::Gnu (line editing + persistent history).
  # Fall back to IO::Prompt::Tiny when Gnu isn't installed.
  my $term = Term::ReadLine->new('raider');
  return {
    read => sub { prompt('raider>') },
    impl => 'IO::Prompt::Tiny (install Term::ReadLine::Gnu for history)',
  } unless $term->ReadLine =~ /Gnu/;

  $term->ornaments(0);
  my $histfile = path($ENV{HOME} // '.')->child('.raider_history')->stringify;
  eval { $term->ReadHistory($histfile) } if -f $histfile;
  # Take SIGINT away from readline so our Perl handler always runs — with
  # catch_signals=1 (the default) Gnu's internal handler swallows Ctrl-C and
  # ours only fires after the next Return, which is the Docker annoyance.
  eval { $term->Attribs->{catch_signals} = 0 };
  # Gray prompt, plain-color user input. Non-printing sequences are
  # wrapped in \x01...\x02 so readline computes prompt width correctly.
  my $ps = "\x01".color('bright_black')."\x02".'raider> '."\x01".color('reset')."\x02";
  return {
    read      => sub { $term->readline($ps) },
    impl      => $term->ReadLine,
    add       => sub { $term->addhistory($_[0]) },
    save      => sub { eval { $term->WriteHistory($histfile) } },
    redisplay => sub {
      eval {
        $term->replace_line('', 0);
        $term->Attribs->{point} = 0;
        $term->Attribs->{end}   = 0;
        $term->on_new_line;
        $term->redisplay;
      };
    },
  };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI::Main>

=back

=cut
