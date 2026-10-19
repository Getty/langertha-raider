package Langertha::Raider::Permissions;
# ABSTRACT: Internal permission policy of a raider session: mode, rules with sources, session rules
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Carp qw( croak );
use Cwd qw( realpath );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use List::Util qw( first );
use Path::Tiny;
use Scalar::Util qw( refaddr );
use URI;
use Langertha::Raider::Home;
use Langertha::Raider::Permissions::Rule;
use Langertha::Raider::ToolEffects;
use Langertha::Raider::ToolNames;

=synopsis

    # Internal to Langertha-Raider -- no API promise.
    my $policy = Langertha::Raider::Permissions->new(
      root  => $root,
      mode  => 'default',
      rules => {
        allow => [ { rule => 'Bash(npm run test:*)', source => '.claude/settings.json' } ],
        deny  => [ { rule => 'Read(./.env)',         source => '.raider/config.yml' } ],
      },
      additional_directories => [ { path => '../docs', source => '.claude/settings.json' } ],
    );

    my $verdict = $policy->decide( { name => 'bash', source => 'engine:2',
      arguments => { command => 'npm run test' } } );
    # { verdict => 'allow', by => 'rule', rule => 'Bash(npm run test:*)', source => ..., reason => ... }

    $policy->add_session_rule('Bash(make)');
    $policy->set_mode('acceptEdits');
    my $child = $policy->for_subrun;     # same mode and rules, shared session rules

=description

B<Internal module.> Its interface may change without notice.

The permission policy of one raider session (ADR 0021, building on the gate
and the approval of ADR 0005): a mode, the allow / ask / deny rules in Claude
Code syntax (L<Langertha::Raider::Permissions::Rule>) with the source of
each, the rules the person allowed for this session, and the additional
directories. L</decide> answers the canonical call the tool gate of
L<Langertha::Raider> sees with C<allow>, C<ask> or C<deny>. The policy only
decides -- asking the person, recording events and building approvals is the
application's part.

Order of a decision: a matching deny rule (from any source) refuses; in
C<bypassPermissions> everything else is allowed; in C<plan> a tool that
changes something (C<write>, C<code> or C<message> effects) is refused; a
matching ask rule asks; a matching allow rule (or session rule) allows;
without a rule the mode decides:

=over

=item C<default> -- tools that only read, or have no effect outside the run,
and the person-facing control tools (C<ask_user>, C<raider_ask_user>,
C<todo_write>, C<skill>, C<exit_plan_mode>) are allowed; everything that
writes, runs code, talks to the network or sends messages asks, and so does
every tool raider does not know (a foreign MCP tool).

=item C<acceptEdits> -- as C<default>, and C<write_file> / C<edit_file> are
allowed inside the root or an additional directory.

=item C<plan> -- as C<default> for reading and network tools; changing tools
are refused, even when an allow rule names them.

=item C<bypassPermissions> -- everything is allowed except what a deny rule
refuses.

=back

Effects come from L<Langertha::Raider::ToolEffects>, and only for raider's
own tools: a tool from a C<catalog:NAME> source, or from a source named in
L</source_servers>, is foreign, whatever its name.

=cut

my @MODES = qw( default acceptEdits plan bypassPermissions );
my %MODE  = map { $_ => 1 } @MODES;

# Tools that face the person or only steer the run: allowed without a rule,
# in plan mode too.
my %CONTROL = map { $_ => 1 } qw( ask_user raider_ask_user todo_write skill exit_plan_mode );

my %EFFECT_TEXT = (
  write   => 'changes files',
  code    => 'runs code',
  network => 'uses the network',
  message => 'sends messages',
);

has root => ( is => 'ro', isa => 'Str', required => 1 );

=attr root

The project root. Required. Relative rule paths and relative additional
directories are read against it, and so are relative path arguments, as the
file tools do.

=cut

has home => ( is => 'ro', isa => 'Str', lazy_build => 1 );

sub _build_home { Langertha::Raider::Home->home_dir }

=attr home

The home for C<~/> in rules and directories. Defaults to
L<Langertha::Raider::Home/home_dir>.

=cut

has mode => ( is => 'ro', isa => 'Str', writer => '_set_mode', default => 'default' );

=attr mode

