#!/usr/bin/env perl
# ABSTRACT: raider records one-shot and REPL runs in a session journal (ADR 0015), --no-session

use strict;
use warnings;
use utf8;
use Test2::V0;
use Encode qw( decode_utf8 );
use File::Temp qw( tempdir );
use JSON::MaybeXS ();
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );
use Langertha::Raider::CLI::Main;
use Langertha::Raider::CLI::Output;

clear_engine_env();

# --- a scripted engine, same shape as t/50_cli_machine_stream.t ---

{
  package SeqResponse;
  use Moose;
  sub is_success  { 1 }
  sub status_line { '200 OK' }
  sub content     { '' }
  __PACKAGE__->meta->make_immutable;
}

{
  package SeqHTTP;
  use Moose;
  use IO::Async::Loop;
  has loop => (is => 'ro', default => sub { IO::Async::Loop->new });
  sub do_request { return $_[0]->loop->new_future->done(SeqResponse->new) }
  __PACKAGE__->meta->make_immutable;
}

{
  package SeqMCP;
  use Moose;
  use Future;
  sub list_tools { return Future->done([ { name => 'bash' }, { name => 'broken' } ]) }
  sub call_tool {
    my ( $self, $name, $input ) = @_;
    return Future->done({ content => [ { type => 'text', text => 'x' x 1500 } ] }) if $name eq 'bash';
    return Future->done({ content => [ { type => 'text', text => "nope: ä" } ], isError => 1 });
  }
  __PACKAGE__->meta->make_immutable;
}

