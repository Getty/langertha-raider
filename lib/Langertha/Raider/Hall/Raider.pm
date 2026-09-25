package Langertha::Raider::Hall::Raider;
our $VERSION = '0.503';
# ABSTRACT: Record of a raider process spawned by the hall

=head1 DESCRIPTION

Data object the L<Langertha::Raider::Hall> keeps per running raider, keyed by run ID:
id, pid, slot and base name, log path, events path and mission.

=cut

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;

has id => (is => 'ro', isa => 'Str', required => 1);
has pid => (is => 'ro', isa => 'Int', predicate => 'has_pid');
has slot_name => (is => 'ro', isa => 'Str', required => 1);
has base_name => (is => 'ro', isa => 'Str', required => 1);
has log_path => (is => 'ro', isa => 'Path::Tiny', required => 1);
has mission => (is => 'ro', isa => 'Str', required => 1);

=attr events_path

The file the raider's C<--stream-json> stdout goes to, one file per run.
Optional; without it L</run_finished> has nothing to read.

=cut

has events_path => (is => 'ro', isa => 'Path::Tiny', predicate => 'has_events_path');

=method run_finished

    my $doc = $raider->run_finished;   # HashRef or undef

The payload of the last C<run.finished> event in L</events_path>: the run's
C<--json> document (C<version>, C<status>, C<response> or C<error>, ...),
without the event fields C<type>, C<seq> and C<time>. Undef when the file is
missing or holds no C<run.finished> -- the process was killed before it
could write one, for example. Lines that are not JSON objects are skipped.

=cut

sub run_finished {
  my ( $self ) = @_;
  return unless $self->has_events_path && -f $self->events_path;
  my $json = JSON::MaybeXS->new( utf8 => 1 );
  for my $line ( reverse $self->events_path->lines_raw({ chomp => 1 }) ) {
    my $event = eval { $json->decode($line) };
    next unless ref $event eq 'HASH' && ( $event->{type} // '' ) eq 'run.finished';
    delete @{$event}{qw( type seq time )};
    return $event;
  }
  return;
}

__PACKAGE__->meta->make_immutable;

1;
