package Langertha::Raider::CLI::Runner;
# ABSTRACT: Internal runner of one raider CLI prompt, for a human or a machine
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;

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

    my $ok = $runner->run_prompt($text, machine => $machine);

Returns true when the run finished, false when it failed (the error is
printed, or with C<machine> is the C<failed> document). An empty prompt runs
nothing and counts as finished.

=cut

sub run_prompt {
  my ( $self, $text, %o ) = @_;
  return 1 unless defined $text && length $text;
  my $app = $self->app;
  my $out = $self->output;

  my $machine = $o{machine};
  if ($machine) {
    $machine->event('run.started', engine => $app->engine_name,
      $app->has_model ? ( model => $app->model ) : ());
    $machine->event('run.state', state => 'running');
  }

  my $t0 = time;
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
