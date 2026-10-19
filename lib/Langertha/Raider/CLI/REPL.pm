package Langertha::Raider::CLI::REPL;
# ABSTRACT: Internal interactive loop of the raider CLI
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Config;
use Encode qw( decode encode FB_QUIET );
use JSON::MaybeXS ();
use List::Util qw( first );
use POSIX ();
use Path::Tiny;
use Scalar::Util qw( weaken );
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

A line C<!CMD> runs C<CMD> in the shell and nothing else
(L</run_shell>); a line C<?CMD> runs it and then sends the command, its
exit status and its output to the model as the next prompt
(L</run_shell_prompt>). A line that is only C<!> or C<?> is a prompt.

On a terminal, lines come from L<Term::ReadLine::Gnu> (line editing,
F<~/.raider_history>) or L<IO::Prompt::Tiny>.

The first C<SIGINT> (Ctrl-C) while a prompt runs cancels that turn
(L<Langertha::Raider::CLI::Runner/cancel_run>): the tool commands still
running are ended, the raid stops at its next safe point, C<turn
cancelled> is printed, the session journal ends the run as C<cancelled>,
and the REPL reads the next line. At the prompt the first Ctrl-C only
warns. A second one within two seconds, or a C<SIGTERM>, leaves the REPL
with exit status 0, after ending the tool commands still running
(L<Langertha::Raider::CLI::Runner/terminate_children>). While a C<!CMD>
or C<?CMD> runs, raider ignores C<SIGINT>, so Ctrl-C ends the command
alone. When L</in>
is not a terminal, lines are read from it as they are, without prompt, so
piped input ends the REPL at its end.

=attr app

The L<Langertha::Raider::CLI>. Required.

=attr output

The L<Langertha::Raider::CLI::Output> to print to. Required.

=attr in

Filehandle lines are read from when it is not a terminal. Defaults to
C<STDIN>.

=attr can_ask

Whether a person answers the model's questions (the C<ask_user> tool,
L</ask_user>), approves tool calls (L</permission_request>) and reviews
plans (L</plan_review>). Defaults to whether L</in> is a terminal; without
one the tool refuses and the model decides itself, and a call the
permission policy asks about is refused.

=attr active_profiles

Agent profiles to show in the banner (C<claude>, C<openai>).

=attr saved_profiles

Profiles saved to the config file by this start, marked C<(saved)>.

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

