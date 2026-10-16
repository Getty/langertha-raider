#!/usr/bin/env perl
# ABSTRACT: Scenario suite: a scripted model drives the real raider and its real tools (t/scenarios/*.yml)
use strict;
use warnings;
use utf8;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";
use Path::Tiny;
use YAML::PP;
use Test::Raider::MockAI qw( mock_app );

# Each F<t/scenarios/NN-name.yml> is one step of what raider has to do end to
# end. The model is scripted (Test::Raider::MockAI); the application, the raid
# loop and the stock tools are real, working inside a fresh temporary root.
#
#   title:   what the scenario shows
#   files:   { path => content }        written to the root before the run
#   prompt:  the user prompt
#   script:  the model's answers, one per request:
#              - tool_calls: [ [ tool_name, { arguments } ], ... ]
#              - text: the final answer
#   expect:
#     answer:      the final answer, exactly
#     files:       { path => content }  must exist afterwards with this content
#     absent:      [ path, ... ]        must not exist afterwards
#     tools:       one entry per tool call, in order:
#                    name:   the tool
#                    error:  true if the call must have failed (default false)
#                    text:   regex the result text must match
#                    not_text: regex it must not match
#
# A new scenario is a new file; nothing here changes. Only the scenarios in
# `skip:` (a reason string) are skipped, so a known gap stays visible.

my $yaml  = YAML::PP->new( boolean => 'JSON::PP' );
my @files = sort glob "$FindBin::Bin/scenarios/*.yml";
ok( scalar @files, 'there are scenarios' );

for my $file (@files) {
  my $s    = $yaml->load_file($file);
  my $name = path($file)->basename;
  subtest "$name: " . ( $s->{title} // '' ) => sub {
    skip_all $s->{skip} if $s->{skip};
    my $root = Path::Tiny->tempdir;
    $root->child($_)->touchpath->spew_utf8( $s->{files}{$_} ) for keys %{ $s->{files} // {} };

    my $app    = mock_app( root => "$root", script => $s->{script} // [] );
    my $answer = eval { '' . $app->run( $s->{prompt} // 'go' ) };
    is( $@, '', 'the raid finishes' );
    my $expect = $s->{expect} // {};

    is( $answer, $expect->{answer}, 'final answer' ) if exists $expect->{answer};

    for my $p ( sort keys %{ $expect->{files} // {} } ) {
      ok( $root->child($p)->is_file, "$p exists" )
        && is( $root->child($p)->slurp_utf8, $expect->{files}{$p}, "$p content" );
    }
    ok( !$root->child($_)->exists, "$_ absent" ) for @{ $expect->{absent} // [] };

    if ( my $want = $expect->{tools} ) {
      my @got = @{ $app->mock_engine->results };
      is( scalar @got, scalar @$want, 'number of tool calls' );
      for my $i ( 0 .. $#$want ) {
        my $w = $want->[$i];
        my $g = $got[$i] or next;
        my $text = join "\n", map { $_->{text} // '' } @{ $g->{result}{content} // [] };
        my $tag  = "tool $i ($w->{name})";
        is( $g->{tool_call}{name}, $w->{name}, "$tag: name" );
        is( !!$g->{result}{isError}, !!$w->{error}, "$tag: " . ( $w->{error} ? 'fails' : 'succeeds' ) );
        like( $text, qr/$w->{text}/s, "$tag: result text" ) if defined $w->{text};
        unlike( $text, qr/$w->{not_text}/s, "$tag: result text excludes" ) if defined $w->{not_text};
      }
    }
  };
}

done_testing;
