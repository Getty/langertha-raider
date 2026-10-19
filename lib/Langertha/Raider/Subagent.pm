package Langertha::Raider::Subagent;
# ABSTRACT: Internal subagent run of raider: one agent call, its own raider, tools and journal
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Future;
use Future::AsyncAwait;
use JSON::MaybeXS;
use MCP::Server;
use Scalar::Util qw( blessed refaddr weaken );
use Time::HiRes ();
use Langertha::Raider;
use Langertha::Raider::AgentTools;
use Langertha::Raider::Briefing;
use Langertha::Raider::FileTools::ReadState;
use Langertha::Raider::PlanTools;
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
        policy  => $app->permissions,        # the caller's permission policy
      } },
    );

    # What one agent call does:
    my $sub = Langertha::Raider::Subagent->new(
      app => $app, agent => $agent, depth => 1, prompt => 'Find ...',
      caller_servers => \@servers, on_caller_event => sub { ... },
      caller_policy => $app->permissions,
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
not. A name there stands for its family (ADR 0025): the task-list tools
(C<todo_write>, C<task_create>, C<task_update>, C<task_list>, C<task_get>)
are one, so are C<edit_file> and C<multi_edit>, and C<bash> brings
C<bash_output> and C<kill_shell>. C<ask_user> always goes (nobody can
answer a subagent), and so does C<enter_plan_mode> (only the main session
enters plan mode). The task-list tools get an instance of their own, so the
subagent's list never overwrites the caller's; the file tools get one over
the subagent's own L</file_read_state>, so it reads a file before it writes
it, as the caller must (ADR 0023); background shells stay the
application's. C<agent> gets one for this depth -- or goes, when this run is
at L<Langertha::Raider::Application/max_agent_depth>. A server whose tools
all stay is mounted as it is; otherwise a new L<MCP::Server> carries the
tools that stay. Prompt and catalogue derive from this set alone; the skill
listing stays only when the set has the C<skill> tool.

=item * B<Briefing> (L</briefing>, ADR 0020 E<sect>6). The skills the agent
declares are resolved through L<Langertha::Raider::Context/skill_resolver>
and put in front of the prompt in the briefing plugin's format
(L<Langertha::Raider::Briefing>); that is the subagent's prompt
(L</briefed_prompt>). A skill that does not resolve refuses the call: the
result is the error C<briefing: agent 'NAME' references unknown skill(s):
a, b>, and nothing starts -- no session, no C<agent.started>, no request.
Above 64 kB of skill text the run goes ahead, and the caller's stream and
journal get C<agent.warning> (C<call>, C<agent>, C<message>: the size
note) before C<agent.started>.

=item * B<Permissions> (L</permissions>, ADR 0021). The caller's policy
through L<Langertha::Raider::Permissions/for_subrun>: the mode the caller
has when the call starts, the same rules and additional directories, and
the B<same> session rules. Every tool call of the subagent passes the
application's gate (L<Langertha::Raider::Application/tool_gate>) with this
policy; a call it asks about goes to the same person
(L<Langertha::Raider::Application/on_permission_request>) or, with nobody to
ask, is refused as in the caller. Its C<permission.*> events go to the
subagent's journal. C<exit_plan_mode> gets an instance of its own that never
switches a mode: a subagent in plan mode gives its plan as its answer, to
the caller.

=item * B<Engine.> One engine of the caller's class and arguments, built by
L<Langertha::Raider::Application/build_subagent_engine> over this set's
clients, on the same loop. Its model is the agent's C<model> as
L<Langertha::Raider::Context::Agents/resolve_model> maps it under the
caller's engine and L<Langertha::Raider::Application/agent_models>
(L</model_resolution>, ADR 0020 E<sect>5): a resolved model replaces the
caller's, otherwise it is inherited. C<agent.started> carries the model the
engine really uses.

=item * B<Journal.> When the caller has a session, the subagent gets its own
session in the same store, whose C<session.created> carries C<parent>,
C<parent_call>, C<agent> and C<depth>, and runs one journaled run there --
C<run.started>, the briefed prompt and the answer as C<message>, every C<tool.call>,
C<tool.result> and C<todo.updated>, and C<run.finished>. The caller gets
only C<agent.started> (C<call>, C<agent>, C<description>, C<session>,
C<model>) and C<agent.finished> (C<call>, C<agent>, C<session>,
C<status>).

=item * B<Hooks> (Claude layout, ADR 0022, ADR 0020 E<sect>6). Before
the run C<SubagentStart> fires (matcher on C<agent_type>) with
C<agent_id> -- the subagent's session id, or C<local-agent-PID-ADDR> without
a session -- and C<agent_type>, the agent's name; its
C<additionalContext> goes in front of the briefed prompt as a
C<< <system-reminder> >> block (L</sent_prompt>), and a C<continue: false>
fails the run before its first request. After a final answer
C<SubagentStop> fires as C<Stop> does for the main run
(L<Langertha::Raider::Application/stop_hook_limit>): a block or
C<additionalContext> sends C<SubagentStop hook feedback:> and the reasons
back to the subagent as its next message, with C<stop_hook_active> true,
and the run goes on. The reports of both go to the caller's stream
(C<hook.ran>, C<hook.message>). The subagent's own tool calls run the
C<PreToolUse> and C<PostToolUse> hooks as the caller's do, with
C<agent_id>, C<agent_type> and its own C<permission_mode> in the input;
those reports go to its journal, and a C<continue: false> there cancels the
subagent only.

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

has caller_policy => (
  is        => 'ro',
  isa       => 'Langertha::Raider::Permissions',
  predicate => 'has_caller_policy',
);

=attr caller_policy

The caller's L<Langertha::Raider::Permissions>: the application's
L<Langertha::Raider::Application/permissions> for a subagent of the main
run, the calling subagent's L</permissions> for a nested one. Defaults to
the application's.

=cut

has permissions => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Permissions',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_permissions',
);

