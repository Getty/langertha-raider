#!/usr/bin/env perl
# ABSTRACT: maint/claude-log-to-scenario drafts a scenario from a Claude Code session, and the draft runs
use strict;
use warnings;
use utf8;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";
use IPC::Open3 qw( open3 );
use Path::Tiny;
use YAML::PP;
BEGIN {
  plan skip_all => 'maint/claude-log-to-scenario is development infrastructure, not in the tarball'
    unless -f "$FindBin::Bin/../maint/claude-log-to-scenario";
  eval { require Langertha::Engine::Virtual; 1 }
    or plan skip_all => 'needs Langertha::Engine::Virtual (Langertha 0.504 or later)';
}
use Test::Raider::Scenario qw( run_scenario_files );

# t/data/claude-log/session.jsonl is a synthetic session of a project at
# /home/tester/work/demo (home /home/tester), in the shape Claude Code writes:
# prompt 1 -- a response split over three lines (thinking, text, Read), a
# response with an unknown tool (ToolSearch) and an Edit, a sidechain record,
# a response with a Read outside the project, a failing Bash and a Bash
# carrying a secret, a closing text; prompt 2 -- a Read in the home, an Agent
# call, a Read of a part of a file, a closing text. Secrets in it are fake.

my $script = path("$FindBin::Bin/../maint/claude-log-to-scenario")->realpath;
my $log    = path("$FindBin::Bin/data/claude-log/session.jsonl")->realpath;
my $yaml   = YAML::PP->new( boolean => 'JSON::PP' );

sub convert {
  my ( @args ) = @_;
  my $err = Path::Tiny->tempfile;
  my $fh  = $err->openw_raw;
  my $pid = open3( my $in, my $out, '>&'.fileno($fh), $^X, "$script", @args );
  close $in;
  my $stdout = do { local $/; <$out> };
  waitpid $pid, 0;
  close $fh;
  utf8::decode($stdout);
  return { out => $stdout, err => $err->slurp_utf8, exit => $? >> 8 };
}

