#!/usr/bin/env perl
# ABSTRACT: raider interrupted while a tool subprocess runs: the bash command and the perl_eval child go with it

use strict;
use warnings;
use Test2::V0;
use File::Temp qw( tempdir );
use IO::Select;
use IO::Socket::INET;
use JSON::MaybeXS ();
use POSIX qw( WIFSIGNALED WTERMSIG );
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );

clear_engine_env();

skip_all 'needs /proc to find the tool subprocess' unless -d '/proc/'.$$;

my $repo = path(__FILE__)->absolute->parent->parent;
my $bin  = $repo->child('bin', 'raider');
my $json = JSON::MaybeXS->new(utf8 => 1, canonical => 1);

# The stub engine endpoint, in its own process: every chat completion
# answers with one call of the tool under test; anything else (the session
# embedding request) gets a 404.
sub stub_engine {
  my ( $tool, $arguments ) = @_;
  my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1,
  ) or die 'listen: '.$!;
  my $body = $json->encode({
    id => 'stub', object => 'chat.completion', created => time, model => 'stub-model',
    choices => [ { index => 0, finish_reason => 'tool_calls', message => {
      role => 'assistant', content => undef,
      tool_calls => [ { id => 'call_1', type => 'function', function => {
        name => $tool, arguments => $json->encode($arguments),
      } } ],
    } } ],
    usage => { prompt_tokens => 1, completion_tokens => 1, total_tokens => 2 },
  });
  my $pid = fork // die 'fork: '.$!;
  unless ($pid) {
    while (IO::Select->new($server)->can_read(60)) {
      my $conn = $server->accept or next;
      my $req = '';
      sysread($conn, $req, 65536, length $req) or last until $req =~ /\r\n\r\n/;
      my ( $head, $rest ) = split /\r\n\r\n/, $req, 2;
      my ( $length ) = $head =~ /^Content-Length:\s*(\d+)/mi;
      sysread($conn, $rest, 65536, length $rest) or last while length($rest) < ($length // 0);
      print {$conn} $head =~ m{\APOST \S*/chat/completions }
        ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
          .length($body)."\r\nConnection: close\r\n\r\n".$body
        : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $conn;
    }
    POSIX::_exit(0);
  }
  my $url = 'http://127.0.0.1:'.$server->sockport.'/v1';
  close $server;
  return ( $pid, $url );
}

# Runs bin/raider --json against a stub engine calling $tool with
# $arguments (PIDFILE in a string replaced by a file the tool writes its
# pid to), sends SIGTERM once that pid is there and returns ( wait status,
# stdout, tool pid ).
sub interrupted_tool_run {
  my ( $tool, $arguments, @flags ) = @_;
  my $root    = tempdir(CLEANUP => 1);
  my $pidfile = path($root)->child('tool.pid');
  s/PIDFILE/$pidfile/g for values %$arguments;
  my ( $stub, $url ) = stub_engine($tool, $arguments);
  my $out = path($root)->child('out');
  my $pid = fork // die 'fork: '.$!;
  unless ($pid) {
    open STDIN,  '<', '/dev/null'           or die $!;
    open STDOUT, '>', "$out"                or die $!;
    open STDERR, '>', path($root)->child('err')->stringify or die $!;
    exec $^X, '-I'.$repo->child('lib'), "$bin", '-r', $root, '-e', 'openai', '-k', 'test',
      '-m', 'stub-model', '-o', 'url='.$url, '--no-trace', '--json', @flags, 'run the tool';
    die 'exec: '.$!;
  }
  my $tool_pid;
  for (1 .. 300) {
    ( $tool_pid ) = ( eval { $pidfile->slurp } // '' ) =~ /(\d+)/ and last;
    select undef, undef, undef, 0.1;
  }
  $tool_pid ? kill TERM => $pid : kill KILL => $pid;
  local $SIG{ALRM} = sub { kill KILL => $pid };
  alarm 30;
  waitpid $pid, 0;
  my $status = $?;
  alarm 0;
  kill KILL => $stub;
  waitpid $stub, 0;
  return ( $status, $out->slurp_raw, $tool_pid );
}

# True while $pid is a live process (a zombie counts as gone: it has ended
# and only waits for init to reap it).
sub alive {
  my ( $pid ) = @_;
  my $stat = eval { path('/proc', $pid, 'stat')->slurp } // return 0;
  return substr($stat, rindex($stat, ')') + 2, 1) ne 'Z';
}

for my $case (
  [ bash      => { command => 'echo $$ > PIDFILE; sleep 300' } ],
  [ perl_eval => { code => 'open my $f, q{>}, q{PIDFILE} or die; print {$f} $$; close $f; sleep 300' }, '--perl' ],
) {
  my ( $tool, $arguments, @flags ) = @$case;
  subtest 'SIGTERM during '.$tool.' ends the tool subprocess' => sub {
    my ( $status, $stdout, $tool_pid ) = interrupted_tool_run($tool, $arguments, @flags);
    ok($tool_pid, $tool.' started and wrote its pid') or return;
    ok(WIFSIGNALED($status) && WTERMSIG($status) == 15, 'raider died of SIGTERM')
      or diag 'wait status '.$status;
    like(eval { $json->decode($stdout) }, { status => 'interrupted', signal => 'TERM' },
      'the interrupted document') or diag 'stdout: '.$stdout;
    my $gone;
    for (1 .. 50) { $gone = !alive($tool_pid) and last; select undef, undef, undef, 0.1 }
    ok($gone, 'the '.$tool.' subprocess is gone');
    unless ($gone) { kill KILL => -$tool_pid; kill KILL => $tool_pid }
  };
}

done_testing;
