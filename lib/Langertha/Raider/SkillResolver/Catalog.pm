package Langertha::Raider::SkillResolver::Catalog;
# ABSTRACT: Internal skill resolver over the skill catalogue of a context
our $VERSION = '0.505';
use Moose;
use namespace::autoclean;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $r = Langertha::Raider::SkillResolver::Catalog->new( catalog => $context->skill_catalog );
    my $skill = $r->resolve('helper:tidy');   # { name, dir, file } or undef

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The first resolver of L<Langertha::Raider::SkillResolver>: a skill of the
L<Langertha::Raider::Context::Skills> catalogue -- every root and enabled
plugin (C<plugin:skill>), model-invocable or not
(L<Langertha::Raider::Context::Skills/find>).

=attr catalog

The L<Langertha::Raider::Context::Skills>. Required.

=cut

has catalog => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Context::Skills',
  required => 1,
);

=method resolve

    my $skill = $r->resolve('pdf');

C<< { name, dir, file } >> of the catalogue's skill of that name, or
C<undef>.

=cut

sub resolve {
  my ( $self, $name ) = @_;
  my $skill = $self->catalog->find($name) or return;
  return { name => $skill->{name}, dir => $skill->{dir}, file => $skill->{file} };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::SkillResolver>

=item * L<Langertha::Raider::Context::Skills>

=back

=cut
