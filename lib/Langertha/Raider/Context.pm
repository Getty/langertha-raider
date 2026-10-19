package Langertha::Raider::Context;
# ABSTRACT: Internal context of an application: layout mode, Claude memory and settings, skills
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Path::Tiny;
use Langertha::Raider::Home;
use Langertha::Raider::Context::Layout;
use Langertha::Raider::Context::Memory;
use Langertha::Raider::Context::Settings;
use Langertha::Raider::Context::Plugins;
use Langertha::Raider::Context::Skills;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $context = Langertha::Raider::Context->new(
      root           => $root,
      config_claude  => $options->{claude},     # undef when not set
      force_claude   => $opt{claude},           # --claude
      skill_specs    => [ { type => 'dir', path => 'my-skills' } ],
      want_agents_md => $opt{openai},           # --openai / --codex
    );
    $context->apply_env;                        # settings env into %ENV, once
    my @items = $context->prompt_items;         # memory, AGENTS.md, skill listing
    my $skills = $context->skill_catalog;       # Langertha::Raider::Context::Skills
    my $more  = $context->nested_memory_for('lib/Foo.pm');   # or undef
    my $report = $context->report;              # for config explain

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Everything ADR 0019 adds to what raider reads from a workspace, behind one
object per application: the layout mode
(L<Langertha::Raider::Context::Layout>), and in the Claude layout the
memory files (L<Langertha::Raider::Context::Memory>), the settings
(L<Langertha::Raider::Context::Settings>) and the enabled plugins
(L<Langertha::Raider::Context::Plugins>); the F<AGENTS.md> of C<--openai>;
and the skill catalogue (L<Langertha::Raider::Context::Skills>) with its
roots in the precedence of ADR 0019 E<sect>4:

=over

=item 1. L</skill_specs>, in their order. C<< { type => 'claude', path } >>
is a directory of skill directories (F<*/SKILL.md>);
C<< { type => 'dir', path, glob } >> a directory of flat F<*.md> skills;
C<< { type => 'dir', path } >> without C<glob> (C<--skills DIR>, a string
in C<skills:>) is both. A relative path is relative to L</root>.

=item 2. F<.raider/skills> of L</root>, then F<~/.raider/skills>.

=item 3. Only in the Claude layout: F<< <claude_home>/skills >>, then
F<.claude/skills> and F<.agents/skills> of the project directory
(L<Langertha::Raider::Context::Layout/project_dir>), then the skills of
every installed and enabled plugin as C<plugin:skill>.

=back

A directory that appears twice is read once, at its first place. With
L</bare> nothing is read at all: mode C<bare>, no memory, no settings, no
skills, no F<AGENTS.md>.

=attr root

The project directory. Required.

=cut

has root => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr bare

C<--bare> (ADR 0014): no layout, nothing read.

=attr force_claude

C<--claude>: the Claude layout is read in every mode but C<bare>.

=attr config_claude

The effective C<claude:> of the configuration (true, false or C<undef>
when not set); the legacy C<skills: [claude]> counts as true. Read by
truth, so YAML and JSON booleans work. Decides the Claude layout in a
raider project (L<Langertha::Raider::Context::Layout/claude_layout>).

=attr skill_specs

The explicit skill directories, highest precedence first, as
L<Langertha::Raider::Config/skill_specs> normalizes them. Defaults to
none.

=attr want_agents_md

True for C<--openai> / C<--codex> or C<skills: [openai]> (also C<codex>,
C<agents>): F<AGENTS.md> of L</root> is an instructions item (unless the
Claude memory already loaded that very file).

=cut

has bare => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has force_claude => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has config_claude => (
  is => 'ro',
);

has skill_specs => (
  is      => 'ro',
  isa     => 'ArrayRef[HashRef]',
  default => sub { [] },
);

has want_agents_md => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

