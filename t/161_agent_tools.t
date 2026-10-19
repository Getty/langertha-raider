#!/usr/bin/env perl
# ABSTRACT: The agent tool: its text, call checks, and where the application mounts it (ADR 0020 §3, k153)
use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use Test::Raider::Env qw( isolate_home );
isolate_home();
use File::Temp qw( tempdir );
use Path::Tiny;
use Langertha::Raider::AgentTools;
use Langertha::Raider::Application;
use Langertha::Raider::Context::Agents;
use Langertha::Raider::ToolEffects;

delete @ENV{qw( ANTHROPIC_API_KEY OPENAI_API_KEY RAIDER_HALL_SOCKET RAIDER_PACK_DIRS )};

sub invoke {
  my ( $server, $args ) = @_;
  my ($tool) = grep { $_->name eq 'agent' } @{ $server->tools };
  return $tool->code->( $tool, $args );
}
sub text { $_[0]{content}[0]{text} }

sub catalog {
  my ( %files ) = @_;
  my $dir = path( tempdir( CLEANUP => 1 ) );
  $dir->child($_)->spew_utf8( $files{$_} ) for keys %files;
  return Langertha::Raider::Context::Agents->new( roots => [ { dir => "$dir", source => '.raider/agents' } ] );
}

my $catalog = catalog(
  'reader.md'  => "---\ndescription: Reads only.\ntools: Read, Grep\n---\nbody\n",
  'careful.md' => "---\ndescription: No shell.\ndisallowedTools: Bash, Write\n---\nbody\n",
  'mute.md'    => "---\ndescription: Nothing at all.\ntools: NotebookEdit\n---\nbody\n",
);

subtest 'the tool text lists every agent with its tools' => sub {
  my $tools = Langertha::Raider::AgentTools->new( catalog => $catalog, on_spawn => sub { die 'not called' } );
  my $text = $tools->description;
  like( $text, qr/\ALaunch a new agent to handle complex, multi-step tasks autonomously\./, 'Claude Code opening' );
  like( $text, qr/^Available agent types and the tools they have access to:$/m, 'the list header' );
  like( $text, qr/^- careful: No shell\. \(Tools: All tools except bash, write_file\)$/m, 'disallowed only: all except, raider names' );
  like( $text, qr/^- mute: Nothing at all\. \(Tools: none\)$/m, 'only unknown names: none' );
  like( $text, qr/^- reader: Reads only\. \(Tools: read_file, grep\)$/m, 'allow-list in raider names' );
  like( $text, qr/^- general-purpose: General-purpose agent for researching complex questions.* \(Tools: \*\)$/m,
    'the built-in, all tools' );
  like( $text, qr/no memory of this conversation.*self-contained prompt/, 'the prompt must stand alone' );
  like( $text, qr/final message is returned to you/, 'what comes back' );
  like( $text, qr/Several agent calls in one message are fine; they run one after the other/, 'several calls: one after the other' );
  unlike( $text, qr/concurren|in parallel|simultaneous/i, 'no promise of concurrency (ADR 0020 section 4)' );

  my ($tool) = @{ $tools->server->tools };
  is( $tool->name, 'agent', 'one tool named agent' );
  is( $tool->description, $text, 'the text is the tool description' );
  is( $tool->input_schema->{required}, [qw( description prompt )], 'description and prompt required' );
  ok( $tool->input_schema->{properties}{subagent_type}, 'subagent_type optional' );
};

subtest 'a call goes to on_spawn with the agent; unknown types and empty prompts do not' => sub {
  my @spawned;
  my $tools = Langertha::Raider::AgentTools->new(
    catalog  => $catalog,
    on_spawn => sub { push @spawned, [@_]; return ( $_[1]{subagent_type} eq 'mute' ? ( 'it broke', 1 ) : ( 'agent text', 0 ) ) },
  );

  my $r = invoke( $tools->server, { description => 'Look', prompt => 'Find it.' } );
  ok( !$r->{isError}, 'succeeds' );
  is( text($r), 'agent text', 'the result is what on_spawn returned' );
  is( $spawned[0][0]{name}, 'general-purpose', 'without subagent_type: general-purpose' );
  is( $spawned[0][1], { description => 'Look', prompt => 'Find it.', subagent_type => 'general-purpose' }, 'the call' );

  $r = invoke( $tools->server, { description => 'x', prompt => 'y', subagent_type => 'reader' } );
  is( $spawned[1][0]{name}, 'reader', 'the named agent' );

  $r = invoke( $tools->server, { description => 'x', prompt => 'y', subagent_type => 'mute' } );
  ok( $r->{isError}, 'an error from on_spawn is an error result' );
  is( text($r), 'it broke', 'with its text' );

  @spawned = ();
  $r = invoke( $tools->server, { description => 'x', prompt => 'y', subagent_type => 'nope' } );
  ok( $r->{isError}, 'unknown subagent_type: error' );
  is( text($r), "Unknown agent type 'nope'. Available agents: careful, mute, reader, general-purpose.",
    'names the available agents' );
  $r = invoke( $tools->server, { description => 'x', prompt => "  \n" } );
  ok( $r->{isError}, 'an empty prompt: error' );
  like( text($r), qr/prompt is empty/, 'says so' );
  is( \@spawned, [], 'neither started a subagent' );
};

sub app {
  my ( %args ) = @_;
  return Langertha::Raider::Application->new(
    root    => tempdir( CLEANUP => 1 ),
    engine  => 'openai',
    api_key => 'test',
    detect  => 0,
    %args,
  );
}

subtest 'the application mounts the agent tool below the depth limit' => sub {
  my $app = app();
  is( $app->max_agent_depth, 1, 'default depth 1' );
  ok( ( grep { $_->name eq 'agent' } $app->_mounted_tools ), 'agent mounted at depth 0' );
  like( $app->mission, qr/^  - agent\(description, prompt, \[subagent_type\]\)$/m, 'and described' );

  my $none = app( max_agent_depth => 0 );
  ok( !( grep { $_->name eq 'agent' } $none->_mounted_tools ), 'max_agent_depth 0: no agent tool' );
  unlike( $none->mission, qr/agent\(/, 'nor its description' );

  is( Langertha::Raider::ToolEffects->effects_for('agent'), [], 'no effect class of its own' );
  my ($entry) = grep { $_->{name} eq 'agent' } @{ $app->explain_config->{tools} };
  ok( $entry, 'config explain lists it' ) && is( $entry->{effects}, [], 'known, no effects' );
};

subtest 'build_subagent_engine: the main engine class and arguments, model replaceable' => sub {
  my $app = app( model => 'gpt-4o-mini' );
  my $engine = $app->build_subagent_engine( mcp_servers => [] );
  isa_ok( $engine, 'Langertha::Engine::OpenAI' );
  is( $engine->chat_model, 'gpt-4o-mini', 'inherits the model' );
  is( $engine->mcp_servers, [], 'over the given clients' );
  is( $app->build_subagent_engine( mcp_servers => [], model => 'gpt-other' )->chat_model, 'gpt-other',
    'a model given replaces it' );
};

done_testing;
