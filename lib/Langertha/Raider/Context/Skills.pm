package Langertha::Raider::Context::Skills;
# ABSTRACT: Internal catalogue of the skills raider lists and loads on demand
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Path::Tiny;
use YAML::PP ();

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $skills = Langertha::Raider::Context::Skills->new(
      roots => [
        { dir => "$root/.raider/skills", source => '.raider/skills', layout => 'skills' },
        { dir => "$root/my-skills",      source => '--skills my-skills', layout => 'flat' },
      ],
      plugins => [ { name => 'superpowers', dirs => [ @skill_dirs ] } ],
    );
    my $prompt = $skills->prompt_text;            # undef when nothing is listed
    my $text   = $skills->tool_text('pdf', 'report.pdf');

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The skill catalogue of ADR 0019 §4. It takes skill roots in precedence
order and the skill directories of plugins, and knows every skill's name,
description and body. Which roots exist in which layout mode is the
caller's decision; this module only reads what it is given. A root or
skill directory that does not exist is skipped silently.

A skill is a plain hash ref:

    {
      name            => 'pdf',               # the identifier the model calls
      description     => 'Work with PDF files ...',
      dir             => '/abs/skills/pdf',   # base directory
      file            => '/abs/skills/pdf/SKILL.md',
      source          => '.claude/skills',    # root label, or 'plugin superpowers'
      frontmatter     => { name => 'pdf', description => '...', ... },   # every key kept
      model_invocable => 1,                   # 0 iff disable-model-invocation is true
    }

=over

=item * B<Name.> In the C<skills> layout the skill directory's name, as
Claude Code uses it as the identifier. A frontmatter C<name> that differs
stays in C<frontmatter> but does not rename the skill. In the C<flat>
layout the file name without F<.md>. Plugin skills are
C<E<lt>pluginE<gt>:E<lt>dirE<gt>>.

=item * B<Description.> The frontmatter C<description> (whitespace
collapsed), else the first non-empty line of the body that is not a
Markdown heading, trimmed and cut to 250 characters.

=item * B<Frontmatter.> A leading C<---> ... C<---> block, parsed as YAML.
What YAML rejects but Claude Code reads -- typically an unquoted C<: >
inside a description -- is read line by line instead: C<key: value> at
column 0 (the value is everything after the first C<: >, trimmed, outer
quotes stripped; C<true> / C<false> are booleans for
C<disable-model-invocation> and C<user-invocable>), indented lines continue
the previous key (joined with a space, C<- item> lines make a list). Only
when that finds no key either, or the YAML is not a mapping, the frontmatter
is empty and L</problems> gets an entry; the skill is still loaded.

=item * B<Precedence.> Roots in the given order, then plugins. The first
skill of a name wins; later ones are reported by L</shadowed>. Plugin
names carry a C<:>, so they never meet a root skill.

=back

=attr roots

Skill roots, highest precedence first. Required. Each a hash ref:

    { dir => '/abs/dir', source => 'label', layout => 'skills' | 'flat' }

C<skills>: a directory of skill directories, each with a F<SKILL.md>.
C<flat>: a directory of F<*.md> files, each one skill (the old
C<--skills DIR> behaviour); without top-level F<*.md> files it holds no
skills.

=cut

has roots => (
  is       => 'ro',
  isa      => 'ArrayRef[HashRef]',
  required => 1,
);

=attr plugins

Plugin skill directories, after all roots. Defaults to none. Each a hash
ref C<< { name => 'plugin', dirs => [ '/abs/skill/dir', ... ] } >> -- the
name and L<Langertha::Raider::Context::Plugins/skill_dirs> of a plugin.

=cut

has plugins => (
  is      => 'ro',
  isa     => 'ArrayRef[HashRef]',
  default => sub { [] },
);

# The longest fallback description taken from a body line.
sub description_limit { 250 }

has _catalog => (
  is         => 'ro',
  isa        => 'HashRef',
  init_arg   => undef,
  lazy_build => 1,
);

