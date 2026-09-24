package Langertha::Raider::Packs::Collection;
our $VERSION = '0.503';
# ABSTRACT: Set of loaded raider packs with per-session enable state

=head1 DESCRIPTION

Returned by L<Langertha::Raider::Packs/build_packs>. Tracks which packs are
enabled, honouring exclusive groups.

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
}

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

=cut

sub enable {
  my ($self, $name) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
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
      @{$self->enabled_pack_names} = grep { !$remove{$_} } @{$self->enabled_pack_names};
    }

    push @{$self->enabled_pack_names}, $name unless $self->_is_enabled($name);
  }

  return;
}

=method disable

    $collection->disable('caveman');
    $collection->disable('git-guru');

=cut

sub disable {
  my ($self, $name) = @_;
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
    # { name, exclusive_group, is_active, has_skill_text, path }

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
  };
}

__PACKAGE__->meta->make_immutable;

1;
