package Langertha::Raider::CLI::Runner;
# ABSTRACT: Internal runner of one raider CLI prompt, for a human or a machine
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Config;
use IO::Handle;
use POSIX qw( sigprocmask SIG_UNBLOCK );

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
events around it.

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

=method run_prompt

    my $ok = $runner->run_prompt($text, machine => $machine, catch_signals => 1);

Returns true when the run finished, false when it failed (the error is
printed, or with C<machine> is the C<failed> document). An empty prompt runs
nothing and counts as finished.

With C<catch_signals>, a C<SIGINT> or C<SIGTERM> during the run ends it as
C<interrupted>: see L</interrupt>.

=cut

sub run_prompt {
  my ( $self, $text, %o ) = @_;
  return 1 unless defined $text && length $text;
  my $app = $self->app;
  my $out = $self->output;
  my $machine = $o{machine};
  my $t0 = time;

  # Handled right in the signal handler: a die from it would be swallowed
  # by whichever eval the run happens to be in (LWP, the raid loop).
  local $SIG{INT}  = $o{catch_signals} ? sub { $self->interrupt(INT  => $machine, time - $t0) } : $SIG{INT};
  local $SIG{TERM} = $o{catch_signals} ? sub { $self->interrupt(TERM => $machine, time - $t0) } : $SIG{TERM};

  if ($machine) {
    $machine->event('run.started', engine => $app->engine_name,
      $app->has_model ? ( model => $app->model ) : ());
    $machine->event('run.state', state => 'running');
  }

  my $result;
  my $ok = eval { $result = $app->run($text); 1 };
  my $elapsed = time - $t0;

  unless ($ok) {
    my $err = $@; chomp $err;
    return $self->_finish_machine($machine, failed => error => $err, elapsed => $elapsed) if $machine;
    $out->say_error($err);
    return 0;
  }

  my $r = $app->raider;
  if ($machine) {
    $machine->event('message', role => 'assistant', content => "$result");
    return $self->_finish_machine($machine, completed =>
      response => "$result", metrics => $r->metrics, elapsed => $elapsed);
  }

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

Ends a run interrupted by the signal: prints a note, or with a C<machine>
writes the C<interrupted> state change and document (with the C<signal>),
then dies of that same signal through L</die_of_signal>.

=cut

sub interrupt {
  my ( $self, $signal, $machine, $elapsed ) = @_;
  # A second signal must not cut the document short.
  local $SIG{INT}  = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  if ($machine) {
    $self->_finish_machine($machine, interrupted => signal => $signal, elapsed => $elapsed);
  }
  else {
    $self->output->say_meta('interrupted (SIG'.$signal.')');
    $self->output->out->flush;
  }
  return $self->die_of_signal($signal);
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

# The last state change and the document; true for a completed run.
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
