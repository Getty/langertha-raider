#!/usr/bin/env perl
# ABSTRACT: The application service opens, creates and replays sessions (ADR 0015)

use strict;
use warnings;
use Test2::V0;
use File::Temp qw( tempdir );
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );
use Langertha::Raider::Application;

clear_engine_env();

# An application whose raider needs no tool servers.
package My::App {
  use Moose;
  extends 'Langertha::Raider::Application';
  sub _build_mcps { [] }
  __PACKAGE__->meta->make_immutable;
}

sub app { My::App->new(root => $_[0], engine => 'openai', api_key => 'test') }

my $root = tempdir(CLEANUP => 1);

subtest 'the store is the project store of the root' => sub {
  my $store = app($root)->session_store;
  isa_ok($store, 'Langertha::Raider::SessionStore');
  is($store->scope, 'project', 'project scope');
  is(path($store->dir)->stringify, path($root, '.raider', 'sessions')->stringify, 'under the root');
};

subtest 'create, open, replay' => sub {
  my $first = app($root);
  my $s = $first->create_session;
  $s->append('run.started', run => 'r1', engine => 'openai');
  $s->append('message', run => 'r1', role => 'user', content => 'hi');
  $s->append('message', run => 'r1', role => 'assistant', content => 'hello');
  $s->append('run.finished', run => 'r1', status => 'completed');

  like(dies { $first->open_session($s->id) }, qr/is in use/, 'one writer');
  $s->release;

  my $app = app($root);
  my $opened = $app->open_session($s->id);
  is($opened->id, $s->id, 'opened');
  my $journal = $app->replay_session($opened);
  isa_ok($journal, 'Langertha::Raider::Session::Journal');
  is([ map { [ $_->{role}, $_->{content} ] } @{ $app->raider->history } ],
    [ [ user => 'hi' ], [ assistant => 'hello' ] ], 'history replayed into the raider');
  ok(scalar @{ $app->raider->session_history }, 'session history replayed');
  $opened->release;
};

done_testing;
