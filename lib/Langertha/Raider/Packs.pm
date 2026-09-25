package Langertha::Raider::Packs;
our $VERSION = '0.503';
# ABSTRACT: Pack discovery, loading, and management for raider personas and power bundles

use strict;
use warnings;
use Carp qw( croak );
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
        root => '/path/to/project',  # workspace root
        home => '/home/me',          # optional
    );

Returns a L<Langertha::Raider::Packs::Collection> of every pack found.
A pack is a directory with an optional F<pack.yml> and an optional
F<SKILL.md> (without one it contributes no skill text). They are searched in these places; a pack name found in an earlier place hides
the same name in a later one:

=over

=item 1. C<project>: F<< <root>/.raider/packs/<name>/ >>

=item 2. C<home>: F<< ~/.raider/packs/<name>/ >>, F<~> being C<home>, else
C<$ENV{HOME}>, else the user's home from the password database

=item 3. C<shipped>: the bundled F<share/packs/>

=item 4. C<env>: the directories in C<$RAIDER_PACK_DIRS> (colon separated)

=back

Each pack keeps the kind of place it came from as
L<Langertha::Raider::Packs::Pack/origin>. When C<root> is the home
directory, its F<.raider/packs/> counts as C<home>.

A pack directory that cannot be loaded (a F<pack.yml> that is not valid
YAML or not a mapping, a value of the wrong type) is skipped
and listed in L<Langertha::Raider::Packs::Collection/skipped_packs>; a pack
of the same name further down the search order takes its place. It never
stops the start.

Project packs are loaded right away, like the C<detect:> rules of the
project's own config: the workspace trust decision of ADR 0004, which is
meant to gate both, does not exist yet.

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

sub _home_dir { $ENV{HOME} // (getpwuid($<))[7] }

# [ origin, directory ] in search order.
sub _pack_search_paths {
  my (%args) = @_;
  my $root = path($args{root} // '.')->absolute;
  my $home_dir = $args{home} // _home_dir();
  my $home = defined $home_dir ? path($home_dir)->absolute : undef;
  my @search_paths;

  my $project = $root->child('.raider', 'packs');
  if (-d $project) {
    my $is_home = $home && -d $home && $root->realpath eq $home->realpath;
    push @search_paths, [ project => $project ] unless $is_home;
  }
  if ($home) {
    my $p = $home->child('.raider', 'packs');
    push @search_paths, [ home => $p ] if -d $p;
  }

  # Bundled share/packs/ discovery, in order of likelihood:
  #
  #   1. File::ShareDir when installed from CPAN (ShareDir plugin
  #      copies share/ into auto/share/dist/Langertha-Raider/).
  #   2. Source-tree layout: $INC{Langertha/Raider/Application.pm} = lib/Langertha/Raider/Application.pm,
  #      sibling share/packs/ is four parents up after ->absolute.
  #   3. blib layout used by `dzil test` / `make test`:
  #      blib/lib/Langertha/Raider/Application.pm with share/packs/ one parent less.
  {
    my $sd = eval {
      File::ShareDir::dist_dir('Langertha-Raider');
    };
    if ($sd) {
      my $p = path($sd)->child('packs');
      push @search_paths, [ shipped => $p ] if -d $p;
    }
  }

  my $mod_path = path($INC{'Langertha/Raider/Application.pm'})->absolute;
  for my $up (qw( parent_x4 parent_x3 )) {
    my $base = $up eq 'parent_x4'
      ? $mod_path->parent->parent->parent->parent
      : $mod_path->parent->parent->parent;
    my $cand = $base->child('share', 'packs');
    push @search_paths, [ shipped => $cand ] if -d $cand;
  }

  # $RAIDER_PACK_DIRS env
  if (my $env_dirs = $ENV{RAIDER_PACK_DIRS}) {
    for my $d (split /:/, $env_dirs) {
      my $p = path($d)->absolute;
      push @search_paths, [ env => $p ] if -d $p;
    }
  }

  return @search_paths;
}

# First line of an error, without the " at FILE line N." Perl and Moose append.
sub _error_line {
  my ($error) = @_;
  my ($line) = split /\n/, "$error";
  $line =~ s/ at (?:\w+ \S+ \(defined at .+ line \d+\)|(?:(?! at ).)+) line \d+\.?\z//;
  return $line;
}

# One pack from its directory; croaks with the reason when it cannot be loaded.
sub _load_pack {
  my ($pack_dir, $origin) = @_;
  my $yml_file   = $pack_dir->child('pack.yml');
  my $skill_file = $pack_dir->child('SKILL.md');

  my $config = {};
  if (-f $yml_file) {
    $config = eval { YAML::PP->new->load_string($yml_file->slurp_utf8) };
    if (my $err = $@) {
      croak 'pack.yml is not valid YAML: '._error_line($err);
    }
    $config //= {};
    croak 'pack.yml is not a mapping' unless ref $config eq 'HASH';
  }

  return Langertha::Raider::Packs::Pack->new({
    name               => $pack_dir->basename,
    path               => $pack_dir->stringify,
    origin             => $origin,
    ( -f $skill_file ? ( skill_text => $skill_file->slurp_utf8 ) : () ),
    exclusive_group    => $config->{exclusive_group} // 'power',
    enabled_by_default => $config->{enabled_by_default} // 0,
    tools              => $config->{tools} // [],
    ( exists $config->{detect} ? ( detect => $config->{detect} ) : () ),
  });
}

sub build_packs {
  my %args = @_;

  my %packs_by_name;
  my %exclusive_groups;
  my @skipped;

  for my $search (_pack_search_paths(%args)) {
    my ( $origin, $sp ) = @$search;
    for my $pack_dir (sort { $a->basename cmp $b->basename } $sp->children) {
      next unless -d $pack_dir;
      my $name = $pack_dir->basename;

      # Skip if already loaded (first-wins from search order)
      next if $packs_by_name{$name};

      my $pack = eval { _load_pack($pack_dir, $origin) };
      unless ($pack) {
        my $reason = _error_line($@ || 'unknown error');
        push @skipped, { name => $name, origin => $origin, path => $pack_dir->stringify, reason => $reason };
        next;
      }

      $packs_by_name{$name} = $pack;
      push @{$exclusive_groups{$pack->exclusive_group}//=[]}, $name;
    }
  }

  # Build the collection with initial defaults
  return Langertha::Raider::Packs::Collection->new({
    packs_by_name    => \%packs_by_name,
    exclusive_groups => \%exclusive_groups,
    skipped_packs    => \@skipped,
    _init_defaults   => _pack_defaults(\%packs_by_name),
  });
}

1;
