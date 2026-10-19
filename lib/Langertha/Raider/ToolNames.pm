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

=cut

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
