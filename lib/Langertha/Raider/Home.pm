package Langertha::Raider::Home;
# ABSTRACT: Internal resolver of the home and project .raider directories
our $VERSION = '0.504';
use strict;
use warnings;
use Path::Tiny;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $home = Langertha::Raider::Home->home_dir;                 # $ENV{HOME}, else getpwuid
    my $user = Langertha::Raider::Home->home_base;                # ~/.raider
    my $proj = Langertha::Raider::Home->project_base($root);      # <root>/.raider

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The one place that knows where the F<.raider> directories of a user and of a
project live (ADR 0011). Class methods only; every path is returned as an
absolute L<Path::Tiny>.

=method home_dir

The user's home: C<$ENV{HOME}>, else the home from the password database.
May be C<undef> when neither knows one.

=method dir_name

The name of the directory inside a home or project, C<.raider>.

=method home_base

    my $base = Langertha::Raider::Home->home_base;          # ~/.raider
    my $base = Langertha::Raider::Home->home_base($home);   # <home>/.raider

F<.raider> under the given home, by default under L</home_dir>. Returns
nothing when there is no home at all.

=method project_base

F<.raider> under the given project root.

=method claude_home

    my $dir = Langertha::Raider::Home->claude_home;          # ~/.claude
    my $dir = Langertha::Raider::Home->claude_home($home);   # <home>/.claude

The Claude Code configuration directory (ADR 0019):
C<$ENV{CLAUDE_CONFIG_DIR}> when it is set and not empty, else F<.claude>
under the given home, by default under L</home_dir>. Returns nothing when
there is neither. The one place the readers of the Claude layout
(L<Langertha::Raider::Context> and its parts) take it from.

=cut

sub home_dir { $ENV{HOME} // (getpwuid($<))[7] }

sub dir_name { '.raider' }

sub home_base {
  my ( $self, $home ) = @_;
  $home //= $self->home_dir;
  return unless defined $home;
  return $self->_base($home);
}

sub project_base {
  my ( $self, $root ) = @_;
  return $self->_base($root);
}

sub claude_home {
  my ( $self, $home ) = @_;
  my $dir = $ENV{CLAUDE_CONFIG_DIR};
  return path($dir)->absolute if defined $dir && length $dir;
  $home //= $self->home_dir;
  return unless defined $home;
  return path($home)->absolute->child('.claude');
}

sub _base { path($_[1])->absolute->child($_[0]->dir_name) }

1;
