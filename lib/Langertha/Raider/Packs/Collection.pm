package Langertha::Raider::Packs::Collection;
our $VERSION = '0.503';
# ABSTRACT: Set of loaded raider packs with per-session enable state

=head1 DESCRIPTION

Returned by L<Langertha::Raider::Packs/build_packs>. Tracks which packs are
enabled, honouring exclusive groups, and why: every enabled pack has a
source (C<default>, C<flag>, C<config>, C<detected>, C<manual>) and a
reason, and the outcome of each detection rule (ADR 0012) is kept for
L</activation_report>.

=cut

use Moose;
use namespace::autoclean;
use JSON::MaybeXS ();

has packs_by_name    => (is => 'ro', isa => 'HashRef', required => 1);
has exclusive_groups => (is => 'ro', isa => 'HashRef', required => 1);

# Enabled pack names for this session. Mutated in-place by enable/disable/toggle.
has enabled_pack_names => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub { [] },
);

# All pack names known
has all_pack_names => (
  is      => 'ro',
  isa     => 'ArrayRef',
  lazy    => 1,
  builder => '_build_all_pack_names',
);

sub BUILD {
  my ($self) = @_;
  my $init = $self->_init_defaults // [];
  my %active;
  my %seen_exclusive;

  for my $name (@$init) {
    my $pack = $self->packs_by_name->{$name} or next;
    my $grp = $pack->exclusive_group;

    if ($grp eq 'power') {
      $active{$name} = 1 unless $active{$name};
    }
    else {
      unless ($seen_exclusive{$grp}++) {
        $active{$name} = 1;
      }
    }
  }

  $self->enabled_pack_names([sort keys %active]);
  $self->sources->{$_} = { source => 'default', reason => 'enabled_by_default' } for keys %active;
}

=attr sources

Why each enabled pack is on: C<< { NAME => { source, reason } } >>.

=attr switched_off

Packs switched off explicitly (C<--no-pack>): C<< { NAME => { source, reason } } >>.

=attr detections

Outcome of each detection rule: C<< { NAME => { rule_from, result, reason, notes } } >>,
C<result> being C<matched>, C<not matched> or C<skipped>.

=attr skipped_packs

Pack directories that could not be loaded, in search order:
C<< [ { name, origin, path, reason } ] >> (see
L<Langertha::Raider::Packs/build_packs>).

=cut

has sources       => (is => 'ro', isa => 'HashRef', default => sub { {} });
has switched_off  => (is => 'ro', isa => 'HashRef', default => sub { {} });
has detections    => (is => 'rw', isa => 'HashRef', default => sub { {} });
has skipped_packs => (is => 'ro', isa => 'ArrayRef[HashRef]', default => sub { [] });

has _init_defaults => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

sub _build_all_pack_names {
  my ($self) = @_;
  return [sort keys %{$self->packs_by_name}];
}

=method enable

    $collection->enable('polite');   # enable polite (toggles off caveman)
    $collection->enable('git-guru');  # stack git-guru on top
    $collection->enable('teacher', config => '.raider.yml packs:');

The optional source and reason say why (L</sources>); they default to
C<manual> and C</pack>.

=cut

