package Test::Raider::StubEngine;
# ABSTRACT: An OpenAI-compatible stub endpoint that always calls one tool

use strict;
use warnings;
use Exporter 'import';
use IO::Select;
use IO::Socket::INET;
use JSON::MaybeXS ();
use POSIX ();
use Path::Tiny;

our @EXPORT_OK = qw( stub_engine alive );

=func stub_engine

    my ( $pid, $url ) = stub_engine($tool, \%arguments);

Starts the stub engine endpoint in its own process: every chat completion
answers with one call of C<$tool> with C<%arguments>; anything else (the
session embedding request) gets a 404. Returns its pid (kill and reap it
when done) and the base URL for C<-o url=...>.

=cut

sub stub_engine {
  my ( $tool, $arguments ) = @_;
  my $json = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
  my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1,
  ) or die 'listen: '.$!;
  my $body = $json->encode({
    id => 'stub', object => 'chat.completion', created => time, model => 'stub-model',
    choices => [ { index => 0, finish_reason => 'tool_calls', message => {
      role => 'assistant', content => undef,
      tool_calls => [ { id => 'call_1', type => 'function', function => {
        name => $tool, arguments => $json->encode($arguments),
      } } ],
    } } ],
    usage => { prompt_tokens => 1, completion_tokens => 1, total_tokens => 2 },
  });
  my $pid = fork // die 'fork: '.$!;
  unless ($pid) {
    while (IO::Select->new($server)->can_read(60)) {
      my $conn = $server->accept or next;
      my $req = '';
      sysread($conn, $req, 65536, length $req) or last until $req =~ /\r\n\r\n/;
      my ( $head, $rest ) = split /\r\n\r\n/, $req, 2;
      my ( $length ) = $head =~ /^Content-Length:\s*(\d+)/mi;
      sysread($conn, $rest, 65536, length $rest) or last while length($rest) < ($length // 0);
      print {$conn} $head =~ m{\APOST \S*/chat/completions }
        ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
          .length($body)."\r\nConnection: close\r\n\r\n".$body
        : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $conn;
    }
    POSIX::_exit(0);
  }
  my $url = 'http://127.0.0.1:'.$server->sockport.'/v1';
  close $server;
  return ( $pid, $url );
}

=func alive

    ok(!alive($pid), 'gone');

True while C<$pid> is a live process, read from F</proc> (a zombie counts
as gone: it has ended and only waits for init to reap it).

=cut

sub alive {
  my ( $pid ) = @_;
  my $stat = eval { path('/proc', $pid, 'stat')->slurp } // return 0;
  return substr($stat, rindex($stat, ')') + 2, 1) ne 'Z';
}

1;
