package Test::Raider::MockAI;
# ABSTRACT: A scripted model driving the real raider application and its real tools

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Path::Tiny;

our @EXPORT_OK = qw( mock_app );

=head1 SYNOPSIS

    use Test::Raider::MockAI qw( mock_app );

    my $app = mock_app(
      root   => $dir,
      script => [
        { tool_calls => [ [ write_file => { path => 'a.txt', content => 'hi' } ] ] },
        { text => 'written' },
      ],
    );
    my $result = $app->run('write a file');

    $app->mock_engine->results;    # what every tool call returned, in order
    $app->mock_engine->requests;   # the conversation of every model request

=head1 DESCRIPTION

The mock model answers from a script, one entry per model request: either
C<< { tool_calls => [ [ $name, \%arguments ], ... ] } >> or C<< { text => $answer } >>.
When the script runs out it answers C<done>. Everything else is the real
thing: L<Langertha::Raider::Application>, the raid loop, the plugins, and the
stock tool servers (files, bash, web) mounted over L<Net::Async::MCP>. A tool
that is called really runs, inside C<root>. No network, no key, no cost.

This is the base of the scenario suite (F<t/scenarios/>, F<t/200_scenarios.t>):
each scenario scripts the model, runs a prompt and states what must have
happened to the files, the tool results and the answer.

=cut

{
  package Test::Raider::MockAI::Response;
  use Moose;
  sub is_success  { 1 }
  sub status_line { '200 OK' }
  sub content     { '' }
  __PACKAGE__->meta->make_immutable;
}

{
  package Test::Raider::MockAI::HTTP;
  use Moose;
  use IO::Async::Loop;
  has loop => (is => 'ro', required => 1);
  sub do_request { return $_[0]->loop->new_future->done(Test::Raider::MockAI::Response->new) }
  __PACKAGE__->meta->make_immutable;
}

{
  package Test::Raider::MockAI::Engine;
  use Moose;
  with 'Langertha::Role::Tools';

  has chat_model     => (is => 'ro', default => 'mock-model');
  has script         => (is => 'rw', default => sub { [] });
  has loop           => (is => 'ro', required => 1);
  has requests       => (is => 'ro', default => sub { [] });
  has results        => (is => 'ro', default => sub { [] });
  has calls          => (is => 'ro', default => sub { [] });
  has _http          => (is => 'ro', lazy => 1,
    default => sub { Test::Raider::MockAI::HTTP->new(loop => $_[0]->loop) });

  sub async_request_f { return $_[0]->_http->do_request }
  sub async_loop      { return $_[0]->loop }

  sub format_tools            { return $_[1] }
  sub response_tool_calls     { return $_[1]->{tool_calls} // [] }
  sub response_text_content   { return $_[1]->{text} }
  sub extract_tool_call       { return ( $_[1]->{name}, $_[1]->{input} ) }
  sub think_tag_filter        { 0 }

  sub build_tool_chat_request {
    my ( $self, $conversation ) = @_;
    push @{ $self->requests }, [ @$conversation ];
    return { request => 1 };
  }

  # The next scripted step, in the shape the raid loop reads.
  sub parse_response {
    my ( $self ) = @_;
    my $step = shift @{ $self->script } // { text => 'done' };
    return { text => $step->{text} } unless $step->{tool_calls};
    my $i = 0;
    return { text => $step->{text}, tool_calls => [ map {
      my ( $name, $input ) = @$_;
      push @{ $self->calls }, [ $name, $input ];
      { id => 'mock'.++$i, name => $name, input => $input }
    } @{ $step->{tool_calls} } ] };
  }

  sub format_tool_results {
    my ( $self, $data, $results ) = @_;
    push @{ $self->results }, @$results;
    return map { { role => 'tool', content => 'r' } } @$results;
  }

  __PACKAGE__->meta->make_immutable;
}

{
  package Test::Raider::MockAI::App;
  use Moose;
  extends 'Langertha::Raider::Application';
  has script => (is => 'ro', default => sub { [] });
  sub mock_engine { $_[0]->_engine }
  sub _build_engine {
    my ( $self ) = @_;
    return Test::Raider::MockAI::Engine->new(
      script      => [ @{ $self->script } ],
      loop        => $self->loop,
      mcp_servers => $self->_mcps,
    );
  }
  __PACKAGE__->meta->make_immutable;
}

=func mock_app

    my $app = mock_app( root => $dir, script => \@steps, %application_args );

Builds the application over C<root> with the mock model. Every further
argument goes to L<Langertha::Raider::Application>.

=cut

sub mock_app {
  my ( %args ) = @_;
  return Test::Raider::MockAI::App->new(
    engine_name => 'openai',
    api_key     => 'mock',
    %args,
  );
}

1;
