package Langertha::Raider::BashTools;
# ABSTRACT: Internal shell tools of raider: bash, bash_output and kill_shell
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Carp qw( croak );
use Encode ();
use List::Util qw( min );
use MCP::Server;
use Path::Tiny;
use POSIX qw( WNOHANG );
use Scalar::Util qw( looks_like_number weaken );
use Time::HiRes ();

=synopsis

    my $shell = Langertha::Raider::BashTools->new(
      loop              => $app->loop,
      working_directory => $root,
      validator         => $loadguard->validator,
    );
    my $server = $shell->server;    # MCP::Server with bash, bash_output, kill_shell

=description

B<Internal module.> Its interface may change without notice.

The shell tools of raider, shaped after Claude Code's C<Bash>,
C<BashOutput> and C<KillShell> (L<Langertha::Raider::ToolNames>, ADR 0024).

C<bash> runs a command with C<bash -c> in L</working_directory> (or the
C<working_directory> argument), in a process group of its own, with standard
input from F</dev/null> and standard output and standard error into one file,
so the result is the combined output in the order it was written, as in
Claude Code. A command that exits with 0 answers with its output, or
C<(Bash completed with no output)>; any other exit status is an error result
that starts with C<Exit code N>. Output over L</output_limit> characters
keeps its start and its end around C<... [N characters truncated] ...>.

A command still running after its C<timeout> (seconds, default
L</default_timeout>, at most L</max_timeout>) is not killed: it is moved to
the background, as Claude Code does, and the result says so with its ID.
C<run_in_background> starts it there at once. A background shell is a child
of raider supervised by the application's event loop
(L<IO::Async::Loop/watch_process>, ADR 0016); C<bash_output> reads what it
wrote since the last call, with its status, and C<kill_shell> stops it. The
background shells belong to this object, so to the application: they live
across the runs of a session and are stopped when it goes away
(L</stop_all>, C<DEMOLISH>).

C<allowed_commands> and C<validator> (the loadguard gate, ADR 0018) are asked
before any command starts, in the foreground or the background, with the
texts L<MCP::Run> used.

=cut

has loop => (
  is       => 'ro',
  isa      => 'IO::Async::Loop',
  required => 1,
);

=attr loop

Required. The event loop that supervises the background shells -- the
application's, the one the raid drives (ADR 0016).

=cut

has working_directory => (
  is  => 'ro',
  isa => 'Str',
);

=attr working_directory

The directory commands run in unless a call names another. Without it,
raider's own working directory.

=cut

has allowed_commands => (
  is        => 'ro',
  isa       => 'ArrayRef[Str]',
  predicate => 'has_allowed_commands',
);

=attr allowed_commands

Optional. The first words a command may start with; any other command is
refused with C<Command not allowed: WORD>.

=cut

has validator => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_validator',
);

=attr validator

Optional. Called as C<< $validator->($command, $working_directory) >> before a
command starts; C<1> lets it run, anything else refuses it with
C<Command REASON> (L<Langertha::Raider::Loadguard/validator>).

=cut

has default_timeout => ( is => 'ro', isa => 'Int', default => 120 );

=attr default_timeout

Seconds a command runs in the foreground when the call gives no C<timeout>:
120, as in Claude Code.

=cut

has max_timeout => ( is => 'ro', isa => 'Int', default => 600 );

=attr max_timeout

The largest C<timeout> of C<bash> and C<bash_output>, in seconds: 600, as in
Claude Code. A larger one is cut down to it.

=cut

has output_limit => ( is => 'ro', isa => 'Int', default => 30000 );

=attr output_limit

Characters of output a result carries: 30000, as in Claude Code. Longer
output keeps its first and its last half of it.

=cut

has kill_grace => ( is => 'ro', isa => 'Num', default => 2 );

=attr kill_grace

Seconds between C<SIGTERM> and C<SIGKILL> when a shell is stopped.

=cut

has block_timeout => ( is => 'ro', isa => 'Int', default => 30 );

=attr block_timeout

Seconds C<bash_output> with C<block> waits when the call gives no C<timeout>.

=cut

has server => (
  is       => 'ro',
  lazy     => 1,
  builder  => '_build_server',
  init_arg => undef,
);

=attr server

The L<MCP::Server> with the tools C<bash>, C<bash_output> and C<kill_shell>,
built once.

=cut

