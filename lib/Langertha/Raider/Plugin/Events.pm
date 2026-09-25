package Langertha::Raider::Plugin::Events;
our $VERSION = '0.503';
# ABSTRACT: Report a raid's tool calls and results as machine-output events

use Moose;
use namespace::autoclean;
use Future::AsyncAwait;
use JSON::MaybeXS ();

extends 'Langertha::Plugin';

=head1 SYNOPSIS

    my $raider = Langertha::Raider->new(
        engine  => $engine,
        plugins => [ '+Langertha::Raider::Plugin::Events' => {
          on_event => sub { my ( $type, %payload ) = @_; ... },
        } ],
    );

=head1 DESCRIPTION

The source of the C<tool.call> and C<tool.result> events of
C<raider --stream-json> and its siblings (ADR 0013). Every tool call the
raid makes is handed to L</on_event> twice: before it runs, with its name
and arguments, and after, with the outcome and the first
L</max_content_length> characters of its text.

Load it after any plugin that may skip or rewrite a tool call, so the
events describe the call that actually runs.

=attr on_event

Code reference called as C<< $on_event->($type, %payload) >>. Required.

=over

=item C<tool.call> -- C<name>, C<arguments>.

=item C<tool.result> -- C<name>, C<ok> (false when the tool reported an
error), C<size> (characters of the whole text), C<content> (the text, cut to
L</max_content_length>) and C<truncated> (whether it was cut).

=back

=cut

has on_event => (
  is       => 'ro',
  isa      => 'CodeRef',
  required => 1,
);

=attr max_content_length

How many characters of a tool result's text go into C<content>. Defaults to
C<1000>.

=cut

has max_content_length => (
  is      => 'ro',
  isa     => 'Int',
  default => 1000,
);

async sub plugin_before_tool_call {
  my ( $self, $name, $input ) = @_;
  $self->on_event->('tool.call', name => $name, arguments => $input // {});
  return ( $name, $input );
}

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result ) = @_;
  my ( $text, $ok ) = ref $result eq 'HASH'
    ? ( join('', map { $_->{text} // '' } grep { ref $_ eq 'HASH' }
        ref $result->{content} eq 'ARRAY' ? @{ $result->{content} } : ()),
        !$result->{isError} )
    : ( $result // '', 1 );
  my $max = $self->max_content_length;
  $self->on_event->('tool.result',
    name      => $name,
    ok        => $ok ? JSON::MaybeXS->true : JSON::MaybeXS->false,
    size      => length $text,
    content   => substr($text, 0, $max),
    truncated => length $text > $max ? JSON::MaybeXS->true : JSON::MaybeXS->false,
  );
  return $result;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI::Machine>

=item * L<Langertha::Plugin>

=back

=cut
