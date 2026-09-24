package Langertha::Raider::Config;
# ABSTRACT: Internal resolver and writer for the legacy .raider.yml
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use Carp qw( croak );
use Path::Tiny;
use YAML::PP ();
use Langertha::Raider::Detect;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $config = Langertha::Raider::Config->new( root => $dir );

    my $engine  = $config->engine;                    # engine: from the file, or undef
    my $options = $config->engine_options('openai');  # for the engine constructor
    my @specs   = $config->skill_specs('openai');
    my $report  = $config->explain('openai');         # which value came from where

    my @added = $config->add_skills('claude');        # the one writer
    $config->set_model('gpt-4o');

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice; use
L<Langertha::Raider::CLI> instead.

The one place that reads and writes the legacy F<.raider.yml> in L</root>.
The file is read in three layers, later ones winning:

=over

=item C<top> -- every top-level key whose value is not a hash (plus
C<skills> and C<detect>, which may be one)

=item C<default> -- the C<default:> section

=item the engine section -- the section named after the active engine
(C<openai:>, C<anthropic:>, ...)

=back

Every other top-level hash is the section of an engine that is not active.
C<skills> is merged across the layers instead of replaced. C<engine> is read
from C<top> and C<default> only, as it picks the engine section.

A file that does not parse, whose top level is not a mapping, or that holds
a mapping under one of raider's own keys other than C<skills> and C<detect>
(see L</is_app_key>), is an error: readers croak and the writer refuses to
overwrite it.

=cut

# Keys that configure raider itself and never reach the engine constructor.
my %APP_KEY = map { $_ => 1 } qw( detect engine no_detect packs perl preferred_lib_target skills );

my %PROFILE_KEYWORD = (
  claude => 'claude',
  openai => 'openai',
  codex  => 'openai',
  agents => 'openai',
);

=attr root

Directory holding F<.raider.yml>. Required.

=cut

has root => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr file

L<Path::Tiny> of the F<.raider.yml> in L</root>.

=cut

has file => (
  is         => 'ro',
  isa        => 'Path::Tiny',
  lazy_build => 1,
);

sub _build_file { path($_[0]->root)->child('.raider.yml') }

=attr data

The parsed file as a hash; empty when the file is missing or empty. Croaks
when the file does not parse, its top level is not a mapping, or a raider
key other than C<skills> and C<detect> holds a mapping.

=cut

has data => (
  is         => 'ro',
  isa        => 'HashRef',
  lazy_build => 1,
);

sub _build_data {
  my ( $self ) = @_;
  my $file = $self->file;
  return {} unless -f $file;
  my $data;
  eval { $data = YAML::PP->new->load_string($file->slurp_utf8); 1 }
    or croak 'Cannot parse '.$file.': '.( split /\n/, $@ )[0];
  return {} unless defined $data;
  croak 'Cannot use '.$file.': the top level must be a mapping' unless ref $data eq 'HASH';
  for my $key (sort keys %$data) {
    next unless $APP_KEY{$key} && !$self->_may_be_mapping($key) && ref $data->{$key} eq 'HASH';
    croak 'Cannot use '.$file.': '.$key.': configures raider, not an engine section; must not be a mapping';
  }
  return $data;
}

=method file_exists

True when F<.raider.yml> exists.

=cut

sub file_exists { -f $_[0]->file ? 1 : 0 }

# The raider keys whose value may be a mapping; any other top-level mapping
# is an engine section.
sub _may_be_mapping {
  my ( $self, $key ) = @_;
  return $key eq 'skills' || $key eq 'detect';
}

sub _is_section {
  my ( $self, $key ) = @_;
  return !$self->_may_be_mapping($key) && ref $self->data->{$key} eq 'HASH';
}

sub _layers {
  my ( $self, $engine ) = @_;
  my $data = $self->data;
  my @layers = ( [ top => { map { $_ => $data->{$_} } grep { !$self->_is_section($_) } keys %$data } ] );
  push @layers, [ default => $data->{default} ] if $self->_is_section('default');
  push @layers, [ $engine => $data->{$engine} ]
    if defined $engine && $engine ne 'default' && $self->_is_section($engine);
  return @layers;
}

# One pass over the layers: effective value and source per key, the shadowed
# sources, the skills of every layer, and what was ignored.
sub _resolve {
  my ( $self, $engine ) = @_;
  my ( %value, %source, %shadowed, @skills, @ignored );
  for my $layer ($self->_layers($engine)) {
    my ( $name, $hash ) = @$layer;
    for my $key (sort keys %$hash) {
      if ($key eq 'skills') {
        push @skills, { source => $name, value => $hash->{$key} };
        next;
      }
      if ($key eq 'engine' && $name ne 'top' && $name ne 'default') {
        push @ignored, { key => $name.'.engine', reason => 'engine: inside an engine section' };
        next;
      }
      push @{ $shadowed{$key} }, $source{$key} if exists $source{$key};
      $value{$key}  = $hash->{$key};
      $source{$key} = $name;
    }
  }
  for my $key (sort keys %{ $self->data }) {
    next unless $self->_is_section($key);
    next if $key eq 'default' || (defined $engine && $key eq $engine);
    push @ignored, { key => $key, reason => 'section of an inactive engine' };
  }
  return {
    value    => \%value,
    source   => \%source,
    shadowed => \%shadowed,
    skills   => \@skills,
    ignored  => \@ignored,
  };
}