{
  package SeqEngine;
  use Moose;
  with 'Langertha::Role::Tools';

  has chat_model     => (is => 'ro', default => 'seq-model');
  has '+mcp_servers' => (default => sub { [] });
  has turns          => (is => 'ro', default => sub { [] });
  has _turn_idx      => (is => 'rw', default => 0);
  has _http          => (is => 'ro', lazy => 1, default => sub { SeqHTTP->new });

  sub _async_http { return $_[0]->_http }

  sub format_tools            { return $_[1] }
  sub build_tool_chat_request { return { request => 1 } }
  sub response_tool_calls     { return $_[1]->{tool_calls} // [] }
  sub response_text_content   { return $_[1]->{text} // 'final answer' }
  sub extract_tool_call       { return ($_[1]->{name}, $_[1]->{input}) }
  sub think_tag_filter        { 0 }
  sub format_tool_results     { my ( $self, $data, $results ) = @_; return map { { role => 'tool', content => 'r' } } @$results }

  # Every raid: two tool calls, then the answer.
  sub parse_response {
    my ( $self ) = @_;
    my $i = $self->_turn_idx;
    $self->_turn_idx(($i + 1) % 2);
    return $i ? { tool_calls => [], text => 'Fertig ✓' } : { tool_calls => [
      { name => 'bash',   input => { command => 'ls' } },
      { name => 'broken', input => {} },
    ] };
  }

  __PACKAGE__->meta->make_immutable;
}

package My::App {
  use Moose;
  extends 'Langertha::Raider::CLI';
  sub _build_mcps { [] }
  sub _build_engine { SeqEngine->new(mcp_servers => [ SeqMCP->new ]) }
  around run => sub {
    my ( $orig, $self, $text ) = @_;
    die "kaputt\n" if $text eq 'fail';
    return $self->$orig($text);
  };
  __PACKAGE__->meta->make_immutable;
}

package My::Main {
  use Moose;
  extends 'Langertha::Raider::CLI::Main';
  sub app_class { 'My::App' }
  __PACKAGE__->meta->make_immutable;
}

sub buffer {
  my $buf = '';
  open my $fh, '>:encoding(UTF-8)', \$buf or die $!;
  return ( $fh, sub { $fh->flush; decode_utf8($buf) } );
}

sub main_run {
  my ( $stdin, @argv ) = @_;
  my ( $out, $read_out ) = buffer();
  my ( $err, $read_err ) = buffer();
  open my $in, '<', \$stdin or die $!;
  local $ENV{ANSI_COLORS_DISABLED};
  my $exit = My::Main->new(
    output => Langertha::Raider::CLI::Output->new(out => $out, color => 0),
    err    => $err,
    in     => $in,
  )->run(@argv);
  return ( $exit, $read_out->(), $read_err->() );
}

my $json = JSON::MaybeXS->new(utf8 => 1);
sub journals { my ( $root ) = @_; my $d = path($root, '.raider', 'sessions'); -d $d ? sort $d->children(qr/\.jsonl\z/) : () }
sub events   { map { $json->decode($_) } path($_[0])->lines_raw({ chomp => 1 }) }

my $secret = 'sk-secret-4711';
sub base { ( '-r', $_[0], '-e', 'openai', '-k', $secret, '-m', 'seq-model', '--no-trace' ) }

subtest 'one-shot: the whole run in a new session' => sub {
  my $root = tempdir(CLEANUP => 1);
  my ( $exit, $out, $err ) = main_run('', base($root), 'hi');
  is($exit, 0, 'exits 0');
  my ( $file ) = journals($root);
  ok($file, 'one journal');
  my $id = $file->basename('.jsonl');
  is($err, 'session '.$id.' ('.$file.")\n", 'named on stderr');
  is(path($root, '.raider', '.gitignore')->slurp_utf8, "sessions/\nlib/\n", '.gitignore written');

  my @e = events($file);
  is([ map { $_->{type} } @e ], [qw( session.created run.started message tool.call tool.result
    tool.call tool.result message run.finished )], 'the events of the run');
  is([ map { $_->{seq} } @e ], [ 1 .. 9 ], 'seq');
  ok(!(grep { $_->{v} != 1 || !$_->{time} } @e), 'v and time everywhere');
  ok(!(grep { $_->{type} ne 'session.created' && ($_->{run} // '') ne 'r1' } @e), 'every run event carries run r1');
  like($e[0], { id => $id, scope => 'project', root => path($root)->absolute->stringify, principal => T(),
    raider => T() }, 'session.created');
  like($e[1], { engine => 'openai', model => 'seq-model' }, 'run.started');
  like($e[2], { role => 'user', content => 'hi' }, 'the user input');
  like($e[3], { call => 'c1', name => 'bash', arguments => { command => 'ls' }, status => 'dispatched' }, 'tool.call');
  like($e[4], { call => 'c1', name => 'bash', status => 'succeeded', size => 1500 }, 'tool.result');
  is(length $e[4]{content}, 1500, 'with the whole content, not cut like the stream');
  like($e[5], { call => 'c2', name => 'broken', status => 'dispatched' }, 'second call');
  like($e[6], { call => 'c2', name => 'broken', status => 'failed', content => 'nope: ä' }, 'a failed tool');
  like($e[7], { role => 'assistant', content => 'Fertig ✓' }, 'the final answer');
  like($e[8], { status => 'completed', metrics => { tool_calls => 2 }, elapsed => T() }, 'run.finished');
  unlike($file->slurp_raw, qr/\Q$secret\E/, 'no API key in the journal');
};

subtest 'machine formats name the session in the document' => sub {
  my $root = tempdir(CLEANUP => 1);
  my ( $exit, $out, $err ) = main_run('', base($root), '--json', 'hi');
  my $doc = $json->decode(Encode::encode_utf8($out));
  my ( $file ) = journals($root);
  is($doc->{session}, { id => $file->basename('.jsonl'), path => "$file" }, 'session: id and path');
  is($err, '', 'nothing on stderr');

  ( $exit, $out ) = main_run('', base($root), '--stream-json', 'hi');
  my @stream = map { $json->decode(Encode::encode_utf8($_)) } split /\n/, $out;
  ok($stream[-1]{session}{id}, 'run.finished of the stream too');
  is([ map { $_->{call} } grep { $_->{type} =~ /^tool\./ } @stream ], [qw( c1 c1 c2 c2 )], 'the stream has the call ids');
  is(scalar(my @j = journals($root)), 2, 'a new session per call');
};

subtest 'a failed run ends in run.finished failed' => sub {
  my $root = tempdir(CLEANUP => 1);
  my ( $exit ) = main_run('', base($root), 'fail');
  is($exit, 1, 'exits 1');
  my @e = events((journals($root))[0]);
  is([ map { $_->{type} } @e ], [qw( session.created run.started message run.finished )], 'events');
  like($e[-1], { run => 'r1', status => 'failed', error => 'kaputt' }, 'the error');
};

subtest '--no-session records nothing' => sub {
  my $root = tempdir(CLEANUP => 1);
  my ( $exit, $out, $err ) = main_run('', base($root), '--no-session', '--json', 'hi');
  is($exit, 0, 'exits 0');
  ok(!-e path($root, '.raider'), 'no .raider directory');
  ok(!exists $json->decode(Encode::encode_utf8($out))->{session}, 'no session in the document');
  ( $exit, $out, $err ) = main_run('', base($root), '--no-session', 'hi');
  is($err, '', 'no session note');
  ( $exit, $out ) = main_run("hi\n", base($root), '--no-session', '-i');
  like($out, qr/^session:  off$/m, 'the REPL banner says off');
  ok(!-e path($root, '.raider'), 'still no .raider directory');
};

subtest 'REPL: one session for all prompts, created with the first' => sub {
  my $root = tempdir(CLEANUP => 1);
  my ( $exit, $out ) = main_run("/help\n", base($root), '-i');
  like($out, qr/^session:  new, saved from the first prompt on$/m, 'banner');
  is([ journals($root) ], [], 'no prompt, no session');

  ( $exit, $out ) = main_run("hi\nfail\nagain\n", base($root), '-i');
  my @files = journals($root);
  is(scalar @files, 1, 'one session');
  my $id = $files[0]->basename('.jsonl');
  like($out, qr/^session \Q$id\E \(/m, 'named when created');
  my @e = events($files[0]);
  is([ map { [ $_->{run}, $_->{status} ] } grep { $_->{type} eq 'run.finished' } @e ],
    [ [ r1 => 'completed' ], [ r2 => 'failed' ], [ r3 => 'completed' ] ], 'three runs');
  is([ map { $_->{content} } grep { $_->{type} eq 'message' && $_->{role} eq 'user' } @e ],
    [qw( hi fail again )], 'every input');
};

subtest 'a session that cannot be written does not stop the run' => sub {
  my $root = tempdir(CLEANUP => 1);
  path($root, '.raider')->spew('not a directory');
  my ( $exit, $out, $err ) = main_run('', base($root), 'hi');
  is($exit, 0, 'the run went on');
  like($err, qr/\Asession not saved: /, 'reported');
  like($out, qr/Fertig/, 'answered');
};

done_testing;
