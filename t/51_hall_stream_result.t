#!/usr/bin/env perl
# ABSTRACT: the Hall runs raiders with --stream-json and takes the result from run.finished

use strict;
use warnings;
use utf8;
use Test2::V0;
use File::Temp qw( tempdir );
use JSON::MaybeXS ();
use Path::Tiny;
use lib 't/lib';
use Test::Raider::Env qw( clear_engine_env );
use Langertha::Raider::Hall;
use Langertha::Raider::Hall::ACP;
use Langertha::Raider::Hall::Raider;

clear_engine_env();

my $repo = path(__FILE__)->absolute->parent->parent;

# A stand-in for bin/raider. It records its argv, writes noise to stderr
# and, depending on the mission, a --stream-json event stream to stdout:
#   silent  - nothing on stdout, exit 0
#   noisy   - non-JSON text on stdout around the events
#   killed  - one event, then SIGKILL on itself before run.finished
#   twice   - two run.finished events, the last one counts
#   *       - run.started, message, run.finished with "answer: MISSION"
my $FAKE = <<'PERL';
use strict;
use warnings;
use JSON::PP;
my $mission = $ARGV[-1];
open my $a, '>>', $ENV{FAKE_ARGV_LOG} or die $!;
print $a JSON::PP->new->canonical->encode([ @ARGV ]), "\n";
close $a;
$| = 1;
my $json = JSON::PP->new->canonical->utf8;
my $seq = 0;
sub event { my ( $type, %p ) = @_; print $json->encode({ version => 1, type => $type, seq => ++$seq, time => time, %p }), "\n" }
print STDERR "warning: some diagnostic noise\n";
print STDERR qq({"type":"run.finished","status":"completed","response":"stderr is not the stream"}\n);
exit 0 if $mission eq 'silent';
print "plain text on stdout\n" if $mission eq 'noisy';
event('run.started');
if ( $mission eq 'killed' ) { kill 'KILL', $$; sleep 5 }
event('message', text => 'thinking');
event('run.finished', status => 'completed', response => 'first', elapsed => 0.1) if $mission eq 'twice';
print "{broken json\n" if $mission eq 'noisy';
event('run.finished', status => 'completed', response => 'answer: '.$mission, metrics => {}, elapsed => 0.2);
print "trailing noise\n" if $mission eq 'noisy';
exit 0;
PERL

sub fake_hall {
  my $tmp = path( tempdir( CLEANUP => 1 ) );
  my $bin = $tmp->child('fake-raider');
  $bin->spew_utf8( "#!$^X\n".$FAKE );
  $bin->chmod(0755);
  $ENV{RAIDER_HALL_RAIDER_BIN} = "$bin";
  $ENV{FAKE_ARGV_LOG} = $tmp->child('argv.jsonl')->stringify;
  return ( Langertha::Raider::Hall->new( root => $tmp ), $tmp );
}

# Spawn and turn the loop until the hall has reaped every raider; returns
# the raider.done events emitted meanwhile.
sub run_spawns {
  my ( $hall, @spawns ) = @_;
  my @done;
  no warnings 'redefine';
  my $orig = \&Langertha::Raider::Hall::_emit;
  local *Langertha::Raider::Hall::_emit = sub {
    my ( $self, $type, $data ) = @_;
    push @done, { %$data } if $type eq 'raider.done';
    $self->$orig( $type, $data );
  };
  for my $spawn (@spawns) {
    $hall->spawn(%$spawn);
  }
  my $deadline = time + 30;
  $hall->loop->loop_once(0.1)
    until ( !%{ $hall->raiders } && @done >= @spawns ) || time > $deadline;
  return @done;
}

