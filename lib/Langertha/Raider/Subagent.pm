package Langertha::Raider::Subagent;
# ABSTRACT: Internal subagent run of raider: one agent call, its own raider, tools and journal
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Future;
use Future::AsyncAwait;
use MCP::Server;
use Scalar::Util qw( blessed refaddr weaken );
use Time::HiRes ();
use Langertha::Raider;
use Langertha::Raider::AgentTools;
use Langertha::Raider::TodoTools;

=synopsis

    # The agent tool of a run at depth 0 (what the application mounts):
    my $server = Langertha::Raider::Subagent->agent_tool_server(
      app    => $app,
      depth  => 0,
      caller => sub { {
        servers => $app->_tool_servers,      # the caller's active tool set
        session => $session,                 # or undef
        call    => 'c3',                     # the agent call's id
        event   => sub { $app->event(@_) },  # the caller's event stream
      } },
    );

    # What one agent call does:
    my $sub = Langertha::Raider::Subagent->new(
      app => $app, agent => $agent, depth => 1, prompt => 'Find ...',
      caller_servers => \@servers, on_caller_event => sub { ... },
    );
    my ( $text, $is_error ) = $sub->run;

=description

B<Internal module.> Its interface may change without notice.

The subagent run of ADR 0020 E<sect>4: one call of the C<agent> tool
(L<Langertha::Raider::AgentTools>) becomes a new L<Langertha::Raider> in
the same process, on the loop of the L</app> (ADR 0016), and the call's
result is the subagent's last assistant text.

=over

=item * B<Own context.> The raider starts with an empty history and gets
only the prompt. Its mission is compiled by the application like the
caller's (L<Langertha::Raider::Application/compile_mission>), with the
agent's body in the place of the persona and the native instructions --
what C<-M> replaces (ADR 0014).

=item * B<Own tool set> (L</tool_servers>). The caller's active set, each
tool kept when the agent's C<tools> allows it and C<disallowedTools> does
not; C<ask_user> always goes (nobody can answer a subagent). C<todo_write>
gets an instance of its own, so the subagent's list never overwrites the
caller's, and C<agent> gets one for this depth -- or goes, when this run is
at L<Langertha::Raider::Application/max_agent_depth>. A server whose tools
all stay is mounted as it is; otherwise a new L<MCP::Server> carries the
tools that stay. Prompt and catalogue derive from this set alone; the skill
listing stays only when the set has the C<skill> tool.

=item * B<Engine.> One engine of the caller's class and arguments, built by
L<Langertha::Raider::Application/build_subagent_engine> over this set's
clients, on the same loop; the model is inherited.

=item * B<Journal.> When the caller has a session, the subagent gets its own
session in the same store, whose C<session.created> carries C<parent>,
C<parent_call>, C<agent> and C<depth>, and runs one journaled run there --
C<run.started>, the prompt and the answer as C<message>, every C<tool.call>,
C<tool.result> and C<todo.updated>, and C<run.finished>. The caller gets
only C<agent.started> (C<call>, C<agent>, C<description>, C<session>,
C<model>) and C<agent.finished> (C<call>, C<agent>, C<session>,
C<status>).

=item * B<End.> A completed run answers with the subagent's text; a failed
one with an error result giving the reason; a cancelled one -- the
application cancels every live subagent with its run
(L<Langertha::Raider::Application/cancel_run>) -- with an error result.
The subagent gets the caller's C<max_iterations>.

=back

=cut

has app => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Application',
  required => 1,
  weak_ref => 1,
);

=attr app

The L<Langertha::Raider::Application> of the main run, which builds the
engine and the mission and owns the loop and the session store. Required,
held weakly.

=cut

has agent => (
  is       => 'ro',
  isa      => 'HashRef',
  required => 1,
);

=attr agent

The catalogue entry of the agent (L<Langertha::Raider::Context::Agents>).
Required.

=cut

has depth => (
  is       => 'ro',
  isa      => 'Int',
  required => 1,
);

=attr depth

The depth of this run: C<1> for a subagent of the main run. Required.

=cut

has prompt => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr prompt

The task, the subagent's only user message. Required.

=cut

has description => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr description

The short label of the call, for C<agent.started>.

=cut

has caller_servers => (
  is       => 'ro',
  isa      => 'ArrayRef',
  required => 1,
);

=attr caller_servers

