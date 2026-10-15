package Langertha::Raider::Provider::Binding;
# ABSTRACT: Internal stored binding of a provider alias: what is pinned, and whether a fetched manifest still matches
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Carp qw( croak );
use POSIX qw( strftime );
use Langertha::Raider::Approval;
use Langertha::Raider::Provider::Change;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $class = 'Langertha::Raider::Provider::Binding';
    my $entry = $class->entry($manifest, $origin,
      allow_internal => 0, credential_env => 'EXAMPLE_API_KEY');
    # { origin => 'https://provider.example', issuer => 'https://provider.example',
    #   auth => [ 'api_key' ], credential_env => 'EXAMPLE_API_KEY',
    #   allow_internal => 0, pinned_at => '2026-10-15T09:30:00Z',
    #   fingerprint => '3f2a...' }

    my $why = $class->verify($entry, $fetched_manifest, $fetched_origin);   # undef: still the same

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The entry C<raider provider add ALIAS HOST> stores under C<providers:> in
F<~/.raider/config.yml> (ADR 0011, written through
L<Langertha::Raider::Config/update_home>) and C<raider --provider ALIAS>
checks a freshly fetched manifest against. Pure logic: nothing is fetched,
asked or stored here.

=over

=item C<origin>, C<issuer>, C<auth> -- what the user accepted: the origin
the manifest was fetched from, the issuer it claims, and the sorted auth
types its endpoints ask for. No TLS pin: a certificate rotation is no new
trust decision.

=item C<credential_env> -- the B<name> of the environment variable the
credential is read from at run time. The secret itself is never written to
a file; the name is shown before the user accepts, because that variable's
value is what goes to the provider.

=item C<allow_internal> -- whether this alias may resolve to a loopback,
private or link-local address. Per alias and part of what the user
accepted: it is covered by the C<fingerprint>, never inherited from a
global setting and not switched by a command-line flag.

=item C<pinned_at> -- when the user accepted, UTC, for display only.

=item C<fingerprint> -- the L<Langertha::Raider::Provider::Change/fingerprint>
of the accepted manifest (origin, issuer, provider id, every endpoint's
origin, dialect and auth type) together with C<allow_internal>. The
precise record that L</verify> compares: it also catches an endpoint that
moved, which C<origin>, C<issuer> and C<auth> alone would not show. An entry
without one never matches.

=back

A manifest change that L<Langertha::Raider::Provider::Change> counts as
needing no consent (models, capabilities, paths, auth labels) leaves the
fingerprint alone, so it needs nothing here.

=cut

sub change_class { 'Langertha::Raider::Provider::Change' }
sub digest_class { 'Langertha::Raider::Approval' }

# The name of the pin's shape, part of the fingerprint like Change's VIEW.
use constant PIN => 'raider-provider-binding-1';

=method valid_alias

    $class->valid_alias('acme-prod');    # 1

True for a name of lowercase letters, digits, C<-> and C<_>, at most 32,
starting with a letter or digit. It has no dot, colon or slash, so it can
never be taken for a host or URL.

=method valid_credential_env

True for a name of an environment variable (C<[A-Za-z_][A-Za-z0-9_]*>).

=cut

sub valid_alias {
  my ( $self, $alias ) = @_;
  return ( defined $alias && !ref $alias && $alias =~ /\A[a-z0-9][a-z0-9_-]{0,31}\z/ ) ? 1 : 0;
}

sub valid_credential_env {
  my ( $self, $name ) = @_;
  return ( defined $name && !ref $name && $name =~ /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/ ) ? 1 : 0;
}

=method auth_types

    my @types = $class->auth_types($manifest, $origin);

The auth types the endpoints of C<$manifest> ask for, sorted, each once;
empty for a provider that asks for none.

=cut

sub auth_types {
  my ( $self, $manifest, $origin ) = @_;
  my $view = $self->change_class->consent_view($manifest, $origin);
  my %seen;
  return sort grep { !$seen{$_}++ } grep { defined } map { $_->{auth} } values %{ $view->{endpoints} };
}

