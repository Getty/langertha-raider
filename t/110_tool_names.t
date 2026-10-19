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

subtest 'the tools raider has today have an effect class' => sub {
  my @built = qw( read_file write_file edit_file bash glob grep list_files web_fetch web_search todo_write ask_user );
  for my $tool (@built) {
    ok( defined Langertha::Raider::ToolEffects->effects_for($tool), "$tool has a class" );
    ok( defined $names->claude_name($tool), "$tool has a Claude name" );
  }
};

done_testing;
