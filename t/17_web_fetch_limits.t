#!/usr/bin/env perl
# ABSTRACT: web_fetch ends on a silent peer and stops reading at max_fetch_bytes (k146)
use strict;
use warnings;
use Test2::V0;
use IO::Async::Listener;
use IO::Async::Loop;
use Time::HiRes qw( time );

use Langertha::Raider::WebTools qw( build_web_tools_server );

local @ENV{qw( BRAVE_API_KEY SERPER_API_KEY GOOGLE_API_KEY GOOGLE_CSE_ID )};
my $loop = IO::Async::Loop->new;
my ( $mode, $sent, @requests ) = ( 'silent', 0 );

my $listener = IO::Async::Listener->new(
  on_stream => sub {
    my ( undef, $stream ) = @_;
    $stream->configure(
      on_read => sub {
        my ( $s, $buffref ) = @_;
        return 0 unless $$buffref =~ /\r\n\r\n/;
        push @requests, $$buffref;
        $$buffref = '';
        return 0 if $mode eq 'silent';
        # Declares 100 MB, sends 64 KB chunks until the peer goes away.
        $s->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 104857600\r\n\r\n");
        my $send;
        $send = sub {
          return unless $s->loop;
          $s->write( 'x' x 65536, on_flush => sub { $sent += 65536; $send->() if $s->loop } );
        };
        $send->();
        return 0;
      },
    );
    $loop->add($stream);
  },
);
$loop->add($listener);
my $port = $listener->listen( addr => { family => 'inet', socktype => 'stream', ip => '127.0.0.1', port => 0 } )
  ->get->read_handle->sockport;

my $server = build_web_tools_server(
  loop => $loop, max_fetch_bytes => 100_000, fetch_timeout => 5, stall_timeout => 1 );
my ($tool) = grep { $_->name eq 'web_fetch' } @{ $server->tools };
my $call = sub { $tool->code->( $tool, { url => "http://127.0.0.1:$port/" } ) };

subtest 'silent peer: tool error, no hang' => sub {
  my ( $res, $hung );
  local $SIG{ALRM} = sub { $hung = 1; die "hung\n" };
  my $t = time;
  alarm 15;
  eval { $res = $call->(); 1 };
  alarm 0;
  ok( !$hung, 'web_fetch ends' );
  ok( $res && $res->{isError}, 'tool error' );
  like( $res->{content}[0]{text}, qr/stall|timed? ?out/i, 'says stall or timeout' ) if $res;
  ok( time - $t < 10, 'within the timeouts' );
};

subtest 'endless body: cut off at max_fetch_bytes' => sub {
  $mode = 'flood';
  my ( $res, $hung );
  local $SIG{ALRM} = sub { $hung = 1; die "hung\n" };
  alarm 15;
  eval { $res = $call->(); 1 };
  alarm 0;
  ok( !$hung, 'web_fetch ends' );
  ok( $res && !$res->{isError}, 'not an error' ) or diag $res && $res->{content}[0]{text};
  my $text = $res ? $res->{content}[0]{text} : '';
  like( $text, qr/\[truncated\]/, 'marked truncated' );
  ok( length($text) < 101_000, 'body is cut at the limit' );
  ok( $sent < 10_000_000, 'sender was stopped long before 100 MB' );
  like( $requests[-1], qr{User-Agent: raider/\d}i, 'user agent carries the version' );
};

done_testing;
