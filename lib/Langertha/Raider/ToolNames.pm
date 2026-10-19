package Langertha::Raider::ToolNames;
# ABSTRACT: Internal table of Claude Code tool names and the raider tools they stand for
our $VERSION = '0.504';
use strict;
use warnings;
use Carp qw( croak );

=description

B<Internal module.> Its interface may change without notice.

One place that says which raider tool a Claude Code tool name means. The
Claude-mode surfaces use it wherever a Claude Code name reaches raider: an
agent file's C<tools:> and C<disallowedTools:> list, a permission rule such as
C<Bash(npm run test:*)>, a hook matcher, a Claude Code session converted into
a scenario.

    Read -> read_file        Write -> write_file     Edit, MultiEdit -> edit_file
    Bash -> bash             Glob -> glob            Grep -> grep
    LS -> list_files         WebFetch -> web_fetch   WebSearch -> web_search
    TodoWrite -> todo_write  Task, Agent -> agent    Skill -> skill
    AskUserQuestion -> ask_user                      ExitPlanMode -> exit_plan_mode

A name C<mcp__server__tool> is an MCP tool and passes through unchanged:
raider addresses MCP tools the same way. Any other name is unknown --
L</raider_name> returns undef; the table never guesses.

The table says nothing about whether the raider tool exists yet (C<agent>,
C<skill>, C<exit_plan_mode> and the web tools arrive with their own steps);
it names the target a Claude Code tool will have. C<MultiEdit> and C<Edit>
both mean C<edit_file> and C<Task> and C<Agent> both mean C<agent>, so the
way back (L</claude_name>) answers with the current name: C<Edit> and
C<Agent>.

=cut

my %RAIDER = (
  Read            => 'read_file',
  Write           => 'write_file',
  Edit            => 'edit_file',
  MultiEdit       => 'edit_file',
  Bash            => 'bash',
  Glob            => 'glob',
  Grep            => 'grep',
  LS              => 'list_files',
  WebFetch        => 'web_fetch',
  WebSearch       => 'web_search',
  TodoWrite       => 'todo_write',
  Task            => 'agent',
  Agent           => 'agent',
  Skill           => 'skill',
  AskUserQuestion => 'ask_user',
  ExitPlanMode    => 'exit_plan_mode',
);

# The way back: the current Claude Code name of each raider tool.
my %CLAUDE = (
  read_file      => 'Read',
  write_file     => 'Write',
  edit_file      => 'Edit',
  bash           => 'Bash',
  glob           => 'Glob',
  grep           => 'Grep',
  list_files     => 'LS',
  web_fetch      => 'WebFetch',
  web_search     => 'WebSearch',
  todo_write     => 'TodoWrite',
  agent          => 'Agent',
  skill          => 'Skill',
  ask_user       => 'AskUserQuestion',
  exit_plan_mode => 'ExitPlanMode',
);

# The arguments that carry another name: raider name => Claude name.
my %ARG_NAME = (
  read_file  => { path => 'file_path' },
  write_file => { path => 'file_path' },
  edit_file  => { path => 'file_path' },
);

=head2 Arguments

The tools also name some arguments differently. L</claude_input> turns a
raider tool's arguments into the Claude Code tool's (what a hook gets as
C<tool_input>), L</raider_input> goes the way back (a hook's
C<updatedInput>):

    read_file, write_file, edit_file   path <-> file_path
    bash                               timeout: seconds <-> milliseconds

Every other key passes through unchanged under its own name, in both
directions: raider's tools took Claude Code's names where they have the same
argument (C<content>, C<old_string>, C<new_string>, C<pattern>, C<glob>,
C<output_mode>, C<-i>, C<command>, C<url>, C<query>, C<todos>, C<skill>,
C<args>, C<prompt>, C<subagent_type>, C<plan>, ...). Keys only one side knows
(C<offset> of C<Read>, C<description> of C<Bash>, C<as_html> of
C<web_fetch>, C<working_directory> of C<bash>) pass through too; the
receiving tool decides what to do with them.

