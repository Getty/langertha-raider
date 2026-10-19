package Langertha::Raider::PathConfine;
# ABSTRACT: Internal keeper of the directories the file and search tools may reach
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Cwd qw( realpath );
use Path::Tiny;

=synopsis

    # Internal to Langertha-Raider -- no API promise.
    my $confine = Langertha::Raider::PathConfine->new(
      root        => $real_root,                  # a real absolute directory
      extra_roots => sub { [ '/other/dir' ] },    # list, ArrayRef or CodeRef
      confine     => sub { 1 },                   # value or CodeRef
    );
    die "Path escapes root\n" unless $confine->allows($real_path);

=description

B<Internal module.> Its interface may change without notice.

The one place that says which real paths L<Langertha::Raider::FileTools> and
L<Langertha::Raider::SearchTools> may reach (ADR 0023): the root, the
additional directories (L</extra_roots>) and whether the tools are confined at
all (L</confine>). Both tools used to carry their own copy.

=cut

has root => ( is => 'ro', isa => 'Maybe[Str]' );

=attr root

The real absolute path of the root directory. Without one nothing is
confined.

=cut

has extra_roots => ( is => 'ro', isa => 'ArrayRef|CodeRef', default => sub { [] } );

=attr extra_roots

More directories besides L</root>: an ArrayRef, or a CodeRef returning the
list (or one ArrayRef), asked on every call. One that cannot be resolved
(C<realpath> finds no existing parent) is left out; with L</dirs_only> so is
one that is not a directory.

=cut

has confine => ( is => 'ro', isa => 'Bool|CodeRef', default => 1 );

=attr confine

True by default. False (or a CodeRef answering false, asked on every call)
lets every path through -- the Claude layout, where the permission gate asks.

=cut

has dirs_only => ( is => 'ro', isa => 'Bool', default => 0 );

=attr dirs_only

True: an additional directory counts only when it is a directory.

=cut

sub confined {
  my ( $self ) = @_;
  my $c = $self->confine;
  return ref $c eq 'CODE' ? ( $c->() ? 1 : 0 ) : ( $c ? 1 : 0 );
}

=method confined

True when the tools are confined right now.

=cut

sub real_extra_roots {
  my ( $self ) = @_;
  my $extra = $self->extra_roots;
  my @extra = ref $extra eq 'CODE' ? $extra->() : @{ $extra };
  @extra = @{ $extra[0] } if @extra == 1 && ref $extra[0] eq 'ARRAY';
  return grep { !$self->dirs_only || -d $_ } grep { defined } map { realpath($_) } grep { defined } @extra;
}

=method real_extra_roots

The additional directories as real absolute paths, read on every call.

=cut

sub allows {
  my ( $self, $real ) = @_;
  return 1 unless defined $self->root && $self->confined;
  my $p = path($real);
  return scalar grep { path($_)->subsumes($p) } $self->root, $self->real_extra_roots;
}

=method allows

    $confine->allows($real_path);

True when C<$real_path> lies inside the root or an additional directory, or
when nothing confines.

=cut

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::FileTools>

=item * L<Langertha::Raider::SearchTools>

=back

=cut
