package Langertha::Raider::CLI::Runner;
# ABSTRACT: Internal runner of one raider CLI prompt, for a human or a machine
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Config;
use IO::Handle;
use POSIX qw( sigprocmask SIG_UNBLOCK WNOHANG );
use Path::Tiny;
use Time::HiRes ();

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $runner = Langertha::Raider::CLI::Runner->new(app => $app, output => $out);
    my $ok = $runner->run_prompt('Summarize README.md');
    $ok = $runner->run_prompt('Summarize README.md', machine => $machine);

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Runs one prompt through
L<Langertha::Raider::Application/run_prompt>, which records the run in
the session journal, and renders the outcome: the agent's answer plus a
status line (elapsed seconds, history size against the context budget,
token usage when tracing), or with a C<machine>
(L<Langertha::Raider::CLI::Machine>) the run's document -- and, when that
machine streams, the C<run.started>, C<run.state>, C<message> and tool
events the application hands it. It also owns the signals of a run.

=attr app

The L<Langertha::Raider::CLI> to run on. Required.

=attr output

The L<Langertha::Raider::CLI::Output> to print to. Required.

=attr err

Filehandle for warnings that must not end up in machine output (a
session journal that cannot be written). Defaults to C<STDERR>.

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

has err => (
  is      => 'ro',
  default => sub { \*STDERR },
);

# The run in progress: { machine, t0 }.
has _current => (
  is       => 'rw',
  init_arg => undef,
  clearer  => '_clear_current',
);

=method run_prompt

    my $ok = $runner->run_prompt($text, machine => $machine, session => $session, catch_signals => 1);

Returns true when the run finished, false when it failed (the error is
printed, or with C<machine> is the C<failed> document). An empty prompt runs
nothing and counts as finished.

With a C<session> (L<Langertha::Raider::Session>) the application records
the run in its journal (L<Langertha::Raider::Application/run_prompt>),
also when it failed or was interrupted; a machine document then names the
session in C<session> (C<id>, C<path>). A journal write that fails is a
warning (L</journal_error>); the run goes on.

With C<catch_signals>, a C<SIGINT> or C<SIGTERM> during the run ends it as
C<interrupted>: see L</interrupt>.

=cut

sub run_prompt {
  my ( $self, $text, %o ) = @_;
  return 1 unless defined $text && length $text;
  my $app = $self->app;
  my $out = $self->output;
  my $machine = $o{machine};
  my $t0 = Time::HiRes::time();
  $self->_current({ machine => $machine, t0 => $t0 });

  # Handled right in the signal handler: a die from it would be swallowed
  # by whichever eval the run happens to be in (LWP, the raid loop).
  local $SIG{INT}  = $o{catch_signals} ? sub { $self->interrupt(INT  => $machine, $self->elapsed_since($t0)) } : $SIG{INT};
  local $SIG{TERM} = $o{catch_signals} ? sub { $self->interrupt(TERM => $machine, $self->elapsed_since($t0)) } : $SIG{TERM};

  my $end = $app->run_prompt($text,
    ( $o{session} ? ( session => $o{session} ) : () ),
    on_event => sub { $self->event(@_) },
  );
  $self->_clear_current;

  if ($end->{status} ne 'completed') {
    $out->say_error($end->{error}) unless $machine;
    return $self->_document($machine, $end);
  }
  return $self->_document($machine, $end) if $machine;

  $out->say_agent($end->{response});

  my $r = $app->raider;
  my $tok = $app->token_stats;
  my $tok_part = $tok
    ? sprintf(' | tokens %d in / %d out / %d total', $tok->{prompt}, $tok->{completion}, $tok->{total})
    : '';
  my $msgs = scalar @{$r->history};
  my $last = $r->has_last_prompt_tokens ? $r->_last_prompt_tokens : 0;
  my $cap  = $r->max_context_tokens;
  my $pct  = $cap ? int(100 * $last / $cap) : 0;
  $out->say_meta(sprintf('%ds | history %d msgs, %d/%d tok (%d%%)%s',
    $end->{elapsed}, $msgs, $last, $cap, $pct, $tok_part));
  return 1;
}

