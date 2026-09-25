use strict;
use warnings;
use Test2::V0;
use File::Temp qw( tempdir );
use Path::Tiny;
use YAML::PP ();
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );
use Langertha::Raider::Config;
use Langertha::Raider::EngineResolver;

# The provider choice on its own, without an application around it:
# engine, model and key precedence, and what goes to the engine class.

clear_engine_env();

sub resolver {
  my ( $yml, %args ) = @_;
  my $root = path(tempdir(CLEANUP => 1));
  $root->child('.raider.yml')->spew_utf8(YAML::PP->new->dump_string($yml)) if $yml;
  return Langertha::Raider::EngineResolver->new(
    config => Langertha::Raider::Config->new(root => "$root"),
    %args,
  );
}

subtest 'engine: flag, -o, .raider.yml, environment, anthropic' => sub {
  is(resolver()->engine_name, 'anthropic', 'nothing set');
  {
    local $ENV{GROQ_API_KEY} = 'x';
    is(resolver()->engine_name, 'groq', 'first *_API_KEY found');
    is(resolver({ engine => 'mistral' })->engine_name, 'mistral', '.raider.yml beats the environment');
  }
  is(resolver({ engine => 'mistral' }, engine_options => { engine => 'gemini' })->engine_name,
    'gemini', '-o engine= beats .raider.yml');
  is(resolver({ engine => 'mistral' }, engine => 'openai', engine_options => { engine => 'gemini' })
    ->engine_name, 'openai', 'the flag beats -o');
};

subtest 'model and key' => sub {
  my $r = resolver({ default => { temperature => 0.3 } }, engine => 'openai');
  is($r->model, 'gpt-4o-mini', 'cheap default');
  ok($r->has_model, 'has a model');
  is($r->api_key, '', 'no key anywhere');
  is($r->api_key_env, 'OPENAI_API_KEY', 'key variable');
  local $ENV{OPENAI_API_KEY} = 'env-key';
  is(resolver(undef, engine => 'openai')->api_key, 'env-key', 'key from the environment');
  is(resolver(undef, engine => 'openai', engine_options => { api_key => 'opt-key' })->api_key,
    'opt-key', '-o api_key= beats the environment');
  is(resolver(undef, engine => 'ollama')->api_key_env, undef, 'ollama has no key variable');
  is(Langertha::Raider::EngineResolver->default_model_for_engine('groq'), 'llama-3.3-70b-versatile',
    'default model on the class');
};

subtest 'engine arguments' => sub {
  my $r = resolver({ default => { temperature => 0.3, model => 'yml-model', perl => 1 } },
    engine => 'openai', model => 'flag-model',
    engine_options => { temperature => 0.5, packs => 'caveman', api_key => 'opt-key' });
  is({ $r->engine_args(mcp_servers => []) },
    { temperature => 0.5, model => 'flag-model', api_key => 'opt-key', mcp_servers => [] },
    '-o over .raider.yml, raider keys left out, flag model last');
  is($r->engine_class, 'Langertha::Engine::OpenAI', 'engine class');
  my $engine = $r->build_engine(mcp_servers => []);
  isa_ok($engine, 'Langertha::Engine::OpenAI');
  is($engine->model, 'flag-model', 'built with the model');
  is(dies { resolver(undef, engine => 'nope')->engine_class }, "Unknown engine: nope\n",
    'unknown engine');
};

done_testing;
