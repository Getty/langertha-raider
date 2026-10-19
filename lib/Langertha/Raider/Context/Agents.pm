package Langertha::Raider::Context::Agents;
# ABSTRACT: Internal catalogue of the agent files a run can start as subagents
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Module::Runtime ();
use Path::Tiny;
use Scalar::Util qw( blessed );
use Langertha::Raider::Context::Frontmatter;
use Langertha::Raider::ToolEffects;
use Langertha::Raider::ToolNames;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $agents = Langertha::Raider::Context::Agents->new(
      roots => [
        { dir => "$root/.raider/agents", source => '.raider/agents' },
        { dir => "$root/.claude/agents", source => '.claude/agents' },
      ],
      plugins => [ { name => 'superpowers', dirs => [ @agent_dirs ] } ],
    );
    my $agent = $agents->find('raider-worker');
    my $model = $agents->resolve_model($agent->{model},
      engine_class => 'Langertha::Engine::Anthropic', engine_name => 'anthropic');

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The agent catalogue of ADR 0020 E<sect>1 and E<sect>2. It takes agent
roots in precedence order and the agent paths of plugins, and knows every
agent's name, description, instructions, tool restriction, model and
declared skills. Which roots exist is the caller's decision
(L<Langertha::Raider::Context/agent_roots>); a root that does not exist is
skipped silently. Nothing here starts an agent.

An agent is a plain hash ref:

    {
      name          => 'raider-worker',
      description   => 'Default Raider worker ...',
      file          => '/abs/.claude/agents/raider-worker.md',   # undef for the built-in
      dir           => '/abs/.claude/agents',                    # the file's directory
      source        => '.claude/agents',     # root label, 'plugin NAME' or 'built-in'
      body          => 'You are ...',        # the instructions, without frontmatter
      frontmatter   => { ... },              # every key kept
      tools         => undef | [ 'read_file', 'bash', ... ],   # undef: every tool
      disallowed    => [ 'write_file', ... ],
      unknown_tools => [ 'NotebookEdit', ... ],   # tools/disallowedTools names not mapped
      model         => 'sonnet' | undef,     # as written; see resolve_model
      skills        => [ 'getty-perl-core', ... ],   # declared, not resolved
      ignored_keys  => [ 'color', ... ],     # frontmatter keys raider does not use
      builtin       => 0 | 1,
    }

=over

=item * B<Files.> Every root and every plugin directory is walked
recursively for F<*.md> -- the files of a directory sorted by name, then its
subdirectories sorted by name (the order of the briefing hook). Hidden files
and directories (a leading C<.>) are skipped. A plugin path may also be one
F<*.md> file.

=item * B<Frontmatter.> Read by L<Langertha::Raider::Context::Frontmatter>
(YAML, else the lenient line reader). A file without a C<description> is
not an agent: it is skipped and listed in L</problems>, as are unreadable
files.

=item * B<Name.> The frontmatter C<name>, else the file name without
F<.md>. Plugin agents are C<plugin:name>.

=item * B<Tools.> C<tools> and C<disallowedTools> take a comma-separated
string or a list. A Claude Code name goes through
L<Langertha::Raider::ToolNames> (C<Read> -> C<read_file>); a raider name --
one of L<Langertha::Raider::ToolNames/raider_names> or of the built-in tool
table L<Langertha::Raider::ToolEffects/tool_names> (C<perl_eval>,
C<raider_*>, ...) -- is taken as it is; C<mcp__*> passes through. Any other
name is ignored and listed in C<unknown_tools>. C<tools> absent, empty or
C<*> means every tool of the caller; a list whose names are all unknown
means none. Names are unique, in the order written.

=item * B<Skills.> Claude Code's top-level C<skills> first, then
C<briefing.skills>; a string is split on commas, a C<[a, b]> flow left as a
string by the lenient reader too; each name once.

=item * B<Precedence.> Roots in the given order, then plugins, then the
built-in C<general-purpose>. The first agent of a name wins; later ones are
listed by L</shadowed>, the built-in included when a file shadows it.

=back

=attr roots

Agent roots, highest precedence first. Required. Each a hash ref
C<< { dir => '/abs/dir', source => 'label' } >>.

=cut

has roots => (
  is       => 'ro',
  isa      => 'ArrayRef[HashRef]',
  required => 1,
);

=attr plugins

Plugin agent paths, after all roots. Defaults to none. Each a hash ref
C<< { name => 'plugin', dirs => [ '/abs/agents', '/abs/x.md', ... ] } >> --
the name and L<Langertha::Raider::Context::Plugins/agent_dirs> of a plugin.

=cut

has plugins => (
  is      => 'ro',
  isa     => 'ArrayRef[HashRef]',
  default => sub { [] },
);

