package Langertha::Raider::Plugin::ClaudeHooks;
our $VERSION = '0.504';
# ABSTRACT: Internal plugin that runs the Claude Code PostToolUse hooks on tool results

use Moose;
use namespace::autoclean;
use Future::AsyncAwait;

extends 'Langertha::Plugin';

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $raider = Langertha::Raider->new(
        engine  => $engine,
        plugins => [ '+Langertha::Raider::Plugin::ClaudeHooks' => { app => $app } ],
    );

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The tool-result side of Claude Code's hooks (ADR 0022) in the Claude
layout. After every tool call it

=over

=item * appends the C<additionalContext> a C<PreToolUse> hook gave for
this call (L<Langertha::Raider::Application/tool_hook> keeps it),

=item * runs the C<PostToolUse> hooks of
L<Langertha::Raider::Application/hooks> on a result that is not an error
and was not cut off by a cancel, with C<tool_name> and C<tool_input> in
Claude Code's form and C<tool_response> as raider's result (an MCP
C<content> list, not Claude Code's per-tool shape), and appends their
C<additionalContext> and the reason of a C<decision: "block"> (or the
stderr of exit 2) -- the tool already ran, so this is feedback for the
model,

=back

each as one more text block wrapped in C<< <system-reminder> >>, the way
L<Langertha::Raider::Plugin::NestedMemory> appends. It sits after
NestedMemory and before the Events plugin, so C<tool.result> in the
journal is the result as the model gets it. The hook runs are reported by
the application (C<hook.ran>, C<hook.message>) to L</on_event>; a
C<continue: false> calls L</on_stop> (default: the run is cancelled). A
failed call (C<isError>) fires no hook: C<PostToolUseFailure> is not run.

=attr app

The L<Langertha::Raider::Application>. Required; held weakly.

=attr on_event

Where the hook runs are reported, called as C<< ->($type, %payload) >>:
the Events consumer of the raider (a subagent's journal). Default: the
application's L<Langertha::Raider::Application/event>.

=attr input

Optional code ref whose pairs go into every hook input -- a subagent's
C<agent_id>, C<agent_type> and C<permission_mode>.

=attr on_stop

Optional code ref called on a C<continue: false>; default
L<Langertha::Raider::Application/cancel_run>.

=cut

has app => (
  is       => 'ro',
  required => 1,
  weak_ref => 1,
);

has on_event => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_on_event',
);

has input => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_input',
);

has on_stop => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_on_stop',
);

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result ) = @_;
  my $app = $self->app or return $result;
  return $result unless ref $result eq 'HASH';
  my @blocks;
  if (defined( my $pre = $app->_take_tool_hook_context($input) )) {
    push @blocks, $pre;
  }
  my $hooks = $app->hooks;
  if ($hooks && $hooks->has_hooks('PostToolUse') && !$result->{isError} && !$result->{cancelled}) {
    my $r = await $hooks->run_f( PostToolUse => $app->_hook_input(
      ( $self->has_input ? $self->input->() : () ),
      tool_name     => $name,
      tool_input    => ref $input eq 'HASH' ? $input : {},
      tool_response => { content => $result->{content} // [] },
    ) );
    $app->_report_hooks($r, $self->has_on_event ? $self->on_event : undef);
    $app->_hook_stopped($self->has_on_stop ? $self->on_stop : undef) if $r->stopped;
    my $tag = $app->_hook_tag('PostToolUse', $name);
    push @blocks, map { $tag.' hook feedback: '.$_ } @{ $r->reasons } ? @{ $r->reasons } : '(no reason given)'
      if $r->blocked;
    push @blocks, $tag.' hook additional context: '.$r->context if defined $r->context;
  }
  return $result unless @blocks;
  return {
    %$result,
    content => [
      ( ref $result->{content} eq 'ARRAY' ? @{ $result->{content} } : () ),
      map { { type => 'text', text => "<system-reminder>\n".$_."\n</system-reminder>" } } @blocks,
    ],
  };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Hooks>

=item * L<Langertha::Raider::Plugin::NestedMemory>

=back

=cut
