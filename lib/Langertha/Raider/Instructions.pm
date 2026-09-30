package Langertha::Raider::Instructions;
# ABSTRACT: Internal resolver of the project instructions file
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Path::Tiny;
use Langertha::Raider::Home;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $instructions = Langertha::Raider::Instructions->new(root => $root);
    my $text  = $instructions->text;     # undef when absent or empty
    my $label = $instructions->label;    # '.raider/instructions.md' or '.raider.md'

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Knows which file holds the project instructions of L</root> (ADR 0011):
F<.raider/instructions.md> when it exists, else the legacy F<.raider.md>.
When both exist, only F<.raider/instructions.md> is used and the legacy
file is reported by L</ignored_files>. The same rule as
L<Langertha::Raider::Config> for F<.raider/config.yml>.

Unlike L<Langertha::Raider::Config/file>, L</file> is decided on every
call, so a file created during a session (C</prompt>, by hand before
C</reload>) is seen on the next reload.

=attr root

The project directory. Required.

=cut

has root => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

sub home_class { 'Langertha::Raider::Home' }

=method native_file

L<Path::Tiny> of F<.raider/instructions.md> in L</root>, present or not.

=method legacy_file

L<Path::Tiny> of F<.raider.md> in L</root>, present or not.

=method file

L<Path::Tiny> of the file in use: L</native_file> when it exists, else
L</legacy_file>. Writers (the prompt-builder) write here, so without any
file they create the legacy F<.raider.md>, never F<.raider/instructions.md>.

=method is_native

True when L</file> is F<.raider/instructions.md>.

=method label

The file in use relative to L</root>, C<.raider/instructions.md> or
C<.raider.md>: how reports name it as a source.

=method file_exists

True when L</file> exists.

=cut

sub native_file { $_[0]->home_class->project_base($_[0]->root)->child('instructions.md') }

sub legacy_file { path($_[0]->root)->child('.raider.md') }

sub file {
  my ( $self ) = @_;
  my $native = $self->native_file;
  return -f $native ? $native : $self->legacy_file;
}

sub is_native { -f $_[0]->native_file ? 1 : 0 }

sub label { $_[0]->is_native ? $_[0]->home_class->dir_name.'/instructions.md' : '.raider.md' }

sub file_exists { -f $_[0]->file ? 1 : 0 }

=method text

The content of L</file>, or C<undef> when it is absent, unreadable or
empty.

=cut

sub text {
  my ( $self ) = @_;
  my $file = $self->file;
  return unless -f $file;
  my $text = eval { $file->slurp_utf8 };
  return defined $text && length $text ? $text : undef;
}

=method ignored_files

    for my $ign ($instructions->ignored_files) {
      warn 'ignoring '.$ign->{file}.': '.$ign->{reason}."\n";
    }

The instructions files that are present but not used, each as C<file>
(absolute path) and C<reason>: the legacy F<.raider.md> while
F<.raider/instructions.md> is in use. Empty otherwise.

=cut

sub ignored_files {
  my ( $self ) = @_;
  return unless $self->is_native && -f $self->legacy_file;
  my $label = $self->label;
  return {
    file   => $self->legacy_file->absolute->stringify,
    reason => 'both .raider.md and '.$label.' exist; only '.$label.' is used',
  };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application/mission>

=item * L<Langertha::Raider::Config>

=back

=cut