The permission mode: C<default>, C<acceptEdits>, C<plan> or
C<bypassPermissions>. Croaks on construction with any other name; changed
with L</set_mode>.

=cut

has mode_source => ( is => 'ro', isa => 'Str', writer => '_set_mode_source', default => 'default' );

=attr mode_source

Where the mode came from (C<--permission-mode>, a settings file, ...), for
reports.

=cut

has rules => ( is => 'ro', isa => 'HashRef', default => sub { {} } );

=attr rules

The configured rules as C<< { allow => [ { rule, source } ], ask => [...], deny => [...] } >>
-- the shape of L<Langertha::Raider::Context::Settings/permissions>. Every
list keeps its order; sources are mixed freely.

=cut

has additional_directories => ( is => 'ro', isa => 'ArrayRef', default => sub { [] } );

=attr additional_directories

C<< [ { path, source } ] >>: directories outside the root the file tools may
use. C<~/x> is under the home, a relative path under the root.

=cut

has source_servers => ( is => 'ro', isa => 'HashRef', default => sub { {} } );

=attr source_servers

C<< { 'engine:N' => 'server' } >>: tool sources that are foreign MCP servers,
with the name C<mcp__server> rules use. A C<catalog:NAME> source is always
the foreign server C<NAME>; every other source (C<engine:N>, C<inline>,
C<raider>) is raider's own unless named here.

=cut

has session_rules => ( is => 'ro', isa => 'ArrayRef', default => sub { [] } );

=attr session_rules

The rules allowed for this session (L</add_session_rule>), as
L<Langertha::Raider::Permissions::Rule> objects. The array is shared with
every policy L</for_subrun> derives, so a rule allowed in a sub-run holds in
the session and the other way round. Lives in memory only.

=cut

has ignored_modes => ( is => 'ro', isa => 'ArrayRef', default => sub { [] } );

=attr ignored_modes

C<< [ { value, source, reason } ] >>: mode names from files that are not
modes, skipped by L</from_sources>. For reports.

=cut

has _file_rules => ( is => 'ro', isa => 'ArrayRef', lazy_build => 1, init_arg => undef );

sub BUILD {
  my ( $self ) = @_;
  croak __PACKAGE__.' unknown permission mode '.$self->mode unless $self->is_mode( $self->mode );
  return;
}

