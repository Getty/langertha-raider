#!/usr/bin/env perl
# ABSTRACT: raider interrupted by SIGINT/SIGTERM mid-run: the interrupted document or run.finished, death by the signal

use strict;
use warnings;
use Test2::V0;
use Config;
use File::Temp qw( tempdir );
use IO::Select;
use IO::Socket::INET;
use JSON::MaybeXS ();
use POSIX qw( WIFSIGNALED WTERMSIG WIFEXITED WEXITSTATUS );
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );

clear_engine_env();

my $repo = path(__FILE__)->absolute->parent->parent;
my $bin  = $repo->child('bin', 'raider');
my $root = tempdir(CLEANUP => 1);

my %signo;
@signo{ split ' ', $Config{sig_name} } = split ' ', $Config{sig_num};

# The stub engine endpoint: accepts the connection and never answers, so
# the run hangs inside the engine request until the signal arrives.
my $server = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1,
) or die 'listen: '.$!;
my $url = 'http://127.0.0.1:'.$server->sockport.'/v1';

# Spawns bin/raider with @flags, waits until its engine request reaches the
# stub, sends $signal and returns ( wait status, stdout, stderr ).
sub interrupted_run {
  my ( $signal, @flags ) = @_;
  my $out = path($root)->child('out');
  my $err = path($root)->child('err');
  my $pid = fork // die 'fork: '.$!;
  unless ($pid) {
    open STDIN,  '<', '/dev/null' or die $!;
    open STDOUT, '>', "$out"      or die $!;
    open STDERR, '>', "$err"      or die $!;
    exec $^X, '-I'.$repo->child('lib'), "$bin", '-r', $root, '-e', 'openai', '-k', 'test',
      '-m', 'stub-model', '-o', 'url='.$url, '--no-trace', @flags, 'hang please';
    die 'exec: '.$!;
  }
  my $conn;
  if (IO::Select->new($server)->can_read(30)) {
    $conn = $server->accept;
    # The request is sent; give the loop a moment to be waiting on the reply.
    select undef, undef, undef, 0.3;
    kill $signal => $pid;
  }
  else {
    kill KILL => $pid;
  }
  my $status;
  local $SIG{ALRM} = sub { kill KILL => $pid };
  alarm 30;
  waitpid $pid, 0;
  $status = $?;
  alarm 0;
  close $conn if $conn;
  return ( $status, $out->slurp_raw, $err->slurp_utf8 );
}

sub died_of {
  my ( $status, $signal, $name ) = @_;
  ok(WIFSIGNALED($status) && WTERMSIG($status) == $signo{$signal},
    $name.': died of SIG'.$signal.' (shell status '.(128 + $signo{$signal}).')')
    or diag 'wait status '.$status;
}

subtest '--json: SIGTERM writes the interrupted document' => sub {
  my ( $status, $stdout, $stderr ) = interrupted_run(TERM => '--json');
  died_of($status, 'TERM', '--json');
  my $doc = eval { JSON::MaybeXS->new(utf8 => 1)->decode($stdout) };
  is($doc, { version => 1, status => 'interrupted', signal => 'TERM', elapsed => E() },
    'one document, status interrupted') or diag 'stdout: '.$stdout."\nstderr: ".$stderr;
  unlike($stderr, qr/ at \S+ line \d+/, 'no Perl error on stderr') or diag $stderr;
};

subtest '--stream-json: SIGINT ends with run.state and run.finished' => sub {
  my ( $status, $stdout, $stderr ) = interrupted_run(INT => '--stream-json');
  died_of($status, 'INT', '--stream-json');
  my $json = JSON::MaybeXS->new(utf8 => 1);
  my @events = map { $json->decode($_) } split /\n/, $stdout;
  is([ map { $_->{type} } @events ], [qw( run.started run.state run.state run.finished )],
    'event sequence') or diag 'stdout: '.$stdout."\nstderr: ".$stderr;
  is($events[2]{state}, 'interrupted', 'last state change is interrupted');
  like($events[-1], { status => 'interrupted', signal => 'INT', elapsed => D(), seq => 4 },
    'run.finished carries the interrupted document');
};

subtest 'human output: a note, no Perl error, death by the signal' => sub {
  my ( $status, $stdout, $stderr ) = interrupted_run('TERM');
  died_of($status, 'TERM', 'human');
  like($stdout.$stderr, qr/interrupted \(SIGTERM\)/, 'says it was interrupted')
    or diag 'stdout: '.$stdout."\nstderr: ".$stderr;
  unlike($stderr, qr/ at \S+ line \d+/, 'no Perl error on stderr') or diag $stderr;
};

done_testing;
