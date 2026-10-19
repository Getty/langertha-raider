package Langertha::Raider::SkillResolver;
# ABSTRACT: Internal chain of skill resolvers: a skill name to its directory and SKILL.md
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $resolver = Langertha::Raider::SkillResolver->new(
      resolvers => [
        Langertha::Raider::SkillResolver::Catalog->new( catalog => $context->skill_catalog ),
      ],
    );
    my $skill = $resolver->resolve('getty-perl-core');
    # { name => 'getty-perl-core', dir => '/abs/.claude/skills/getty-perl-core',
    #   file => '/abs/.claude/skills/getty-perl-core/SKILL.md' }  or undef

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The one interface through which a skill an agent declares is found when
it is briefed (ADR 0020 E<sect>6): an ordered chain of resolvers, each
an object with a C<resolve($name)> method that returns
C<< { name, dir, file } >> or nothing. The first resolver that knows the
name wins.

The chain of an application is L<Langertha::Raider::Context/skill_resolver>,
built from L<Langertha::Raider::Context/skill_resolvers>: today only the
skill catalogue of the context
(L<Langertha::Raider::SkillResolver::Catalog>). A resolver that reads the
skills of the sources in F<skilletor.json> straight from the source,
without installing them, joins as one more entry in that list once the
Skilletor distribution is released -- nothing else changes.

=attr resolvers

The resolvers, first asked first. Defaults to none (nothing resolves).

=cut

has resolvers => (
  is      => 'ro',
  isa     => 'ArrayRef[Object]',
  default => sub { [] },
);

=method resolve

    my $skill = $resolver->resolve('superpowers:brainstorming');

The C<< { name, dir, file } >> of the first resolver that knows C<$name>,
or C<undef>.

=cut

sub resolve {
  my ( $self, $name ) = @_;
  return unless defined $name && length $name;
  for my $resolver (@{ $self->resolvers }) {
    my $skill = $resolver->resolve($name);
    return $skill if $skill;
  }
  return;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::SkillResolver::Catalog>

=item * L<Langertha::Raider::Briefing>

=back

=cut
