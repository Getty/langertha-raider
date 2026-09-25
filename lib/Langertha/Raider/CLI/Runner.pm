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

Runs one prompt through L<Langertha::Raider::CLI/run> and renders the
outcome: the agent's answer plus a status line (elapsed seconds, history
size against the context budget, token usage when tracing), or with a
C<machine> (L<Langertha::Raider::CLI::Machine>) the run's document -- and,
when that machine streams, the C<run.started>, C<run.state> and C<message>
events around it. The same events, with the tool calls, go into a session
journal when one is given.

=attr app

The L<Langertha::Raider::CLI> to run on. Required.

=attr output

The L<Langertha::Raider::CLI::Output> to print to. Required.

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

# The run in progress: { machine, session, run, t0 }.
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

With a C<session> (L<Langertha::Raider::Session>) the run is recorded in
its journal as the session's next run (ADR 0015): C<run.started>, the user
input as C<message>, every C<tool.call> and C<tool.result> with the whole
result text, the final answer as C<message>, and C<run.finished> with the
end state -- also when the run failed or was interrupted. A machine
document then names the session in C<session> (C<id>, C<path>).

With C<catch_signals>, a C<SIGINT> or C<SIGTERM> during the run ends it as
C<interrupted>: see L</interrupt>.

=cut

sub run_prompt {
  my ( $self, $text, %o ) = @_;
  return 1 unless defined $text && length $text;
  my $app = $self->app;
  my $out = $self->output;
  my $machine = $o{machine};
  my $session = $o{session};
  my $t0 = Time::HiRes::time();
  $self->_current({
    machine => $machine,
    session => $session,
    run     => $session ? $session->next_run : undef,
    t0      => $t0,
  });

  # Handled right in the signal handler: a die from it would be swallowed
  # by whichever eval the run happens to be in (LWP, the raid loop).
  local $SIG{INT}  = $o{catch_signals} ? sub { $self->interrupt(INT  => $machine, $self->elapsed_since($t0)) } : $SIG{INT};
  local $SIG{TERM} = $o{catch_signals} ? sub { $self->interrupt(TERM => $machine, $self->elapsed_since($t0)) } : $SIG{TERM};

  $self->event('run.started', engine => $app->engine_name, $app->has_model ? ( model => $app->model ) : ());
  $self->event('run.state', state => 'running');
  $self->_journal('message', role => 'user', content => $text);

  my $result;
  my $ok = eval { $result = $app->run($text); 1 };
  my $elapsed = $self->elapsed_since($t0);

  unless ($ok) {
    my $err = $@; chomp $err;
    $out->say_error($err) unless $machine;
    return $self->_finish(failed => error => $err, elapsed => $elapsed);
  }

  my $r = $app->raider;
  $self->event('message', role => 'assistant', content => "$result");
  my $completed = $self->_finish(completed => response => "$result", metrics => $r->metrics, elapsed => $elapsed);
  return $completed if $machine;

  $out->say_agent("$result");

  my $tok = $app->token_stats;
  my $tok_part = $tok
    ? sprintf(' | tokens %d in / %d out / %d total', $tok->{prompt}, $tok->{completion}, $tok->{total})
    : '';
  my $msgs = scalar @{$r->history};
  my $last = $r->has_last_prompt_tokens ? $r->_last_prompt_tokens : 0;
  my $cap  = $r->max_context_tokens;
  my $pct  = $cap ? int(100 * $last / $cap) : 0;
  $out->say_meta(sprintf('%ds | history %d msgs, %d/%d tok (%d%%)%s',
    $elapsed, $msgs, $last, $cap, $pct, $tok_part));
  return 1;
}

=method interrupt

    $runner->interrupt(TERM => $machine, $elapsed);

Ends a run interrupted by the signal: ends the tool subprocesses still
running (L</terminate_children>), prints a note, or with a C<machine>
writes the C<interrupted> state change and document (with the C<signal>),
then dies of that same signal through L</die_of_signal>.

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
    $self->_finish(interrupted => signal => $signal, elapsed => $elapsed);
  }
  elsif ($machine) {
    $self->_finish_machine($machine, interrupted => signal => $signal, elapsed => $elapsed);
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
  $self->_finish(interrupted => signal => $signal, elapsed => $self->elapsed_since($current->{t0}));
  return;
}

=method event

    $runner->event('tool.call', call => 'c1', name => 'bash', arguments => { ... });

One event of the run in progress, handed to every consumer: the machine
stream (L<Langertha::Raider::CLI::Machine/event>) and, for the event types
it records, the session journal, with the run's C<run> id. The app's
C<on_event> (tool calls and results) comes in here. Outside a run it does
nothing.

=cut

# The ADR 0015 event types the journal records from the shared events;
# run.finished is written by _finish.
my %JOURNAL_TYPE = map { $_ => 1 } qw( run.started message tool.call tool.result );

sub event {
  my ( $self, $type, %payload ) = @_;
  my $current = $self->_current or return;
  $current->{machine}->event($type, %payload) if $current->{machine};
  $self->_journal($type, %payload) if $JOURNAL_TYPE{$type};
  return;
}

# One event into the session journal of the run in progress, if any.
sub _journal {
  my ( $self, $type, %payload ) = @_;
  my $current = $self->_current or return;
  my $session = $current->{session} or return;
  $session->append($type, run => $current->{run}, %payload);
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

# The last state change and the document; true for a completed run.
# Ends the run in progress: run.finished into the journal (with the run's
# metrics when the raider has them), then the machine's last state change
# and document, which names the session. True for a completed run.
sub _finish {
  my ( $self, $status, %fields ) = @_;
  my $current = $self->_current;
  $self->_clear_current;
  if (my $session = $current->{session}) {
    my $metrics = $fields{metrics} // eval { $self->app->raider->metrics };
    $session->append('run.finished', run => $current->{run}, status => $status,
      ( map { defined $fields{$_} ? ( $_ => $fields{$_} ) : () } qw( error signal elapsed ) ),
      $metrics ? ( metrics => $metrics ) : ());
    $fields{session} = { id => $session->id, path => ''.$session->path };
  }
  return $self->_finish_machine($current->{machine}, $status, %fields) if $current->{machine};
  return $status eq 'completed' ? 1 : 0;
}

sub _finish_machine {
  my ( $self, $machine, $status, %fields ) = @_;
  $machine->event('run.state', state => $status);
  $machine->finish($machine->document($status, %fields));
  return $status eq 'completed' ? 1 : 0;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI::Main>

=back

=cut
