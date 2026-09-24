package Langertha::Raider::Packs;
our $VERSION = '0.503';
# ABSTRACT: Pack discovery, loading, and management for raider personas and power bundles

use strict;
use warnings;
use Path::Tiny;
use YAML::PP ();
use JSON::MaybeXS ();
use File::ShareDir ();

use Langertha::Raider::Packs::Collection;
use Langertha::Raider::Packs::Pack;

use Exporter 'import';
our @EXPORT_OK = qw( build_packs );

=func build_packs

    my $packs = Langertha::Raider::Packs::build_packs(
        root     => '/path/to/project',  # chroot root
        packs    => ['caveman', 'git-guru'],  # enabled pack names
    );

Returns an L<Langertha::Raider::Packs::Collection> containing the loaded packs.

=cut

sub _pack_defaults {
  my ($packs) = @_;
  my @defaults;

  for my $pack (values %$packs) {
    push @defaults, $pack->name if $pack->enabled_by_default;
  }

  my %seen_group;
  my @filtered;
  for my $name (@defaults) {
    my $pack = $packs->{$name};
    my $grp = $pack->exclusive_group;
    next if $grp eq 'power';
    unless ($seen_group{$grp}++) {
      push @filtered, $name;
    }
  }

  push @filtered, grep { $packs->{$_}->exclusive_group eq 'power' } @defaults;

  return \@filtered;
}

sub build_packs {
  my %args = @_;
  my $root = path($args{root} // '.')->absolute;

  my @search_paths;

  # Bundled share/packs/ discovery, in order of likelihood:
  #
  #   1. File::ShareDir when installed from CPAN (ShareDir plugin
  #      copies share/ into auto/share/dist/Langertha-Raider/).
  #   2. Source-tree layout: $INC{Langertha/Raider/CLI.pm} = lib/Langertha/Raider/CLI.pm,
  #      sibling share/packs/ is four parents up after ->absolute.
  #   3. blib layout used by `dzil test` / `make test`:
  #      blib/lib/Langertha/Raider/CLI.pm with share/packs/ one parent less.
  #   4. $RAIDER_PACK_DIRS env for explicit overrides.
  {
    my $sd = eval {
      File::ShareDir::dist_dir('Langertha-Raider');
    };
    if ($sd) {
      my $p = path($sd)->child('packs');
      push @search_paths, $p if -d $p;
    }
  }

  my $mod_path = path($INC{'Langertha/Raider/CLI.pm'})->absolute;
  for my $up (qw( parent_x4 parent_x3 )) {
    my $base = $up eq 'parent_x4'
      ? $mod_path->parent->parent->parent->parent
      : $mod_path->parent->parent->parent;
    my $cand = $base->child('share', 'packs');
    push @search_paths, $cand if -d $cand;
  }

  # $RAIDER_PACK_DIRS env
  if (my $env_dirs = $ENV{RAIDER_PACK_DIRS}) {
    for my $d (split /:/, $env_dirs) {
      my $p = path($d)->absolute;
      push @search_paths, $p if -d $p;
    }
  }

  my %packs_by_name;
  my %exclusive_groups;

  for my $sp (@search_paths) {
    next unless -d $sp;
    for my $pack_dir ($sp->children) {
      next unless -d $pack_dir;
      my $name = $pack_dir->basename;

      # Skip if already loaded (first-wins from search order)
      next if $packs_by_name{$name};

      my $yml_file = $pack_dir->child('pack.yml');
      my $skill_file = $pack_dir->child('SKILL.md');

      my $config = {};
      if (-f $yml_file) {
        $config = eval { YAML::PP->new->load_string($yml_file->slurp_utf8) } // {};
      }

      my $pack = Langertha::Raider::Packs::Pack->new({
        name          => $name,
        path          => $pack_dir->stringify,
        ( -f $skill_file ? ( skill_text => $skill_file->slurp_utf8 ) : () ),
        exclusive_group => $config->{exclusive_group} // 'power',
        enabled_by_default => $config->{enabled_by_default} // 0,
        extra_mcp     => $config->{mcp} // [],
        add_allowed_commands => $config->{add_allowed_commands} // [],
        engine_options => $config->{engine_options} // {},
        tools         => $config->{tools} // [],
        ( exists $config->{detect} ? ( detect => $config->{detect} ) : () ),
      });

      $packs_by_name{$name} = $pack;

      my $group = $pack->exclusive_group;
      push @{$exclusive_groups{$group}//=[]}, $name;
    }
  }

  # Build the collection with initial defaults
  return Langertha::Raider::Packs::Collection->new({
    packs_by_name    => \%packs_by_name,
    exclusive_groups => \%exclusive_groups,
    _init_defaults   => _pack_defaults(\%packs_by_name),
  });
}

1;
