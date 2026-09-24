package Langertha::Raider::Hall::ACP::SubStream;
our $VERSION = '0.503';
# ABSTRACT: Stream shim feeding hall output into an ACP callback

=head1 DESCRIPTION

Minimal stand-in for an L<IO::Async::Stream> used by
L<Langertha::Raider::Hall::ACP>: each written JSON line is passed to a
callback.

=cut

use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  bless { cb => $args{cb}, opened => 1 }, $class;
}
sub write {
  my ($self, $line) = @_;
  chomp(my $l = $line);
  $self->{cb}->($l);
  return 1;
}
sub handle { $_[0] }
sub opened { $_[0]->{opened} }

1;
