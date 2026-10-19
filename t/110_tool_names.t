#!/usr/bin/env perl
# ABSTRACT: The table of Claude Code tool names and the raider tools they stand for
use strict;
use warnings;
use Test2::V0;
use Langertha::Raider::ToolNames;
use Langertha::Raider::ToolEffects;

my $names = 'Langertha::Raider::ToolNames';

subtest 'every Claude Code name maps to its raider tool' => sub {
  my %want = (
    Read => 'read_file', Write => 'write_file', Edit => 'edit_file', MultiEdit => 'edit_file',
    Bash => 'bash', Glob => 'glob', Grep => 'grep', LS => 'list_files',
    WebFetch => 'web_fetch', WebSearch => 'web_search', TodoWrite => 'todo_write',
    Task => 'agent', Agent => 'agent', Skill => 'skill',
    AskUserQuestion => 'ask_user', ExitPlanMode => 'exit_plan_mode',
  );
  is( $names->raider_name($_), $want{$_}, "$_ -> $want{$_}" ) for sort keys %want;
  is( [ $names->claude_names ], [ sort keys %want ], 'the table has exactly these names' );
};

subtest 'mcp__ names pass through, unknown names are unknown' => sub {
  is( $names->raider_name('mcp__github__create_issue'), 'mcp__github__create_issue', 'mcp tool' );
  is( $names->raider_name('mcp__plugin_x_y__do-it'),    'mcp__plugin_x_y__do-it',    'server with underscores' );
  is( $names->claude_name('mcp__github__create_issue'), 'mcp__github__create_issue', 'the way back too' );
  ok( $names->is_mcp('mcp__a__b'), 'is_mcp' );
  ok( !$names->is_mcp($_), 'not mcp: ' . ( $_ // 'undef' ) ) for 'mcp__server', 'mcp____', 'Read', 'mcp_a_b', undef;
  is( $names->raider_name('NotATool'), undef, 'unknown: undef' );
  is( $names->raider_name('read_file'), undef, 'a raider name is not a Claude name' );
  like( dies { $names->raider_name('') }, qr/needs a tool name/, 'empty name croaks' );
};

subtest 'the way back answers with the current Claude name' => sub {
  is( $names->claude_name('edit_file'), 'Edit', 'Edit, not MultiEdit' );
  is( $names->claude_name('agent'),     'Agent', 'Agent, not Task' );
  is( $names->claude_name('list_files'), 'LS', 'LS' );
  is( $names->claude_name('perl_eval'), undef, 'a raider-only tool has no Claude name' );
  is( $names->raider_name( $names->claude_name($_) ), $_, "round trip: $_" ) for $names->raider_names;
};

subtest 'arguments: raider form to Claude form' => sub {
  is( $names->claude_input( read_file => { path => 'lib/A.pm' } ), { file_path => 'lib/A.pm' }, 'Read' );
  is( $names->claude_input( write_file => { path => 'a', content => 'x' } ),
    { file_path => 'a', content => 'x' }, 'Write' );
  is( $names->claude_input( edit_file => { path => 'a', old_string => 'o', new_string => 'n' } ),
    { file_path => 'a', old_string => 'o', new_string => 'n' }, 'Edit' );
  is( $names->claude_input( bash => { command => 'ls', timeout => 120 } ),
    { command => 'ls', timeout => 120000 }, 'Bash: seconds become milliseconds' );
  my %same = (
    list_files => { path => 'lib' },
    glob       => { pattern => '**/*.pm', path => 'lib' },
    grep       => { pattern => 'x', path => 'lib', glob => '*.pm', output_mode => 'content', '-i' => 1, multiline => 0 },
    web_fetch  => { url => 'https://example.org', as_html => 1 },
    web_search => { query => 'perl', limit => 3 },
    todo_write => { todos => [ { content => 'a', status => 'pending', activeForm => 'doing a' } ] },
    ask_user   => { question => 'Which?', options => [ 'a', 'b' ] },
    skill      => { skill => 'pdf', args => 'x' },
    agent      => { description => 'd', prompt => 'p', subagent_type => 'Explore' },
    perl_eval  => { code => '1' },
    mcp__a__b  => { path => 'x' },
  );
  is( $names->claude_input( $_ => $same{$_} ), $same{$_}, "$_: unchanged" ) for sort keys %same;
  is( $names->claude_input( read_file => { path => 'a', offset => 2 } ), { file_path => 'a', offset => 2 },
    'unknown keys pass through' );
  my $in = { path => 'a' };
  my $out = $names->claude_input( read_file => $in );
  is( $in, { path => 'a' }, 'the input is not changed' );
  ok( $out != $in, 'a new hash' );
  is( $names->claude_input( read_file => { path => 'a', file_path => 'b' } ), { file_path => 'a' },
    'both names: the translated key wins' );
};

subtest 'arguments: Claude form back to raider form' => sub {
  is( $names->raider_input( read_file => { file_path => '/abs/A.pm', offset => 10, limit => 5 } ),
    { path => '/abs/A.pm', offset => 10, limit => 5 }, 'Read' );
  is( $names->raider_input( edit_file => { file_path => 'a', old_string => 'o', new_string => 'n', replace_all => 1 } ),
    { path => 'a', old_string => 'o', new_string => 'n', replace_all => 1 }, 'Edit' );
  is( $names->raider_input( bash => { command => 'ls', timeout => 120000, description => 'list' } ),
    { command => 'ls', timeout => 120, description => 'list' }, 'Bash: milliseconds become seconds' );
  is( $names->raider_input( bash => { command => 'ls', timeout => 1500 } )->{timeout}, 2,
    'part of a second rounds up to a whole second' );
  is( $names->raider_input( bash => { command => 'ls', timeout => 'soon' } )->{timeout}, 'soon',
    'a timeout that is no number passes unchanged' );
  is( $names->raider_input( grep => { pattern => 'x', path => 'lib' } ), { pattern => 'x', path => 'lib' }, 'Grep unchanged' );
  is( $names->raider_input( ask_user => { questions => [ { question => 'q' } ] } ),
    { questions => [ { question => 'q' } ] }, 'AskUserQuestion: shape differs, passes unchanged' );
};

subtest 'arguments: the round trip is lossless' => sub {
  my @cases = (
    [ read_file  => { path => 'lib/A.pm' } ],
    [ write_file => { path => '/abs/x', content => "a\nb" } ],
    [ edit_file  => { path => 'a', old_string => 'o', new_string => 'n' } ],
    [ bash       => { command => 'prove', timeout => 300, working_directory => 't' } ],
    [ bash       => { command => 'ls' } ],
    [ grep       => { pattern => 'x', '-C' => 2 } ],
    [ ask_user   => { question => 'q', options => ['a'] } ],
    [ mcp__s__t  => { file_path => 'x', path => 'y' } ],
  );
  for my $c (@cases) {
    my ( $tool, $args ) = @$c;
    is( $names->raider_input( $tool => $names->claude_input( $tool => $args ) ), $args, "$tool: raider -> Claude -> raider" );
  }
  my @back = (
    [ read_file => { file_path => '/a', offset => 1, limit => 2 } ],
    [ edit_file => { file_path => '/a', old_string => 'o', new_string => 'n', replace_all => 1 } ],
    [ bash      => { command => 'ls', timeout => 60000, run_in_background => 0 } ],
  );
  for my $c (@back) {
    my ( $tool, $args ) = @$c;
    is( $names->claude_input( $tool => $names->raider_input( $tool => $args ) ), $args, "$tool: Claude -> raider -> Claude" );
  }
  like( dies { $names->claude_input( read_file => 'x' ) }, qr/needs the arguments as a hash ref/, 'not a hash: croaks' );
  like( dies { $names->raider_input( undef, {} ) }, qr/needs a tool name/, 'no tool: croaks' );
};

subtest 'the tools raider has today have an effect class' => sub {
  my @built = qw( read_file write_file edit_file bash glob grep list_files web_fetch web_search todo_write ask_user );
  for my $tool (@built) {
    ok( defined Langertha::Raider::ToolEffects->effects_for($tool), "$tool has a class" );
    ok( defined $names->claude_name($tool), "$tool has a Claude name" );
  }
};

done_testing;
