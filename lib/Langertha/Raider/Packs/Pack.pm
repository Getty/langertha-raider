package Langertha::Raider::Packs::Pack;
our $VERSION = '0.503';
# ABSTRACT: A single raider pack - persona or power bundle

=head1 DESCRIPTION

Holds one pack loaded by L<Langertha::Raider::Packs>: its skill text,
exclusive group and the MCP servers, commands and engine options it adds.

=cut

use Moose;
use namespace::autoclean;

has name          => (is => 'ro', isa => 'Str', required => 1);
has path          => (is => 'ro', isa => 'Str', required => 1);
has skill_text    => (is => 'ro', isa => 'Str', predicate => 'has_skill_text');
has exclusive_group => (is => 'ro', isa => 'Str', default => 'power');
has enabled_by_default => (is => 'ro', isa => 'Bool', default => 0);
has extra_mcp     => (is => 'ro', isa => 'ArrayRef', default => sub { [] });
has add_allowed_commands => (is => 'ro', isa => 'ArrayRef', default => sub { [] });
has engine_options => (is => 'ro', isa => 'HashRef', default => sub { {} });

__PACKAGE__->meta->make_immutable;

1;