sub frontmatter_class { 'Langertha::Raider::Context::Frontmatter' }
sub tool_names_class  { 'Langertha::Raider::ToolNames' }
sub tool_effects_class { 'Langertha::Raider::ToolEffects' }

# The frontmatter keys raider reads; every other one is listed as ignored.
my %USED_KEY = map { $_ => 1 } qw( name description tools disallowedTools model skills briefing );

=method builtin_name

The name of the built-in agent: C<general-purpose>.

=method builtin_description

Its description, Claude Code's word for word.

=method builtin_body

Its instructions: a short general-purpose system prompt.

=cut

sub builtin_name { 'general-purpose' }

sub builtin_description {
  'General-purpose agent for researching complex questions, searching for code, and executing'
    .' multi-step tasks. When you are searching for a keyword or file and are not confident that'
    .' you will find the right match in the first few tries use this agent to perform the search'
    .' for you.';
}

sub builtin_body { <<'EOM' }
You are an agent for raider. Given the task below, use the tools available to
complete it. Do what has been asked; nothing more, nothing less.

- Search broadly when you do not know where something lives; try several
  names and places before you conclude it is not there.
- Read before you change anything. Prefer editing existing files to creating
  new ones.
- When you are done, answer with a concise report of what you did and found,
  with absolute file paths. It goes back to the agent that started you, which
  sees nothing else of your work.
EOM

