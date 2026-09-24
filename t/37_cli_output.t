#!/usr/bin/env perl
# ABSTRACT: The raider CLI renderer: lines, config report and the --json documents

use strict;
use warnings;
use utf8;
use Test2::V0;
use Encode qw( decode_utf8 );
use JSON::MaybeXS ();
use Langertha::Raider::CLI::Output;

# An Output writing into a string through the same :encoding(UTF-8) layer
# bin/raider puts on STDOUT. Returns the output and a reader for the octets.
sub output {
  my ( %args ) = @_;
  my $buf = '';
  open my $fh, '>:encoding(UTF-8)', \$buf or die $!;
  my $out = Langertha::Raider::CLI::Output->new(out => $fh, %args);
  return ( $out, sub { close $fh; my $b = $buf; $b } );
}

subtest 'plain lines without a terminal' => sub {
  my ( $out, $read ) = output();
  ok(!$out->color, 'no color on a non-terminal handle');
  $out->say_meta('history cleared.');
  $out->say_error('boom');
  $out->say_agent('run `prove`');
  is($read->(), "history cleared.\nerror: boom\nrun `prove`\n", 'lines');
};

subtest 'colors and inline code' => sub {
  local $ENV{ANSI_COLORS_DISABLED};
  my ( $out, $read ) = output(color => 1);
  like($out->c(meta => 'x'), qr/\e\[[\d;]+mx\e\[0m/, 'colored');
  like($out->render_inline_code('a `b` c'), qr/a \e\[[\d;]+mb\e\[0m\e\[[\d;]+m c/, 'inline code highlighted');
  is($out->render_inline_code("```\ncode\n```"), "```\ncode\n```", 'fences untouched');
};

subtest 'config report' => sub {
  my ( $out, $read ) = output();
  $out->config_report({
    file    => '/x/.raider.yml',
    exists  => 0,
    engine  => 'openai',
    values  => [
      { key => 'model', value => 'm', source => '-m', shadowed => ['.raider.yml'], applies_to => 'engine' },
      { key => 'skills', value => ['claude'], source => '.raider.yml', shadowed => [], merged => 1,
        applies_to => 'raider' },
    ],
    ignored => [ { key => 'anthropic', reason => 'section of an inactive engine' } ],
  });
  is($read->(), <<'OUT', 'report');
file:   /x/.raider.yml (not present)
engine: openai
  model                  m  (from -m, overrides .raider.yml; engine)
  skills                 ["claude"]  (from .raider.yml, merged; raider)
  ignored anthropic: section of an inactive engine
OUT
};

subtest '--json result' => sub {
  my ( $out, $read ) = output();
  $out->json_result('Grüße ✓', { raids => 1 }, 3);
  my $octets = $read->();
  my $doc = JSON::MaybeXS->new(utf8 => 1)->decode($octets);
  is($doc, { response => 'Grüße ✓', metrics => { raids => 1 }, elapsed => 3 }, 'document, UTF-8 once');
  like(decode_utf8($octets), qr/\A\{\n   "elapsed" : 3,\n/, 'pretty and canonical');
};

subtest '--json error' => sub {
  my ( $out, $read ) = output();
  $out->json_error('kaputt: ä', 0);
  is(JSON::MaybeXS->new(utf8 => 1)->decode($read->()), { error => 'kaputt: ä', elapsed => 0 }, 'error document');
};

done_testing;