has _shells => ( is => 'ro', isa => 'HashRef', default => sub { {} }, init_arg => undef );
has _count  => ( is => 'rw', isa => 'Int', default => 0, init_arg => undef );
has _dir    => ( is => 'ro', lazy => 1, builder => '_build__dir', init_arg => undef );

sub _build__dir { Path::Tiny->tempdir( TEMPLATE => 'raider-bash-XXXXXXXX' ) }

#### Texts

sub _no_output { '(Bash completed with no output)' }

sub _hint {
  my ( $self, $id ) = @_;
  return 'Read its output and see whether it has finished with bash_output (bash_id: '.$id
    .'); stop it with kill_shell (shell_id: '.$id.').';
}

sub _no_shell { 'No task found with ID: '.$_[1] }

#### The server

sub _build_server {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  my $call = sub {
    my ( $method ) = @_;
    return sub {
      my ( $tool, $in ) = @_;
      return $tool->text_result( 'the shell tools are gone', 1 ) unless $weak;
      return $tool->text_result( $weak->$method( $in // {} ) );
    };
  };
  my $server = MCP::Server->new( name => 'raider-bash', version => '1.0' );
  $server->tool(
    name         => 'bash',
    description  => 'Run a shell command with bash -c in the project root. Returns the combined output (stdout and stderr); '
      .'a failing command is an error result that starts with "Exit code N". timeout is in seconds (default '
      .$self->default_timeout.', at most '.$self->max_timeout.'); a command still running then is moved to the background. '
      .'run_in_background: true starts it in the background at once. A background command is read with bash_output and '
      .'stopped with kill_shell. Use this for ls, grep, find, git, cat, running tests, any shell pipeline '
      .'-- anything you would type at a terminal.',
    input_schema => {
      type       => 'object',
      properties => {
        command           => { type => 'string',  description => 'The command to run' },
        description       => { type => 'string',  description => 'What the command does, in a few words' },
        timeout           => { type => 'integer', description => 'Seconds before the command is moved to the background (default '
          .$self->default_timeout.', at most '.$self->max_timeout.')' },
        run_in_background => { type => 'boolean', description => 'Start the command in the background and return its ID at once' },
        working_directory => { type => 'string',  description => 'Directory to run in (default: the project root)' },
      },
      required => ['command'],
    },
    code => $call->('bash'),
  );
  $server->tool(
    name         => 'bash_output',
    description  => 'Read the output a background shell has written since the last call, with its status (running, '
      .'completed, killed) and, once it has finished, its exit code. filter: a regex; only matching lines are '
      .'returned, the others are discarded. block: true waits until the command has finished, at most timeout '
      .'seconds (default '.$self->block_timeout.', at most '.$self->max_timeout.').',
    input_schema => {
      type       => 'object',
      properties => {
        bash_id => { type => 'string',  description => 'The ID of the background shell' },
        filter  => { type => 'string',  description => 'Regex: only lines matching it are returned' },
        block   => { type => 'boolean', description => 'Wait until the command has finished' },
        timeout => { type => 'integer', description => 'With block: the most seconds to wait' },
      },
      required => ['bash_id'],
    },
    code => $call->('bash_output'),
  );
  $server->tool(
    name         => 'kill_shell',
    description  => 'Stop a background shell by its ID: SIGTERM to its process group, SIGKILL after '
      .$self->kill_grace.' seconds.',
    input_schema => {
      type       => 'object',
      properties => {
        shell_id => { type => 'string', description => 'The ID of the background shell to stop' },
      },
      required => ['shell_id'],
    },
    code => $call->('kill_shell'),
  );
  return $server;
}

#### bash

=method bash

    my ( $text, $is_error ) = $shell->bash({ command => 'make test', timeout => 300 });

The C<bash> tool: runs the command and returns the result text and whether
it is an error result.

=cut

sub bash {
  my ( $self, $in ) = @_;
  my $command = $in->{command};
  return ( 'No command given: the command parameter must be a non-empty string', 1 )
    unless defined $command && $command =~ /\S/;
  my $wd = $in->{working_directory} // $self->working_directory;
  if ( my $refused = $self->_refusal( $command, $wd ) ) {
    return ( $refused, 1 );
  }
  my $shell = $self->_spawn( $command, $wd );
  return ( 'Cannot start bash: '.$shell, 1 ) unless ref $shell;

  if ( $in->{run_in_background} ) {
    $self->_adopt($shell);
    return ( 'Command running in background with ID: '.$shell->{id}.'. '.$self->_hint( $shell->{id} ), 0 );
  }

  my $timeout = $self->_seconds( $in->{timeout}, $self->default_timeout );
  unless ( $self->_wait( $shell, $timeout, 1 ) ) {
    $self->_adopt($shell);
    return ( 'Command did not complete within its '.$timeout.'s timeout and was moved to the background (ID: '
      .$shell->{id}.'). '.$self->_hint( $shell->{id} ), 0 );
  }
  my $output = $self->_clip( $self->_take_output( $shell, 1 ) =~ s/[\r\n]+\z//r );
  $self->_forget($shell);
  if ( $shell->{status} eq 'killed' ) {
    return ( 'Command was stopped before it finished'.( length $output ? "\n".$output : '' ), 1 );
  }
  return ( length $output ? $output : $self->_no_output, 0 ) if $shell->{exit_code} == 0;
  return ( 'Exit code '.$shell->{exit_code}.( length $output ? "\n".$output : '' ), 1 );
}

# The text of a refusal by allowed_commands or the validator, or nothing.
sub _refusal {
  my ( $self, $command, $wd ) = @_;
  if ( $self->has_allowed_commands ) {
    my ( $first ) = $command =~ /^\s*(\S+)/;
    return 'Command not allowed: '.$first unless grep { $_ eq $first } @{ $self->allowed_commands };
  }
  if ( $self->has_validator ) {
    my $verdict = $self->validator->( $command, $wd );
    return if defined $verdict && !ref $verdict && $verdict eq '1';
    return 'Command '.( defined $verdict && length $verdict ? $verdict : 'denied' );
  }
  return;
}

# A usable number of seconds: whole, at least 1, at most max_timeout; the
# default for anything else.
sub _seconds {
  my ( $self, $value, $default ) = @_;
  return $default unless defined $value && looks_like_number($value) && $value == $value && $value > 0;
  return min( $self->max_timeout, $value < 1 ? 1 : int $value );
}

#### Processes

# Starts the command; returns the shell (a hash) or the reason it could not.
sub _spawn {
  my ( $self, $command, $wd ) = @_;
  my $n    = $self->_count + 1;
  $self->_count($n);
  my $id   = 'bash_'.$n;
  my $file = $self->_dir->child( $id.'.output' );
  open my $out, '>', "$file" or return 'cannot write '.$file.': '.$!;
  my $pid = fork;
  return 'fork: '.$! unless defined $pid;
  unless ($pid) {
    # The child: into a process group of its own (stopping it reaches every
    # process it starts), the signals back to their defaults, one file for
    # both outputs.
    eval { setpgrp( 0, 0 ) };
    $SIG{$_} = 'DEFAULT' for grep { exists $SIG{$_} } qw( INT TERM HUP QUIT PIPE CHLD ALRM );
    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>&', $out;
    open STDERR, '>&', $out;
    # chdir, not "cd DIR && COMMAND": a command ending in & would take the cd
    # into the background with it and run the rest elsewhere.
    if ( defined $wd && length $wd && !chdir $wd ) {
      print STDERR 'raider: cannot change to '.$wd.': '.$!."\n";
      POSIX::_exit(1);
    }
    { no warnings 'exec'; exec 'bash', '-c', $command; }
    print STDERR 'raider: cannot run bash: '.$!."\n";
    POSIX::_exit(127);
  }
  close $out;
  my $shell = {
    id        => $id,
    command   => $command,
    pid       => $pid,
    file      => $file,
    offset    => 0,
    status    => 'running',
    started   => Time::HiRes::time(),
  };
  $self->_shells->{$id} = $shell;
  return $shell;
}

# Hands a running shell to the loop, which reaps it when it ends while the
# loop runs; bash_output and kill_shell look themselves.
sub _adopt {
  my ( $self, $shell ) = @_;
  $shell->{background} = 1;
  return unless $shell->{status} eq 'running';
  weaken( my $weak = $self );
  $shell->{watched} = 1;
  $self->loop->watch_process( $shell->{pid}, sub {
    my ( undef, $status ) = @_;
    $shell->{watched} = 0;
    $weak->_ended( $shell, $status ) if $weak;
  } );
  return;
}

# True when the shell has ended (and is reaped).
sub _poll {
  my ( $self, $shell ) = @_;
  return 1 unless $shell->{status} eq 'running';
  my $got = waitpid( $shell->{pid}, WNOHANG );
  return 0 if $got == 0;
  if ( $got == $shell->{pid} ) {
    $self->_unwatch($shell);
    $self->_ended( $shell, $? );
    return 1;
  }
  # Reaped by someone else: by the loop, which may only have queued its
  # callback yet (watch_process reaps a child that is gone already), or by the
  # surface stopping the children of a cancelled run.
  $self->loop->loop_once(0) if $shell->{watched} && ${^GLOBAL_PHASE} ne 'DESTRUCT';
  $self->_unwatch($shell);
  $self->_ended( $shell, undef ) if $shell->{status} eq 'running';
  return 1;
}

sub _unwatch {
  my ( $self, $shell ) = @_;
  return unless delete $shell->{watched};
  eval { $self->loop->unwatch_process( $shell->{pid} ) };
  return;
}

# Records how a shell ended; a wait status of undef: unknown, stopped.
sub _ended {
  my ( $self, $shell, $status ) = @_;
  return unless $shell->{status} eq 'running';
  $shell->{ended} = Time::HiRes::time();
  if ( !defined $status || $shell->{stopping} ) {
    $shell->{status} = 'killed';
    return;
  }
  $shell->{status}    = 'completed';
  $shell->{exit_code} = ( $status & 127 ) ? 128 + ( $status & 127 ) : $status >> 8;
  return;
}

# Waits up to $seconds for the shell to end; true when it has. With
# $forward, a HUP, INT or TERM nobody else handles stops the command
# before raider goes, as MCP::Run::Bash did.
sub _wait {
  my ( $self, $shell, $seconds, $forward ) = @_;
  my @forward = $forward ? grep { _unclaimed($_) } qw( HUP INT TERM ) : ();
  local @SIG{@forward} = map {
    my $signal = $_;
    sub { $self->_stop($shell); $SIG{$signal} = 'DEFAULT'; kill $signal => $$ };
  } @forward;
  my $deadline = Time::HiRes::time() + $seconds;
  my $pause    = 0.001;
  while (1) {
    return 1 if $self->_poll($shell);
    my $left = $deadline - Time::HiRes::time();
    return 0 if $left <= 0;
    Time::HiRes::sleep( min( $pause, $left ) );
    $pause = min( $pause * 2, 0.05 );
  }
}

sub _unclaimed {
  my ( $signal ) = @_;
  my $handler = $SIG{$signal};
  return !ref $handler && ( !defined $handler || $handler eq '' || $handler eq 'DEFAULT' );
}

sub _signal {
  my ( $self, $shell, $signal ) = @_;
  return kill( $signal => -$shell->{pid} ) || kill( $signal => $shell->{pid} );
}

# Stops a running shell: SIGTERM to its group, SIGKILL after kill_grace.
sub _stop {
  my ( $self, @shells ) = @_;
  my @running = grep { $_->{status} eq 'running' } @shells or return;
  for my $shell (@running) {
    $shell->{stopping} = 1;
    $self->_signal( $shell, 'TERM' );
  }
  my $deadline = Time::HiRes::time() + $self->kill_grace;
  while ( my @left = grep { !$self->_poll($_) } @running ) {
    if ( Time::HiRes::time() >= $deadline ) {
      for my $shell (@left) {
        $self->_signal( $shell, 'KILL' );
        my $got = waitpid( $shell->{pid}, 0 );
        $self->_unwatch($shell);
        $self->_ended( $shell, $got == $shell->{pid} ? $? : undef );
      }
      last;
    }
    Time::HiRes::sleep(0.02);
  }
  return;
}

sub _forget {
  my ( $self, $shell ) = @_;
  delete $self->_shells->{ $shell->{id} };
  $shell->{file}->remove;
  return;
}

#### Output

# The output written since the last call, decoded. While the command runs,
# an incomplete UTF-8 sequence at the end waits for the next call.
sub _take_output {
  my ( $self, $shell, $all ) = @_;
  my $bytes = '';
  if ( open my $fh, '<:raw', $shell->{file}->stringify ) {
    seek $fh, $shell->{offset}, 0;
    local $/;
    $bytes = <$fh> // '';
  }
  my $keep = $all ? 0 : _incomplete_tail($bytes);
  substr( $bytes, -$keep ) = '' if $keep;
  $shell->{offset} += length $bytes;
  return Encode::decode( 'UTF-8', $bytes );
}

sub _incomplete_tail {
  my ( $bytes ) = @_;
  my $len = length $bytes;
  for my $back ( 1 .. min( 4, $len ) ) {
    my $byte = ord substr( $bytes, -$back, 1 );
    next if ( $byte & 0xC0 ) == 0x80;    # a continuation byte
    my $need = $byte >= 0xF0 ? 4 : $byte >= 0xE0 ? 3 : $byte >= 0xC0 ? 2 : 1;
    return $need > $back ? $back : 0;
  }
  return 0;
}

# Output over output_limit keeps its start and its end, as Claude Code does.
sub _clip {
  my ( $self, $text ) = @_;
  my $max = $self->output_limit;
  return $text if length $text <= $max;
  my $half = int( $max / 2 );
  my $cut  = length($text) - 2 * $half;
  return substr( $text, 0, $half )."\n\n... [".$cut." characters truncated] ...\n\n".substr( $text, -$half );
}

#### bash_output

=method bash_output

    my ( $text, $is_error ) = $shell->bash_output({ bash_id => 'bash_1', filter => 'FAIL', block => 1 });

The C<bash_output> tool: the new output of a background shell, with its
status and exit code:

    <status>completed</status>

    <exit_code>0</exit_code>

    <stdout>
    ...
    </stdout>

C<stdout> carries both outputs and is left out when there is no new output.
An unknown ID is an error result C<No task found with ID: ID>.

=cut

sub bash_output {
  my ( $self, $in ) = @_;
  my $id    = $in->{bash_id} // '';
  my $shell = $self->_shells->{$id} or return ( $self->_no_shell($id), 1 );
  my $filter;
  if ( defined $in->{filter} && length $in->{filter} ) {
    $filter = eval { qr/$in->{filter}/ } or do {
      ( my $why = $@ ) =~ s/ at \S+ line \d+.*//s;
      return ( 'Invalid filter regex: '.$why, 1 );
    };
  }
  $in->{block}
    ? $self->_wait( $shell, $self->_seconds( $in->{timeout}, $self->block_timeout ) )
    : $self->_poll($shell);
  my $output = $self->_take_output( $shell, $shell->{status} ne 'running' );
  if ($filter) {
    $output = join '', grep { /$filter/ } split /^/m, $output;
  }
  $output = $self->_clip( $output =~ s/[\r\n]+\z//r );
  my @parts = ( '<status>'.$shell->{status}.'</status>' );
  push @parts, '<exit_code>'.$shell->{exit_code}.'</exit_code>' if defined $shell->{exit_code};
  push @parts, "<stdout>\n".$output."\n</stdout>" if length $output;
  return ( join( "\n\n", @parts ), 0 );
}

#### kill_shell

=method kill_shell

    my ( $text, $is_error ) = $shell->kill_shell({ shell_id => 'bash_1' });

The C<kill_shell> tool: stops a running background shell (L</kill_grace>)
and answers C<Successfully stopped task: ID (COMMAND)>. An unknown ID, or a
shell that is not running, is an error result.

=cut

sub kill_shell {
  my ( $self, $in ) = @_;
  my $id    = $in->{shell_id} // '';
  my $shell = $self->_shells->{$id} or return ( $self->_no_shell($id), 1 );
  $self->_poll($shell);
  return ( 'Task '.$id.' is not running (status: '.$shell->{status}.')', 1 )
    unless $shell->{status} eq 'running';
  $self->_stop($shell);
  return ( 'Successfully stopped task: '.$id.' ('.$shell->{command}.')', 0 );
}

#### The shells

=method background_pids

The process IDs of the background shells still running. A surface that
stops the children of a cancelled run leaves these alone: they belong to the
session, not to the run.

=cut

sub background_pids {
  my ( $self ) = @_;
  return map { $_->{pid} } grep { $_->{background} && $_->{status} eq 'running' } values %{ $self->_shells };
}

=method stop_all

    $shell->stop_all;

Stops every shell still running (L</kill_grace>). C<DEMOLISH> does the same,
so no shell outlives the application.

=cut

sub stop_all {
  my ( $self ) = @_;
  $self->_stop( values %{ $self->_shells } );
  return;
}

sub DEMOLISH {
  my ( $self ) = @_;
  $self->stop_all;
  return;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::Loadguard>

=item * L<Langertha::Raider::ToolNames>

=back

=cut
