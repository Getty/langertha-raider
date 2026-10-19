#!/usr/bin/env perl
# ABSTRACT: The skill tool loads a catalogue skill on demand (ADR 0019 §4, k151)
use strict;
use warnings;
use Test2::V0;
use File::Temp qw( tempdir );
use Path::Tiny;
use IO::Async::Loop;
use Net::Async::MCP;
use Langertha::Raider::Context::Skills;
use Langertha::Raider::SkillTools qw( build_skill_tools_server );
use Langertha::Raider::ToolEffects;

# One MCP tool, `skill`, in the shape of Claude Code's Skill tool: the body
# under "Base directory for this skill: DIR", arguments substituted; unknown
# or not model-invocable names are error results naming the listed skills.

local $ENV{HOME} = tempdir(CLEANUP => 1);
local $ENV{CLAUDE_CONFIG_DIR} = tempdir(CLEANUP => 1);

my $w = path(tempdir(CLEANUP => 1));
sub put { my ( $rel, $text ) = @_; my $f = $w->child($rel); $f->parent->mkpath; $f->spew_utf8($text); return $f }
put('skills/pdf/SKILL.md', "---\ndescription: PDF things\n---\nRead \$ARGUMENTS with pdftotext.\n");
put('skills/plain/SKILL.md', "---\ndescription: plain\n---\nPlain body.\n");
put('skills/secret/SKILL.md', "---\ndescription: humans only\ndisable-model-invocation: true\n---\nsecret\n");
put('plug/skills/brainstorm/SKILL.md', "---\ndescription: think\n---\nThink first.\n");

my $cat = Langertha::Raider::Context::Skills->new(
  roots   => [ { dir => "$w/skills", source => '.claude/skills', layout => 'skills' } ],
  plugins => [ { name => 'sp', dirs => [ "$w/plug/skills/brainstorm" ] } ],
);
my $server = build_skill_tools_server(skills => $cat);

sub call_tool {
  my ( $name, $args ) = @_;
  my ( $tool ) = grep { $_->name eq $name } @{ $server->tools };
  die "no tool $name" unless $tool;
  return $tool->code->($tool, $args);
}

subtest 'one tool with the schema' => sub {
  is([ map { $_->name } @{ $server->tools } ], [ 'skill' ], 'only skill');
  my ( $tool ) = @{ $server->tools };
  is($tool->input_schema->{required}, [ 'skill' ], 'skill required');
  is([ sort keys %{ $tool->input_schema->{properties} } ], [qw( args skill )], 'skill and args');
  like($tool->description, qr/BEFORE acting/, 'tells the model to load before acting');
  is(Langertha::Raider::ToolEffects->effects_for('skill'), [ 'read' ], 'effect class read');
};

subtest 'loads a skill' => sub {
  my $res = call_tool('skill', { skill => 'pdf', args => 'report.pdf' });
  ok(!$res->{isError}, 'no error');
  is($res->{content}[0]{text}, "Base directory for this skill: $w/skills/pdf\n\nRead report.pdf with pdftotext.\n",
    'tool text with arguments');
  is(call_tool('skill', { skill => ' /plain ' })->{content}[0]{text},
    "Base directory for this skill: $w/skills/plain\n\nPlain body.\n", 'slash and blanks tolerated');
  is(call_tool('skill', { skill => 'plain', args => 'more' })->{content}[0]{text},
    "Base directory for this skill: $w/skills/plain\n\nPlain body.\n\nARGUMENTS: more", 'args appended');
  like(call_tool('skill', { skill => 'sp:brainstorm' })->{content}[0]{text}, qr/Think first\./, 'plugin skill');
};

subtest 'errors name the listed skills' => sub {
  my $res = call_tool('skill', { skill => 'nope' });
  ok($res->{isError}, 'unknown is an error');
  is($res->{content}[0]{text}, 'Error: unknown skill: nope. Available skills: pdf, plain, sp:brainstorm',
    'names the listed skills');
  my $hidden = call_tool('skill', { skill => 'secret' });
  ok($hidden->{isError}, 'not model-invocable is an error');
  unlike($hidden->{content}[0]{text}, qr/Available skills:.*secret/, 'and not offered');
  ok(call_tool('skill', {})->{isError}, 'missing name');
  like(call_tool('skill', { skill => [ 'x' ] })->{content}[0]{text}, qr/\(none given\)/, 'non-string name');

  my $empty = build_skill_tools_server(skills => Langertha::Raider::Context::Skills->new(roots => []));
  my ( $t ) = @{ $empty->tools };
  is($t->code->($t, { skill => 'x' })->{content}[0]{text}, 'Error: unknown skill: x. No skills are available.',
    'empty catalogue');
  like(dies { build_skill_tools_server() }, qr/needs skills/, 'croaks without skills');
};

subtest 'end to end over MCP' => sub {
  my $loop = IO::Async::Loop->new;
  my $mcp = Net::Async::MCP->new(server => $server);
  $loop->add($mcp);
  $mcp->initialize->get;
  my $tools = $mcp->list_tools->get;
  is([ map { $_->{name} } @$tools ], [ 'skill' ], 'listed over MCP');
  my $res = $mcp->call_tool('skill', { skill => 'pdf', args => 'x.pdf' })->get;
  is($res->{content}[0]{text}, "Base directory for this skill: $w/skills/pdf\n\nRead x.pdf with pdftotext.\n", 'called over MCP');
  my $err = $mcp->call_tool('skill', { skill => 'secret' })->get;
  ok($err->{isError}, 'error flag survives MCP');
};

done_testing;