=method engine

The engine name from C<engine:> (top level or C<default:>), or undef.

=cut

sub engine {
  my ( $self ) = @_;
  my $engine = $self->_resolve(undef)->{value}{engine};
  return defined $engine && !ref $engine && length $engine ? $engine : undef;
}

=method options

    my $opts = $config->options($engine_name);

Every effective key except C<skills>, layered for C<$engine_name>.

=cut

sub options {
  my ( $self, $engine ) = @_;
  return { %{ $self->_resolve($engine)->{value} } };
}

=method engine_options

    my $opts = $config->engine_options($engine_name);

L</options> without raider's own keys (C<detect>, C<engine>, C<no_detect>,
C<packs>, C<perl>, C<preferred_lib_target>, C<skills>): what goes to the
engine constructor.

=cut

sub engine_options {
  my ( $self, $engine ) = @_;
  my $opts = $self->options($engine);
  delete @$opts{keys %APP_KEY};
  return $opts;
}

=method is_app_key

    $config->is_app_key('perl');   # 1

True for the keys that configure raider itself (C<detect>, C<engine>,
C<no_detect>, C<packs>, C<perl>, C<preferred_lib_target>, C<skills>) and
never reach the engine constructor.

=cut

sub is_app_key {
  my ( $self, $key ) = @_;
  return $APP_KEY{$key} ? 1 : 0;
}

sub detect_class { 'Langertha::Raider::Detect' }

=method detect_settings

    my $d = $config->detect_settings($engine_name);
    # { enabled => 1,
    #   rules   => { perl => { must => [ { file => 'cpanfile' } ] } },
    #   off     => { rust => 'no_detect', go => 'detect: go: false' } }

Pack detection (ADR 0012) as configured in the file: L</normalize_detect>
of the effective C<detect> and C<no_detect> values for C<$engine_name>.
Croaks on an invalid value or rule.

=cut

sub detect_settings {
  my ( $self, $engine ) = @_;
  my $opts = $self->options($engine);
  return $self->normalize_detect($opts->{detect}, $opts->{no_detect});
}

=method normalize_detect

    my $d = $config->normalize_detect($detect, $no_detect);

Checks and normalizes a C<detect> value -- a map of pack name to rule
(L<Langertha::Raider::Detect>) or C<false>, a pack name mapped to C<false>
switching detection off for that pack, the whole key C<false> switching
it off entirely -- and a C<no_detect> list of pack names (or a
comma-separated string). Returns C<enabled>, C<rules> and C<off> (pack name
to the reason) as in L</detect_settings>; croaks naming the offending key.

=cut

