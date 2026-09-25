package Langertha::Raider::Packs::Pack;
our $VERSION = '0.503';
# ABSTRACT: A single raider pack - persona or power bundle

=head1 DESCRIPTION

Holds one pack loaded by L<Langertha::Raider::Packs>: its skill text,
exclusive group, the kind of place it was found in, the built-in tools it
requests and its default detection rule (C<detect:> in F<pack.yml>, see
L<Langertha::Raider::Detect>).

=cut

use Moose;
use namespace::autoclean;

has name          => (is => 'ro', isa => 'Str', required => 1);
has path          => (is => 'ro', isa => 'Str', required => 1);

=attr origin

Where the pack was found: C<project> (F<< <root>/.raider/packs/ >>),
C<home> (F<~/.raider/packs/>), C<shipped> (the bundled F<share/packs/>) or
C<env> (C<$RAIDER_PACK_DIRS>); see L<Langertha::Raider::Packs/build_packs>.

=cut

has origin        => (is => 'ro', isa => 'Str', default => 'shipped');
has skill_text    => (is => 'ro', isa => 'Str', predicate => 'has_skill_text');
has exclusive_group => (is => 'ro', isa => 'Str', default => 'power');
has enabled_by_default => (is => 'ro', isa => 'Bool', default => 0);

# Built-in tool servers the pack requests (tools: in pack.yml, e.g. [perl]);
# a request, the CLI decides whether to grant it (ADR 0005).
has tools         => (is => 'ro', isa => 'ArrayRef[Str]', default => sub { [] });

# Default detection rule from pack.yml; validated when it is evaluated.
has detect        => (is => 'ro', predicate => 'has_detect');

__PACKAGE__->meta->make_immutable;

1;