C<ask_user> is the one tool whose arguments have another I<shape>, not other
names (C<question> and a list of C<options> strings, against
C<AskUserQuestion>'s C<questions> list of objects). There is no lossless
mapping, so its arguments pass through unchanged.

The round trip is lossless: C<raider_input( $t, claude_input( $t, $args ) )>
is C<$args> again, and the other way round, as long as an input does not
carry both names of one argument (C<path> and C<file_path>): then the
translated key wins and the other is dropped. The C<bash> C<timeout> is
lossless from raider (whole seconds) and back; milliseconds that are not
whole seconds become the next whole second, as raider's C<bash> takes
integers.

=method is_mcp

    Langertha::Raider::ToolNames->is_mcp('mcp__github__create_issue');   # true

True for a name of the form C<mcp__server__tool>.

=method raider_name

    my $name = Langertha::Raider::ToolNames->raider_name('Read');   # 'read_file'

The raider tool for a Claude Code tool name, an C<mcp__*> name unchanged, or
undef for a name that is in neither.

=method claude_name

    my $name = Langertha::Raider::ToolNames->claude_name('read_file');   # 'Read'

The Claude Code name of a raider tool, an C<mcp__*> name unchanged, or undef
for a tool the table does not know.

=method claude_names

All Claude Code names of the table (not the MCP pass-through), sorted.

=method raider_names

All raider tool names of the table, sorted, each once.

=method claude_input

    my $in = Langertha::Raider::ToolNames->claude_input( read_file => { path => 'lib/A.pm' } );
    # { file_path => 'lib/A.pm' }

The arguments of a raider tool (named first, by its raider name) in the
form the Claude Code tool takes. A new hash ref; the input is not changed.
An unknown tool or an C<mcp__*> tool gets a plain copy. Croaks without a
tool name or when the arguments are not a hash ref.

=method raider_input

    my $in = Langertha::Raider::ToolNames->raider_input(
      edit_file => { file_path => '/abs/A.pm', old_string => 'a', new_string => 'b' },
    );
    # { path => '/abs/A.pm', old_string => 'a', new_string => 'b' }

The way back: arguments in the Claude Code form, for the raider tool named
first. Same rules as L</claude_input>.

=cut

sub claude_input {
  my ( $self, $tool, $args ) = @_;
  return $self->_translate_input( 'claude_input', $tool, $args, 0 );
}

sub raider_input {
  my ( $self, $tool, $args ) = @_;
  return $self->_translate_input( 'raider_input', $tool, $args, 1 );
}

sub _translate_input {
  my ( $self, $method, $tool, $args, $back ) = @_;
  croak __PACKAGE__.'->'.$method.' needs a tool name' unless defined $tool && length $tool;
  croak __PACKAGE__.'->'.$method.' needs the arguments as a hash ref' unless ref $args eq 'HASH';
  my %names = %{ $ARG_NAME{$tool} // {} };
  %names = reverse %names if $back;
  my %out = map { $_ => $args->{$_} } grep { !exists $names{$_} } keys %$args;
  $out{ $names{$_} } = $args->{$_} for grep { exists $args->{$_} } sort keys %names;
  $out{timeout} = $self->_bash_timeout( $out{timeout}, $back )
    if $tool eq 'bash' && exists $out{timeout};
  return \%out;
}

# raider's bash takes whole seconds, Claude Code's Bash milliseconds.
sub _bash_timeout {
  my ( $self, $value, $back ) = @_;
  return $value unless defined $value && !ref $value && $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
  return $value * 1000 unless $back;
  my $seconds = $value / 1000;
  return $seconds == int $seconds ? int $seconds : int($seconds) + 1;
}

sub is_mcp { my ( $self, $name ) = @_; return defined $name && $name =~ /\Amcp__[^_].*__.+\z/s ? 1 : 0 }

sub raider_name {
  my ( $self, $name ) = @_;
  croak __PACKAGE__.'->raider_name needs a tool name' unless defined $name && length $name;
  return $name if $self->is_mcp($name);
  return $RAIDER{$name};
}

sub claude_name {
  my ( $self, $name ) = @_;
  croak __PACKAGE__.'->claude_name needs a tool name' unless defined $name && length $name;
  return $name if $self->is_mcp($name);
  return $CLAUDE{$name};
}

sub claude_names { return sort keys %RAIDER }

sub raider_names { return sort keys %CLAUDE }

1;
