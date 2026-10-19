#!/usr/bin/env perl
# ABSTRACT: The application wires the file tools: read state per run, layout decides confinement, images by engine (ADR 0023)
use strict;
use warnings;
use Test2::V0;
use Path::Tiny;
use lib 't/lib';

BEGIN {
  eval { require Langertha::Engine::Virtual; 1 }
    or plan skip_all => 'needs Langertha::Engine::Virtual (Langertha 0.504)';
}
use Test::Raider::MockAI qw( mock_app );

my $home = Path::Tiny->tempdir;
local $ENV{HOME} = $home->realpath->stringify;
delete local $ENV{CLAUDE_CONFIG_DIR};

my @keep;    # the temporary directories live until the end
sub project {
  my ( %files ) = @_;
  push @keep, Path::Tiny->tempdir;
  my $root = $keep[-1]->realpath;
  $root->child($_)->touchpath->spew_utf8( $files{$_} ) for keys %files;
  return $root;
}

subtest 'the layout decides whether the tools reach outside the root' => sub {
  my $claude = mock_app( root => "".project( 'CLAUDE.md' => "x\n" ) );
  is $claude->context->mode, 'claude', 'Claude layout';
  ok $claude->permissions->ask_outside_roots, 'the policy asks for paths outside the roots';
  my $raider = mock_app( root => "".project( '.raider/config.yml' => "permissions: {}\n" ) );
  isnt $raider->context->mode, 'claude', 'raider layout';
  ok !$raider->permissions->ask_outside_roots, 'confined';
};

subtest 'the read state lives for one run' => sub {
  my $root = project( 'a.txt' => "a\n" );
  my $app  = mock_app( root => "$root" );
  $app->file_read_state->record( $root->child('a.txt')->stringify, bytes => "a\n" );
  ok $app->file_read_state->has_read( $root->child('a.txt')->stringify ), 'recorded';
  $app->begin_run;
  ok !$app->file_read_state->has_read( $root->child('a.txt')->stringify ), 'begin_run empties it';
  $app->end_run('completed');
};

subtest 'images go back as content only to a model and wire that take them' => sub {
  my $root = project( 'CLAUDE.md' => "x\n" );
  $root->child('pic.png')->spew_raw("\x89PNG\r\n\x1a\n0000");
  my $script = [ { tool_calls => [ [ read_file => { path => 'pic.png' } ] ] }, { text => 'seen' } ];
  my %can = ( image_input => 0 );
  my $wire = 'anthropic';
  no warnings 'redefine';
  my $orig_supports = Langertha::Engine::Virtual->can('supports');
  local *Langertha::Engine::Virtual::supports = sub {
    my ( $self, $flag ) = @_;
    return exists $can{$flag} ? $can{$flag} : $self->$orig_supports($flag);
  };
  local *Langertha::Engine::Virtual::tool_wire_format = sub { $wire };

  my $result_of = sub {
    my $app = mock_app( root => "$root", script => $script );
    $app->run('look');
    return $app->mock_engine->results->[0]{result};
  };
  my $r = $result_of->();
  ok $r->{isError}, 'a model without image_input: refused';
  like $r->{content}[0]{text}, qr/This model cannot see images/, '... saying why';

  $can{image_input} = 1;
  $r = $result_of->();
  ok !$r->{isError}, 'image_input on the anthropic wire: read';
  is $r->{content}[0]{type}, 'image', 'as image content';

  $wire = 'openai';
  $r = $result_of->();
  ok $r->{isError}, 'the openai wire has no image in a tool result: refused rather than a placeholder';
};

done_testing;