=method interrupt

    $runner->interrupt(TERM => $machine, $elapsed);

Ends a run interrupted by the signal: ends the tool subprocesses still
running (L</terminate_children>), ends the application's run as
C<interrupted> (with the C<signal>), prints a note, or with a C<machine>
writes the C<interrupted> document, then dies of that same signal through
L</die_of_signal>.

With a C<machine> it also works as a class method, which
L<Langertha::Raider::CLI::Main> uses for a signal during startup, before
there is an app to run: the stream then has no C<run.started>, only the
C<interrupted> state change and C<run.finished>.

=cut

sub interrupt {
  my ( $self, $signal, $machine, $elapsed ) = @_;
  # A second signal must not cut the document short.
  local $SIG{INT}  = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  $self->terminate_children;
  if (ref $self && $self->_current) {
    $self->abandon($signal);
  }
  elsif ($machine) {
    $machine->event('run.state', state => 'interrupted');
    $self->_document($machine, { status => 'interrupted', signal => $signal, elapsed => $elapsed });
  }
  unless ($machine) {
    $self->output->say_meta('interrupted (SIG'.$signal.')');
    $self->output->out->flush;
  }
  return $self->die_of_signal($signal);
}

=method abandon

    $runner->abandon('TERM');

Ends the run in progress, if there is one, as C<interrupted> by the
signal -- its C<run.finished> in the session journal, and with a machine
its document -- without leaving the process. The REPL calls it when it is
left during a run.

=cut

sub abandon {
  my ( $self, $signal ) = @_;
  my $current = $self->_current or return;
  # Still current, so the run.state of end_run reaches the stream.
  my $end = $self->app->end_run(interrupted => signal => $signal);
  $self->_clear_current;
  my $machine = $current->{machine} or return;
  unless ($end) {
    # Interrupted before the application started the run.
    $end = { status => 'interrupted', signal => $signal, elapsed => $self->elapsed_since($current->{t0}) };
    $machine->event('run.state', state => 'interrupted');
  }
  $self->_document($machine, $end);
  return;
}

=method event

    $runner->event('tool.call', call => 'c1', name => 'bash', arguments => { ... });

One event of the run in progress, as the application hands it on: into
the machine stream (L<Langertha::Raider::CLI::Machine/event>), except the
user's own input -- a stream C<message> is the agent's (ADR 0013).
Outside a run it does nothing.

=cut