subtest 'run_finished reads the last run.finished of the events file' => sub {
  my $tmp = path( tempdir( CLEANUP => 1 ) );
  my $events = $tmp->child('x.events.jsonl');
  my $raider = sub {
    Langertha::Raider::Hall::Raider->new(
      id => 'x-1', slot_name => 'x', base_name => 'x', mission => 'm',
      log_path => $tmp->child('x.log'), @_ );
  };
  is( $raider->()->run_finished, undef, 'no events path: undef' );
  is( $raider->( events_path => $events )->run_finished, undef, 'missing file: undef' );

  $events->spew_raw( qq({"version":1,"type":"run.started","seq":1,"time":1}\n) );
  is( $raider->( events_path => $events )->run_finished, undef, 'no run.finished: undef' );

  $events->spew_raw( join "\n",
    'noise',
    qq({"version":1,"type":"run.finished","seq":2,"time":1,"status":"completed","response":"old"}),
    '{half',
    'more noise', '' );
  my $bytes = qq({"version":1,"type":"run.finished","seq":3,"time":2,"status":"completed","response":"Gr\xc3\xbc\xc3\x9fe"}\n);
  $events->append_raw($bytes);
  is( $raider->( events_path => $events )->run_finished,
    { version => 1, status => 'completed', response => 'Grüße' },
    'last event wins, UTF-8 decoded, event fields stripped' );
};

subtest 'bin/raider --stream-json stdout gives a run.finished the Hall reads' => sub {
  my $tmp = path( tempdir( CLEANUP => 1 ) );
  my $events = $tmp->child('r.events.jsonl');
  my $log = $tmp->child('r.log');
  my @cmd = ( $^X, '-I'.$repo->child('lib'), $repo->child('bin', 'raider')->stringify,
    '--stream-json', '-e', 'openai', '-k', 'test', '-r', "$tmp",
    '-o', 'url=http://127.0.0.1:1', '--', 'hi' );
  my $q = join ' ', map { "'$_'" } @cmd;
  `$q >'$events' 2>>'$log' </dev/null`;
  is( $? >> 8, 1, 'unreachable engine: run failed' );
  my $doc = Langertha::Raider::Hall::Raider->new(
    id => 'r-1', slot_name => 'r', base_name => 'r', mission => 'hi',
    log_path => $log, events_path => $events )->run_finished;
  is( $doc, hash {
    field version => 1;
    field status  => 'failed';
    field error   => T();
    etc;
  }, 'the failure document' );
};

subtest 'spawn uses --stream-json and a per-run events file' => sub {
  my ( $hall, $tmp ) = fake_hall();
  my ($done) = run_spawns( $hall, { name => 'bjorn', mission => 'hello' } );
  my ($argv) = map { JSON::MaybeXS->new->decode($_) } path( $ENV{FAKE_ARGV_LOG} )->lines;
  ok( ( grep { $_ eq '--stream-json' } @$argv ), 'raider started with --stream-json' );
  ok( !( grep { $_ eq '--json' } @$argv ), 'not with --json' );
  is( $done->{status}, 'completed', 'status from run.finished' );
  is( $done->{response}, 'answer: hello', 'response from run.finished' );
  ok( !exists $done->{error}, 'no error' );
  my $logs = $tmp->child( '.raider-hall', 'logs' );
  like( $logs->child('bjorn.log')->slurp_utf8, qr/some diagnostic noise/, 'stderr goes to the log' );
  unlike( $logs->child('bjorn.log')->slurp_utf8, qr/run\.started/, 'the stream does not' );
  ok( $logs->child( $done->{id}.'.events.jsonl' )->exists, 'events file named after the run' );
};

subtest 'a reused slot never returns the previous result' => sub {
  my ( $hall ) = fake_hall();
  my ($first) = run_spawns( $hall, { name => 'bjorn', mission => 'one' } );
  is( $first->{response}, 'answer: one', 'first run' );
  my ($second) = run_spawns( $hall, { name => 'bjorn', mission => 'silent' } );
  is( $second->{status}, 'failed', 'second run without run.finished failed' );
  ok( !exists $second->{response}, 'no stale response' );
  like( $second->{error}, qr/ended without a result \(exit code 0\)/, 'says why' );

  my @queued = run_spawns( $hall,
    { name => '1ivar', mission => 'alpha' },
    { name => '1ivar', mission => 'beta' } );
  is( [ map { $_->{response} } @queued ], [ 'answer: alpha', 'answer: beta' ],
    'singleton queue: each run gets its own result' );
};

