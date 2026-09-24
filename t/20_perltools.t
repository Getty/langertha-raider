#!/usr/bin/env perl
# ABSTRACT: Unit tests for the PerlTools MCP server

use strict;
use warnings;
use Test2::Bundle::More;
use File::Temp qw( tempdir );
use Path::Tiny;
use IPC::Run ();
use JSON::MaybeXS ();

use Langertha::Raider::PerlTools qw( build_perl_tools_server );

my $dir = tempdir(CLEANUP => 1);

# Run from a scratch cwd that is not the root, so cwd and relative-path
# checks mean something and a regression cannot write into the checkout.
my $scratch = path(tempdir(CLEANUP => 1))->child('cwd');
$scratch->mkpath;
chdir $scratch or die "chdir $scratch: $!";

my $fakebin = path($dir)->child('fakebin');
$fakebin->mkpath;
my $fake_cpanm = $fakebin->child('cpanm');
$fake_cpanm->spew_utf8(<<'SH');
#!/bin/sh
case "$*" in
  *Definitely::Not::A::Real::Raider::Module::XYZ*) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod 0755, $fake_cpanm;
$ENV{PATH} = $fakebin . ':' . $ENV{PATH};

my $server = build_perl_tools_server(root => $dir);

sub call_tool {
  my ($name, $args) = @_;
  my ($tool) = grep { $_->name eq $name } @{ $server->tools };
  die "no tool $name" unless $tool;
  return $tool->code->($tool, $args);
}

sub decoded {
  my ($res) = @_;
  my $text = $res->{content}[0]{text};
  return JSON::MaybeXS::decode_json($text);
}

subtest perl_eval_basic => sub {
  my $res = call_tool('perl_eval', { code => 'print "hello world"' });
  ok(!$res->{isError}, 'no error');
  my $d = decoded($res);
  like($d->{stdout}, qr/hello world/, 'stdout captured');
  is($d->{exit_code}, 0, 'exit code 0');
};

subtest perl_eval_stderr => sub {
  my $res = call_tool('perl_eval', { code => 'warn "test warning"' });
  my $d = decoded($res);
  like($d->{stderr}, qr/test warning/, 'stderr captured');
};

subtest perl_eval_return_value => sub {
  my $res = call_tool('perl_eval', { code => 'print "42"' });
  my $d = decoded($res);
  is($d->{return_value}, '42', 'return value from stdout');
};

subtest perl_eval_bad_code => sub {
  my $res = call_tool('perl_eval', { code => 'die "boom"' });
  my $d = decoded($res);
  ok($d->{exit_code} != 0, 'non-zero exit code');
  like($d->{stderr}, qr/boom/, 'stderr captured');
};

subtest perl_eval_stdin => sub {
  my $res = call_tool('perl_eval', {
    code    => 'my $x = <STDIN>; print uc $x',
    stdin   => "hello\n",
    timeout => 5,
  });
  my $d = decoded($res);
  like($d->{stdout}, qr/HELLO/, 'stdin processed');
};

subtest perl_check_valid => sub {
  my $res = call_tool('perl_check', { code => 'print "valid"' });
  ok(!$res->{isError}, 'no error');
  my $d = decoded($res);
  is($d->{valid}, JSON::MaybeXS::true, 'valid syntax');
  ok(!defined $d->{syntax_error}, 'no syntax error');
};

subtest perl_check_invalid => sub {
  my $res = call_tool('perl_check', { code => 'use strict; my @a = (1, 2' });
  ok(!$res->{isError}, 'tool call itself succeeded');
  my $d = decoded($res);
  is($d->{valid}, JSON::MaybeXS::false, 'invalid syntax');
  ok(defined $d->{syntax_error}, 'syntax_error populated');
};

subtest perl_eval_runs_in_root_with_current_perl => sub {
  my $fake_perl = $fakebin->child('perl');
  $fake_perl->spew_utf8("#!/bin/sh\necho fake-perl\n");
  chmod 0755, $fake_perl;
  IPC::Run::clearcache();
  my $res = call_tool('perl_eval', {
    code => 'use Cwd qw( getcwd ); print getcwd(), "\n", $^X, "\n"',
  });
  my $d = decoded($res);
  my ( $cwd, $perl ) = split /\n/, $d->{stdout};
  is(path($cwd)->realpath->stringify, path($dir)->realpath->stringify, 'cwd is the root');
  is($perl, $^X, 'runs the perl that runs raider');
  $fake_perl->remove;
};

subtest perl_eval_timeout_reported => sub {
  my $res = call_tool('perl_eval', { code => 'sleep 10', timeout => 1 });
  my $d = decoded($res);
  is($d->{error}, 'timeout', 'timeout reported as timeout');
};

subtest perl_eval_timeout_kills_child => sub {
  my $pidfile = path($dir)->child('eval-timeout.pid');
  $pidfile->remove;
  my $res = call_tool('perl_eval', {
    code    => 'open my $f, ">", "eval-timeout.pid" or die; print $f $$; close $f; sleep 30',
    timeout => 1,
  });
  my $d = decoded($res);
  is($d->{error}, 'timeout', 'timeout reported');
  ok(-f $pidfile, 'child wrote its pid') or return;
  my $pid = $pidfile->slurp_utf8;
  ok(!kill(0, $pid), 'child is gone after the timeout');
  kill 'KILL', $pid;
};

