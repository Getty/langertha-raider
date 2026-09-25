#!/usr/bin/env perl
# ABSTRACT: Session journals: create, append, read, the single-writer lock, crash rules (ADR 0015)

use strict;
use warnings;
use utf8;
use Test2::V0;
use File::Temp qw( tempdir );
use JSON::MaybeXS ();
use POSIX ();
use Path::Tiny;
use Langertha::Raider::SessionStore;

my $json = JSON::MaybeXS->new(utf8 => 1);
sub lines { map { $json->decode($_) } path($_[0])->lines_raw({ chomp => 1 }) }

subtest 'create: id, file, line 1, .gitignore' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $t = 1790000000.25;
  my $store = Langertha::Raider::SessionStore->new(root => $root, principal => 'bjorn', clock => sub { $t });
  is([ $store->ids ], [], 'no sessions yet, no directory needed');
  ok(!-e path($root, '.raider'), 'reading creates nothing');

  my $s = $store->create;
  like($s->id, qr/\A20260921-\d{6}-[0-9a-f]{4}\z/, 'id: UTC date and time, four hex digits');
  ok($store->is_id($s->id), 'is_id');
  is(path($s->path)->stringify, path($root, '.raider', 'sessions', $s->id.'.jsonl')->stringify, 'journal path');
  is(path($root, '.raider', '.gitignore')->slurp_utf8, "sessions/\nlib/\n", '.gitignore written');
  is([ lines($s->path) ], [ {
    v => 1, seq => 1, time => $t, type => 'session.created',
    id => $s->id, scope => 'project', root => path($root)->absolute->stringify,
    principal => 'bjorn', raider => $Langertha::Raider::SessionStore::VERSION,
  } ], 'session.created is line 1');
  ok(-e $s->lock_path, 'lock file next to the journal');

  path($root, '.raider', '.gitignore')->spew_utf8("mine\n");
  $store->create->release;
  is(path($root, '.raider', '.gitignore')->slurp_utf8, "mine\n", 'an existing .gitignore is left alone');
  is(scalar(my @ids = $store->ids), 2, q{two sessions});
  $s->release;
};

subtest 'append: v, seq, time, type, UTF-8' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $store = Langertha::Raider::SessionStore->new(root => $root);
  my $s = $store->create;
  is($s->next_run, 'r1', 'first run');
  my $e = $s->append('message', run => 'r1', role => 'user', content => "grüß\ndich");
  is($e->{seq}, 2, 'seq continues after session.created');
  my @l = lines($s->path);
  like($l[1], { v => 1, seq => 2, type => 'message', run => 'r1', content => "grüß\ndich", time => T() },
    'read back');
  is(scalar path($s->path)->lines_raw, 2, 'one line per event');
  $s->release;
  like(dies { $s->append('message') }, qr/is closed/, 'no append after release');
};

subtest 'one writer: a second one fails at once, in this process and another' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $store = Langertha::Raider::SessionStore->new(root => $root);
  my $s = $store->create;
  my $id = $s->id;
  like(dies { $store->open($id) }, qr/\Asession \Q$id\E is in use/, 'same process');

  pipe my $r, my $w or die $!;
  my $pid = fork // die $!;
  unless ($pid) {
    close $r;
    my $ok = eval { Langertha::Raider::SessionStore->new(root => $root)->open($id); 1 };
    print {$w} $ok ? 'opened' : $@;
    close $w;
    POSIX::_exit(0);
  }
  close $w;
  my $msg = do { local $/; <$r> };
  waitpid $pid, 0;
  like($msg, qr/\Asession \Q$id\E is in use/, 'another process');

  my $t0 = time;
  ok(dies { $store->open($id) }, 'still locked');
  ok(time - $t0 < 2, 'never waits');

  my $journal = $store->read($id);
  is($journal->created->{id}, $id, 'readers need no lock');

  $s->release;
  my $again = $store->open($id);
  ok($again->is_open, 'free again after release');
  undef $again;
  ok(lives { $store->open($id)->release }, 'and after the writer went out of scope');
};

subtest 'reopen continues seq and runs' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $store = Langertha::Raider::SessionStore->new(root => $root);
  my $s = $store->create;
  my $id = $s->id;
  $s->append('run.started', run => $s->next_run);
  $s->append('run.started', run => $s->next_run);
  $s->release;
  my $o = $store->open($id);
  is($o->next_run, 'r3', 'run numbering goes on');
  is($o->append('run.started', run => 'r3')->{seq}, 4, 'seq goes on');
  is(scalar @{ $o->journal->events }, 3, 'the journal as it was on opening');
  $o->release;
  is([ map { $_->{seq} } lines(path($store->path_of($id))) ], [ 1 .. 4 ], 'one sequence in the file');
};