=attr permissions

The subagent's policy: L<Langertha::Raider::Permissions/for_subrun> of
L</caller_policy>, built once.

=cut

sub _build_permissions {
  my ( $self ) = @_;
  my $caller = $self->has_caller_policy ? $self->caller_policy : $self->app->permissions;
  return $caller->for_subrun;
}

has briefing => (
  is       => 'ro',
  isa      => 'Langertha::Raider::Briefing',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_briefing',
);

=attr briefing

The L<Langertha::Raider::Briefing> of the agent's declared skills, built
once (L</briefing_class>).

=cut

has briefed_prompt => (
  is       => 'ro',
  isa      => 'Str',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_briefed_prompt',
);

=attr briefed_prompt

What the subagent is asked: L</prompt> behind its briefing, or L</prompt>
itself when the agent declares no skill.

=cut

has sent_prompt => (
  is       => 'ro',
  isa      => 'Str',
  init_arg => undef,
  writer   => '_set_sent_prompt',
);

=attr sent_prompt

What the subagent was really sent once the run has started: the
C<additionalContext> of C<SubagentStart> hooks in front of
L</briefed_prompt>, or L</briefed_prompt> itself.

=cut

has agent_id => (
  is       => 'ro',
  isa      => 'Str',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_agent_id',
);

=attr agent_id

The C<agent_id> of the hook inputs: the subagent's session id, else
C<local-agent-PID-ADDR>, unique while the subagent runs.

=cut

sub _build_agent_id {
  my ( $self ) = @_;
  return $self->session ? $self->session->id : 'local-agent-'.$$.'-'.refaddr($self);
}

has model_resolution => (
  is       => 'ro',
  isa      => 'HashRef',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_model_resolution',
);

=attr model_resolution

What the agent's C<model> means under the caller's engine
(L<Langertha::Raider::Context::Agents/resolve_model>): C<< { model => ... } >>
or C<< { inherit => 1, reason => ... } >>.

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

The subagent's own task list, as its task tools (or C<todo_write>) last
left it.

=cut

has file_read_state => (
  is       => 'ro',
  isa      => 'Langertha::Raider::FileTools::ReadState',
  init_arg => undef,
  lazy     => 1,
  builder  => '_build_file_read_state',
);

=attr file_read_state

The subagent's own record of the files it has read
(L<Langertha::Raider::FileTools::ReadState>, ADR 0023): its C<write_file>,
C<edit_file> and C<multi_edit> hold against it, so a file the caller read
counts as unread until the subagent reads it itself.

=cut

has _own_todos       => ( is => 'ro', init_arg => undef, lazy => 1, builder => '_build_own_todos' );
has _own_file_server => ( is => 'ro', init_arg => undef, lazy => 1, builder => '_build_own_file_server' );

has _mcps    => ( is => 'ro', init_arg => undef, lazy => 1, builder => '_build_mcps', predicate => '_has_mcps' );
has _call    => ( is => 'rw', init_arg => undef );
has _run_id  => ( is => 'rw', init_arg => undef );
has _t0      => ( is => 'rw', init_arg => undef );
has _model   => ( is => 'rw', init_arg => undef );
has _journal_failed => ( is => 'rw', init_arg => undef, default => 0 );