=method fingerprint

    my $hex = $class->fingerprint($manifest, $origin, $allow_internal);

=cut

sub fingerprint {
  my ( $self, $manifest, $origin, $allow_internal ) = @_;
  return $self->digest_class->digest_arguments({
    pin            => PIN,
    consent        => $self->change_class->fingerprint($manifest, $origin),
    allow_internal => $allow_internal ? 1 : 0,
  });
}

=method entry

    my $entry = $class->entry($manifest, $origin,
      allow_internal => $bool, credential_env => $name, now => $epoch);

The hash to store (see L</DESCRIPTION>). C<$origin> is the origin, or any
URL of it, the manifest was fetched from. Croaks on an invalid
C<credential_env>.

=cut

sub entry {
  my ( $self, $manifest, $origin, %opt ) = @_;
  my $allow = $opt{allow_internal} ? 1 : 0;
  my $view  = $self->change_class->consent_view($manifest, $origin);
  my $env   = $opt{credential_env};
  croak __PACKAGE__.'->entry: credential_env is not an environment variable name'
    if defined $env && !$self->valid_credential_env($env);
  return {
    origin         => $view->{origin},
    issuer         => $view->{issuer},
    auth           => [ $self->auth_types($manifest, $origin) ],
    ( defined $env ? ( credential_env => $env ) : () ),
    allow_internal => $allow,
    pinned_at      => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime( $opt{now} // time )),
    fingerprint    => $self->fingerprint($manifest, $origin, $allow),
  };
}

=method problem

    my $why = $class->problem($entry);

Why a stored entry (hand-edited, or from a newer raider) cannot be used,
or C<undef>. Nothing in it is trusted beyond its shape.

=cut

sub problem {
  my ( $self, $entry ) = @_;
  return 'is not a mapping' unless ref $entry eq 'HASH';
  for my $field (qw( origin issuer fingerprint )) {
    return $field.' is missing' unless defined $entry->{$field} && !ref $entry->{$field} && length $entry->{$field};
  }
  return 'origin is not an https origin' unless $entry->{origin} =~ m{\Ahttps://[^/?#@\s]+\z};
  return 'auth is not a list' unless ref $entry->{auth} eq 'ARRAY';
  return 'credential_env is not an environment variable name'
    if defined $entry->{credential_env} && !$self->valid_credential_env($entry->{credential_env});
  return;
}

=method verify

    my $why = $class->verify($entry, $manifest, $origin);

Compares a fetched C<$manifest> (from C<$origin>) with the accepted
C<$entry>. C<undef> when it is what was accepted -- the same
L</fingerprint>. Otherwise one line naming what differs: the origin, the
issuer and the auth types where they changed, else only that endpoints or
the binding itself differ. A change of the model list, capabilities or a
path never lands here (L<Langertha::Raider::Provider::Change>).

=cut

sub verify {
  my ( $self, $entry, $manifest, $origin ) = @_;
  my $view = $self->change_class->consent_view($manifest, $origin);
  my $allow = $entry->{allow_internal} ? 1 : 0;
  return if defined $entry->{fingerprint}
    && $entry->{fingerprint} eq $self->fingerprint($manifest, $origin, $allow);
  my @why;
  push @why, 'origin '.$entry->{origin}.' -> '.$view->{origin} if $entry->{origin} ne $view->{origin};
  push @why, 'issuer '.$entry->{issuer}.' -> '.$view->{issuer} if $entry->{issuer} ne $view->{issuer};
  my @auth = $self->auth_types($manifest, $origin);
  my @was  = sort @{ $entry->{auth} // [] };
  push @why, 'auth ['.join(', ', @was).'] -> ['.join(', ', @auth).']' if "@was" ne "@auth";
  push @why, 'the endpoints, their origins, dialects or auth, or the binding itself, differ from what was accepted'
    unless @why;
  return join('; ', @why);
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Provider::Change> -- what counts as needing renewed consent

=item * L<Langertha::Raider::CLI::Provider> -- C<provider add>, which writes the entry

=item * L<Langertha::Raider::Config/providers> -- where it is read from

=back

=cut