has can_ask => (
  is      => 'ro',
  isa     => 'Bool',
  lazy    => 1,
  default => sub { -t $_[0]->in ? 1 : 0 },
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

=attr session_store

The L<Langertha::Raider::SessionStore> a new session is created in, with
the first prompt. Without one (C<--no-session>) nothing is recorded.

=attr session

The L<Langertha::Raider::Session> the prompts are recorded in, once there
is one. A C</clear> is recorded there too, as C<history.cleared>, so
resuming the session starts with an empty history again.

=cut

has session_store => (
  is        => 'ro',
  isa       => 'Langertha::Raider::SessionStore',
  predicate => 'has_session_store',
);

has session => (
  is        => 'ro',
  isa       => 'Langertha::Raider::Session',
  writer    => '_set_session',
  predicate => 'has_session',
);

=attr notes

Lines printed right after the banner: what resuming L</session> found
(L<Langertha::Raider::CLI::Sessions/restore>).

=cut

has notes => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub { [] },
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
layout mode (ADR 0019) and the memory files it loads, the listed
skills, packs, ignored agent files, engine, model, API key, root.

=cut

sub banner {
  my ( $self, $rl_impl ) = @_;
  my $app = $self->app;
  my $out = $self->output;
  my $line = sub { $out->emit($out->c(meta => $_[0]), $out->c(title => $_[1]), "\n") };

  my $env = $app->api_key_env;
  my $resolver = $app->engine_resolver;
  my $env_display = $resolver->has_provider
    # --provider: the key comes from -k, never from the environment, and
    # only an endpoint with an auth_ref needs one. Never print the key.
    ? ( defined $resolver->provider->{auth}
        ? 'auth '.$resolver->provider->{auth}.' ('.( length $resolver->api_key ? 'set' : 'missing' ).')'
        : length $resolver->api_key ? '(the endpoint asks for none; the key you gave is set and sent)'
        : '(no API key required)' )
    : defined $env
      ? ($ENV{$env} ? $env.' (set)' : $env.' (missing)')
      : '(no API key required)';
  my $model = $app->has_model ? $app->model : '(engine default)';
  my $source = $app->mission_source;
  my $file   = $app->instructions->label;
  my $persona = $source eq '-M'   ? 'from -M ('.$file.' not used)'
              : $source eq q(claude base) ? q(Claude Code base text (CLAUDE.md memory, no persona))
              : $source eq $file  ? 'custom ('.$file.' loaded)'
              :                     'Langertha (default)';
  $persona .= ', bare (no '.$file.' or skills, only explicit packs)' if $app->bare;

  $out->emit($out->c(brand => $LOGO));
  $out->emit($out->c(accent => ' perl agent - powered by Langertha'), "\n\n");
  $line->('persona:  ', $persona);

  if (my @profiles = @{ $self->active_profiles }) {
    $line->('profiles: ', join(', ', map { $_.($self->saved_profiles->{$_} ? ' (saved)' : '') } @profiles));
  }

  my $context = $app->context;
  my $layout = $context->layout;
  $line->('layout:   ', $layout->mode.' ('.$layout->reason.')'
    .( $context->claude_layout && $layout->mode ne 'claude' ? ', Claude layout on ('.$layout->claude_layout_reason.')' : '' ));
  if (my @memory = $context->instruction_items) {
    $line->('memory:   ', join(', ', map { $_->{label} } @memory));
  }

  my @skills = $app->loaded_skill_names;
  $line->('skills:   ', @skills
    ? sprintf('%d listed (%s)', scalar @skills, join(', ', @skills))
    : 'none');

  my @active_packs = @{$app->packs->active_pack_names};
  $line->('packs:    ', join(', ', @active_packs)) if @active_packs;

  for my $ign ($app->ignored_agent_files) {
    $out->emit($out->c(meta => '          '),
      $out->c(warn => 'seeing '.$ign->{path}.', ignoring (use --'.$ign->{profile}.' to load)'), "\n");
  }
  if ($resolver->has_provider) {
    my $p = $resolver->provider;
    $line->('provider: ', ( defined $p->{alias} ? $p->{alias}.' (stored alias, ' : '(' ).( $p->{provider_id} // '' )
      .', endpoint '.( $p->{endpoint} // '' ).', '.( $p->{url} // '' ).')');
  }
  $line->('engine:   ', $app->engine_name);
  $line->('model:    ', $model);
  $line->('api key:  ', $env_display);
  $line->('root:     ', $app->root);
  $line->('session:  ', $self->has_session ? $self->session->id.' ('.$self->session->path.')'
                      : $self->has_session_store ? 'new, saved from the first prompt on'
                      : 'off');
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

  if ( $self->can_ask ) {
    weaken( my $repl = $self );
    $self->app->on_ask_user( sub { $repl ? $repl->ask_user(@_) : undef } );
    $self->app->on_permission_request( sub { $repl ? $repl->permission_request(@_) : undef } );
    $self->app->on_plan_review( sub { $repl ? $repl->plan_review(@_) : undef } );
  }

  my $rl = -t $in ? $self->_terminal_reader : {
    read => sub { my $l = <$in>; $l },
    impl => 'none (input is not a terminal)',
  };
  my $call = sub { my $cb = $rl->{ $_[0] }; $cb->(@_[ 1 .. $#_ ]) if $cb };

  # Two-strike Ctrl-C: first press cancels the turn in progress (or only
  # warns at the prompt), second within 2s exits. Saves the user from
  # accidentally killing raider and removes the old "Ctrl-C + Return"
  # Docker quirk. Cancelling and leaving end the tool commands still
  # running: a bash command sits in a process group of its own and would
  # outlive raider.
  my $leave = sub {
    my ( $signal ) = @_;
    local $SIG{INT}  = 'IGNORE';
    local $SIG{TERM} = 'IGNORE';
    $self->runner->terminate_children;
    $self->runner->abandon($signal);
    $call->('save');
    $out->emit($out->c(meta => "\nbye."), "\n");
    exit 0;
  };
  my $last_sigint = 0;
  local $SIG{INT} = sub {
    my $now = time;
    $leave->('INT') if $last_sigint && $now - $last_sigint <= 2;
    $last_sigint = $now;
    # Only a flag and signals: a die here would be swallowed by an eval.
    if ($self->runner->cancel_run) {
      $out->emit($out->c(meta => "\n(cancelling the turn; press Ctrl-C again within 2s to quit)"), "\n");
      return;
    }
    $out->emit($out->c(meta => "\n(press Ctrl-C again within 2s to quit)"), "\n");
    $call->('redisplay');
  };
  local $SIG{TERM} = $leave;

  $self->banner($rl->{impl});
  $out->say_meta($_) for @{ $self->notes };
  $self->commands->cmd_prompt if $self->customize_prompt;
  if (@first) { my $first = join ' ', @first; $first =~ m{^/} ? $self->run_slash($first) : $self->run_prompt($first) }

  while (defined(my $line = $rl->{read}->())) {
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;

    if ($line =~ m{^(?:/quit|/exit|:q|quit|exit)$}i) {
      $out->emit($out->c(meta => 'bye.'), "\n");
      last;
    }
    $call->(add => $line);
    if ($line =~ m{^/}) {
      $self->run_slash($line);
      next;
    }
    if ($line =~ m{\A([!?])\s*(\S.*)\z}s) {
      $1 eq '!' ? $self->run_shell($2) : $self->run_shell_prompt($2);
      next;
    }
    $self->run_prompt($line);
  }

  $call->('save');
  $self->app->shutdown_hooks;
  return;
}

=method ask_user

    my $answer = $repl->ask_user($question, \@options);

Puts the model's question to the person: the question, the options
numbered, then a line read from L</in>. A number that names an option
answers with that option's text, any other line is the answer as typed.
Returns undef when the input is closed or the line is empty. The REPL
registers this as the application's
L<on_ask_user|Langertha::Raider::Application/on_ask_user> when it can ask.

=cut

sub ask_user {
  my ( $self, $question, $options ) = @_;
  $options //= [];
  my $out = $self->output;
  my $in  = $self->in;
  $out->emit( $out->c( title => '? '.$question ), "\n" );
  $out->emit( $out->c( meta => '  '.( $_ + 1 ).') '.$options->[$_] ), "\n" ) for 0 .. $#$options;
  $out->emit( $out->c( meta => ( @$options ? 'answer (a number picks an option)' : 'answer' ).'> ' ) );
  my $line = <$in>;
  return unless defined $line;
  $line =~ s/^\s+|\s+\z//g;
  return unless length $line;
  return $options->[ $line - 1 ] if $line =~ /\A\d+\z/ && $line >= 1 && $line <= @$options;
  return $line;
}

=method permission_request

    my $answer = $repl->permission_request({ tool => 'bash', arguments => { command => 'make' },
      reason => '...', rule => 'Bash(make)' });

Puts a tool call the permission policy asks about to the person (ADR
0021): the tool and what it would do (the command, the path, the URL), why
it asks, then the choices -- C<1> yes, once; C<2> yes, for this session,
naming the rule that is added (only when there is one); C<3> no. C<y> and
C<n> work too. A "no" asks for an optional reason, which the model gets.
Returns C<< { answer => 'once' | 'session' | 'no', reason => ... } >>; a
closed input is a "no". The REPL registers this as the application's
L<on_permission_request|Langertha::Raider::Application/on_permission_request>
when it can ask -- for every raider of the application, the prompt builder's
too.

=cut

sub permission_request {
  my ( $self, $req ) = @_;
  my $out  = $self->output;
  my $in   = $self->in;
  my $rule = $req->{rule};
  $out->emit( $out->c( title => '? allow '.$req->{tool}.': ' ), $self->call_summary($req), "\n" );
  $out->emit( $out->c( meta => '  ('.$req->{reason}.')' ), "\n" ) if defined $req->{reason};
  $out->emit( $out->c( meta => '  1) yes, once' ), "\n" );
  $out->emit( $out->c( meta => '  2) yes, for this session: '.$rule ), "\n" ) if defined $rule;
  $out->emit( $out->c( meta => '  3) no, and tell the model why' ), "\n" );
  while (1) {
    $out->emit( $out->c( meta => 'choice> ' ) );
    my $line = <$in>;
    return { answer => 'no' } unless defined $line;
    $line =~ s/^\s+|\s+\z//g;
    return { answer => 'once' } if $line =~ /\A(?:1|y|yes)\z/i;
    return { answer => 'session' } if defined $rule && $line eq '2';
    if ( $line =~ /\A(?:3|n|no)\z/i ) {
      $out->emit( $out->c( meta => 'reason (optional)> ' ) );
      my $why = <$in>;
      $why = '' unless defined $why;
      $why =~ s/^\s+|\s+\z//g;
      return { answer => 'no', ( length $why ? ( reason => $why ) : () ) };
    }
  }
}

=method call_summary

    my $text = $repl->call_summary({ tool => 'bash', arguments => { command => 'ls' } });   # 'ls'

What a call would do, in one line for the question: the command of
C<bash>, the C<path> of a file tool, the C<url> of C<web_fetch>, the
C<query> of C<web_search>, else the arguments as JSON -- cut at 200
characters.

=cut

sub call_summary {
  my ( $self, $req ) = @_;
  my $args = ref $req->{arguments} eq 'HASH' ? $req->{arguments} : {};
  my $text = first { defined && !ref } map { $args->{$_} } qw( command path url query );
  $text //= JSON::MaybeXS->new( canonical => 1, allow_nonref => 1 )->encode($args);
  $text = substr( $text, 0, 200 ).'...' if length $text > 200;
  return $text;
}

=method plan_review

    my $answer = $repl->plan_review($plan);   # { approve => 1 } or { approve => 0, feedback => ... }

Shows the plan the model presents with C<exit_plan_mode> and asks whether
to accept it: C<y> accepts (the permission mode becomes C<default>),
anything else asks for feedback, which the model gets. A closed input
does not accept. Registered as
L<on_plan_review|Langertha::Raider::Application/on_plan_review> when the
REPL can ask.

=cut

sub plan_review {
  my ( $self, $plan ) = @_;
  my $out = $self->output;
  my $in  = $self->in;
  $out->emit( $out->c( title => '? the plan:' ), "\n", $plan // '', "\n" );
  $out->emit( $out->c( meta => 'accept the plan? [y/n]> ' ) );
  my $line = <$in>;
  return { approve => 0 } unless defined $line;
  $line =~ s/^\s+|\s+\z//g;
  return { approve => 1 } if $line =~ /\A(?:y|yes|1)\z/i;
  $out->emit( $out->c( meta => 'what should change? (optional)> ' ) );
  my $feedback = <$in>;
  $feedback = '' unless defined $feedback;
  $feedback =~ s/^\s+|\s+\z//g;
  return { approve => 0, ( length $feedback ? ( feedback => $feedback ) : () ) };
}

=method run_prompt

    $repl->run_prompt($text);

Runs one prompt through the runner, recorded in L</session>. The first
prompt with a L</session_store> starts the session and names it.

=cut

sub run_prompt {
  my ( $self, $text ) = @_;
  return $self->runner->run_prompt($text, session => scalar $self->_session_for_run);
}

=method run_slash

    $repl->run_slash('/review src/App.pm');

A C</...> line (also the first prompt from the command line): resolved by
L<Langertha::Raider::CLI::Commands/dispatch>. A run request it returns (a
catalogue entry, C</init>, a path such as C</etc/hosts is broken>) runs as
the next prompt with its run options, recorded in L</session>. A C</clear>,
C</reset> or C</new> is recorded there as C<history.cleared>.

=cut

sub run_slash {
  my ( $self, $line ) = @_;
  my $r = $self->commands->dispatch($line, session => sub { scalar $self->_session_for_run });
  return $self->runner->run_prompt($r->{prompt}, %$r, session => scalar $self->_session_for_run) if ref $r eq 'HASH';
  # A resume must not bring back what /clear removed (ADR 0015).
  $self->runner->record($self->session, 'history.cleared')
    if $r && $self->has_session && $line =~ m{\A/(?:clear|reset|new)(?:\s|\z)};
  return $r;
}

=method run_shell

    my $status = $repl->run_shell('git status');

The REPL's C<!CMD>: runs the command with C<$SHELL -c> (C</bin/sh>
without C<SHELL>) in the app's root, on the terminal raider runs on, so
C<less> or C<vim> work. A non-zero exit status is printed, as C<exit
status N>, a command ended by a signal as C<interrupted (SIGINT)> or
C<killed by SIGTERM>. Nothing goes to the model or into the session
journal. Returns the wait status, or undef when the command could not be
started.

=cut

sub run_shell {
  my ( $self, $command ) = @_;
  # Ctrl-C reaches the command and raider alike; it is for the command.
  local $SIG{INT}  = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  my $pid = $self->_spawn_shell($command) // return;
  waitpid $pid, 0;
  my $status = $?;
  $self->output->say_meta($self->_shell_status_text($status)) if $status;
  return $status;
}

=method run_shell_prompt

    my $ok = $repl->run_shell_prompt('make test');

The REPL's C<?CMD>: runs the command as L</run_shell> does, but with its
standard output and standard error shown as they come and captured, and
standard input from F</dev/null>. Then the command, its exit status and
the captured output (L</shell_prompt>) go to the model through
L</run_prompt>, as any prompt: the model answers, the session journal
records the turn. A command ended by Ctrl-C (C<SIGINT>) sends nothing,
since Ctrl-C in the REPL cancels the turn. Returns what L</run_prompt>
returns, false when nothing was sent.

=cut

sub run_shell_prompt {
  my ( $self, $command ) = @_;
  my $out = $self->output;
  my ( $text, $status ) = ( '' );
  {
    local $SIG{INT}  = 'IGNORE';
    local $SIG{QUIT} = 'IGNORE';
    my ( $r, $w );
    unless (pipe $r, $w) {
      $out->say_error('cannot run the command: '.$!);
      return 0;
    }
    my $pid = $self->_spawn_shell($command, $w);
    close $w;
    unless (defined $pid) {
      close $r;
      return 0;
    }
    my $bytes = '';
    while (1) {
      my $n = sysread $r, $bytes, 65536, length $bytes;
      next if !defined $n && $!{EINTR};
      last unless $n;
      my $chunk = $self->_decode_output(\$bytes);
      $out->emit($chunk);
      $out->out->flush;
      $text .= $chunk;
    }
    close $r;
    if (length $bytes) {
      # What is left can be no character: replaced.
      my $rest = decode('UTF-8', $bytes);
      $out->emit($rest);
      $text .= $rest;
    }
    $out->emit("\n") if length $text && $text !~ /\n\z/;
    waitpid $pid, 0;
    $status = $?;
  }
  if ($self->_signal_name($status & 127) eq 'INT') {
    $out->say_meta('command interrupted (SIGINT), nothing sent to the model');
    return 0;
  }
  $out->say_meta($self->_shell_status_text($status)) if $status;
  return $self->run_prompt($self->shell_prompt($command, $status, $text));
}

=method shell_prompt

    my $prompt = $repl->shell_prompt($command, $wait_status, $output);

The prompt L</run_shell_prompt> sends: where the command ran, the command,
its exit status and its output. An output longer than
L</shell_output_limit> characters keeps its head and its tail, half the
limit each, with a line C<[... N characters omitted ...]> between them.

=method shell_output_limit

How many characters of a C<?CMD> output reach the model: 20000.

=cut

sub shell_output_limit { 20_000 }

sub shell_prompt {
  my ( $self, $command, $status, $output ) = @_;
  my $limit = $self->shell_output_limit;
  if (length $output > $limit) {
    my $half = int($limit / 2);
    $output = substr($output, 0, $half)
      ."\n[... ".(length($output) - 2 * $half)." characters omitted ...]\n"
      .substr($output, -$half);
  }
  $output =~ s/\n\z//;
  return join "\n",
    'I ran a shell command in '.$self->app->root.':',
    '',
    '$ '.$command,
    '',
    'Result: '.$self->_shell_status_text($status),
    '',
    length $output ? ( 'Output (stdout and stderr):', $output ) : '(no output)';
}

# Forks the shell running $command in the app's root. With $capture, its
# stdout and stderr go there and stdin comes from /dev/null; without, it
# has raider's terminal. The pid, or undef after an error line.
sub _spawn_shell {
  my ( $self, $command, $capture ) = @_;
  my $shell = $ENV{SHELL} || '/bin/sh';
  my $root  = $self->app->root;
  my $pid = fork;
  unless (defined $pid) {
    $self->output->say_error('cannot run the command: '.$!);
    return;
  }
  return $pid if $pid;

  # The child: never back into raider's code, whatever fails.
  $SIG{INT} = $SIG{QUIT} = 'DEFAULT';
  if ($capture) {
    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>&', $capture;
    open STDERR, '>&', $capture;
  }
  unless (chdir $root) {
    print STDERR 'raider: cannot change to '.$root.': '.$!."\n";
    POSIX::_exit(126);
  }
  { exec { $shell } $shell, '-c', encode('UTF-8', $command) }
  print STDERR 'raider: cannot run '.$shell.': '.$!."\n";
  POSIX::_exit(127);
}

# The complete UTF-8 characters at the start of $$bytes, which keeps a
# character cut off at its end for the next read. A byte that starts no
# character becomes U+FFFD.
sub _decode_output {
  my ( $self, $bytes ) = @_;
  my $text = '';
  while (length $$bytes) {
    $text .= decode('UTF-8', $$bytes, FB_QUIET);
    last if length $$bytes < 4;
    substr($$bytes, 0, 1, '');
    $text .= "\x{FFFD}";
  }
  return $text;
}

# A wait status for the user: "exit status N", "interrupted (SIGINT)",
# "killed by SIGTERM".
sub _shell_status_text {
  my ( $self, $status ) = @_;
  my $signal = $status & 127;
  return 'exit status '.($status >> 8) unless $signal;
  my $name = $self->_signal_name($signal);
  return $name eq 'INT' ? 'interrupted (SIGINT)' : 'killed by SIG'.$name;
}

# The name of the signal number (INT), empty for 0.
sub _signal_name {
  my ( $self, $number ) = @_;
  return $number ? ( split ' ', $Config{sig_name} )[$number] // $number : '';
}

sub _session_for_run {
  my ( $self ) = @_;
  return $self->session if $self->has_session;
  return unless $self->has_session_store;
  my $out = $self->output;
  my $session = eval { $self->session_store->create };
  unless ($session) {
    my $error = $out->error_text($@);
    $out->say_error('session not saved: '.$error);
    return;
  }
  $self->_set_session($session);
  $out->say_meta('session '.$session->id.' ('.$session->path.')');
  return $session;
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
