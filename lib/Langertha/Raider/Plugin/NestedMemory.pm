package Langertha::Raider::Plugin::NestedMemory;
our $VERSION = '0.505';
# ABSTRACT: Internal plugin that appends nested CLAUDE.md files to the results of file tools

use Moose;
use namespace::autoclean;
use Future::AsyncAwait;

extends 'Langertha::Plugin';

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $raider = Langertha::Raider->new(
        engine  => $engine,
        plugins => [ '+Langertha::Raider::Plugin::NestedMemory' => {
          context => $app->context,   # Langertha::Raider::Context
        } ],
    );

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Claude Code's nested memory (ADR 0019 E<sect>2.4): F<CLAUDE.md> files below
the project root are not in the system prompt. The first time a tool
touches a path in such a subtree, this plugin appends that subtree's
F<CLAUDE.md> to the tool's result, as one more text block wrapped in
C<< <system-reminder> >> ... C<< </system-reminder> >> -- once per file and
session (L<Langertha::Raider::Context/nested_memory_for> keeps track).

Any tool counts whose arguments carry a C<path> or C<file_path> string:
C<read_file>, C<write_file>, C<edit_file>, C<list_files> and every later
tool of that shape. A result that is an error (C<isError>) or was cut off
by a cancel is left alone and uses up nothing. The same touch brings in
skills (k157): the F<.claude/skills> of a subtree and the skills whose
C<paths:> match the file, announced in a second block of the same kind
(L<Langertha::Raider::Context/nested_skills_for>). The application mounts
the plugin always; outside the Claude layout only the C<paths:> skills of
the other skill roots can fire.

=attr context

The L<Langertha::Raider::Context> (anything with C<nested_reminders_for>).
Required.

=cut

has context => (
  is       => 'ro',
  required => 1,
);

=method path_keys

The argument names that carry the path a tool touches: C<path>,
C<file_path>.

=cut

sub path_keys { qw( path file_path ) }

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result ) = @_;
  return $result unless ref $result eq 'HASH' && ref $input eq 'HASH';
  return $result if $result->{isError} || $result->{cancelled};
  my ( $path ) = grep { defined && !ref && length } map { $input->{$_} } $self->path_keys;
  return $result unless defined $path;
  my @texts = $self->context->nested_reminders_for($path);
  return $result unless @texts;
  return {
    %$result,
    content => [
      ( ref $result->{content} eq 'ARRAY' ? @{ $result->{content} } : () ),
      map { { type => 'text', text => "<system-reminder>\n".$_."\n</system-reminder>" } } @texts,
    ],
  };
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Context::Memory/nested_for>

=item * L<Langertha::Plugin>

=back

=cut