sub home_class     { 'Langertha::Raider::Home' }
sub layout_class   { 'Langertha::Raider::Context::Layout' }
sub memory_class   { 'Langertha::Raider::Context::Memory' }
sub settings_class { 'Langertha::Raider::Context::Settings' }
sub plugins_class  { 'Langertha::Raider::Context::Plugins' }
sub skills_class   { 'Langertha::Raider::Context::Skills' }

=attr home

The user's home directory, by default L<Langertha::Raider::Home/home_dir>.

=attr claude_home

The Claude Code directory, by default
L<Langertha::Raider::Home/claude_home> of L</home>. Every part gets this
one, so they agree.

=cut

has home => (
  is         => 'ro',
  isa        => 'Maybe[Str]',
  lazy_build => 1,
);

sub _build_home { $_[0]->home_class->home_dir }

has claude_home => (
  is         => 'ro',
  isa        => 'Maybe[Str]',
  lazy_build => 1,
);

sub _build_claude_home {
  my ( $self ) = @_;
  return unless defined $self->home || length( $ENV{CLAUDE_CONFIG_DIR} // '' );
  my $dir = $self->home_class->claude_home($self->home);
  return defined $dir ? $dir->stringify : undef;
}

=attr layout

The L<Langertha::Raider::Context::Layout> of L</root>.

=method mode

L<Langertha::Raider::Context::Layout/mode>: C<bare>, C<raider>, C<claude>
or C<native>.

=method claude_layout

L<Langertha::Raider::Context::Layout/claude_layout>: whether memory,
settings, plugins and the Claude skill roots are read.

=cut

has layout => (
  is         => 'ro',
  isa        => 'Langertha::Raider::Context::Layout',
  init_arg   => undef,
  lazy_build => 1,
  handles    => [qw( mode claude_layout )],
);

sub _build_layout {
  my ( $self ) = @_;
  return $self->layout_class->new(
    root          => $self->root,
    home          => $self->home,
    claude_home   => $self->claude_home,
    config_claude => $self->config_claude,
    force_claude  => $self->force_claude ? 1 : 0,
    bare          => $self->bare ? 1 : 0,
  );
}

=attr memory

The L<Langertha::Raider::Context::Memory> in the Claude layout, else
C<undef>.

=attr settings

The L<Langertha::Raider::Context::Settings> of the project directory in
the Claude layout, else C<undef>.

=attr plugins

The L<Langertha::Raider::Context::Plugins> (installed and enabled by the
settings) in the Claude layout, else C<undef>.

=cut

has memory => (
  is         => 'ro',
  isa        => 'Maybe[Langertha::Raider::Context::Memory]',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_memory {
  my ( $self ) = @_;
  return unless $self->claude_layout;
  return $self->memory_class->new(
    root        => $self->root,
    home        => $self->home,
    claude_home => $self->claude_home,
    walk_dirs   => [ $self->layout->walk_dirs ],
  );
}

has settings => (
  is         => 'ro',
  isa        => 'Maybe[Langertha::Raider::Context::Settings]',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_settings {
  my ( $self ) = @_;
  return unless $self->claude_layout;
  return $self->settings_class->new(
    project_dir => $self->layout->project_dir->stringify,
    claude_home => $self->claude_home,
  );
}

has plugins => (
  is         => 'ro',
  isa        => 'Maybe[Langertha::Raider::Context::Plugins]',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_plugins {
  my ( $self ) = @_;
  my $settings = $self->settings or return;
  return $self->plugins_class->new(
    cwd         => $self->root,
    claude_home => $self->claude_home,
    enabled     => $settings->enabled_plugin_map,
  );
}

=attr skill_roots

The skill roots in precedence order (see L</DESCRIPTION>), each
C<< { dir, source, layout } >> as L<Langertha::Raider::Context::Skills/roots>
takes them. Roots that do not exist are listed too; the catalogue skips
them.

=cut

has skill_roots => (
  is         => 'ro',
  isa        => 'ArrayRef[HashRef]',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_skill_roots {
  my ( $self ) = @_;
  return [] if $self->bare;
  my $root = path($self->root)->absolute;
  my @roots;
  for my $spec (@{ $self->skill_specs }) {
    my $rel = $spec->{path};
    next unless defined $rel && !ref $rel && length $rel;
    my $dir  = path($rel)->absolute($root);
    my $type = $spec->{type} // 'dir';
    my @layouts = $type eq 'claude' ? ('skills')
      : $type eq 'dir' ? ( defined $spec->{glob} ? ('flat') : qw( skills flat ) )
      : ();
    push @roots, map { { dir => $dir->stringify, source => $rel, layout => $_ } } @layouts;
  }
  push @roots, {
    dir    => $self->home_class->project_base($root)->child('skills')->stringify,
    source => $self->home_class->dir_name.'/skills',
    layout => 'skills',
  };
  if (defined $self->home) {
    push @roots, {
      dir    => $self->home_class->home_base($self->home)->child('skills')->stringify,
      source => '~/'.$self->home_class->dir_name.'/skills',
      layout => 'skills',
    };
  }
  if ($self->claude_layout) {
    if (defined( my $ch = $self->claude_home )) {
      my $dir = path($ch)->child('skills');
      push @roots, { dir => $dir->stringify, source => $self->_home_label($dir), layout => 'skills' };
    }
    my $project = $self->layout->project_dir;
    for my $sub (qw( .claude .agents )) {
      my $dir = $project->child($sub, 'skills');
      push @roots, { dir => $dir->stringify, source => $self->_root_label($dir), layout => 'skills' };
    }
  }
  my %seen;
  return [ grep { !$seen{ $self->_real($_->{dir}).' '.$_->{layout} }++ } @roots ];
}

=attr skill_catalog

The L<Langertha::Raider::Context::Skills> over L</skill_roots> and, in the
Claude layout, the skill directories of L</plugins>.

=method has_listed_skills

True when the catalogue lists at least one skill to the model: then the
C<skill> tool is mounted.

=cut

has skill_catalog => (
  is         => 'ro',
  isa        => 'Langertha::Raider::Context::Skills',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_skill_catalog {
  my ( $self ) = @_;
  my $plugins = $self->plugins;
  return $self->skills_class->new(
    roots   => $self->skill_roots,
    plugins => $plugins
      ? [ map { { name => $_->{name}, dirs => [ $plugins->skill_dirs($_) ] } } @{ $plugins->plugins } ]
      : [],
  );
}

sub has_listed_skills { scalar( () = $_[0]->skill_catalog->listed ) ? 1 : 0 }

=attr agents_md

The F<AGENTS.md> instructions item of L</want_agents_md>, or C<undef>: the
file is absent or empty, L</bare>, or the Claude memory already holds it.
A hash with C<file>, C<label>, C<scope> (C<project>), C<kind>
(C<AGENTS.md>), C<text> and C<imports> (none), the shape of
L<Langertha::Raider::Context::Memory/items>.

=cut

has agents_md => (
  is         => 'ro',
  isa        => 'Maybe[HashRef]',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build_agents_md {
  my ( $self ) = @_;
  return if $self->bare || !$self->want_agents_md;
  my $file = path($self->root)->absolute->child('AGENTS.md');
  return unless -f $file;
  my $real = $self->_real($file);
  if (my $memory = $self->memory) {
    return if grep { $_->{file} eq $real } @{ $memory->items };
  }
  my $text = eval { $file->slurp_utf8 };
  return unless defined $text && $text =~ /\S/;
  return {
    file    => $real,
    label   => 'AGENTS.md',
    scope   => 'project',
    kind    => 'AGENTS.md',
    text    => $text,
    imports => [],
  };
}

=method instruction_items

    for my $item ($context->instruction_items) { say $item->{label} }

The memory items of the Claude layout, then L</agents_md> -- every
instructions file this context puts into the prompt.

=cut

sub instruction_items {
  my ( $self ) = @_;
  my $memory = $self->memory;
  return ( ( $memory ? @{ $memory->items } : () ), $self->agents_md // () );
}

=method prompt_items

    my @texts = $context->prompt_items;

The context items of the system prompt, in order, each a string: the Claude
memory (under the header Claude Code puts over it, see
L</memory_header>), the F<AGENTS.md> item, the skill listing
(L<Langertha::Raider::Context::Skills/prompt_text>). Items without content
are left out.

=method memory_header

The line above the Claude memory files, as Claude Code words it.

=cut

sub memory_header {
  'Codebase and user instructions are shown below. Be sure to adhere to these instructions.'
    .' IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them'
    .' exactly as written.';
}

sub prompt_items {
  my ( $self ) = @_;
  my @items;
  if (my $memory = $self->memory) {
    my $text = $memory->prompt_text;
    push @items, $self->memory_header."\n\n".$text if defined $text;
  }
  if (my $agents = $self->agents_md) {
    ( my $text = $agents->{text} ) =~ s/\s+\z//;
    push @items, 'Contents of '.$agents->{file}." (project instructions (AGENTS.md)):\n\n".$text;
  }
  my $skills = $self->skill_catalog->prompt_text;
  push @items, $skills if defined $skills;
  return @items;
}

=method apply_env

    my @keys = $context->apply_env;

Sets the C<env> of the Claude settings (ADR 0019 E<sect>3) in C<%ENV> of
this process, so tools and their subprocesses see it, as in Claude Code; a
value there replaces the one in the environment. Runs once per object --
later calls only return the keys. Nothing outside the Claude layout.
Returns the names of the keys set (L</applied_env>).

=attr applied_env

The names of the environment variables L</apply_env> set, sorted.

=cut

has applied_env => (
  is       => 'ro',
  isa      => 'ArrayRef[Str]',
  init_arg => undef,
  default  => sub { [] },
);

has _env_done => (
  is       => 'rw',
  isa      => 'Bool',
  init_arg => undef,
  default  => 0,
);

sub apply_env {
  my ( $self ) = @_;
  unless ($self->_env_done) {
    $self->_env_done(1);
    if (my $settings = $self->settings) {
      my $values = $settings->env_values;
      for my $key (sort keys %$values) {
        $ENV{$key} = $values->{$key};
        push @{ $self->applied_env }, $key;
      }
    }
  }
  return @{ $self->applied_env };
}

=method nested_memory_for

    my $text = $context->nested_memory_for('sub/dir/file.txt');

The F<CLAUDE.md> files below L</root> on the way to C<$path> that were not
handed out before (L<Langertha::Raider::Context::Memory/nested_for>),
formatted for a tool result; C<undef> when there is none, outside the
Claude layout and for a path outside L</root>.

=cut

sub nested_memory_for {
  my ( $self, $path ) = @_;
  my $memory = $self->memory or return;
  my $text = $memory->nested_text($memory->nested_for($path));
  return $text;
}

=method report

    my $report = $context->report;

What C<config explain> shows of the context, plain data (JSON-safe):

    {
      layout => { mode, reason, claude_layout => 0|1, claude_layout_reason,
                  project_dir => '/abs' | undef },
      memory => [ { label, scope, kind, imports => [ '/abs', ... ] }, ... ],
      settings => {                     # only in the Claude layout
        files       => [ { label, exists => 0|1, error => undef|'...' }, ... ],
        permissions => { allow => N, ask => N, deny => N,
                         additional_directories => N, default_mode => undef|'...' },
        env         => [ 'NAME', ... ],                  # names only, never values
        enabled_plugins => [ 'name@market', ... ],       # enabled ones
        hooks       => { PreToolUse => N, ... },         # matcher groups per event
        ignored     => [ { key, source }, ... ],
      },
      skills          => [ { name, source, listed => 0|1 }, ... ],
      shadowed_skills => [ { name, source, by }, ... ],
      skill_problems  => [ { file, reason }, ... ],
      plugins         => [ { name, key, scope }, ... ],
    }

C<memory> includes the F<AGENTS.md> item.

=cut

sub report {
  my ( $self ) = @_;
  my $layout = $self->layout;
  my $claude = $self->claude_layout ? 1 : 0;
  my $catalog = $self->skill_catalog;
  my $plugins = $self->plugins;
  return {
    layout => {
      mode                 => $layout->mode,
      reason               => $layout->reason,
      claude_layout        => $claude,
      claude_layout_reason => $layout->claude_layout_reason,
      project_dir          => $claude ? $layout->project_dir->stringify : undef,
    },
    memory => [ map { {
      label   => $_->{label},
      scope   => $_->{scope},
      kind    => $_->{kind},
      imports => [ @{ $_->{imports} } ],
    } } $self->instruction_items ],
    ( $self->settings ? ( settings => $self->_settings_report ) : () ),
    skills          => [ map { { name => $_->{name}, source => $_->{source}, listed => $_->{model_invocable} } } $catalog->skills ],
    shadowed_skills => [ map { { name => $_->{name}, source => $_->{source}, by => $_->{by} } } $catalog->shadowed ],
    skill_problems  => [ map { { file => $_->{file}, reason => $_->{reason} } } $catalog->problems ],
    plugins         => $plugins ? [ map { { name => $_->{name}, key => $_->{key}, scope => $_->{scope} } } @{ $plugins->plugins } ] : [],
  };
}

sub _settings_report {
  my ( $self ) = @_;
  my $s = $self->settings;
  my $p = $s->permissions;
  my $enabled = $s->enabled_plugin_map;
  my $hooks = $s->hooks;
  return {
    files       => [ map { { label => $_->{label}, exists => $_->{exists}, error => $_->{error} } } @{ $s->files } ],
    permissions => {
      ( map { $_ => scalar @{ $p->{$_} } } qw( allow ask deny additional_directories ) ),
      default_mode => $p->{default_mode} ? $p->{default_mode}{value} : undef,
    },
    env             => [ sort keys %{ $s->env } ],
    enabled_plugins => [ sort grep { $enabled->{$_} } keys %$enabled ],
    hooks           => { map { $_ => scalar @{ $hooks->{$_} } } keys %$hooks },
    ignored         => [ map { { key => $_->{key}, source => $_->{source} } } @{ $s->ignored } ],
  };
}

# A directory as reports name it: relative to root inside it, ~/... under
# the home, else absolute.
sub _root_label {
  my ( $self, $dir ) = @_;
  my $root = path($self->_real($self->root));
  my $real = path($self->_real($dir));
  return $real->relative($root)->stringify if $root->subsumes($real);
  return $self->_home_label($dir);
}

sub _home_label {
  my ( $self, $dir ) = @_;
  my $real = path($self->_real($dir));
  if (defined $self->home) {
    my $home = path($self->_real($self->home));
    return '~/'.$real->relative($home)->stringify if $home->subsumes($real);
  }
  return $real->stringify;
}

# The real path of $p as a string; for a path that does not exist, the real
# path of its nearest existing ancestor with the rest appended.
sub _real {
  my ( $self, $p ) = @_;
  my $path = path($p)->absolute;
  my @rest;
  until (-e $path || $path->is_rootdir) {
    unshift @rest, $path->basename;
    $path = $path->parent;
  }
  my $real = eval { $path->realpath } // $path;
  return ( @rest ? $real->child(@rest) : $real )->stringify;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application/context>

=item * L<Langertha::Raider::SkillTools>

=item * L<Langertha::Raider::Plugin::NestedMemory>

=back

=cut
