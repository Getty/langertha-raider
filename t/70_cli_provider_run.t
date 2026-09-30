#!/usr/bin/env perl
# ABSTRACT: raider --provider HOST: the command line, and a run on a manifest's endpoint (k119)
use strict;
use warnings;
use utf8;
use Test2::V0;
use Encode qw( decode_utf8 );
use Future;
use JSON::MaybeXS ();
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env isolate_home );
use Test::Raider::FakeHTTPS;
isolate_home();
clear_engine_env();

my $pki = Test::Raider::FakeHTTPS->pki( names => [ 'provider.example', 'localhost' ] );
our $CA = $pki->{ca};
# The engine's own TLS client trusts the test CA through the default CA
# store: IO::Socket::SSL reads SSL_CERT_FILE.
$ENV{SSL_CERT_FILE} = $CA;

use Langertha::Engine::Anthropic;
use Langertha::Raider::CLI::Main;
use Langertha::Raider::CLI::Output;
use Langertha::Raider::Config;
use Langertha::Raider::EngineResolver;

# The manifest fetch trusts the test CA; every name resolves to the fake
# server. The engine itself connects to the address literal the manifest
# names, so nothing needs DNS.
package My::Provider {
  use Moose;
  extends 'Langertha::Raider::CLI::Provider';
  has '+fetch_args' => ( default => sub { {
    ssl_options => { SSL_ca_file => $main::CA },
    resolver    => sub { Future->done('127.0.0.1') },
    # not the production 10 s: a loaded machine must not turn a slow fetch into a red test
    timeout     => 120,
  } } );
  __PACKAGE__->meta->make_immutable;
}

package My::Main {
  use Moose;
  extends 'Langertha::Raider::CLI::Main';
  sub provider_class { 'My::Provider' }
  __PACKAGE__->meta->make_immutable;
}

sub buffer {
  my $buf = '';
  open my $fh, '>:encoding(UTF-8)', \$buf or die $!;
  return ( $fh, sub { $fh->flush; decode_utf8($buf) } );
}

my $root = Path::Tiny->tempdir;
# A .raider.yml with a key, a URL and a model meant for another provider.
$root->child('.raider.yml')->spew_utf8(
  "api_key: yml-secret\nurl: https://api.example/v1\nmodel: yml-model\nopenai:\n  api_key: yml-section-secret\n" );

sub main_run {
  my ( @argv ) = @_;
  my ( $out, $read_out ) = buffer();
  my ( $err, $read_err ) = buffer();
  local $ENV{ANSI_COLORS_DISABLED};
  my $exit = My::Main->new(
    output => Langertha::Raider::CLI::Output->new( out => $out, color => 0 ),
    err    => $err,
    in     => do { open my $in, '<', \'' or die $!; $in },
  )->run( '-r', "$root", '--no-session', '--no-trace', @argv );
  my @res = ( $exit, $read_out->(), $read_err->() );
  diag $res[2] if $res[2] =~ /timed out/;
  return @res;
}

my $T = JSON::MaybeXS->true;

sub manifest {
  my ( %over ) = @_;
  return {
    schema_version => 1,
    kind           => 'langertha-provider',
    provider_id    => 'example-provider',
    issuer         => 'ORIGIN',
    endpoints      => [ { id => 'chat', dialect => 'openai-chat', base_url => 'ORIGIN/v1', auth_ref => 'api' } ],
    auth           => [ { id => 'api', type => 'api_key' } ],
    models         => [ { id => 'm1', endpoint_ref => 'chat', capabilities => { tools_native => $T } } ],
    %over,
  };
}

my $other = Test::Raider::FakeHTTPS->new( pki => $pki, routes => {} );
my $other_port = $other->port;