has _catalog => (
  is         => 'ro',
  isa        => 'HashRef',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build__catalog {
  my ( $self ) = @_;
  my %cat = ( agents => [], shadowed => [], problems => [], by_name => {} );

  for my $root (@{ $self->roots }) {
    my $dir = $root->{dir};
    next unless defined $dir && -d $dir;
    $self->_add_file(\%cat, $_, $root->{source}, '') for $self->_walk(path($dir)->absolute);
  }

  for my $plugin (@{ $self->plugins }) {
    for my $p (@{ $plugin->{dirs} // [] }) {
      my $path = path($p)->absolute;
      my @files = -d $path ? $self->_walk($path) : -f $path ? ( $path ) : ();
      $self->_add_file(\%cat, $_, 'plugin '.$plugin->{name}, $plugin->{name}.':') for @files;
    }
  }

  my $builtin = $self->builtin_name;
  if (my $winner = $cat{by_name}{$builtin}) {
    push @{ $cat{shadowed} }, { name => $builtin, source => 'built-in', file => undef, by => $winner->{source} };
  }
  else {
    my $agent = {
      name          => $builtin,
      description   => $self->builtin_description,
      file          => undef,
      dir           => undef,
      source        => 'built-in',
      body          => $self->builtin_body,
      frontmatter   => {},
      tools         => undef,
      disallowed    => [],
      unknown_tools => [],
      model         => undef,
      skills        => [],
      ignored_keys  => [],
      builtin       => 1,
    };
    push @{ $cat{agents} }, $agent;
    $cat{by_name}{$builtin} = $agent;
  }
  return \%cat;
}

# Every *.md below $dir: the files of a directory sorted by name, then its
# subdirectories; hidden entries skipped, each real directory once.
sub _walk {
  my ( $self, $dir, $seen ) = @_;
  $seen //= {};
  my $real = eval { $dir->realpath->stringify } // $dir->stringify;
  return if $seen->{$real}++;
  my @children = sort { $a->basename cmp $b->basename } grep { $_->basename !~ /\A\./ } eval { $dir->children };
  return (
    ( grep { -f $_ && $_->basename =~ /\.md\z/ } @children ),
    ( map { $self->_walk($_, $seen) } grep { -d $_ } @children ),
  );
}

sub _add_file {
  my ( $self, $cat, $file, $source, $prefix ) = @_;
  my $text = eval { $file->slurp_utf8 };
  unless (defined $text) {
    push @{ $cat->{problems} }, { file => $file->stringify, reason => 'unreadable' };
    return;
  }
  my ( $fm, $body, $problem ) = $self->frontmatter_class->parse($text);
  my $desc = $fm->{description};
  unless (defined $desc && !ref $desc && $desc =~ /\S/) {
    push @{ $cat->{problems} }, {
      file   => $file->stringify,
      reason => ( defined $problem ? $problem.'; ' : '' ).'no description: not an agent',
    };
    return;
  }
  $desc =~ s/\s+/ /g;
  $desc =~ s/\A | \z//g;
  my $fm_name = $fm->{name};
  my $name = $prefix.( defined $fm_name && !ref $fm_name && $fm_name =~ /\S/
    ? $fm_name =~ s/\A\s+|\s+\z//gr
    : $file->basename(qr/\.md\z/) );

  if (my $winner = $cat->{by_name}{$name}) {
    push @{ $cat->{shadowed} }, { name => $name, source => $source, file => $file->stringify, by => $winner->{source} };
    return;
  }

  my @unknown;
  my $tools = $self->_tool_names($fm->{tools}, \@unknown);
  my $disallowed = $self->_tool_names($fm->{disallowedTools}, \@unknown) // [];
  my %u;
  my $briefing = $fm->{briefing};
  my $model = $fm->{model};
  my $agent = {
    name          => $name,
    description   => $desc,
    file          => $file->stringify,
    dir           => $file->parent->stringify,
    source        => $source,
    body          => $body,
    frontmatter   => $fm,
    tools         => $tools,
    disallowed    => $disallowed,
    unknown_tools => [ grep { !$u{$_}++ } @unknown ],
    model         => defined $model && !ref $model && $model =~ /\S/ ? $model =~ s/\A\s+|\s+\z//gr : undef,
    skills        => $self->_unique( map { $self->_name_list($_) }
      $fm->{skills}, ( ref $briefing eq 'HASH' ? $briefing->{skills} : () ) ),
    ignored_keys  => [ sort grep { !$USED_KEY{$_} } keys %$fm ],
    builtin       => 0,
  };
  push @{ $cat->{agents} }, $agent;
  $cat->{by_name}{$name} = $agent;
  return;
}

# A tools / disallowedTools value as raider names: undef for every tool
# (absent, empty, '*'), else the mapped names; unmappable ones are pushed
# onto @$unknown.
sub _tool_names {
  my ( $self, $value, $unknown ) = @_;
  my @names = $self->_name_list($value);
  return if !@names || grep { $_ eq '*' } @names;
  my @out;
  for my $n (@names) {
    my $raider = $self->raider_tool_name($n);
    if (defined $raider) { push @out, $raider } else { push @$unknown, $n }
  }
  return $self->_unique(@out);
}

=method raider_tool_name

    my $name = $agents->raider_tool_name('Read');   # 'read_file'

The raider tool an agent file's tool name means (see L</DESCRIPTION>), or
C<undef> for a name that is neither a Claude Code name of the table, a raider
tool nor C<mcp__*>.

=cut

sub raider_tool_name {
  my ( $self, $name ) = @_;
  return unless defined $name && !ref $name && length $name;
  my $mapped = $self->tool_names_class->raider_name($name);
  return $mapped if defined $mapped;
  my %known = map { $_ => 1 } $self->tool_names_class->raider_names, $self->tool_effects_class->tool_names;
  return $known{$name} ? $name : undef;
}

# Names from a string (comma-separated, an optional [ ] flow around it) or
# a list of strings; trimmed, empty ones dropped.
sub _name_list {
  my ( $self, $value ) = @_;
  return () unless defined $value;
  my @items;
  if (ref $value eq 'ARRAY') {
    @items = grep { defined && !ref } @$value;
  }
  elsif (!ref $value) {
    ( my $s = $value ) =~ s/\A\s*\[(.*)\]\s*\z/$1/s;
    @items = split /,/, $s;
  }
  my @out;
  for my $item (@items) {
    ( my $n = $item ) =~ s/\A\s+|\s+\z//g;
    $n =~ s/\A(["'])(.*)\1\z/$2/s;
    push @out, $n if length $n;
  }
  return @out;
}

sub _unique {
  my ( $self, @names ) = @_;
  my %seen;
  return [ grep { !$seen{$_}++ } @names ];
}

=method agents

    for my $a ($agents->agents) { say $a->{name}.' ('.$a->{source}.')' }

Every agent that won its name, in precedence order: roots in the given
order, plugins in the given order, the built-in last.

=method shadowed

Agents that lost their name to an earlier one, each
C<< { name, source, file, by } >> -- C<by> is the winner's C<source>. A
shadowed built-in has C<file> C<undef>.

=method problems

Agent files that are not agents -- unreadable, or without a description
(with the frontmatter error when there was one) -- each
C<< { file, reason } >>.

=cut

sub agents   { @{ $_[0]->_catalog->{agents} } }
sub shadowed { @{ $_[0]->_catalog->{shadowed} } }
sub problems { @{ $_[0]->_catalog->{problems} } }

=method find

    my $agent = $agents->find('general-purpose');

The agent of exactly that name, or C<undef>.

=cut

sub find {
  my ( $self, $name ) = @_;
  return unless defined $name;
  return $self->_catalog->{by_name}{$name};
}

=method model_aliases

    my $table = $agents->model_aliases;   # { opus => 'claude-opus-5-5', ... }

The alias table of ADR 0020 E<sect>5, a new hash ref.

=method anthropic_class

The engine class a model alias needs: C<Langertha::Engine::Anthropic> (and
its subclasses), not the other Anthropic-dialect engines.

=cut

sub model_aliases {
  return {
    opus   => 'claude-opus-5-5',
    sonnet => 'claude-sonnet-5-5',
    haiku  => 'claude-haiku-5-5',
  };
}

sub anthropic_class { 'Langertha::Engine::Anthropic' }

=method resolve_model

    my $r = $agents->resolve_model('sonnet',
      engine_class => 'Langertha::Engine::Anthropic',   # or an engine object
      engine_name  => 'anthropic',                      # for the reason text
      agent_models => { sonnet => 'claude-sonnet-4-6' }, # config agent_models
    );
    # { model => 'claude-sonnet-4-6' }
    # or { inherit => 1, reason => 'model sonnet: inherited, engine openai is not the Anthropic API' }

What an agent's C<model> means under the caller's engine (ADR 0020
E<sect>5); never an error. Absent or C<inherit>: inherit. An alias
(C<opus>, C<sonnet>, C<haiku>, any case) goes through L</model_aliases>,
each overridable by C<agent_models> (other keys there are ignored); a full
C<claude-*> id stays as it is. Either gives C<model> only when the engine
class is (a subclass of) L</anthropic_class>; in every other case the agent
inherits and C<reason> says why. Builds nothing; loads the engine class
when given as a name.

=cut

sub resolve_model {
  my ( $self, $model, %arg ) = @_;
  return { inherit => 1, reason => 'no model set' } unless defined $model && length $model;
  return { inherit => 1, reason => 'model inherit' } if $model eq 'inherit';
  my $table = $self->model_aliases;
  my $over = $arg{agent_models};
  if (ref $over eq 'HASH') {
    for my $alias (grep { exists $table->{$_} } keys %$over) {
      my $v = $over->{$alias};
      $table->{$alias} = $v if defined $v && !ref $v && length $v;
    }
  }
  my $target = $table->{ lc $model } // ( $model =~ /\Aclaude-/ ? $model : undef );
  return { inherit => 1, reason => 'model '.$model.': inherited, not an alias ('
    .join(', ', sort keys %$table).') or a claude-* model id' } unless defined $target;
  my $class = $arg{engine_class};
  my $engine = $arg{engine_name} // ( blessed $class ? ref $class : $class ) // 'unknown';
  return { inherit => 1, reason => 'model '.$model.': inherited, engine '.$engine.' is not the Anthropic API' }
    unless $self->_is_anthropic($class);
  return { model => $target };
}

sub _is_anthropic {
  my ( $self, $class ) = @_;
  return 0 unless defined $class;
  return $class->isa($self->anthropic_class) ? 1 : 0 if blessed $class;
  return 0 if ref $class || !eval { Module::Runtime::require_module($class); 1 };
  return $class->isa($self->anthropic_class) ? 1 : 0;
}

=method report

    my $r = $agents->report(engine_class => $class, engine_name => 'openai', agent_models => {});

What C<config explain> shows of the agents, plain data (JSON-safe):

    {
      agents => [ {
        name, source, file,                 # file undef for the built-in
        tools      => '*' | [ 'read_file', ... ],
        disallowed => [ ... ],
        model      => { declared => 'sonnet' | undef, model => '...' }
                    | { declared => ..., inherit => 1, reason => '...' },
        skills        => [ ... ],           # declared
        unknown_tools => [ ... ],
        ignored_keys  => [ ... ],
      }, ... ],
      shadowed => [ { name, source, file, by }, ... ],
      problems => [ { file, reason }, ... ],
    }

The arguments go to L</resolve_model>.

=cut

sub report {
  my ( $self, %arg ) = @_;
  return {
    agents => [ map { {
      name          => $_->{name},
      source        => $_->{source},
      file          => $_->{file},
      tools         => defined $_->{tools} ? [ @{ $_->{tools} } ] : '*',
      disallowed    => [ @{ $_->{disallowed} } ],
      model         => { declared => $_->{model}, %{ $self->resolve_model($_->{model}, %arg) } },
      skills        => [ @{ $_->{skills} } ],
      unknown_tools => [ @{ $_->{unknown_tools} } ],
      ignored_keys  => [ @{ $_->{ignored_keys} } ],
    } } $self->agents ],
    shadowed => [ map { { %$_ } } $self->shadowed ],
    problems => [ map { { %$_ } } $self->problems ],
  };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Context/agent_catalog>

=item * L<Langertha::Raider::Context::Plugins/agent_dirs>

=item * L<Langertha::Raider::ToolNames>

=back

=cut