=method agent_tool_server

    my $server = Langertha::Raider::Subagent->agent_tool_server(
      app => $app, depth => $depth, caller => sub { { servers, session, call, event, policy } });

The L<MCP::Server> with the C<agent> tool for a run at C<$depth>, over the
agent catalogue of the application's context. Every call asks C<caller>
for the state of the calling run at that moment -- its active tool set,
session, the id of the call, its event stream and its permission policy
-- and runs a new subagent of the invocant class at C<$depth + 1>
(L</run>).

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
        ( $c->{policy}  ? ( caller_policy  => $c->{policy} )  : () ),
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
  return ( $outcome->{error}, 1 ) if $outcome->{status} eq 'refused';
  return ( 'Agent \''.$name.'\' was cancelled.', 1 ) if $outcome->{status} eq 'cancelled';
  return ( 'Agent \''.$name.'\' failed: '.$outcome->{error}, 1 );
}

=method run_f

    my $outcome = await $sub->run_f;

The run itself: starts the journal and C<agent.started>, raids with the
briefed prompt, ends the journal and C<agent.finished>. Never fails;
returns the outcome as a hash reference: C<status> (C<completed>,
C<failed>, C<cancelled>, or C<refused> when a declared skill does not
resolve -- then nothing ran), C<text> of a completed run, C<error> of a
failed or refused one.

=cut

async sub run_f {
  my ( $self ) = @_;
  my $briefing = $self->briefing;
  return { status => 'refused', error => $briefing->missing_note } if $briefing->has_missing;
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
  $self->_open_session;
  my $start = await $self->_subagent_start_f;
  $self->_begin($start);
  die 'a SubagentStart hook stopped it'.( defined $start->stop_reason ? ': '.$start->stop_reason : '' )."\n"
    if $start && $start->stopped;
  my $raider = $self->raider;
  for my $mcp ( @{ $self->_mcps } ) {
    await $mcp->initialize;
  }
  $raider->cancel if $self->cancel_requested;
  my $result = await $raider->raid_f( $self->sent_prompt );
  return await $self->_after_answer_f($result);
}

# The pairs every hook input of this subagent carries besides the caller's
# session fields (ADR 0022 section 5).
sub _hook_fields {
  my ( $self ) = @_;
  return (
    agent_id        => $self->agent_id,
    agent_type      => $self->agent->{name},
    permission_mode => $self->permissions->mode,
  );
}

# SubagentStart (Claude layout): resolves to its Hooks::Result, or undef when
# no hook is configured. Reported to the caller's stream.
sub _subagent_start_f {
  my ( $self ) = @_;
  my $app   = $self->app;
  my $hooks = $app->hooks;
  return Future->done(undef) unless $hooks && $hooks->has_hooks('SubagentStart');
  return $hooks->run_f( SubagentStart => $app->_hook_input( $self->_hook_fields ) )->then( sub {
    my ( $r ) = @_;
    $app->_report_hooks( $r, $self->on_caller_event );
    return Future->done($r);
  } );
}

# SubagentStop after a final answer, as the application's Stop hooks for the
# main run: a block or additionalContext sends the feedback back as the next
# message (stop_hook_active true), at most stop_hook_limit times; the turns
# in between go into the subagent's journal. Resolves to the last result.
async sub _after_answer_f {
  my ( $self, $result ) = @_;
  my $app   = $self->app;
  my $hooks = $app ? $app->hooks : undef;
  return $result unless $hooks;
  my $active = 0;
  for ( my $round = 0; ; $round++ ) {
    return $result unless blessed $result && $result->can('is_final') && $result->is_final;
    return $result if $self->cancel_requested;
    return $result unless $hooks->has_hooks('SubagentStop');
    my $r = await $hooks->run_f( SubagentStop => $app->_hook_input(
      $self->_hook_fields,
      ( $self->session ? ( agent_transcript_path => ''.$self->session->path ) : () ),
      stop_hook_active       => $active ? JSON::MaybeXS->true : JSON::MaybeXS->false,
      last_assistant_message => "$result",
    ) );
    $app->_report_hooks( $r, $self->on_caller_event );
    return $result if $r->stopped;
    my @feedback = ( $r->blocked ? ( @{ $r->reasons } ? @{ $r->reasons } : '(no reason given)' ) : () ),
      ( defined $r->context ? $r->context : () );
    return $result unless @feedback;
    if ( $round >= $app->stop_hook_limit ) {
      $self->on_caller_event->( 'hook.message', hook_event => 'SubagentStop', kind => 'error',
        text => 'SubagentStop hooks kept agent \''.$self->agent->{name}.'\' going '.$app->stop_hook_limit
          .' times in a row; it ends here' );
      return $result;
    }
    my $feedback = "SubagentStop hook feedback:\n".join( "\n", @feedback );
    $self->event( 'message', role => 'assistant', content => "$result" );
    $self->event( 'message', role => 'user', content => $feedback, hook => 'SubagentStop' );
    $active = 1;
    $result = await $self->raider->raid_f($feedback);
  }
}