sub normalize_detect {
  my ( $self, $detect, $no_detect ) = @_;
  my %settings = ( enabled => 1, rules => {}, off => {} );
  if (defined $detect) {
    if (ref $detect eq 'HASH') {
      for my $name (sort keys %$detect) {
        my $rule = $detect->{$name};
        if (ref $rule eq 'HASH') {
          $self->detect_class->validate_rule($rule, 'detect.'.$name);
          $settings{rules}{$name} = $rule;
        }
        elsif (ref $rule || !defined $rule || ($rule && $rule ne '1')) {
          croak 'Invalid detect setting detect.'.$name.': must be a rule or false';
        }
        elsif (!$rule) {
          $settings{off}{$name} = 'detect: '.$name.': false';
        }
      }
    }
    elsif (ref $detect) {
      croak 'Invalid detect setting detect: must be a map of pack name to rule, or false';
    }
    else {
      $settings{enabled} = $detect ? 1 : 0;
    }
  }
  if (defined $no_detect) {
    my @names = ref $no_detect eq 'ARRAY' ? @$no_detect
              : ref $no_detect            ? croak 'Invalid detect setting no_detect: must be a list of pack names'
              :                             split /\s*,\s*/, $no_detect;
    for my $name (@names) {
      croak 'Invalid detect setting no_detect: must be a list of pack names' if ref $name || !length($name // '');
      $settings{off}{$name} = 'no_detect';
    }
  }
  return \%settings;
}

=method normalize_skill_spec

    my @specs = $config->normalize_skill_spec($item);

Turns one C<skills:> item into skill-source hashes: C<claude> becomes
F<CLAUDE.md> plus F<.claude/skills>, C<openai> / C<codex> / C<agents> become
F<AGENTS.md>, any other string a markdown directory, a hash passes through.

=cut

sub normalize_skill_spec {
  my ( $self, $spec ) = @_;
  if (!ref $spec) {
    return (
      { type => 'file',   path => 'CLAUDE.md' },
      { type => 'claude', path => '.claude/skills' },
    ) if $spec eq 'claude';
    return { type => 'file', path => 'AGENTS.md' } if $PROFILE_KEYWORD{$spec};
    return { type => 'dir', path => $spec };
  }
  return $spec if ref $spec eq 'HASH';
  return;
}

sub _skill_items {
  my ( $self, $engine ) = @_;
  my @items;
  for my $layer (@{ $self->_resolve($engine)->{skills} }) {
    my $raw = $layer->{value};
    next unless defined $raw;
    push @items, ref $raw eq 'ARRAY' ? @$raw : ($raw);
  }
  return @items;
}

sub _spec_key {
  my ( $self, $spec ) = @_;
  return join "\0", map { $spec->{$_} // '' } qw( type path glob );
}

=method skill_specs

    my @specs = $config->skill_specs($engine_name, @cli_specs);

The skill sources of every layer, then C<@cli_specs>, normalized and
deduplicated in that order.

=cut

sub skill_specs {
  my ( $self, $engine, @cli ) = @_;
  my ( %seen, @specs );
  for my $spec (map { $self->normalize_skill_spec($_) } $self->_skill_items($engine), @cli) {
    push @specs, $spec unless $seen{ $self->_spec_key($spec) }++;
  }
  return @specs;
}

=method profiles

    my @profiles = $config->profiles($engine_name);

The agent profiles (C<claude>, C<openai>) named in C<skills:>, in order.

=cut

sub profiles {
  my ( $self, $engine ) = @_;
  my ( %seen, @profiles );
  for my $item ($self->_skill_items($engine)) {
    next if ref $item;
    my $profile = $PROFILE_KEYWORD{$item} or next;
    push @profiles, $profile unless $seen{$profile}++;
  }
  return @profiles;
}

=method explain

    my $report = $config->explain($engine_name);

Where each effective value came from:

    {
      file    => '/path/.raider.yml',
      exists  => 1,
      engine  => 'openai',
      values  => [
        { key => 'temperature', value => 0.7, source => 'openai',
          shadowed => ['default'], applies_to => 'engine' },
        { key => 'skills', value => ['claude'], source => 'top',
          merged => 1, applies_to => 'raider' },
      ],
      ignored => [ { key => 'anthropic', reason => 'section of an inactive engine' } ],
    }

C<source> is a layer (C<top>, C<default> or the engine name);
C<applies_to> says whether the value reaches the engine constructor or
configures raider itself. C<skills> gets one entry per layer, as they merge.

=cut

sub explain {
  my ( $self, $engine ) = @_;
  my $r = $self->_resolve($engine);
  my @values = map {
    my $key = $_;
    {
      key        => $key,
      value      => $r->{value}{$key},
      source     => $r->{source}{$key},
      shadowed   => $r->{shadowed}{$key} // [],
      applies_to => $APP_KEY{$key} ? 'raider' : 'engine',
    }
  } sort keys %{ $r->{value} };
  push @values, map {
    { key => 'skills', value => $_->{value}, source => $_->{source}, merged => 1, applies_to => 'raider' }
  } @{ $r->{skills} };
  return {
    file    => $self->file->stringify,
    exists  => $self->file_exists,
    engine  => $engine,
    values  => \@values,
    ignored => $r->{ignored},
  };
}

# The one writer: mutate the parsed data, write it back when the callback
# returns true, then re-read. Refuses (croaks) on a file that does not parse.
sub _update {
  my ( $self, $code ) = @_;
  my $data = $self->data;
  return unless $code->($data);
  $self->file->spew_utf8(YAML::PP->new->dump_string($data));
  $self->clear_data;
  return 1;
}

=method add_skills

    my @added = $config->add_skills('claude', 'my-skills');

Appends the items not yet listed to the top-level C<skills:> list and writes
the file. Items already present at top level or in C<default:> are skipped.
Returns the items that were added.

=cut

sub add_skills {
  my ( $self, @items ) = @_;
  my @added;
  $self->_update(sub {
    my ( $data ) = @_;
    my @have;
    for my $raw ($data->{skills}, (ref $data->{default} eq 'HASH' ? $data->{default}{skills} : ())) {
      next unless defined $raw;
      push @have, ref $raw eq 'ARRAY' ? @$raw : ($raw);
    }
    my %have = map { $self->_item_key($_) => 1 } @have;
    my @list = !defined $data->{skills} ? ()
             : ref $data->{skills} eq 'ARRAY' ? @{ $data->{skills} }
             : ($data->{skills});
    for my $item (@items) {
      next if $have{ $self->_item_key($item) }++;
      push @list, $item;
      push @added, $item;
    }
    return 0 unless @added;
    $data->{skills} = \@list;
    return 1;
  });
  return @added;
}

sub _item_key {
  my ( $self, $item ) = @_;
  return ref $item eq 'HASH' ? $self->_spec_key($item) : 'item:'.($item // '');
}

=method set_model

    $config->set_model('gpt-4o');

Writes C<default: { model: ... }>, the shape the REPL's C</model> saves.

=cut

sub set_model {
  my ( $self, $model ) = @_;
  $self->_update(sub {
    my ( $data ) = @_;
    $data->{default} = {} unless ref $data->{default} eq 'HASH';
    $data->{default}{model} = $model;
    return 1;
  });
  return;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI>

=back

=cut