sub event {
  my ( $self, $type, %payload ) = @_;
  my $current = $self->_current or return;
  my $machine = $current->{machine} or return;
  return if $type eq 'message' && ($payload{role} // '') eq 'user';
  $machine->event($type, %payload);
  return;
}

=method record

    $runner->record($session, 'history.cleared');

Appends one event outside a run to the session journal
(L<Langertha::Raider::Application/record>). A write that fails is a
warning (L</journal_error>) and returns false.

=cut

sub record {
  my ( $self, $session, $type, %fields ) = @_;
  return $self->app->record($session, $type, %fields);
}

=method journal_error

    $runner->journal_error($session, $error);

Reports a session journal that cannot be written on L</err>, C<warning:
session ID not fully saved: ...>: the application's
L<Langertha::Raider::Application/on_journal_error>, which reports only the
first failure of a run.

=cut

sub journal_error {
  my ( $self, $session, $error ) = @_;
  print { $self->err } 'warning: session '.$session->id.' not fully saved: '.$self->output->error_text($error)."\n";
  return;
}

=method die_of_signal

    $runner->die_of_signal('TERM');

Ends the process by the signal, restored to its default action: the parent
sees a process killed by that signal (a shell reports 130 for C<INT>, 143
for C<TERM>; the Hall records the raider as C<signaled>). Should the
process survive it, it exits with 128 plus the signal number.

=cut

sub die_of_signal {
  my ( $self, $signal ) = @_;
  my %number;
  @number{ split ' ', $Config{sig_name} } = split ' ', $Config{sig_num};
  $SIG{$signal} = 'DEFAULT';
  # Perl blocks the signal while its handler runs; unblocked, the signal
  # takes effect right here instead of after exit has restored the handler.
  sigprocmask(SIG_UNBLOCK, POSIX::SigSet->new($number{$signal}));
  kill $signal => $$;
  exit 128 + $number{$signal};
}

=method terminate_children

    $runner->terminate_children;

Ends the processes this raider started that still run -- a C<bash>
command (L<MCP::Run::Bash> puts it into a process group of its own, so a
signal aimed at raider alone never reaches it), a C<perl_eval> or
C<perl_cpanm> child: C<SIGTERM> to each child's process group, or to the
child when it leads none, and C<SIGKILL> to what is left after
L</terminate_grace> seconds.

=cut

sub terminate_grace { 2 }

sub terminate_children {
  my ( $self ) = @_;
  my @pids = $self->child_pids or return;
  $self->_signal_group_or_pid(TERM => $_) for @pids;
  my %left = map { $_ => 1 } @pids;
  my $deadline = Time::HiRes::time() + $self->terminate_grace;
  while (%left && Time::HiRes::time() < $deadline) {
    delete @left{ grep { waitpid($_, WNOHANG) != 0 } keys %left };
    Time::HiRes::sleep(0.05) if %left;
  }
  for my $pid (keys %left) {
    $self->_signal_group_or_pid(KILL => $pid);
    waitpid $pid, 0;
  }
  return;
}

=method child_pids

The process IDs of this process's children, from F</proc>, or from C<ps>
where there is none.

=cut

sub child_pids {
  my ( $self ) = @_;
  my @children;
  if (-d '/proc/'.$$) {
    for my $dir (path('/proc')->children(qr/\A\d+\z/)) {
      # "pid (comm) state ppid ...": comm may hold spaces and parens.
      my $stat = eval { $dir->child('stat')->slurp } // next;
      my ( $ppid ) = substr($stat, rindex($stat, ')') + 2) =~ /\A\S+ (\d+)/ or next;
      push @children, 0 + $dir->basename if $ppid == $$;
    }
    return @children;
  }
  my $ps_pid = open(my $ps, '-|', 'ps', '-A', '-o', 'pid=', '-o', 'ppid=') or return;
  while (my $line = <$ps>) {
    my ( $pid, $ppid ) = $line =~ /(\d+)\s+(\d+)/ or next;
    push @children, 0 + $pid if $ppid == $$ && $pid != $ps_pid;
  }
  close $ps;
  return @children;
}

# The child's process group when it leads one, else the child alone.
sub _signal_group_or_pid {
  my ( $self, $signal, $pid ) = @_;
  return kill($signal => -$pid) || kill($signal => $pid);
}

=method elapsed_since

    my $elapsed = $runner->elapsed_since($t0);

Seconds since the L<Time::HiRes> time C<$t0>, to the millisecond: the
C<elapsed> of a document.

=cut

sub elapsed_since {
  my ( $self, $t0 ) = @_;
  return 0 + sprintf('%.3f', Time::HiRes::time() - $t0);
}

# The document of a run that ended ($end as from end_run, plus response
# and metrics of a completed one) when there is a machine; true for a
# completed run.
sub _document {
  my ( $self, $machine, $end ) = @_;
  if ($machine) {
    $machine->finish($machine->document($end->{status},
      map { exists $end->{$_} ? ( $_ => $end->{$_} ) : () } qw( response metrics error signal elapsed session )));
  }
  return $end->{status} eq 'completed' ? 1 : 0;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI::Main>

=item * L<Langertha::Raider::Application>

=back

=cut