sub _build__catalog {
  my ( $self ) = @_;
  my %cat = ( skills => [], shadowed => [], problems => [], by_name => {}, body => {} );

  for my $root (@{ $self->roots }) {
    my $dir = $root->{dir};
    next unless defined $dir && -d $dir;
    my $base = path($dir)->absolute;
    my $layout = $root->{layout} // 'skills';
    my @found;
    if ($layout eq 'flat') {
      @found = map { [ $_->basename(qr/\.md\z/), $_, $base ] }
        grep { -f $_ } $base->children(qr/\.md\z/);
    }
    else {
      @found = map { [ $_->basename, $_->child('SKILL.md'), $_ ] }
        grep { -d $_ && -f $_->child('SKILL.md') } $base->children;
    }
    $self->_add(\%cat, @$_, $root->{source}) for sort { $a->[0] cmp $b->[0] } @found;
  }

  for my $plugin (@{ $self->plugins }) {
    for my $d (@{ $plugin->{dirs} // [] }) {
      my $sd = path($d)->absolute;
      next unless -f $sd->child('SKILL.md');
      $self->_add(\%cat, $plugin->{name}.':'.$sd->basename, $sd->child('SKILL.md'), $sd,
        'plugin '.$plugin->{name});
    }
  }
  return \%cat;
}

sub _add {
  my ( $self, $cat, $name, $file, $dir, $source ) = @_;
  if (my $winner = $cat->{by_name}{$name}) {
    push @{ $cat->{shadowed} }, {
      name   => $name,
      source => $source,
      file   => $file->stringify,
      by     => $winner->{source},
    };
    return;
  }
  my $text = eval { $file->slurp_utf8 };
  unless (defined $text) {
    push @{ $cat->{problems} }, { file => $file->stringify, reason => 'unreadable' };
    return;
  }
  my ( $fm, $body ) = $self->_split($text, $file, $cat->{problems});
  my $skill = {
    name            => $name,
    description     => $self->_description($fm, $body),
    dir             => $dir->stringify,
    file            => $file->stringify,
    source          => $source,
    frontmatter     => $fm,
    model_invocable => $self->_is_true($fm->{'disable-model-invocation'}) ? 0 : 1,
  };
  push @{ $cat->{skills} }, $skill;
  $cat->{by_name}{$name} = $skill;
  $cat->{body}{$name} = $body;
  return;
}

# ( frontmatter hashref, body ) of a skill file. The body loses the
# frontmatter and its leading blank lines.
sub _split {
  my ( $self, $text, $file, $problems ) = @_;
  my $fm = {};
  if ($text =~ s/\A---[ \t]*\r?\n(.*?)^---[ \t]*(?:\r?\n|\z)//ms) {
    my $yaml = $1;
    my $data = eval { YAML::PP->new->load_string($yaml) };
    if (my $err = $@) {
      if (my $lenient = $self->_lenient_frontmatter($yaml)) {
        $fm = $lenient;
      }
      else {
        my ( $line ) = grep { /\S/ } split /\n/, "$err";
        $line //= 'syntax error';
        $line =~ s/ at (?:(?! at ).)+ line \d+\.?\z//;
        push @$problems, { file => $file->stringify, reason => 'invalid frontmatter: '.$line };
      }
    }
    elsif (ref $data eq 'HASH') {
      $fm = $data;
    }
    elsif (defined $data) {
      push @$problems, { file => $file->stringify, reason => 'frontmatter is not a mapping' };
    }
  }
  $text =~ s/\A(?:[ \t]*\r?\n)+//;
  return ( $fm, $text );
}

# The frontmatter keys whose true / false the line parser reads as booleans.
my %BOOL_KEY = map { $_ => 1 } qw( disable-model-invocation user-invocable );

# The frontmatter YAML rejects but Claude Code reads (an unquoted ': ' in a
# description): 'key: value' lines at column 0 -- the value is everything
# after the first ': ', trimmed, surrounding quotes stripped; indented lines
# continue the previous key (joined with a space), '- item' lines make it a
# list; a '|' / '>' block becomes its lines joined with spaces. Undef when
# no key is found.
sub _lenient_frontmatter {
  my ( $self, $yaml ) = @_;
  my ( %fm, $key );
  for my $line (split /\r?\n/, $yaml) {
    next unless $line =~ /\S/;
    if ($line =~ /\A([A-Za-z0-9_][\w.-]*):(?:[ \t]+(.*?))?[ \t]*\z/) {
      $key = $1;
      my $value = $2 // '';
      $value = '' if $value =~ /\A[|>][+-]?\z/;
      $fm{$key} = length $value ? $self->_lenient_value($key, $value) : undef;
      next;
    }
    next if $line =~ /\A#/ || !defined $key || $line !~ /\A[ \t]+(.*?)[ \t]*\z/;
    my $more = $1;
    if ($more =~ /\A-[ \t]+(.*)\z/ && ( !defined $fm{$key} || ref $fm{$key} eq 'ARRAY' )) {
      push @{ $fm{$key} }, $self->_unquote($1);
    }
    elsif (!ref $fm{$key}) {
      $fm{$key} = defined $fm{$key} && length $fm{$key} ? $fm{$key}.' '.$more : $more;
    }
  }
  return %fm ? \%fm : undef;
}

sub _lenient_value {
  my ( $self, $key, $value ) = @_;
  return $value eq 'true' ? !!1 : !!0 if $BOOL_KEY{$key} && $value =~ /\A(?:true|false)\z/;
  return $self->_unquote($value);
}

sub _unquote {
  my ( $self, $value ) = @_;
  $value =~ s/\A(["'])(.*)\1\z/$2/s;
  return $value;
}

sub _description {
  my ( $self, $fm, $body ) = @_;
  my $desc = $fm->{description};
  if (defined $desc && !ref $desc && $desc =~ /\S/) {
    $desc =~ s/\s+/ /g;
    $desc =~ s/\A | \z//g;
    return $desc;
  }
  for my $line (split /\r?\n/, $body) {
    next unless $line =~ /\S/;
    next if $line =~ /\A\s*#/;
    $line =~ s/\A\s+|\s+\z//g;
    my $limit = $self->description_limit;
    $line = substr($line, 0, $limit - 3).'...' if length $line > $limit;
    return $line;
  }
  return '';
}

# YAML true: a boolean object, or the plain true/yes/1 a schema may leave.
sub _is_true {
  my ( $self, $v ) = @_;
  return 0 unless defined $v;
  return $v ? 1 : 0 if ref $v;
  return $v =~ /\A(?:true|yes|on|1)\z/i ? 1 : 0;
}

=method skills

    for my $s ($skills->skills) { say $s->{name}.' ('.$s->{source}.')' }

Every skill that won its name, in precedence order: roots in the given
order, sorted by name inside a root, then the plugins in the given order.
Model-invocable or not.

=method shadowed

    for my $s ($skills->shadowed) { say $s->{name}.' in '.$s->{source}.' shadowed by '.$s->{by} }

Skills that lost their name to an earlier one, each
C<< { name, source, file, by } >> -- C<by> is the winner's C<source>.

=method problems

    warn $_->{file}.': '.$_->{reason}."\n" for $skills->problems;

Skill files that could not be read (not loaded) or whose frontmatter is
broken (loaded with an empty frontmatter), each C<< { file, reason } >>.

=cut

sub skills   { @{ $_[0]->_catalog->{skills} } }
sub shadowed { @{ $_[0]->_catalog->{shadowed} } }
sub problems { @{ $_[0]->_catalog->{problems} } }

=method find

    my $skill = $skills->find('/pdf');   # or 'pdf', 'superpowers:brainstorming'

The skill of exactly that name (a leading C</> is ignored), or C<undef>.
Finds skills that are not model-invocable too.

=cut

sub find {
  my ( $self, $name ) = @_;
  return unless defined $name;
  $name =~ s{\A/}{};
  return $self->_catalog->{by_name}{$name};
}

=method listed

    my @offered = $skills->listed;

The L</skills> the model may see and load: those with C<model_invocable>.

=cut

sub listed { grep { $_->{model_invocable} } $_[0]->skills }

=method body

    my $md = $skills->body('pdf');

The skill file's text without the frontmatter and leading blank lines, or
C<undef> for an unknown name.

=cut

sub body {
  my ( $self, $name ) = @_;
  my $skill = $self->find($name) or return;
  return $self->_catalog->{body}{ $skill->{name} };
}

=method tool_text

    my $text = $skills->tool_text('pdf', 'report.pdf');

What the C<skill> tool returns (the shape of Claude Code's Skill tool), or
C<undef> for an unknown name:

    Base directory for this skill: /abs/skills/pdf

    <body>

Every C<$ARGUMENTS> in the body is replaced by C<$args>; without C<$args>
(undefined or empty) by nothing, as Claude Code does. When the body has no
C<$ARGUMENTS> and C<$args> is given, C<ARGUMENTS: $args> is appended after
a blank line.

=cut

sub tool_text {
  my ( $self, $name, $args ) = @_;
  my $skill = $self->find($name) or return;
  my $body = $self->body($name);
  my $have = defined $args && length $args;
  my $value = $have ? "$args" : '';
  if ($body =~ /\$ARGUMENTS/) {
    $body =~ s/\$ARGUMENTS/$value/g;
  }
  elsif ($have) {
    $body =~ s/\s+\z//;
    $body .= "\n\nARGUMENTS: ".$value;
  }
  return 'Base directory for this skill: '.$skill->{dir}."\n\n".$body;
}

=method prompt_text

    my $block = $skills->prompt_text;

The system-prompt block that lists the L</listed> skills, or C<undef> when
none is listed:

    Skills: specialised instructions loaded on demand. When a task matches a
    skill's description, call the `skill` tool with its name BEFORE acting,
    then follow what it returns. Available skills:
    - pdf: Work with PDF files ...
    - superpowers:brainstorming: ...

(the first paragraph is one line). A skill without description is listed
by its name alone.

=cut

sub prompt_text {
  my ( $self ) = @_;
  my @listed = $self->listed or return;
  return join "\n",
    'Skills: specialised instructions loaded on demand. When a task matches a skill\'s'
      .' description, call the `skill` tool with its name BEFORE acting, then follow what it'
      .' returns. Available skills:',
    map { '- '.$_->{name}.( length $_->{description} ? ': '.$_->{description} : '' ) } @listed;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::SkillTools>

=item * L<Langertha::Raider::Context::Plugins>

=back

=cut