sub enable {
  my ($self, $name, $source, $reason) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
  $self->sources->{$name} = { source => $source // 'manual', reason => $reason // '/pack' };
  delete $self->switched_off->{$name};
  my $grp = $pack->exclusive_group;

  if ($grp eq 'power') {
    push @{$self->enabled_pack_names}, $name unless $self->_is_enabled($name);
  }
  else {
    # Exclusive group: remove others in same group first
    my @others = grep {
      my $p = $self->packs_by_name->{$_};
      $p && $p->exclusive_group eq $grp && $_ ne $name;
    } @{$self->enabled_pack_names};

    if (@others) {
      my %remove = map { $_ => 1 } @others;
      delete @{$self->sources}{@others};
      @{$self->enabled_pack_names} = grep { !$remove{$_} } @{$self->enabled_pack_names};
    }

    push @{$self->enabled_pack_names}, $name unless $self->_is_enabled($name);
  }

  return;
}

=method disable

    $collection->disable('caveman');
    $collection->disable('git-guru', flag => '--no-pack');

With a source and reason the pack is recorded in L</switched_off>.

=cut

sub disable {
  my ($self, $name, $source, $reason) = @_;
  delete $self->sources->{$name};
  $self->switched_off->{$name} = { source => $source, reason => $reason } if defined $source;
  my %remove = map { $_ => 1 } ($name);
  @{$self->enabled_pack_names} = grep { !$remove{$_} } @{$self->enabled_pack_names};
  return;
}

=method toggle

    $collection->toggle('polite');  # on if off, off if on

=cut

sub toggle {
  my ($self, $name) = @_;
  if ($self->_is_enabled($name)) {
    $self->disable($name);
  }
  else {
    $self->enable($name);
  }
}

=method enable_detected

    my $holder = $collection->enable_detected('perl', $clause);

Enables a detected pack with source C<detected>, unless its exclusive group
already holds a pack that is not merely a C<default> one: explicit beats
detected, and the first detected pack of a group keeps it. Returns the
name of that holder when the pack stays off, nothing when it was enabled.

=cut

sub enable_detected {
  my ($self, $name, $reason) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
  my $grp = $pack->exclusive_group;
  if ($grp ne 'power') {
    my ($holder) = grep {
      my $p = $self->packs_by_name->{$_};
      $_ ne $name && $p && $p->exclusive_group eq $grp
        && ($self->sources->{$_}{source} // '') ne 'default';
    } @{$self->enabled_pack_names};
    return $holder if $holder;
  }
  $self->enable($name, detected => $reason);
  return;
}

=method activation_report

    my @packs = @{ $collection->activation_report };

One entry per pack that is enabled, was switched off explicitly or has a
detection outcome, sorted by name; rules for packs that are not installed
come last. C<origin> is L<Langertha::Raider::Packs::Pack/origin>:

    { name => 'perl', exclusive_group => 'power', origin => 'shipped',
      active => 1,
      source => 'detected', reason => 'must file=cpanfile (cpanfile)',
      detection => { rule_from => 'pack default', result => 'matched',
                     reason => '...', notes => [] } }

=cut

sub activation_report {
  my ($self) = @_;
  my @report;
  for my $name (@{$self->all_pack_names}) {
    my $active    = $self->_is_enabled($name) ? 1 : 0;
    my $why       = $active ? $self->sources->{$name} : $self->switched_off->{$name};
    my $detection = $self->detections->{$name};
    next unless $active || $why || $detection;
    my $pack = $self->packs_by_name->{$name};
    push @report, {
      name            => $name,
      exclusive_group => $pack->exclusive_group,
      origin          => $pack->origin,
      active          => $active,
      ( $why       ? ( source => $why->{source}, reason => $why->{reason} ) : () ),
      ( $detection ? ( detection => $detection ) : () ),
    };
  }
  for my $name (sort grep { !$self->packs_by_name->{$_} } keys %{$self->detections}) {
    push @report, { name => $name, active => 0, detection => $self->detections->{$name} };
  }
  return \@report;
}

sub _is_enabled {
  my ($self, $name) = @_;
  my %enabled = map { $_ => 1 } @{$self->enabled_pack_names};
  return $enabled{$name};
}

=method skill_texts

Returns the concatenated SKILL.md texts from all enabled packs.

=cut

sub skill_texts {
  my ($self) = @_;
  my @texts;
  for my $name (@{$self->enabled_pack_names}) {
    my $pack = $self->packs_by_name->{$name} or next;
    if ($pack->has_skill_text) {
      push @texts, "### Pack: $name\n\n" . $pack->skill_text;
    }
  }
  return @texts;
}

=method requested_tools

    my @servers = @{ $collection->requested_tools };   # ['perl']

The built-in tool servers the enabled packs request (C<tools:> in
F<pack.yml>), sorted and deduplicated. A request, not a grant.

=cut

sub requested_tools {
  my ($self) = @_;
  my %seen;
  for my $name (@{$self->enabled_pack_names}) {
    my $pack = $self->packs_by_name->{$name} or next;
    $seen{$_}++ for @{$pack->tools};
  }
  return [ sort keys %seen ];
}

=method active_pack_names

Returns pack names that are currently enabled.

=cut

sub active_pack_names { $_[0]->enabled_pack_names }

=method is_active

    if ($collection->is_active('caveman')) { ... }

=cut

sub is_active { $_[0]->_is_enabled($_[1]) }

=method pack_info

    my $info = $collection->pack_info('caveman');
    # { name, exclusive_group, is_active, has_skill_text, path, origin }

=cut

sub pack_info {
  my ($self, $name) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
  return {
    name            => $pack->name,
    exclusive_group => $pack->exclusive_group,
    is_active       => $self->_is_enabled($name) ? JSON::MaybeXS::true : JSON::MaybeXS::false,
    has_skill_text  => $pack->has_skill_text ? JSON::MaybeXS::true : JSON::MaybeXS::false,
    path            => $pack->path,
    origin          => $pack->origin,
  };
}

__PACKAGE__->meta->make_immutable;

1;