=method approval_binding

    my %binding = $sub->approval_binding;   # session_id, run_id

What an approval of one of the subagent's calls is bound to: its own
session and run, when it has a session; else nothing, and the
application's stand-ins apply.

=cut

sub approval_binding {
  my ( $self ) = @_;
  my $session = $self->session or return;
  return ( session_id => $session->id, ( defined $self->_run_id ? ( run_id => $self->_run_id ) : () ) );
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

# The subagent's own session (when the caller has one) and its run id.
sub _open_session {
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
  return;
}

# agent.started and the start of the journal; $start is SubagentStart's
# result (or undef): its context goes in front of the briefed prompt, its
# stop leaves the prompt unsent.
sub _begin {
  my ( $self, $start ) = @_;
  my $app = $self->app;
  my $model = eval { $self->engine->chat_model };
  $self->_model($model);
  $self->on_caller_event->( 'agent.warning', $self->_defined(
    call    => $self->caller_call,
    agent   => $self->agent->{name},
    message => $self->briefing->size_note,
  ) ) if $self->briefing->oversized;
  $self->on_caller_event->( 'agent.started', $self->_defined(
    call        => $self->caller_call,
    agent       => $self->agent->{name},
    description => $self->description,
    session     => $self->session ? $self->session->id : undef,
    model       => $model,
  ) );
  $self->event( 'run.started', engine => $app->engine_name, defined $model ? ( model => $model ) : () );
  return if $start && $start->stopped;
  my $context = $start ? $start->context : undef;
  $self->_set_sent_prompt( join "\n\n",
    ( defined $context ? "<system-reminder>\nSubagentStart hook additional context: ".$context."\n</system-reminder>" : () ),
    $self->briefed_prompt );
  $self->event( 'message', role => 'user', content => $self->sent_prompt );
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

# Tools an agent file's tools / disallowedTools name together (ADR 0025):
# each name of a family stands for all of it -- the task-list family is one
# whichever of its two shapes is mounted, multi_edit is edit_file with more
# edits -- and bash brings the tools that read and stop its background
# shells (those alone do not bring bash).
my @FAMILY = (
  [ [qw( todo_write task_create task_update task_list task_get )] => [qw( todo_write task_create task_update task_list task_get )] ],
  [ [qw( edit_file multi_edit )] => [qw( edit_file multi_edit )] ],
  [ [qw( bash )] => [qw( bash_output kill_shell )] ],
);

# Tools a subagent never has: nobody can answer it (ask_user), and only the
# main session can enter plan mode (enter_plan_mode).
my @NEVER = qw( ask_user enter_plan_mode );

sub _with_families {
  my ( $self, @names ) = @_;
  my %set = map { $_ => 1 } @names;
  for my $f (@FAMILY) {
    my ( $by, $brings ) = @$f;
    next unless grep { $set{$_} } @$by;
    $set{$_} = 1 for @$brings;
  }
  return %set;
}

# The file tools are the subagent's own, over its own read state; the
# task-list tools its own, over its own list.
sub _own_tools {
  my ( $self ) = @_;
  my %own = (
    exit_plan_mode => sub { $self->_own_plan_tool },
    agent          => sub { $self->depth < $self->app->max_agent_depth ? $self->_own_agent_tool : undef },
  );
  for my $server ( $self->_own_file_server, $self->_own_todos->server, $self->_own_todos->task_server ) {
    for my $tool ( @{ $server->tools } ) {
      $own{ $tool->name } = sub { $tool };
    }
  }
  return %own;
}

sub _build_tool_servers {
  my ( $self ) = @_;
  my $agent = $self->agent;
  my %allow = $self->_with_families( @{ $agent->{tools} // [] } );
  my %deny  = ( $self->_with_families( @{ $agent->{disallowed} // [] } ), map { $_ => 1 } @NEVER );
  my $all   = !defined $agent->{tools};
  my %own   = $self->_own_tools;
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

sub _build_own_todos {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  return Langertha::Raider::TodoTools->new( on_update => sub {
    my ( $list ) = @_;
    my $sub = $weak or return;
    $sub->_set_todos($list);
    $sub->event( 'todo.updated', todos => [ map { { %$_ } } @$list ] );
  } );
}

sub _build_own_file_server {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  return $self->app->_file_tools_server(
    read_state  => $self->file_read_state,
    sees_images => sub { $weak && $weak->app ? $weak->app->_engine_sees_images( $weak->engine ) : 0 },
    reads_pdf   => sub { $weak && $weak->app ? $weak->app->_engine_reads_pdf( $weak->engine ) : 0 },
  );
}

sub _build_file_read_state { Langertha::Raider::FileTools::ReadState->new }

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
      policy  => $weak->permissions,
    } },
  )->tools->[0];
}

# exit_plan_mode of the subagent: nobody reviews a subagent's plan and its
# mode never changes the caller's, so in plan mode the plan is its answer.
sub _own_plan_tool {
  my ( $self ) = @_;
  weaken( my $weak = $self );
  return Langertha::Raider::PlanTools->new( handler => sub {
    my $sub = $weak or return ( 'the subagent is gone', 1 );
    # Claude Code's words (ADR 0026), without its pointer to enter_plan_mode,
    # which a subagent does not have.
    return ( '<tool_use_error>You are not in plan mode. If your plan was already approved, continue with '
      .'implementation.</tool_use_error>', 1 )
      unless $sub->permissions->mode eq 'plan';
    return ( 'Nobody can approve the plan in a subagent. Stay in plan mode and give the plan as your final'
      .' answer; the caller gets it.', 0 );
  } )->server->tools->[0];
}

=method briefing_class

The class of L</briefing>: L<Langertha::Raider::Briefing>.

=cut

sub briefing_class { 'Langertha::Raider::Briefing' }

sub _build_briefing {
  my ( $self ) = @_;
  return $self->briefing_class->new(
    agent    => $self->agent->{name},
    skills   => [ @{ $self->agent->{skills} // [] } ],
    resolver => $self->app->context->skill_resolver,
  );
}

sub _build_briefed_prompt {
  my ( $self ) = @_;
  return $self->briefing->prompt( $self->prompt );
}

sub _build_model_resolution {
  my ( $self ) = @_;
  my $app = $self->app;
  return $app->context->agent_catalog->resolve_model( $self->agent->{model},
    engine_class => scalar eval { $app->_engine_class },
    engine_name  => $app->engine_name,
    agent_models => $app->agent_models,
  );
}

sub _build_mission {
  my ( $self ) = @_;
  return $self->app->compile_mission( $self->agent->{body} // '', $self->tool_servers );
}

sub _build_mcps {
  my ( $self ) = @_;
  my $app = $self->app;
  # The caller's configured MCP servers lead, as views by the agent's tools
  # (same connections, same engine:N for the policy; ADR 0029).
  return [ $app->configured_mcp->views( tools => $self->agent->{tools}, disallowed => $self->agent->{disallowed} ),
    map { $app->_mcp_client($_) } @{ $self->tool_servers } ];
}

sub _build_engine {
  my ( $self ) = @_;
  my $model = $self->model_resolution->{model};
  return $self->app->build_subagent_engine( mcp_servers => $self->_mcps,
    defined $model ? ( model => $model ) : () );
}

sub _build_raider {
  my ( $self ) = @_;
  my $app = $self->app;
  weaken( my $weak = $self );
  my %hook = (
    input   => sub { $weak ? $weak->_hook_fields : () },
    on_stop => sub { $weak->cancel if $weak },
  );
  return Langertha::Raider->new(
    _tool_gate                 => $app->tool_gate(
      policy   => $self->permissions,
      on_event => sub { $weak->event(@_) if $weak },
      binding  => sub { $weak ? $weak->approval_binding : () },
    ),
    ( $app->context->claude_layout
      ? ( _tool_hook => $app->tool_hook( %hook, on_event => sub { $weak->event(@_) if $weak } ) ) : () ),
    engine                     => $self->engine,
    mission                    => $self->mission,
    max_iterations             => $app->max_iterations,
    max_context_tokens         => $app->max_context_tokens,
    context_compress_threshold => $app->context_compress_threshold,
    plugins                    => [ $app->run_plugins( sub { $weak->event(@_) if $weak }, %hook ) ],
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