The caller's active tool set, as L<MCP::Server> objects. Required.

=cut

has caller_session => (
  is        => 'ro',
  predicate => 'has_caller_session',
);

=attr caller_session

The caller's L<Langertha::Raider::Session>, if it has one.

=cut

has caller_call => (
  is  => 'ro',
  isa => 'Maybe[Str]',
);

=attr caller_call

The id of the caller's C<agent> tool call (C<c3>), as its journal names it.

=cut

has on_caller_event => (
  is       => 'ro',
  isa      => 'CodeRef',
  required => 1,
);

=attr on_caller_event

The caller's event stream, called as C<< ->($type, %payload) >> with
C<agent.started> and C<agent.finished>. Required.

=cut

has tool_servers => (
  is       => 'ro',
  isa      => 'ArrayRef',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_tool_servers',
);

=attr tool_servers

The subagent's active tool set (see L</DESCRIPTION>), built once.

=cut

has mission => (
  is       => 'ro',
  isa      => 'Str',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_mission',
);

=attr mission

The subagent's system prompt, built once.

=cut

has engine => (
  is       => 'ro',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_engine',
);

=attr engine

The subagent's engine, built once.

=cut

has raider => (
  is        => 'ro',
  isa       => 'Langertha::Raider',
  init_arg  => undef,
  lazy      => 1,
  builder   => '_build_raider',
  predicate => '_has_raider',
);

=attr raider

The subagent's L<Langertha::Raider>, built once.

=cut

has session => (
  is       => 'ro',
  init_arg => undef,
  writer   => '_set_session',
);

=attr session

The subagent's own L<Langertha::Raider::Session> once the run has started,
when the caller has one.

=cut

has cancel_requested => (
  is       => 'ro',
  isa      => 'Bool',
  init_arg => undef,
  default  => 0,
  writer   => '_set_cancel_requested',
);

=attr cancel_requested

True once L</cancel> was called.

=cut

has todos => (
  is       => 'ro',
  isa      => 'ArrayRef',
  init_arg => undef,
  default  => sub { [] },
  writer   => '_set_todos',
);

=attr todos

The subagent's own task list, as its C<todo_write> last sent it.

=cut

has _mcps    => ( is => 'ro', init_arg => undef, lazy => 1, builder => '_build_mcps', predicate => '_has_mcps' );
has _call    => ( is => 'rw', init_arg => undef );
has _run_id  => ( is => 'rw', init_arg => undef );
has _t0      => ( is => 'rw', init_arg => undef );
has _model   => ( is => 'rw', init_arg => undef );
has _journal_failed => ( is => 'rw', init_arg => undef, default => 0 );

=method agent_tool_server

    my $server = Langertha::Raider::Subagent->agent_tool_server(
      app => $app, depth => $depth, caller => sub { { servers, session, call, event } });

The L<MCP::Server> with the C<agent> tool for a run at C<$depth>, over the
agent catalogue of the application's context. Every call asks C<caller>
for the state of the calling run at that moment -- its active tool set,
session, the id of the call and its event stream -- and runs a new
subagent of the invocant class at C<$depth + 1> (L</run>).

=cut

sub agent_tool_server {
  my ( $class, %arg ) = @_;
  my ( $app, $depth, $caller ) = @arg{qw( app depth caller )};
  weaken $app;
  return Langertha::Raider::AgentTools->new(
    catalog  => $app->context->agent_catalog,
    on_spawn => sub {
      my ( $agent, $call ) = @_;
      my $c = $caller->();
      return $class->new(
        app             => $app,
        agent           => $agent,
        depth           => $depth + 1,
        description     => $call->{description},
        prompt          => $call->{prompt},
        caller_servers  => $c->{servers},
        on_caller_event => $c->{event},
        caller_call     => $c->{call},
        ( $c->{session} ? ( caller_session => $c->{session} ) : () ),
      )->run;
    },
  )->server;
}

=method run

    my ( $text, $is_error ) = $sub->run;

Runs the subagent to its end on the application's loop (L</run_f>) and
returns the tool result: the subagent's text, or an error text with a true
C<$is_error> for a failed or cancelled run. While it runs, the application
knows it as live, so cancelling the main run cancels it.

=cut

