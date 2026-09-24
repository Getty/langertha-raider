package Langertha::Raider::Hall::Raider;
our $VERSION = '0.503';
# ABSTRACT: Record of a raider process spawned by the hall

=head1 DESCRIPTION

Plain data object the L<Langertha::Raider::Hall> keeps per running raider
slot: id, pid, slot and base name, log path and mission.

=cut

use Moose;
use namespace::autoclean;

has id => (is => 'ro', isa => 'Str', required => 1);
has pid => (is => 'ro', isa => 'Int', predicate => 'has_pid');
has slot_name => (is => 'ro', isa => 'Str', required => 1);
has base_name => (is => 'ro', isa => 'Str', required => 1);
has log_path => (is => 'ro', isa => 'Path::Tiny', required => 1);
has mission => (is => 'ro', isa => 'Str', required => 1);

__PACKAGE__->meta->make_immutable;

1;