sub _build__file_rules {
  my ( $self ) = @_;
  my @rules;
  for my $kind (qw( deny ask allow )) {
    for my $entry ( @{ $self->rules->{$kind} // [] } ) {
      my ( $text, $source ) = ref $entry eq 'HASH' ? @{$entry}{qw( rule source )} : ( $entry, 'unknown' );
      next unless defined $text && !ref $text;
      push @rules, Langertha::Raider::Permissions::Rule->new(
        text => $text, source => $source // 'unknown', kind => $kind,
      );
    }
  }
  return \@rules;
}

sub from_sources {
  my ( $class, %arg ) = @_;
  my ( %rules, @dirs, @ignored, $mode );
  if ( my $cli = $arg{cli_mode} ) {
    croak __PACKAGE__.'->from_sources: unknown permission mode '.( $cli->{value} // 'undef' )
      unless $class->is_mode( $cli->{value} );
    $mode = $cli;
  }
  for my $source ( grep { defined } @{ $arg{sources} // [] } ) {
    push @{ $rules{$_} }, @{ $source->{$_} // [] } for qw( allow ask deny );
    push @dirs, @{ $source->{additional_directories} // [] };
    my $m = $source->{default_mode} or next;
    if ( !$class->is_mode( $m->{value} ) ) {
      push @ignored, { %$m, reason => 'not a permission mode (one of '.join( ', ', @MODES ).')' };
    }
    elsif ( !$mode ) {
      $mode = $m;
    }
  }
  return $class->new(
    root                   => $arg{root},
    ( defined $arg{home} ? ( home => $arg{home} ) : () ),
    ( $mode ? ( mode => $mode->{value}, mode_source => $mode->{source} ) : () ),
    rules                  => \%rules,
    additional_directories => \@dirs,
    ignored_modes          => \@ignored,
    ( $arg{source_servers} ? ( source_servers => $arg{source_servers} ) : () ),
    ( $arg{session_rules}  ? ( session_rules  => $arg{session_rules} )  : () ),
  );
}

=method from_sources

    my $policy = Langertha::Raider::Permissions->from_sources(
      root     => $root,
      cli_mode => { value => 'plan', source => '--permission-mode' },   # optional
      sources  => [ $config->permissions, $settings->permissions ],
    );

The policy of a session from its sources, each in the shape of
L<Langertha::Raider::Context::Settings/permissions>. The rules and
additional directories of all sources are concatenated. The mode is the
first of C<cli_mode> and the sources' C<default_mode> in the order given
that is a mode; a C<default_mode> that is none is skipped and kept in
L</ignored_modes>. Without any, C<default>. C<session_rules> and
C<source_servers> are passed on as they are (a policy read again keeps the
session's rules). Croaks on an invalid C<cli_mode> -- the command line
refuses it before.

=cut

sub report {
  my ( $self ) = @_;
  return {
    mode          => $self->mode,
    mode_source   => $self->mode_source,
    ignored_modes => [ map { { %$_ } } @{ $self->ignored_modes } ],
    rules         => { map {
      my $kind = $_;
      $kind => [ map { { rule => $_->text, source => $_->source } } grep { $_->kind eq $kind } $self->rule_list ];
    } qw( allow ask deny ) },
    invalid_rules => [ map { $_->as_hash } $self->invalid_rules ],
    additional_directories => [ $self->_directory_entries ],
  };
}

=method report

The policy for C<config explain> and C</permissions>: C<mode>,
C<mode_source>, C<ignored_modes>, C<rules> (per kind the valid rules with
their source, session rules included), C<invalid_rules> (with C<kind> and
C<error>) and C<additional_directories> (absolute, with their source).

=cut

sub modes { @MODES }

=method modes

The mode names, in display order. Callable on the class.

=cut

sub is_mode { my ( $self, $name ) = @_; defined $name && $MODE{$name} ? 1 : 0 }

=method is_mode

    Langertha::Raider::Permissions->is_mode('acceptEdits');   # 1

True for a valid mode name (exactly as Claude Code writes it).

=cut

sub rule_list {
  my ( $self ) = @_;
  return ( ( grep { $_->is_valid } @{ $self->_file_rules } ), @{ $self->session_rules } );
}

=method rule_list

Every valid rule: the configured ones (deny, ask, allow) and then the
session rules.

=cut

sub invalid_rules { grep { !$_->is_valid } @{ $_[0]->_file_rules } }

=method invalid_rules

The configured rules that could not be parsed or name an unknown tool; they
are ignored.

=cut

sub add_session_rule {
  my ( $self, $text ) = @_;
  my $rule = Langertha::Raider::Permissions::Rule->new( text => $text, source => 'session', kind => 'allow' );
  croak __PACKAGE__.'->add_session_rule: '.$rule->error.': '.$text unless $rule->is_valid;
  my $known = first { $_->text eq $rule->text } @{ $self->session_rules };
  return $known if $known;
  push @{ $self->session_rules }, $rule;
  return $rule;
}

=method add_session_rule

    my $rule = $policy->add_session_rule('Bash(make test)');

Allows what the rule names for the rest of the session (source C<session>).
Croaks on an invalid rule. Returns the rule; adding the same text again
changes nothing.

=cut

sub set_mode {
  my ( $self, $mode, $source ) = @_;
  croak __PACKAGE__.'->set_mode: unknown permission mode '.( $mode // 'undef' ) unless $self->is_mode($mode);
  my $from = $self->mode;
  $self->_set_mode($mode);
  $self->_set_mode_source( $source // 'session' );
  return $from;
}

=method set_mode

    my $from = $policy->set_mode( 'default', 'exit_plan_mode' );

Switches the mode; C<$source> (default C<session>) becomes
L</mode_source>. Returns the previous mode. Croaks on an unknown mode.

=cut

sub additional_directory_paths { map { $_->{path} } $_[0]->_directory_entries }

# The additional directories as { path (absolute), source }.
sub _directory_entries {
  my ( $self ) = @_;
  my $base = Langertha::Raider::Permissions::Rule->_lexical( path( $self->root )->absolute->stringify );
  my @out;
  for my $entry ( @{ $self->additional_directories } ) {
    my ( $p, $source ) = ref $entry eq 'HASH' ? @{$entry}{qw( path source )} : ( $entry, undef );
    next unless defined $p && length $p;
    $p = $self->home.'/'.$1 if $p =~ m{\A~/(.*)\z}s;
    $p = $self->home if $p eq '~';
    $p = $base.'/'.$p unless path($p)->is_absolute;
    push @out, { path => Langertha::Raider::Permissions::Rule->_lexical($p), source => $source // 'unknown' };
  }
  return @out;
}

=method additional_directory_paths

The additional directories as absolute paths (C<..> taken out).

=cut

sub allowed_roots {
  my ( $self ) = @_;
  my $root = Langertha::Raider::Permissions::Rule->_lexical( path( $self->root )->absolute->stringify );
  return ( $root, $self->additional_directory_paths );
}

=method allowed_roots

The root followed by the additional directories, absolute: where the file
tools may work.

=cut

sub policy_revision {
  my ( $self ) = @_;
  my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
  return sha256_hex( $json->encode({
    mode    => $self->mode,
    rules   => [ map { [ $_->kind, $_->text, $_->source ] } @{ $self->_file_rules } ],
    session => [ map { $_->text } @{ $self->session_rules } ],
    dirs    => [ $self->additional_directory_paths ],
  }) );
}

=method policy_revision

The SHA-256 (hex) over the mode, every rule with its source, the session
rules and the additional directories. An approval
(L<Langertha::Raider::Approval>) is bound to it: switching the mode or
allowing a session rule invalidates approvals given before.

=cut

sub for_subrun {
  my ( $self ) = @_;
  return ( ref $self )->new(
    root                   => $self->root,
    home                   => $self->home,
    mode                   => $self->mode,
    mode_source            => $self->mode_source,
    rules                  => $self->rules,
    additional_directories => $self->additional_directories,
    source_servers         => $self->source_servers,
    session_rules          => $self->session_rules,
  );
}

=method for_subrun

    my $policy_of_subagent = $policy->for_subrun;

The policy a sub-run (a sub-agent, a delegated task) uses: a new object with
the mode this policy has now, the same configured rules, additional
directories and source servers, and the B<same> session rules array. A mode
change of either afterwards stays with that one (a sub-agent leaving plan
mode does not take the session with it); a session rule allowed in either
holds in both. A sub-run never gets more than its parent had: there is no
argument to widen it.

=cut

#### Deciding

sub _ctx_base {
  my ( $self ) = @_;
  my $both = sub {
    my $abs  = Langertha::Raider::Permissions::Rule->_lexical( path( $_[0] )->absolute->stringify );
    my $real = realpath($abs);
    return defined $real && $real ne $abs ? [ $abs, $real ] : [ $abs ];
  };
  return { roots => $both->( $self->root ), homes => $both->( $self->home ) };
}

sub _call_origin {
  my ( $self, $call ) = @_;
  my $source = $call->{source};
  return ( 0, undef ) unless defined $source;
  return ( 0, $1 ) if $source =~ /\Acatalog:(.+)\z/s;
  return ( 0, $self->source_servers->{$source} ) if exists $self->source_servers->{$source};
  return ( 1, undef );
}

# What a call does, for the mode: control, read, network, change or unknown;
# and the effect words for a reason.
sub _call_class {
  my ( $self, $name, $builtin ) = @_;
  return ( 'unknown', [] ) unless $builtin;
  return ( 'control', [] ) if $CONTROL{$name};
  my $effects = Langertha::Raider::ToolEffects->effects_for($name) // return ( 'unknown', [] );
  my @change = grep { $_ eq 'write' || $_ eq 'code' || $_ eq 'message' } @$effects;
  return ( 'change', \@change ) if @change;
  return ( 'network', [ 'network' ] ) if grep { $_ eq 'network' } @$effects;
  return ( 'read', [] );
}

sub decide {
  my ( $self, $call ) = @_;
  croak __PACKAGE__.'->decide needs a call hash' unless ref $call eq 'HASH';
  my $name = $call->{name} // '';
  my ( $builtin, $server ) = $self->_call_origin($call);
  my $ctx   = { %{ $self->_ctx_base }, builtin => $builtin, server => $server };
  my @rules = $self->rule_list;
  my $mode  = $self->mode;

  if ( my $rule = first { $_->kind eq 'deny' && $_->matches( $call, $ctx ) } @rules ) {
    return $self->_by_rule( deny => $rule,
      "denied by rule '".$rule->text."' from ".$rule->source );
  }

  return $self->_by_mode( allow => 'bypassPermissions mode' ) if $mode eq 'bypassPermissions';

  my ( $class, $effects ) = $self->_call_class( $name, $builtin );

  return $self->_by_mode( deny => 'plan mode: '.$name.' '.join( ' and ', map { $EFFECT_TEXT{$_} } @$effects )
    .', which plan mode does not allow; present your plan with exit_plan_mode first' )
    if $mode eq 'plan' && $class eq 'change';

  if ( my $rule = first { $_->kind eq 'ask' && $_->matches( $call, $ctx ) } @rules ) {
    return $self->_by_rule( ask => $rule,
      "rule '".$rule->text."' from ".$rule->source.' asks before this call' );
  }

  if ( my @allow = $self->_allowing_rules( $call, $ctx, $builtin, \@rules ) ) {
    my %seen;
    return {
      verdict => 'allow',
      by      => 'rule',
      rule    => join( ', ', map { $_->text } @allow ),
      source  => join( ', ', grep { !$seen{$_}++ } map { $_->source } @allow ),
      reason  => 'allowed by rule '.join( ', ', map { "'".$_->text."'" } @allow ),
      mode    => $mode,
    };
  }

  return $self->_by_mode( allow => $mode.' mode' ) if $class eq 'read' || $class eq 'control';
  return $self->_by_mode( allow => 'acceptEdits mode, inside the allowed directories' )
    if $mode eq 'acceptEdits' && $builtin && $self->_edit_in_allowed_roots( $call, $ctx );

  my $what = $class eq 'unknown'
    ? $name.' is not a tool of raider'.( defined $server ? " (MCP server '".$server."')" : '' )
    : $name.' '.join( ' and ', map { $EFFECT_TEXT{$_} } @$effects );
  return $self->_by_mode( ask => $mode.' mode asks before this call: '.$what );
}

=method decide

    my $verdict = $policy->decide( { name => $tool, source => $source, arguments => \%args } );

The verdict on the canonical call: a hash with C<verdict> (C<allow>, C<ask>,
C<deny>), C<by> (C<rule> or C<mode>), C<reason> (a sentence for the person
or the model), C<mode>, and for a rule C<rule> (its text) and C<source>; for
the mode C<source> is L</mode_source>. A command of several parts that
several allow rules cover together names all of them. The shape is the one
the tool gate of L<Langertha::Raider> takes.

=cut

sub _by_rule {
  my ( $self, $verdict, $rule, $reason ) = @_;
  return {
    verdict => $verdict,
    by      => 'rule',
    rule    => $rule->text,
    source  => $rule->source,
    reason  => $reason,
    mode    => $self->mode,
  };
}

sub _by_mode {
  my ( $self, $verdict, $reason ) = @_;
  return {
    verdict => $verdict,
    by      => 'mode',
    source  => $self->mode_source,
    reason  => $reason,
    mode    => $self->mode,
  };
}

# The allow rules that together allow the call: one that matches it, or for
# raider's bash, one per part of a command of several parts.
sub _allowing_rules {
  my ( $self, $call, $ctx, $builtin, $rules ) = @_;
  my @allow = grep { $_->kind eq 'allow' } @$rules;
  if ( my $rule = first { $_->matches( $call, $ctx ) } @allow ) {
    return ( $rule );
  }
  return unless $builtin && ( $call->{name} // '' ) eq 'bash';
  my $command = ref $call->{arguments} eq 'HASH' ? $call->{arguments}{command} : undef;
  return unless defined $command && !ref $command;
  my $shell = Langertha::Raider::Permissions::Rule->shell_parts($command);
  return if $shell->{opaque} || !@{ $shell->{parts} };
  my @bash = grep { $_->family eq 'bash' } @allow;
  my ( @used, %seen );
  for my $part ( @{ $shell->{parts} } ) {
    my $rule = first { $_->covers_command_part($part) } @bash or return;
    push @used, $rule unless $seen{ refaddr $rule }++;
  }
  return @used;
}

sub _edit_in_allowed_roots {
  my ( $self, $call, $ctx ) = @_;
  my $name = $call->{name} // '';
  return 0 unless $name eq 'write_file' || $name eq 'edit_file';
  my $path = ref $call->{arguments} eq 'HASH' ? $call->{arguments}{path} : undef;
  return 0 unless defined $path && !ref $path && length $path;
  my @roots = map {
    my $real = realpath($_);
    ( $_, ( defined $real ? $real : () ) );
  } $self->allowed_roots;
  for my $p ( Langertha::Raider::Permissions::Rule->call_paths( $path, $ctx ) ) {
    return 0 unless first { $p eq $_ || index( $p, ( $_ eq '/' ? '/' : $_.'/' ) ) == 0 } @roots;
  }
  return 1;
}

#### Reading below a search root

sub read_rules_active {
  my ( $self ) = @_;
  return ( grep { $_->kind ne 'allow' && grep { $_ eq 'read_file' } @{ $_->tools } } $self->rule_list ) ? 1 : 0;
}

=method read_rules_active

True when a deny or ask rule applies to reading files (C<Read(...)>,
C<read_file>): only then can L</hides_read> hide anything.

=cut

sub hides_read {
  my ( $self, $path ) = @_;
  return $self->decide( { name => 'read_file', source => 'raider', arguments => { path => $path } } )->{verdict} ne 'allow'
    ? 1 : 0;
}

=method hides_read

    next if $policy->hides_read('/abs/path/secrets/key');

True when reading the file at the absolute C<$path> would not simply be
allowed: a deny rule refuses it or an ask rule asks. C<glob> and C<grep>
leave such files out of their results (L<Langertha::Raider::SearchTools/hider>)
instead of refusing the whole search.

=cut

#### Session rule suggestion

sub suggest_rule {
  my ( $self, $call ) = @_;
  my $name = $call->{name} // '';
  my $args = ref $call->{arguments} eq 'HASH' ? $call->{arguments} : {};
  my ( $builtin, $server ) = $self->_call_origin($call);
  unless ($builtin) {
    return unless defined $server;
    return 'mcp__'.$server.'__'.$name;
  }
  if ( $name eq 'bash' ) {
    my $command = $args->{command};
    return unless defined $command && !ref $command;
    ( my $trimmed = $command ) =~ s/\A\s+|\s+\z//g;
    return if !length $trimmed
      || Langertha::Raider::Permissions::Rule->shell_parts($trimmed)->{opaque};
    return 'Bash('.$trimmed.')';
  }
  if ( $name eq 'write_file' || $name eq 'edit_file' ) {
    my $path = $args->{path};
    return 'Edit' unless defined $path && !ref $path && length $path;
    my $ctx  = $self->_ctx_base;
    my ( $abs ) = Langertha::Raider::Permissions::Rule->call_paths( $path, $ctx );
    my $dir  = path($abs)->parent->stringify;
    my $root = $ctx->{roots}[0];
    return 'Edit(/**)' if $dir eq $root;
    return 'Edit('.substr( $dir, length($root) + 1 ).'/**)' if index( $dir, $root.'/' ) == 0;
    return 'Edit(/'.$dir.'/**)';
  }
  if ( $name eq 'web_fetch' ) {
    my $url  = $args->{url};
    my $uri  = defined $url && !ref $url ? URI->new($url) : undef;
    my $host = $uri && $uri->can('host') ? lc( $uri->host // '' ) : '';
    return length $host ? 'WebFetch(domain:'.$host.')' : 'WebFetch';
  }
  return Langertha::Raider::ToolNames->claude_name($name) // $name;
}

=method suggest_rule

    my $text = $policy->suggest_rule($call);   # 'Bash(make test)'

The rule the person would allow with "yes, for this session": C<bash> ->
C<Bash(EXACT COMMAND)>; C<write_file> / C<edit_file> -> C<Edit(DIR/**)> for
the directory of the file (C<Edit(/**)> in the root, C<Edit(//ABS/**)>
outside it); C<web_fetch> -> C<WebFetch(domain:HOST)>; a foreign tool ->
C<mcp__SERVER__TOOL>; any other tool -> its name. Returns nothing when no
rule can name the call safely: a command with substitutions, redirections
into files or heredocs, or a foreign tool whose server has no
name.

=cut

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Permissions::Rule>

=item * L<Langertha::Raider::Approval>

=item * L<Langertha::Raider::ToolEffects>

=back

=cut