sub run {
  my ( $self ) = @_;
  my $app  = $self->app;
  my $live = $app->_live_subagents;
  my $key  = refaddr $self;
  $live->{$key} = $self;
  weaken $live->{$key};
  $self->cancel if $app->has_run && $app->_run->{cancelled};
  my $f = $self->run_f;
  $app->loop->await($f);
  delete $live->{$key};
  my $outcome = $f->get;
  my $name = $self->agent->{name};
  return ( $outcome->{text} // '', 0 ) if $outcome->{status} eq 'completed';
  return ( 'Agent \''.$name.'\' was cancelled.', 1 ) if $outcome->{status} eq 'cancelled';
  return ( 'Agent \''.$name.'\' failed: '.$outcome->{error}, 1 );
}

=method run_f

    my $outcome = await $sub->run_f;

The run itself: starts the journal and C<agent.started>, raids with the
prompt, ends the journal and C<agent.finished>. Never fails; returns the
outcome as a hash reference: C<status> (C<completed>, C<failed> or
C<cancelled>), C<text> of a completed run, C<error> of a failed one.

=cut

async sub run_f {
  my ( $self ) = @_;
  my $outcome = await Future->call( sub { $self->_raid_f } )->then(
    sub { Future->done( $self->_outcome_of( $_[0] ) ) },
    sub {
      my ( $error ) = @_;
      $error = "$error";
      $error =~ s/\s+\z//;
      Future->done( { status => 'failed', error => $error } );
    },
  );
  $self->_finish($outcome);
  return $outcome;
}

async sub _raid_f {
  my ( $self ) = @_;
  $self->_begin;
  my $raider = $self->raider;
  for my $mcp ( @{ $self->_mcps } ) {
    await $mcp->initialize;
  }
  $raider->cancel if $self->cancel_requested;
  return await $raider->raid_f( $self->prompt );
}

=method cancel

Asks the run to stop (L<Langertha::Raider/cancel>); only sets flags, so a
signal handler may call it.

=cut

sub cancel {
  my ( $self ) = @_;
  $self->_set_cancel_requested(1);
  $self->raider->cancel if $self->_has_raider;
  return;
}

=method event

    $sub->event('tool.call', call => 'c1', name => 'read_file', ...);

One event of the subagent's own run: into its journal for the types the
application journals (L<Langertha::Raider::Application/is_journal_type>),
nowhere else.

=cut

sub event {
  my ( $self, $type, %payload ) = @_;
  $self->_call( $payload{call} ) if $type eq 'tool.call';
  $self->_append( $type, run => $self->_run_id, %payload ) if $self->app->is_journal_type($type);
  return;
}

sub _begin {
  my ( $self ) = @_;
  my $app = $self->app;
  $self->_t0( Time::HiRes::time() );
  if ( $self->has_caller_session ) {
    my $session = eval {
      $app->session_store->create(
        parent => $self->caller_session->id,
        ( defined $self->caller_call ? ( parent_call => $self->caller_call ) : () ),
        agent  => $self->agent->{name},
        depth  => $self->depth,
      );
    };
    if ($session) {
      $self->_set_session($session);
      $self->_run_id( $session->next_run );
    }
    else {
      $self->_report_journal_error( $self->caller_session, $@ );
    }
  }
  my $model = eval { $self->engine->chat_model };
  $self->_model($model);
  $self->on_caller_event->( 'agent.started', $self->_defined(
    call        => $self->caller_call,
    agent       => $self->agent->{name},
    description => $self->description,
    session     => $self->session ? $self->session->id : undef,
    model       => $model,
  ) );
  $self->event( 'run.started', engine => $app->engine_name, defined $model ? ( model => $model ) : () );
  $self->event( 'message', role => 'user', content => $self->prompt );
  return;
}

sub _outcome_of {
  my ( $self, $result ) = @_;
  return { status => 'cancelled' } if blessed $result && $result->can('is_cancelled') && $result->is_cancelled;
  return { status => 'completed', text => "$result" };
}

sub _finish {
  my ( $self, $outcome ) = @_;
  my $app = $self->app;
  $self->event( 'message', role => 'assistant', content => $outcome->{text} ) if $outcome->{status} eq 'completed';
  if ( my $session = $self->session ) {
    my $metrics = $self->_has_raider ? $self->raider->metrics : undef;
    $self->_append( 'run.finished', $self->_defined(
      run     => $self->_run_id,
      status  => $outcome->{status},
      error   => $outcome->{error},
      elapsed => 0 + sprintf( '%.3f', Time::HiRes::time() - ( $self->_t0 // Time::HiRes::time() ) ),
      metrics => $metrics,
    ) );
    $session->release;
  }
  if ( $self->_has_mcps && $app ) {
    $_->loop && $_->loop->remove($_) for @{ $self->_mcps };
  }
  $self->on_caller_event->( 'agent.finished', $self->_defined(
    call    => $self->caller_call,
    agent   => $self->agent->{name},
    session => $self->session ? $self->session->id : undef,
    status  => $outcome->{status},
  ) );
  return;
}

# The pairs whose value is defined.
sub _defined {
  my ( $self, @pairs ) = @_;
  my @out;
  while ( my ( $k, $v ) = splice @pairs, 0, 2 ) {
    push @out, $k => $v if defined $v;
  }
  return @out;
}

sub _append {
  my ( $self, $type, %fields ) = @_;
  my $session = $self->session or return;
  return 1 if eval { $session->append( $type, %fields ); 1 };
  $self->_report_journal_error( $session, $@ ) unless $self->_journal_failed;
  $self->_journal_failed(1);
  return 0;
}

sub _report_journal_error {
  my ( $self, $session, $error ) = @_;
  my $app = $self->app;
  if ( $app && $app->has_on_journal_error ) {
    $app->on_journal_error->( $session, $error );
  }
  else {
    warn 'subagent session of '.$session->id.' not fully saved: '.$error;
  }
  return;
}

sub _build_tool_servers {
  my ( $self ) = @_;
  my $agent = $self->agent;
  my %allow = map { $_ => 1 } @{ $agent->{tools} // [] };
  my %deny  = map { $_ => 1 } @{ $agent->{disallowed} // [] }, 'ask_user';
  my $all   = !defined $agent->{tools};
  my %own   = (
    todo_write => sub { $self->_own_todo_tool },
    agent      => sub { $self->depth < $self->app->max_agent_depth ? $self->_own_agent_tool : undef },
  );
  my @servers;
  for my $server ( @{ $self->caller_servers } ) {
    my @tools = @{ $server->tools };
    my @kept = map { $own{ $_->name } ? ( $own{ $_->name }->() // () ) : $_ }
      grep { !$deny{ $_->name } && ( $all || $allow{ $_->name } ) } @tools;
    next unless @kept;
    my $same = @kept == @tools && !grep { refaddr $kept[$_] != refaddr $tools[$_] } 0 .. $#kept;
    push @servers, $same ? $server : MCP::Server->new( name => $server->name, version => $server->version, tools => \@kept );
  }
  return \@servers;
}

sub _own_todo_tool {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  my $todo = Langertha::Raider::TodoTools->new( on_update => sub {
    my ( $list ) = @_;
    my $sub = $weak or return;
    $sub->_set_todos($list);
    $sub->event( 'todo.updated', todos => [ map { { %$_ } } @$list ] );
  } );
  return $todo->server->tools->[0];
}

sub _own_agent_tool {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  return ref($self)->agent_tool_server(
    app    => $self->app,
    depth  => $self->depth,
    caller => sub { {
      servers => $weak->tool_servers,
      session => $weak->session,
      call    => $weak->_call,
      event   => sub { $weak->event(@_) if $weak },
    } },
  )->tools->[0];
}

sub _build_mission {
  my ( $self ) = @_;
  return $self->app->compile_mission( $self->agent->{body} // '', $self->tool_servers );
}

sub _build_mcps {
  my ( $self ) = @_;
  my $app = $self->app;
  return [ map { $app->_mcp_client($_) } @{ $self->tool_servers } ];
}

sub _build_engine {
  my ( $self ) = @_;
  return $self->app->build_subagent_engine( mcp_servers => $self->_mcps );
}

sub _build_raider {
  my ( $self ) = @_;
  my $app = $self->app;
  weaken( my $weak = $self );
  return Langertha::Raider->new(
    engine                     => $self->engine,
    mission                    => $self->mission,
    max_iterations             => $app->max_iterations,
    max_context_tokens         => $app->max_context_tokens,
    context_compress_threshold => $app->context_compress_threshold,
    plugins                    => [ $app->run_plugins( sub { $weak->event(@_) if $weak } ) ],
  );
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::AgentTools>

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::Context::Agents>

=back

=cut
