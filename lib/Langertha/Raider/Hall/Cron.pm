package Langertha::Raider::Hall::Cron;
our $VERSION = '0.503';
# ABSTRACT: Non-blocking cron scheduler for the raider hall

=head1 DESCRIPTION

Arms an L<IO::Async::Timer::Absolute> per configured cron entry of a
L<Langertha::Raider::Hall> and spawns the named raider when it fires.

=cut

# Non-blocking cron: for each entry we compute the next execution time via
# Schedule::Cron and arm an IO::Async::Timer::Absolute. When it fires we
# spawn the raider, then re-arm for the following occurrence. Overlap is
# controlled per-entry: default is hall's 1name queue (opt-in coalesce
# drops the run if the previous is still in-flight).

use Moose;
use namespace::autoclean;
use Schedule::Cron;
use IO::Async::Timer::Absolute;

has hall => (
  is => 'ro',
  isa => 'Langertha::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has _jobs => (
  is => 'ro',
  default => sub { {} },
);

# A single parsing helper — we only use Schedule::Cron to compute the next
# time from the expression; we never call its own run loop.
sub _next_time_for {
  my ($self, $expr) = @_;
  my $sc = Schedule::Cron->new(sub { }, nofork => 1);
  my $idx = $sc->add_entry($expr, sub { });
  return $sc->get_next_execution_time($expr);
}

sub add_job {
  my ($self, %args) = @_;
  my $id = $args{id} // die "need id";
  my $cron_expr = $args{cron} // die "need cron expr";
  my $name = $args{name} // die "need name";
  my $mission = $args{mission} // '';
  my $coalesce = $args{coalesce} // 0;

  $self->_jobs->{$id} = {
    id => $id,
    cron => $cron_expr,
    name => $name,
    mission => $mission,
    coalesce => $coalesce,
    running => 0,
  };
  $self->_arm($id);
  return $id;
}

sub _arm {
  my ($self, $id) = @_;
  my $job = $self->_jobs->{$id} or return;
  my $when = eval { $self->_next_time_for($job->{cron}) };
  return unless $when;

  my $timer = IO::Async::Timer::Absolute->new(
    time => $when,
    on_expire => sub {
      my $t = $self->_jobs->{$id};
      return unless $t;  # cancelled
      if ($t->{coalesce} && $t->{running}) {
        $self->hall->_emit('cron.coalesced', { id => $id, name => $t->{name} });
      } else {
        $t->{running} = 1;
        my $res = eval { $self->hall->spawn(name => $t->{name}, mission => $t->{mission}) };
        $self->hall->_emit('cron.fired', {
          id => $id, name => $t->{name},
          ($res && $res->{id} ? (raider_id => $res->{id}) : ()),
        });
        # Clear running once the spawn returned a handle; 1name queueing
        # owns overlap protection when coalesce is off.
        $t->{running} = 0;
      }
      $self->_arm($id);  # re-schedule next occurrence
    },
  );
  $job->{timer} = $timer;
  $self->hall->loop->add($timer);
}

sub start {
  my ($self) = @_;
  my $conf = $self->hall->config;
  my $cron_list = $conf->{cron} // [];
  for my $entry (@$cron_list) {
    $self->add_job(
      id => $entry->{id} // $entry->{name},
      cron => $entry->{cron},
      name => $entry->{name},
      mission => $entry->{mission} // '',
      coalesce => $entry->{coalesce} // 0,
    );
  }
}

sub cancel_job {
  my ($self, $id) = @_;
  my $job = delete $self->_jobs->{$id} or return;
  if ($job->{timer}) {
    eval { $self->hall->loop->remove($job->{timer}) };
  }
}

__PACKAGE__->meta->make_immutable;

1;
