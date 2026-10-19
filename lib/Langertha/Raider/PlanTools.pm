package Langertha::Raider::PlanTools;
# ABSTRACT: Internal plan-mode tool of raider: exit_plan_mode
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use MCP::Server;

=synopsis

    my $plan   = Langertha::Raider::PlanTools->new( handler => sub { my ( $plan ) = @_; ...; return ( $text, $is_error ) } );
    my $server = $plan->server;      # MCP::Server with the tool exit_plan_mode

=description

B<Internal module.> Its interface may change without notice.

The C<exit_plan_mode> tool, shaped after Claude Code's C<ExitPlanMode>
(L<Langertha::Raider::ToolNames>): in the C<plan> permission mode (ADR
0021) the model reads and plans, and presents the plan with this tool to
leave the mode. The tool decides nothing itself: L</handler> -- the
application -- puts the plan to the person, switches the mode or says why
it stays, and returns the text the model gets.

The application mounts the tool only once its run has been in plan mode.

=cut

has handler => (
  is       => 'ro',
  isa      => 'CodeRef',
  required => 1,
);

=attr handler

Required. Called as C<< $handler->($plan) >> on every call; returns the
result text and whether it is an error.

=cut

has server => (
  is       => 'ro',
  lazy     => 1,
  builder  => '_build_server',
  init_arg => undef,
);

=attr server

The L<MCP::Server> with the tool C<exit_plan_mode>, built once.

=cut

sub _build_server {
  my ( $self ) = @_;
  my $server = MCP::Server->new( name => 'raider-plan', version => '1.0' );
  $server->tool(
    name         => 'exit_plan_mode',
    description  => 'In plan mode: present your finished plan to the user for approval. Call it when you have read '
      .'enough and know what you would change and how; the user approves it (then you may edit files and run commands) '
      .'or tells you what to change. Only for plans of work that changes something, not for research questions.',
    input_schema => {
      type       => 'object',
      properties => {
        plan => { type => 'string', description => 'The plan, concise, in Markdown' },
      },
      required => ['plan'],
    },
    code => sub {
      my ( $tool, $in ) = @_;
      my ( $text, $is_error ) = $self->handler->( $in->{plan} );
      return $tool->text_result( $text, $is_error ? 1 : 0 );
    },
  );
  return $server;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::Permissions>

=back

=cut
