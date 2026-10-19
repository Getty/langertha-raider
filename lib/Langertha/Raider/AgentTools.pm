package Langertha::Raider::AgentTools;
# ABSTRACT: Internal subagent tool of raider: agent
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use MCP::Server;

=synopsis

    my $agents = Langertha::Raider::AgentTools->new(
      catalog  => $context->agent_catalog,
      on_spawn => sub { my ( $agent, $call ) = @_; ...; return ( $text, $is_error ) },
    );
    my $server = $agents->server;      # MCP::Server with the tool agent

=description

B<Internal module.> Its interface may change without notice.

The C<agent> tool of ADR 0020 E<sect>3, shaped after Claude Code's C<Agent>
(formerly C<Task>, both mapped by L<Langertha::Raider::ToolNames>): the
model hands a task to a subagent, which works in a context of its own and
answers with its last text.

The tool knows the agents (L</catalog>), checks the call and describes
every agent in its text; it starts nothing itself. L</on_spawn> runs the
subagent (L<Langertha::Raider::Subagent>). An unknown C<subagent_type> is an
error result naming the available agents, and no subagent starts.

=cut

has catalog => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Context::Agents',
  required => 1,
);

=attr catalog

The L<Langertha::Raider::Context::Agents> the agents come from. Required.

=cut

has on_spawn => (
  is       => 'ro',
  isa      => 'CodeRef',
  required => 1,
);

=attr on_spawn

Required. Called for every valid call as
C<< $on_spawn->($agent, { description => ..., prompt => ..., subagent_type => ... }) >>,
with C<$agent> the catalogue entry; returns the tool result as
C<( $text, $is_error )>.

=cut

has server => (
  is       => 'ro',
  lazy     => 1,
  builder  => '_build_server',
  init_arg => undef,
);

=attr server

The L<MCP::Server> with the tool C<agent>, built once.

=cut

=method tools_label

    my $label = $agents->tools_label($agent);   # '*', 'read_file, grep', 'All tools except bash'

What the tool text says an agent may use, in raider names: C<*> for every
tool of the caller, else the list of C<tools> without C<disallowedTools>,
or C<All tools except ...> when only C<disallowedTools> restricts it.

=cut

sub tools_label {
  my ( $self, $agent ) = @_;
  my %no = map { $_ => 1 } @{ $agent->{disallowed} // [] };
  unless ( defined $agent->{tools} ) {
    return '*' unless %no;
    return 'All tools except '.join( ', ', @{ $agent->{disallowed} } );
  }
  my @tools = grep { !$no{$_} } @{ $agent->{tools} };
  return @tools ? join( ', ', @tools ) : 'none';
}

=method description

The text of the tool: what it does, one line per agent
(C<- name: description (Tools: ...)>) and how to use it.

=cut

sub description {
  my ( $self ) = @_;
  my $agents = join "\n", map {
    '- '.$_->{name}.': '.$_->{description}.' (Tools: '.$self->tools_label($_).')'
  } $self->catalog->agents;
  return <<"EOM" =~ s/\n+\z//r;
Launch a new agent to handle complex, multi-step tasks autonomously. Each agent type has its own instructions and tools.

Available agent types and the tools they have access to:
$agents

Set subagent_type to pick the agent type; without it, general-purpose runs.

Usage notes:
- The agent starts with no memory of this conversation: write a self-contained prompt with the task, the context it needs, and what it should report back.
- Its final message is returned to you as the result of this tool; the user does not see it, so pass on what matters.
- Launch independent agents in one message, with several agent calls, to run them concurrently.
- Use it for broad searches and work that would fill your own context; for a single known file or symbol, use the other tools directly.
EOM
}

=method unknown

    my $text = $agents->unknown('nope');

The error text for an unknown C<subagent_type>, naming the available
agents.

=cut

sub unknown {
  my ( $self, $type ) = @_;
  return 'Unknown agent type \''.$type.'\'. Available agents: '
    .join( ', ', map { $_->{name} } $self->catalog->agents ).'.';
}

sub _build_server {
  my ( $self ) = @_;
  my $server = MCP::Server->new( name => 'raider-agent', version => '1.0' );
  $server->tool(
    name         => 'agent',
    description  => $self->description,
    input_schema => {
      type       => 'object',
      properties => {
        description   => { type => 'string', description => 'A short (3-5 word) description of the task' },
        prompt        => { type => 'string', description => 'The task for the agent to perform' },
        subagent_type => { type => 'string', description => 'The type of agent to use (default: general-purpose)' },
      },
      required => [qw( description prompt )],
    },
    code => sub {
      my ( $tool, $in ) = @_;
      my $type = defined $in->{subagent_type} && length $in->{subagent_type}
        ? $in->{subagent_type} : $self->catalog->builtin_name;
      my $agent = $self->catalog->find($type)
        or return $tool->text_result( $self->unknown($type), 1 );
      return $tool->text_result( 'Error: the prompt is empty: write the task for the agent.', 1 )
        unless defined $in->{prompt} && $in->{prompt} =~ /\S/;
      my ( $text, $is_error ) = $self->on_spawn->( $agent, {
        description   => $in->{description} // '',
        prompt        => $in->{prompt},
        subagent_type => $type,
      } );
      return $tool->text_result( $text // '', $is_error ? 1 : 0 );
    },
  );
  return $server;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Subagent>

=item * L<Langertha::Raider::Context::Agents>

=item * L<Langertha::Raider::ToolNames>

=back

=cut