my %manifests = (
  '/.well-known/langertha.json' => manifest(),
  '/two.json'    => manifest( models => [ { id => 'a', endpoint_ref => 'chat' }, { id => 'b', endpoint_ref => 'chat' } ] ),
  '/noauth.json' => manifest( endpoints => [ { id => 'chat', dialect => 'openai-chat', base_url => 'ORIGIN/v1' } ], auth => [],
                      models => [ { id => 'm1', endpoint_ref => 'chat' } ] ),
  '/redir.json'  => manifest( endpoints => [ { id => 'chat', dialect => 'openai-chat', base_url => 'ORIGIN/redir/v1', auth_ref => 'api' } ] ),
  '/pigeon.json' => manifest( endpoints => [ { id => 'chat', dialect => 'carrier-pigeon', base_url => 'ORIGIN/v1', auth_ref => 'api' } ] ),
);
my %routes = map {
  my $doc = JSON::MaybeXS->new( canonical => 1 )->encode( $manifests{$_} );
  ( $_ => sub {
    my ( $req ) = @_;
    ( my $served = $doc ) =~ s{ORIGIN}{https://$req->{headers}{host}}g;
    Test::Raider::FakeHTTPS->json( 200, $served );
  } );
} keys %manifests;
$routes{'/v1/chat/completions'} = sub {
  Test::Raider::FakeHTTPS->json( 200, {
    id => 'c1', object => 'chat.completion', created => 1, model => 'm1',
    choices => [ { index => 0, finish_reason => 'stop', message => { role => 'assistant', content => 'hello from the provider' } } ],
    usage => { prompt_tokens => 3, completion_tokens => 4, total_tokens => 7 },
  } );
};
# Every request to /redir/ is sent on to the other origin.
for my $path ( '/redir/v1/chat/completions', '/redir/v1/models' ) {
  ( my $to = $path ) =~ s{^/redir}{};
  $routes{$path} = sub { Test::Raider::FakeHTTPS->response( 307, '', Location => 'https://127.0.0.1:'.$other_port.$to ) };
}
my $srv  = Test::Raider::FakeHTTPS->new( pki => $pki, routes => \%routes );
my $host = '127.0.0.1:'.$srv->port;

# Run with the manifest at $path of the provider's origin.
sub provider_run {
  my ( $path, @args ) = @_;
  no warnings 'redefine';
  my $orig = \&Langertha::Raider::Provider::Fetch::target_url;
  local *Langertha::Raider::Provider::Fetch::target_url = sub {
    my $url = $orig->(@_);
    $url =~ s{/\.well-known/langertha\.json\z}{$path};
    return $url;
  };
  return main_run( '--provider', $host, '--allow-internal', @args );
}

# The requests since the first $seen, without the session embedding
# requests the raider sends on the side (they may arrive a subtest late;
# the last subtest checks every request).
sub requests_since {
  my ( $server, $seen ) = @_;
  my @requests = $server->requests;
  return grep { $_->{path} !~ m{/embeddings\z} } @requests[ $seen .. $#requests ];
}

my %env_keys = map { $_ => 'env-secret' } qw( OPENAI_API_KEY LANGERTHA_OPENAI_API_KEY ANTHROPIC_API_KEY );

subtest 'a run on the endpoint the manifest declares' => sub {
  local @ENV{ keys %env_keys } = values %env_keys;
  my $seen = () = $srv->requests;
  my ( $exit, $out, $err ) = main_run( '--provider', $host, '--allow-internal', '-k', 'sk-cli', '--json', 'say hello' );
  is( $exit, 0, 'exit 0' ) or diag $err;
  my $doc = JSON::MaybeXS->new->decode($out);
  is( [ @$doc{qw( status response )} ], [ 'completed', 'hello from the provider' ], 'the endpoint answered' );
  my @requests = requests_since( $srv, $seen );
  is( [ map { $_->{method}.' '.$_->{path} } @requests ],
    [ 'GET /.well-known/langertha.json', 'POST /v1/chat/completions' ], 'manifest, then the chat at base_url' );
  ok( !exists $requests[0]{headers}{authorization}, 'no key with the manifest fetch' );
  is( $requests[1]{headers}{authorization}, 'Bearer sk-cli', 'the -k key with the chat' );
  my $sent = JSON::MaybeXS->new->canonical->encode( [ map { $_->{headers} } @requests ] );
  unlike( $sent, qr/secret/, 'no key from .raider.yml or the environment' );
  unlike( $out.$err, qr/sk-cli/, 'the key is not in the output' );
};

subtest 'an endpoint without auth gets no key at all' => sub {
  local @ENV{ keys %env_keys } = values %env_keys;
  my $seen = () = $srv->requests;
  my ( $exit, $out, $err ) = provider_run( '/noauth.json', '--json', 'say hello' );
  is( $exit, 0, 'exit 0' ) or diag $err;
  like( $err, qr/^raider --provider: warning: model 'm1' does not declare tools_native; raider works through tool calls$/m,
    'the tools_native warning on stderr' );
  my @requests = requests_since( $srv, $seen );
  is( [ map { $_->{path} } @requests ], [ '/noauth.json', '/v1/chat/completions' ], 'manifest, then the chat' );
  ok( !exists $requests[1]{headers}{authorization}, 'no Authorization: the configured keys stay home' );
};

subtest 'a redirect does not carry the key to another origin' => sub {
  my $seen = () = $srv->requests;
  my ( $exit, $out, $err ) = provider_run( '/redir.json', '-k', 'sk-cli', '--json', 'say hello' );
  is( $exit, 1, 'the run fails' );
  is( JSON::MaybeXS->new->decode($out)->{status}, 'failed', 'a failed document' );
  is( [ map { $_->{path} } requests_since( $srv, $seen ) ], [ '/redir.json', '/redir/v1/chat/completions' ],
    'the chat POST got the redirect' );
  is( [ $other->requests ], [], 'the other origin got nothing' );
  unlike( $out.$err, qr/sk-cli/, 'the key is not in the output' );
};

subtest 'command-line errors: exit 2' => sub {
  for my $case (
    [ [ '--provider', $host, '-e', 'openai', 'hi' ], qr/^--provider: not with -e\/--engine; the provider manifest decides the engine and its URL$/, '-e' ],
    [ [ '--provider', $host, '-o', 'engine=openai', 'hi' ], qr/^--provider: not with -o engine=/, '-o engine=' ],
    [ [ '--provider', $host, '-o', 'url=https://x.example', 'hi' ], qr/^--provider: not with -o url=/, '-o url=' ],
    [ [ '--provider', $host, 'config', 'explain' ], qr/^--provider: not with config explain$/, 'config explain' ],
    [ [ '--allow-internal', 'hi' ], qr/^--allow-internal: only with --provider$/, '--allow-internal alone' ],
    [ [ '--provider', 'http://'.$host, 'hi' ], qr/^raider --provider: only https is allowed/, 'an http target' ],
    [ [ '--provider', $host, '--allow-internal', 'hi' ],
      qr/^raider --provider: endpoint 'chat' needs an API key \(auth 'api', type api_key\); pass it with -k KEY$/, 'no key' ],
    [ [ '--provider', $host, '--allow-internal', '-k', 'sk', '-m', 'gpt-9', 'hi' ],
      qr/^raider --provider: model 'gpt-9' is not in the manifest of example-provider \(models: m1\)$/, 'an unknown model' ],
  ) {
    my ( $args, $message, $what ) = @$case;
    my $seen = () = $srv->requests;
    my ( $exit, $out, $err ) = main_run(@$args);
    is( $exit, 2, "$what: exit 2" );
    is( $out, '', "$what: nothing on stdout" );
    like( $err, $message, "$what: message" );
  }
  local $ENV{OPENAI_API_KEY} = 'env-secret';
  my ( $exit, $out, $err ) = provider_run( '/two.json', 'hi' );
  is( $exit, 2, 'several models without -m: exit 2' );
  like( $err, qr/lists several models; choose one with -m MODEL \(models: a, b\)/, 'lists them' );
  ( $exit, $out, $err ) = main_run( '--provider', $host, '--allow-internal', '-o', 'api_key=sk', '-o', 'model=m1', '--json', 'hi' );
  is( $exit, 0, '-o api_key= and -o model= count as -k and -m' ) or diag $err;
};

subtest 'provider-side refusals: exit 1' => sub {
  my ( $exit, $out, $err ) = main_run( '--provider', $host, '-k', 'sk', 'hi' );
  is( $exit, 1, 'an internal address without --allow-internal' );
  like( $err, qr/^raider --provider: refused: 127\.0\.0\.1 is \(loopback address\); only --allow-internal/,
    'refused, saying why' );
  ( $exit, $out, $err ) = provider_run( '/pigeon.json', '-k', 'sk', 'hi' );
  is( $exit, 1, 'an unknown dialect' );
  like( $err, qr/^raider --provider: failed: endpoint 'chat': dialect 'carrier-pigeon' is unknown to this raider/, 'no guessing' );
};

subtest 'every request of this file, embeddings included' => sub {
  my @requests = $srv->requests;
  my @with_key = grep { exists $_->{headers}{authorization} } @requests;
  ok( scalar @with_key, 'some requests carried a key' );
  is( [ grep { $_->{headers}{authorization} !~ /\ABearer (?:sk-cli|sk)\z/ } @with_key ], [],
    'only ever a command-line key' );
  is( [ grep { $_->{path} =~ /\.json\z/ && exists $_->{headers}{authorization} } @requests ], [],
    'never with a manifest fetch' );
  unlike( JSON::MaybeXS->new->canonical->encode( \@requests ), qr/secret/, 'no configured key anywhere' );
  is( [ $other->requests ], [], 'the other origin got nothing, ever' );
};

subtest 'the synchronous user agent follows no redirect either (REPL /model list)' => sub {
  local $ENV{PERL_LWP_SSL_CA_FILE} = $CA;
  # The Anthropic family sends its key as x-api-key, which LWP keeps on a
  # redirect to another origin (it strips only Authorization).
  my $url = 'https://'.$host.'/redir';
  my $control = Langertha::Engine::Anthropic->new( url => $url, api_key => 'sk-control', model => 'm1' );
  eval { $control->list_models };
  my ( $leaked ) = $other->requests;
  is( $leaked && $leaked->{headers}{'x-api-key'}, 'sk-control',
    'control: an engine built without the provider settings follows the GET redirect with its key' );

  my $seen_other = () = $other->requests;
  my $engine = Langertha::Raider::EngineResolver->new(
    config   => Langertha::Raider::Config->new( root => "$root" ),
    provider => { engine_name => 'anthropic', engine_class => 'Langertha::Engine::Anthropic', url => $url, model => 'm1' },
    api_key  => 'sk-cli',
  )->build_engine;
  my $seen = () = $srv->requests;
  eval { $engine->list_models };
  is( [ map { $_->{path} } requests_since( $srv, $seen ) ], ['/redir/v1/models'], 'the GET got the redirect' );
  is( [ requests_since( $other, $seen_other ) ], [], 'and did not follow it' );
};

subtest 'usage' => sub {
  my ( $exit, $out ) = main_run('--help');
  like( $out, qr/--provider HOST\[:PORT\]/, '--help names --provider' );
  like( $out, qr/--allow-internal +With --provider/, '... and --allow-internal' );
};

done_testing;