subtest perl_eval_start_failure_not_reported_as_timeout => sub {
  my $res = call_tool('perl_eval', { code => 'print 1', timeout => 'not-a-number' });
  my $d = decoded($res);
  ok(defined $d->{error}, 'error reported');
  isnt($d->{error}, 'timeout', 'non-timeout failure is not called a timeout');
};

subtest perl_check_description_is_honest => sub {
  my ($tool) = grep { $_->name eq 'perl_check' } @{ $server->tools };
  unlike($tool->description, qr/without executing/i, 'does not claim nothing runs');
  like($tool->description, qr/BEGIN/, 'warns that BEGIN and use run');
};

subtest perl_check_uses_target_lib_and_root => sub {
  my $pm = path($dir)->child('.raider', 'lib', 'lib', 'perl5', 'Raider', 'CheckOnly.pm');
  $pm->parent->mkpath;
  $pm->spew_utf8("package Raider::CheckOnly; 1;\n");
  path($dir)->child('marker-root.txt')->spew_utf8("1\n");
  my $res = call_tool('perl_check', {
    code => 'use Raider::CheckOnly; BEGIN { -f "marker-root.txt" or die "not in root" }',
  });
  my $d = decoded($res);
  is($d->{valid}, JSON::MaybeXS::true, 'module from target lib and root cwd are visible')
    or diag $d->{syntax_error};
};

subtest perl_cpanm_rejects_target_outside_root => sub {
  my $outside = tempdir(CLEANUP => 1);
  my $dotdot = path($dir)->stringify.'/../'.path($outside)->basename;
  for my $target ($outside, $dotdot, '../escape') {
    my $res = call_tool('perl_cpanm', {
      module  => 'Acme::Outside',
      options => { target => $target },
    });
    ok($res->{isError}, 'target '.$target.' rejected');
  }
  ok(!-e path($outside)->child('cpanfile'), 'nothing written outside root');
};

subtest perl_cpanm_relative_target_inside_root => sub {
  my $res = call_tool('perl_cpanm', {
    module  => 'Acme::Relative',
    options => { target => '.raider/rel' },
  });
  ok(!$res->{isError}, 'relative target accepted');
  ok(-f path($dir)->child('.raider', 'rel', 'cpanfile'), 'resolved against the root');
};

subtest relative_lib_target_resolves_against_root => sub {
  my $rel_server = build_perl_tools_server(root => $dir, lib_target => '.raider/rel-conf');
  my $call = sub {
    my ($name, $args) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $rel_server->tools };
    return $tool->code->($tool, $args);
  };

  my $pm = path($dir)->child('.raider', 'rel-conf', 'lib', 'perl5', 'Raider', 'RelConf.pm');
  $pm->parent->mkpath;
  $pm->spew_utf8("package Raider::RelConf; 1;\n");
  my $d = decoded($call->('perl_eval', { code => 'use Raider::RelConf; print "ok"' }));
  is($d->{stdout}, 'ok', 'PERL5LIB points into the root') or diag $d->{stderr};

  my $c = decoded($call->('perl_cpanm', { module => 'Acme::RelConf' }));
  is($c->{target}, path($dir)->child('.raider', 'rel-conf')->stringify, 'cpanm --local-lib is the root-relative path');
  ok(-f path($dir)->child('.raider', 'rel-conf', 'cpanfile'), 'cpanm target resolved against the root');
  ok(!-e path('.raider'), 'nothing created relative to the process cwd');
};

subtest perl_cpanm_description_names_real_default => sub {
  my ($tool) = grep { $_->name eq 'perl_cpanm' } @{ $server->tools };
  unlike($tool->description, qr{\.raider/lib/standalone}, 'no stale standalone path');
};

subtest perl_cpanm_init_lib => sub {
  my $target = path($dir)->child('.raider', 'lib')->stringify;

  my $res = call_tool('perl_cpanm', {
    module  => 'Acme::Test::Raider',
    options => { target => $target },
  });

  ok(-d $target, 'lib directory created');
  ok(-f path($target, 'cpanfile'), 'cpanfile created');
  ok(-f path($target, 'perl-version'), 'perl-version created');
};

subtest perl_cpanm_idempotent => sub {
  my $target = path($dir)->child('.raider', 'lib2')->stringify;

  call_tool('perl_cpanm', {
    module  => 'Acme::Double',
    options => { target => $target },
  });
  call_tool('perl_cpanm', {
    module  => 'Acme::Double',
    options => { target => $target },
  });

  my $cpanfile = path($target, 'cpanfile')->slurp_utf8;
  my $count = () = $cpanfile =~ /\bAcme::Double\b/g;
  is($count, 1, 'cpanfile entry is idempotent (no duplicates)');
};

subtest perl_cpanm_failed_install_not_recorded => sub {
  my $target = path($dir)->child('.raider', 'lib3')->stringify;
  my $module = 'Definitely::Not::A::Real::Raider::Module::XYZ';

  my $res = call_tool('perl_cpanm', {
    module  => $module,
    options => { target => $target, from => path($dir)->child('empty-cpan')->stringify },
  });
  my $d = decoded($res);
  ok(!$d->{installed}, 'install reported failure');

  my $cpanfile = path($target, 'cpanfile')->slurp_utf8;
  unlike($cpanfile, qr/\Q$module\E/, 'failed install not appended to cpanfile');
};

done_testing;
