package Langertha::Raider::ToolEffects;
# ABSTRACT: Internal static table of what each built-in tool can do (effect classes)
our $VERSION = '0.503';
use strict;
use warnings;
use Carp qw( croak );

=description

B<Internal module.> Its interface may change without notice.

One place that says what each built-in tool of raider can do to the world,
in five effect classes (ADR 0005, information only -- nothing here allows or
refuses a call):

=over

=item C<read> -- reads local files or state

=item C<write> -- changes local files

=item C<network> -- talks to the internet

=item C<code> -- runs arbitrary code; it can do anything the other classes do

=item C<message> -- sends something to a person or to another agent

=back

A tool with an empty list has no effect outside the run (pure control flow).
A tool that is not in the table has no answer: L</effects_for> returns undef
and reports say C<unknown>. The table is keyed by name, so ask it only about
tools the caller knows to be built-in -- an external MCP server may use any
name, and its C<read_file> is not ours. C<explain_config> asks about the tools
raider itself mounted; a later policy (the gate of ADR 0005) must combine it
with the tool's source.

C<perl_eval> and C<perl_check> are C<code>: C<perl -c> runs C<BEGIN> blocks and
C<use>. C<perl_cpanm> is C<network> and C<code>: it downloads and then runs
distribution build and test code. C<bash> is C<code> alone, as the class
covers the rest. C<hall_spawn> starts another raider with a mission, so it
is C<message> and C<code>. C<raider_wait_for> is C<code>: the host runs a
callback of its own for the condition and raider cannot say what it does, so
the table takes the cautious reading. C<raider_manage_mcps> is C<code>
(activating starts a tool server) and C<raider_switch_engine> is C<network>
(later prompts go to another provider).

=cut

my %EFFECTS = (
  # files
  list_files             => [qw( read )],
  read_file              => [qw( read )],
  write_file             => [qw( write )],
  edit_file              => [qw( write )],
  # shell
  bash                   => [qw( code )],
  # web
  web_search             => [qw( network )],
  web_fetch              => [qw( network )],
  # perl
  perl_eval              => [qw( code )],
  perl_check             => [qw( code )],
  perl_cpanm             => [qw( network code )],
  # hall
  telegram_reply         => [qw( message )],
  hall_status            => [qw( read )],
  hall_spawn             => [qw( message code )],
  # raider self-tools
  raider_ask_user        => [qw( message )],
  raider_wait            => [],
  raider_wait_for        => [qw( code )],
  raider_pause           => [],
  raider_abort           => [],
  raider_session_history => [qw( read )],
  raider_manage_mcps     => [qw( code )],
  raider_switch_engine   => [qw( network )],
);

my @CLASSES = qw( read write network code message );

=method classes

The effect classes, in display order.

=method tool_names

All built-in tool names of the table, sorted.

=method effects_for

    my $classes = Langertha::Raider::ToolEffects->effects_for('write_file');   # ['write']

A new array ref of effect classes (empty: no effect outside the run), or
undef for a tool that is not in the table.

=cut

sub classes { my ($self) = @_; return @CLASSES }

sub tool_names { my ($self) = @_; return sort keys %EFFECTS }

sub effects_for {
  my ( $self, $name ) = @_;
  croak __PACKAGE__.'->effects_for needs a tool name' unless defined $name && length $name;
  my $effects = $EFFECTS{$name} or return;
  return [ @$effects ];
}

1;