subtest 'the first prompt up to the next one' => sub {
  my $run = convert( "$log", '--home', '/home/tester' );
  is( $run->{exit}, 0, 'converts' ) or diag $run->{err};
  my $text = $run->{out};
  my $s    = $yaml->load_string($text);

  like( $text, qr/\A# DRAFT -- written by maint\/claude-log-to-scenario/, 'the head says it is a draft' );
  is( $s->{prompt}, 'Change two to 2 in app.txt. My key is REDACTED.', 'prompt: path relative, key redacted' );
  is( $s->{files}, { 'app.txt' => "one\ntwo\nthree\n\n" }, 'files: rebuilt from the whole Read, its trailing empty line kept' );
  ok( !exists $s->{home}, 'no home file' );
  is( $s->{script}, [
    { tool_calls => [ [ read_file => { path => 'app.txt' } ] ] },
    { tool_calls => [ [ edit_file => { path => 'app.txt', old_string => 'two', new_string => '2', replace_all => F() } ] ] },
    { tool_calls => [
      [ bash => { command => 'ls {{ROOT}}/no-such-dir', description => 'List a missing directory' } ],
      [ bash => { command => 'echo API_TOKEN=REDACTED > /dev/null', timeout => 30 } ],
    ] },
    { text => 'Done: two is now 2 in app.txt.' },
  ], 'script: one step per response (split lines joined), names and arguments translated, sidechain skipped' );
  is( $s->{expect}, {
    answer => 'Done: two is now 2 in app.txt.',
    tools  => [
      { name => 'read_file', text => 'one' },
      { name => 'edit_file' },
      { name => 'bash', error => T() },
      { name => 'bash' },
    ],
  }, 'expect: the answer and every call, the failed one an error, the whole read anchored' );

  like( $text, qr/^  # left out ToolSearch: raider has no such tool$/m, 'the unknown tool is noted' );
  like( $text, qr{^  # left out Read /etc/hostname: outside the project and the home$}m, 'the call outside is noted' );
  like( $text, qr/^    # Claude Code: Exit code 2$/m, "Claude Code's error is noted" );
  like( $text, qr/^  # model: I read the file first\.$/m, 'the text beside tool calls is noted' );
  unlike( $text, qr/sk-fake|ghp_fake|hunter22/, 'no secret left' );
  unlike( $text, qr{/home/tester}, 'no path of the session left' );
  unlike( $text, qr/side\.txt|plan/, 'neither sidechain nor thinking' );

  my $dir = Path::Tiny->tempdir;
  my $file = $dir->child('from-claude-log.yml');
  $file->spew_utf8($text);
  run_scenario_files("$file");
};

subtest 'the second prompt: the home, an agent, a partial read' => sub {
  my $run = convert( "$log", '--home', '/home/tester', '--from', 'u0000019' );
  is( $run->{exit}, 0, 'converts' ) or diag $run->{err};
  my $s = $yaml->load_string( $run->{out} );
  is( $s->{prompt}, 'Now look at my config.', 'the prompt it starts at' );
  is( $s->{home}, { '.config/demo.conf' => "name=demo\npassword=REDACTED\n" }, 'home: the file read there, its password redacted' );
  ok( !exists $s->{files}, 'big.txt is not rebuilt from a part' );
  like( $run->{out}, qr/^# big\.txt: not rebuilt, read only in part \(lines 10 to 14 of 40\)$/m, 'and that is noted' );
  is( $s->{script}[0], { tool_calls => [
    [ read_file => { path => '{{HOME}}/.config/demo.conf' } ],
    [ agent     => { description => 'Check', prompt => 'Look at {{ROOT}}', subagent_type => 'general-purpose' } ],
  ] }, 'a home path as {{HOME}}, Agent as agent with the root a placeholder' );
  is( $s->{script}[1], { tool_calls => [ [ read_file => { path => 'big.txt', offset => 10, limit => 5 } ] ] },
    'the arguments raider does not know pass through' );
};

subtest '--turns runs on over the next prompt' => sub {
  my $run = convert( "$log", '--home', '/home/tester', '--from', 'u0000012', '--turns', '3' );
  is( $run->{exit}, 0, 'converts' ) or diag $run->{err};
  my $s = $yaml->load_string( $run->{out} );
  is( $s->{prompts}, [ 'Change two to 2 in app.txt. My key is REDACTED.', 'Now look at my config.' ],
    'the prompt before the start, then the one met on the way' );
  is( [ map { $_->{text} // 'calls' } @{ $s->{script} } ], [ 'calls', 'Done: two is now 2 in app.txt.', 'calls', 'done' ],
    'a turn cut short ends on a text answer' );
  like( $run->{out}, qr/# the turn ends here without a text answer in the log/, 'which is noted' );
};

subtest 'a session id is looked up in the Claude projects' => sub {
  my $config = Path::Tiny->tempdir;
  my $copy   = $config->child( 'projects', '-home-tester-work-demo', '00000000-0000-4000-8000-000000000001.jsonl' );
  $copy->touchpath;
  $log->copy($copy);
  local $ENV{CLAUDE_CONFIG_DIR} = "$config";
  my $by_id = convert( '00000000-0000-4000', '--home', '/home/tester' );
  is( $by_id->{exit}, 0, 'found by the start of its id' ) or diag $by_id->{err};
  like( $by_id->{out}, qr/^# 00000000-0000-4000-8000-000000000001, from record/m, 'the head names the session' );
  my $listed = convert( '00000000-0000-4000-8000-000000000001', '--list' );
  like( $listed->{out}, qr/^u0000001-\S+  \S+  PROMPT  Change two .* My key is REDACTED\.$/m, '--list shows the prompts, redacted' );
  like( $listed->{out}, qr/^u0000003-\S+  \S+  MODEL   "I read the file first\." Read$/m, 'and the responses' );
};

subtest 'mistakes are refused with a message' => sub {
  my $result = convert( "$log", '--from', 'u0000006' );
  is( $result->{exit}, 2, 'a tool result is no start' );
  like( $result->{err}, qr/\Aclaude-log-to-scenario: Record u0000006-\S+ is a tool result: start at a prompt or a model response\n\z/,
    'said in one line' );
  my $missing = convert( "$log", '--from', 'nope' );
  is( $missing->{exit}, 2, 'an unknown record' );
  like( $missing->{err}, qr/No record nope/, 'is named' );
};

done_testing;