subtest 'stdout noise and several run.finished events' => sub {
  my ( $hall ) = fake_hall();
  my ($noisy) = run_spawns( $hall, { name => 'bjorn', mission => 'noisy' } );
  is( $noisy->{response}, 'answer: noisy', 'non-JSON lines are skipped' );
  my ($twice) = run_spawns( $hall, { name => 'bjorn', mission => 'twice' } );
  is( $twice->{response}, 'answer: twice', 'the last run.finished counts' );
};

subtest 'a killed raider is a clear failure, not raw text' => sub {
  my ( $hall ) = fake_hall();
  my ($done) = run_spawns( $hall, { name => 'bjorn', mission => 'killed' } );
  is( $done->{signaled}, 1, 'signaled' );
  is( $done->{status}, 'failed', 'failed' );
  like( $done->{error}, qr/^raider bjorn-\d+ ended without a result \(killed by signal 9\)$/,
    'error names the run and the signal' );
};

{
  package CaptureStream;
  sub new { bless { lines => [] }, shift }
  sub write { push @{ $_[0]{lines} }, JSON::MaybeXS->new->decode( $_[1] ); 1 }
}

sub acp_prompt {
  my ( $mission ) = @_;
  my ( $hall, $tmp ) = fake_hall();
  $tmp->child('.raider-hall.yml')->spew_utf8("raiders:\n  bjorn: {}\n");
  $hall = Langertha::Raider::Hall->new( root => $tmp );
  my $acp = Langertha::Raider::Hall::ACP->new( hall => $hall, port => 0, host => '127.0.0.1' );
  my $stream = CaptureStream->new;
  $acp->_sessions->{s1} = { stream => $stream, raider_name => 'bjorn' };
  $acp->_session_prompt( $stream, 7, { sessionId => 's1', prompt => [ { type => 'text', text => $mission } ] } );
  my $deadline = time + 30;
  $hall->loop->loop_once(0.1)
    until ( grep { ( $_->{id} // 0 ) == 7 } @{ $stream->{lines} } ) || time > $deadline;
  my @chunks = map { $_->{params}{update}{content}{text} }
    grep { ( $_->{method} // '' ) eq 'session/update' } @{ $stream->{lines} };
  my ($reply) = grep { ( $_->{id} // 0 ) == 7 } @{ $stream->{lines} };
  return ( $chunks[-1], $reply->{result}{stopReason} );
}

subtest 'ACP forwards the response of run.finished' => sub {
  my ( $text, $stop ) = acp_prompt('hello');
  is( $text, 'answer: hello', 'response as the last chunk' );
  is( $stop, 'end_turn', 'end_turn' );
};

subtest 'ACP forwards a clear error when the raider was killed' => sub {
  my ( $text, $stop ) = acp_prompt('killed');
  like( $text, qr/ended without a result \(killed by signal 9\)/, 'error, not raw log text' );
  unlike( $text, qr/run\.started|diagnostic noise/, 'no stream or stderr content' );
  is( $stop, 'cancelled', 'signaled: cancelled' );
};

subtest 'ACP maps an interrupted run to cancelled' => sub {
  my $hall = Langertha::Raider::Hall->new( root => path( tempdir( CLEANUP => 1 ) ) );
  my $acp = Langertha::Raider::Hall::ACP->new( hall => $hall, port => 0, host => '127.0.0.1' );
  my $stream = CaptureStream->new;
  my $session = { stream => $stream, raider_name => 'bjorn', pending_request_id => 9 };
  $acp->_sessions->{s1} = $session;
  $acp->_attach_subscription( $session, 'bjorn-1', $stream );
  $hall->_emit( 'raider.done', { id => 'bjorn-1', exit_code => 0, signaled => 0,
    status => 'interrupted', error => 'interrupted by SIGTERM' } );
  my ($reply) = grep { ( $_->{id} // 0 ) == 9 } @{ $stream->{lines} };
  is( $reply->{result}{stopReason}, 'cancelled', 'interrupted: cancelled' );
};

done_testing;
