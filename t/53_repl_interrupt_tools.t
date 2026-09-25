#!/usr/bin/env perl
# ABSTRACT: the REPL left by Ctrl-C twice or SIGTERM while a tool runs: the bash command and the perl_eval child go with it

use strict;
use warnings;
use Test2::V0;
use File::Temp qw( tempdir );
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );
use Test::Raider::StubEngine qw( stub_engine alive );

clear_engine_env();

skip_all 'needs /proc to find the tool subprocess' unless -d '/proc/'.$$;

my $repo = path(__FILE__)->absolute->parent->parent;
my $bin  = $repo->child('bin', 'raider');

sub wait_until {
  my ( $cond ) = @_;
  for (1 .. 50) { return 1 if $cond->(); select undef, undef, undef, 0.1 }
  return 0;
}

# Starts bin/raider -i with its stdin a pipe kept open (the REPL reads lines
# without a terminal), sends a prompt the stub engine answers with a call of
# $tool, and returns ( raider pid, tool pid, stdout file, stub pid, pipe ).
sub repl_in_tool {
  my ( $tool, $arguments, @flags ) = @_;
  my $root    = tempdir(CLEANUP => 1);
  my $pidfile = path($root)->child('tool.pid');
  s/PIDFILE/$pidfile/g for values %$arguments;
  my ( $stub, $url ) = stub_engine($tool, $arguments);
  my $out = path($root)->child('out');
  pipe(my $r, my $w) or die 'pipe: '.$!;
  my $pid = fork // die 'fork: '.$!;
  unless ($pid) {
    close $w;
    open STDIN,  '<&', $r                   or die $!;
    open STDOUT, '>', "$out"                or die $!;
    open STDERR, '>', path($root)->child('err')->stringify or die $!;
    exec $^X, '-I'.$repo->child('lib'), "$bin", '-r', $root, '-e', 'openai', '-k', 'test',
      '-m', 'stub-model', '-o', 'url='.$url, '--no-trace', '-i', @flags;
    die 'exec: '.$!;
  }
  close $r;
  syswrite $w, "run the tool\n";
  my $tool_pid;
  for (1 .. 300) {
    ( $tool_pid ) = ( eval { $pidfile->slurp } // '' ) =~ /(\d+)/ and last;
    select undef, undef, undef, 0.1;
  }
  return ( $pid, $tool_pid, $out, $stub, $w );
}

# Waits for raider to end (KILL after 30s), returns its wait status and
# cleans up the stub and a tool process that survived.
sub finish {
  my ( $pid, $tool_pid, $stub ) = @_;
  local $SIG{ALRM} = sub { kill KILL => $pid };
  alarm 30;
  waitpid $pid, 0;
  my $status = $?;
  alarm 0;
  kill KILL => $stub;
  waitpid $stub, 0;
  return $status;
}

for my $case (
  [ bash      => INT  => { command => 'echo $$ > PIDFILE; sleep 300' } ],
  [ perl_eval => INT  => { code => 'open my $f, q{>}, q{PIDFILE} or die; print {$f} $$; close $f; sleep 300' }, '--perl' ],
  [ bash      => TERM => { command => 'echo $$ > PIDFILE; sleep 300' } ],
) {
  my ( $tool, $signal, $arguments, @flags ) = @$case;
  my $how = $signal eq 'INT' ? 'Ctrl-C twice' : 'SIGTERM';
  subtest $how.' in the REPL during '.$tool.' ends the tool subprocess' => sub {
    my ( $pid, $tool_pid, $out, $stub, $w ) = repl_in_tool($tool, $arguments, @flags);
    unless (ok($tool_pid, $tool.' started and wrote its pid')) {
      kill KILL => $pid;
      finish($pid, 0, $stub);
      return;
    }

    if ($signal eq 'INT') {
      kill INT => $pid;
      # The second one has to follow within two seconds.
      select undef, undef, undef, 0.5;
      ok(alive($pid), 'raider still runs after the first Ctrl-C');
      ok(alive($tool_pid), 'so does the '.$tool.' subprocess');
    }
    kill $signal => $pid;
    my $status = finish($pid, $tool_pid, $stub);
    is($status, 0, 'raider left the REPL with exit status 0');
    like($out->slurp, qr/press Ctrl-C again within 2s to quit/, 'the first Ctrl-C only warned')
      if $signal eq 'INT';
    like($out->slurp, qr/bye\.\n\z/, 'and said bye');

    my $gone = wait_until(sub { !alive($tool_pid) });
    ok($gone, 'the '.$tool.' subprocess is gone');
    unless ($gone) { kill KILL => -$tool_pid; kill KILL => $tool_pid }
    close $w;
  };
}

done_testing;