subtest 'crash: a cut-off last line' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $store = Langertha::Raider::SessionStore->new(root => $root);
  my $s = $store->create;
  my $id = $s->id;
  $s->append('run.started', run => $s->next_run);
  $s->release;
  my $file = path($store->path_of($id));
  $file->append_raw('{"v":1,"seq":3,"type":"mess');

  my $j = $store->read($id);
  is([ map { $_->{type} } @{ $j->events } ], [qw( session.created run.started )], 'the broken line is ignored');
  is($j->damaged, [3], 'and reported');
  ok($j->unterminated, 'unterminated');

  my $o = $store->open($id);
  is($o->append('message', run => 'r2', role => 'user', content => 'x')->{seq}, 3, 'seq after the last good line');
  $o->release;
  my @raw = $file->lines_raw({ chomp => 1 });
  is(scalar @raw, 4, 'the next append started on a fresh line');
  $j = $store->read($id);
  is($j->damaged, [3], 'the broken line stays reported');
  is($j->events->[-1]{content}, 'x', 'the new event reads fine');
  ok(!$j->unterminated, 'terminated again');
};

subtest 'journal: runs, unknown calls, history' => sub {
  my $root = tempdir(CLEANUP => 1);
  my $store = Langertha::Raider::SessionStore->new(root => $root);
  my $s = $store->create;
  $s->append('run.started', run => 'r1', engine => 'openai');
  $s->append('message', run => 'r1', role => 'user', content => 'one');
  $s->append('tool.call', run => 'r1', call => 'c1', name => 'bash', arguments => {}, status => 'dispatched');
  $s->append('tool.result', run => 'r1', call => 'c1', name => 'bash', status => 'succeeded', content => 'ok');
  $s->append('message', run => 'r1', role => 'assistant', content => 'done one');
  $s->append('run.finished', run => 'r1', status => 'completed');
  $s->append('run.started', run => 'r2');
  $s->append('message', run => 'r2', role => 'user', content => 'two');
  $s->append('run.finished', run => 'r2', status => 'failed', error => 'boom');
  $s->append('run.started', run => 'r3');
  $s->append('message', run => 'r3', role => 'user', content => 'three');
  $s->append('tool.call', run => 'r3', call => 'c1', name => 'bash', arguments => { command => 'rm x' }, status => 'dispatched');
  $s->append('future.type', run => 'r3', whatever => 1);
  my $j = $store->read($s->id);
  is([ map { [ $_->{run}, $_->{status} ] } @{ $j->runs } ],
    [ [ r1 => 'completed' ], [ r2 => 'failed' ], [ r3 => 'interrupted' ] ], 'run states');
  is($j->runs->[0]{prompt}, 'one', 'prompt');
  is($j->runs->[0]{response}, 'done one', 'response');
  is([ map { [ $_->{run}, $_->{call}, $_->{arguments}{command} ] } @{ $j->unknown_calls } ],
    [ [ 'r3', 'c1', 'rm x' ] ], 'the call without a result is unknown; the same call id in r1 is not');
  is($j->history_messages, [ { role => 'user', content => 'one' }, { role => 'assistant', content => 'done one' } ],
    'history: only runs with an answer');
  is($j->last_run_number, 3, 'last run');
  $s->release;
};

subtest 'home scope, ids, unknown and bad ids' => sub {
  my $home = tempdir(CLEANUP => 1);
  local $ENV{HOME} = $home;
  my $store = Langertha::Raider::SessionStore->new(scope => 'home');
  my @made = map { my $s = $store->create; $s->release; $s->id } 1 .. 3;
  is([ $store->ids ], [ reverse sort @made ], 'newest first');
  is($store->latest, ($store->ids)[0], 'latest');
  ok(-d path($home, '.raider', 'sessions'), 'under ~/.raider/sessions');
  ok(!-e path($home, '.raider', '.gitignore'), 'no .gitignore at home');
  is(($store->read($made[0])->created)->{scope}, 'home', 'scope home');
  like(dies { $store->open('20200101-000000-0000') }, qr/\Aunknown session 20200101-000000-0000/, 'unknown id');
  like(dies { $store->read('../../etc/passwd') }, qr/unknown session/, 'no path from a non-id');
  like(dies { $store->path_of('x/../y') }, qr/not a session id/, 'path_of refuses a non-id');
  like(dies { Langertha::Raider::SessionStore->new(scope => 'project') }, qr/needs a root/, 'project needs a root');
};

done_testing;
