package Langertha::Raider::Hooks::Result;
# ABSTRACT: Internal value of one hook event: the merged answer of its hooks and a report per run
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $r = await $hooks->run_f( PreToolUse => { tool_name => 'bash', tool_input => { command => 'ls' } } );
    return deny( $r->reason ) if ( $r->decision // '' ) eq 'deny';
    $args = $r->updated_input if $r->updated_input;
    journal( 'hook.run', %$_ ) for @{ $r->runs };

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

What L<Langertha::Raider::Hooks/run_f> answers for one event: every hook
that ran is one entry of L</runs>, and their outputs are merged into one
answer. Which fields an event uses is the caller's business; the runner
only fills them the way Claude Code reads them:

=over

=item * C<PreToolUse> -- L</decision> (C<deny> E<gt> C<ask> E<gt> C<allow>),
L</reasons> of the winning decision, L</updated_input> (raider form),
L</additional_context>

=item * C<UserPromptSubmit> -- L</blocked> (the prompt does not go to the
model; L</reasons> are for the user), L</additional_context> (plain stdout
counts)

=item * C<PostToolUse>, C<PostToolUseFailure> -- L</blocked> with
L</reasons>: feedback next to the tool result (the tool already ran),
L</additional_context>

=item * C<Stop>, C<SubagentStop> -- L</blocked>: do not stop, L</reasons>
are the next instruction; L</additional_context>: go on with this feedback

=item * C<SessionStart>, C<SubagentStart> -- L</additional_context> only
(plain stdout counts for C<SessionStart>)

=item * every event -- L</system_messages> for the user, L</stopped> and
L</stop_reason> (C<continue: false> ends the run, whatever else was said),
L</errors> (non-blocking: the action goes ahead)

=back

=attr event

The event name, e.g. C<PreToolUse>.

=cut

has event => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr runs

One hash ref per hook the event selected, in configuration order,
including the ones skipped (duplicate, native briefing, unsupported type)
and async hooks still running:

    {
      event       => 'PreToolUse',
      source      => '.claude/settings.json' | 'plugin:loadguard',
      plugin      => 'loadguard' | undef,
      matcher     => 'Bash' | undef,
      command     => '${CLAUDE_PLUGIN_ROOT}/hooks/loadguard',   # as configured
      args        => [ '${CLAUDE_PLUGIN_DATA}' ] | undef,       # as configured
      argv        => [ '/abs/hooks/loadguard', '/abs/data' ],   # what was started
      form        => 'exec' | 'shell',
      async       => 0 | 1,
      timeout     => 5,                                         # seconds; undef for async
      outcome     => 'success' | 'block' | 'error' | 'timeout' | 'skipped' | 'running' | 'cancelled',
      message     => undef | 'why it is an error or was skipped',
      exit        => 0, signal => 0,                            # undef when not started
      duration_ms => 12,
      stdout      => '...', stderr => '...',
      output      => 'empty' | 'text' | 'json' | 'invalid',
      json        => { ... } | undef,                           # the decoded stdout
    }

=attr errors

Non-blocking errors, one line each in Claude Code's words
(C<PreToolUse:Bash hook error: [cmd]: Failed with non-blocking status
code: ...>), plus configuration problems (an invalid matcher). The action
goes ahead.

=attr decision

C<PreToolUse> only: C<deny>, C<ask>, C<allow> or C<undef> (no hook
decided). Exit code 2 is C<deny>.

=attr reasons

The reasons that go with L</decision> (C<permissionDecisionReason>, the
stderr of an exit 2) or with L</blocked> (C<reason>, the stderr of an exit
2), in configuration order.

=attr blocked

True when a hook blocked an event that can be blocked (C<decision:
"block"> or exit code 2): see L</DESCRIPTION> for what it means per event.
C<PreToolUse> uses L</decision> instead.

=attr additional_context

Text for the model: every C<hookSpecificOutput.additionalContext>, and the
plain stdout of C<UserPromptSubmit> and C<SessionStart> hooks, in
configuration order.

=attr system_messages

Every C<systemMessage>, for the user.

=attr stopped

True when a hook answered C<continue: false>; then nothing else counts.

=attr stop_reason

The first C<stopReason> of a stopping hook, else C<undef>.

=attr updated_input

C<PreToolUse> only: the tool arguments a hook replaced, in raider form
(translated back by L<Langertha::Raider::ToolNames/raider_input>), or
C<undef>. Never set when L</decision> is C<deny>.

=cut

has [qw( runs errors reasons additional_context system_messages )] => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

has decision => (
  is  => 'ro',
  isa => 'Maybe[Str]',
);

has [qw( blocked stopped )] => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has stop_reason => (
  is  => 'ro',
  isa => 'Maybe[Str]',
);

has updated_input => (
  is  => 'ro',
  isa => 'Maybe[HashRef]',
);

=method reason

    my $why = $r->reason;   # L</reasons> joined with newlines, or undef

=method context

    my $text = $r->context;   # L</additional_context> joined with blank lines, or undef

=method ran

The number of hooks that were started (not skipped).

=cut

sub reason {
  my ( $self ) = @_;
  my @r = grep { defined && length } @{ $self->reasons };
  return @r ? join("\n", @r) : undef;
}

sub context {
  my ( $self ) = @_;
  my @c = grep { defined && length } @{ $self->additional_context };
  return @c ? join("\n\n", @c) : undef;
}

sub ran { scalar grep { $_->{outcome} ne 'skipped' } @{ $_[0]->runs } }

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Hooks>

=back

=cut
