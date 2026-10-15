package Langertha::Raider::WebTools;
our $VERSION = '0.504';
# ABSTRACT: MCP::Server factory with web search and fetch tools (Net::Async::WebSearch + Net::Async::HTTP)

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use HTTP::Request::Common qw( GET );
use MCP::Server;
use Net::Async::HTTP;
use Net::Async::WebSearch;
use Net::Async::WebSearch::Provider::DuckDuckGo;
use Net::Async::WebSearch::Provider::Brave;
use Net::Async::WebSearch::Provider::Serper;
use Net::Async::WebSearch::Provider::Google;
use HTML::TreeBuilder;
use Langertha::Raider::ConnectCheck qw( connect_error );

use Exporter 'import';
our @EXPORT_OK = qw( build_web_tools_server );

=description

The web tools of L<raider>: an L<MCP::Server> with C<web_search> and
C<web_fetch>, run on the caller's L<IO::Async::Loop>.

=func build_web_tools_server

    my $server = Langertha::Raider::WebTools::build_web_tools_server(
        loop           => $loop,         # required
        max_fetch_bytes => 2_000_000,
        fetch_timeout   => 60,           # whole web_fetch request or web_search, seconds
        stall_timeout   => 20,           # seconds without data
    );

Returns an L<MCP::Server> instance with two tools:

=over

=item * C<web_search(query, [limit])>  -- multi-provider search via
L<Net::Async::WebSearch>. DuckDuckGo is always enabled (keyless). Brave,
Serper and Google are auto-added when C<BRAVE_API_KEY>, C<SERPER_API_KEY>,
or both C<GOOGLE_API_KEY> + C<GOOGLE_CSE_ID> are set in the environment.
The whole search ends within C<fetch_timeout> (default 60 s) -- a provider
that never answers is a tool error -- and the requests of the default
HTTP client stop at C<fetch_timeout> and after C<stall_timeout> (default
20 s) without data, as for C<web_fetch>.

=item * C<web_fetch(url, [as_html])>  -- fetch a URL via L<Net::Async::HTTP>.
Returns the status, the content type and the body, cut at
C<max_fetch_bytes> (default 2_000_000). HTML is flattened to readable text
unless C<as_html> is true. The body is read in chunks and the request is
cancelled once C<max_fetch_bytes> is exceeded; a request that exceeds
C<fetch_timeout> (default 60 s) or stalls for C<stall_timeout> (default 20 s)
without data is a tool error.

C<limit> of C<web_search> defaults to 8.

=back

Both tools return a tool error, and send nothing, when a module
L<Net::Async::HTTP> needs to connect does not load
(L<IO::Async::Internals::Connector>; for https L<IO::Async::SSL>, which
needs L<IO::Socket::SSL>, L<Net::SSLeay> and the system libssl). The error
names the module. For C<web_fetch> that holds for every redirect it follows
as well: an http URL that redirects to https is the same tool error.

=cut

sub _flatten_html {
  my ($html) = @_;
  my $t = HTML::TreeBuilder->new_from_content($html);
  $_->delete for $t->look_down(_tag => qr/^(?:script|style|noscript)$/);
  my $text = $t->as_text;
  $t->delete;
  $text =~ s/[ \t]+/ /g;
  $text =~ s/\n{3,}/\n\n/g;
  return $text;
}

sub build_web_tools_server {
  my %args = @_;
  my $loop            = $args{loop} or die "loop is required\n";
  my $max_fetch_bytes = $args{max_fetch_bytes} // 2_000_000;
  my $fetch_timeout   = $args{fetch_timeout}   // 60;
  my $stall_timeout   = $args{stall_timeout}   // 20;

  my $http = $args{http} // Net::Async::HTTP->new(
    user_agent    => 'raider/'.$VERSION,
    max_in_flight => 4,
    # Defaults of every request the search providers make (k148); web_fetch
    # passes its own per request.
    timeout       => $fetch_timeout,
    stall_timeout => $stall_timeout,
  );
  $loop->add($http);

  my $ws = $args{web_search} // Net::Async::WebSearch->new(http => $http);
  $loop->add($ws);

  $ws->add_provider(Net::Async::WebSearch::Provider::DuckDuckGo->new)
    unless $args{web_search};

  if (!$args{web_search} && $ENV{BRAVE_API_KEY}) {
    $ws->add_provider(Net::Async::WebSearch::Provider::Brave->new(
      api_key => $ENV{BRAVE_API_KEY},
    ));
  }
  if (!$args{web_search} && $ENV{SERPER_API_KEY}) {
    $ws->add_provider(Net::Async::WebSearch::Provider::Serper->new(
      api_key => $ENV{SERPER_API_KEY},
    ));
  }
  if (!$args{web_search} && $ENV{GOOGLE_API_KEY} && $ENV{GOOGLE_CSE_ID}) {
    $ws->add_provider(Net::Async::WebSearch::Provider::Google->new(
      api_key => $ENV{GOOGLE_API_KEY},
      cx      => $ENV{GOOGLE_CSE_ID},
    ));
  }

  my $server = MCP::Server->new(name => 'raider-web', version => '1.0');

  $server->tool(
    name         => 'web_search',
    description  => 'Search the web across multiple providers (DuckDuckGo always; Brave/Serper/Google added when their API keys are in the environment). Returns ranked merged results.',
    input_schema => {
      type       => 'object',
      properties => {
        query => { type => 'string',  description => 'Search query' },
        limit => { type => 'integer', description => 'Max results (default 8)' },
      },
      required => ['query'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $query = $in->{query};
      my $limit = $in->{limit} // 8;
      # Every search provider is https (see connect_error for why a failed
      # load must not reach Net::Async::HTTP).
      if (my $error = connect_error('https:')) {
        return $tool->text_result("Error: $error", 1);
      }
      # The whole search ends within fetch_timeout, whatever http the
      # providers use: a provider that never answers is a tool error.
      my $f = $ws->search(query => $query, limit => $limit);
      my $out = eval {
        my $race = Future->wait_any(
          $f,
          $loop->delay_future( after => $fetch_timeout )
            ->then_fail('web_search timed out after '.$fetch_timeout."s\n"),
        );
        $loop->await($race);
        $race->get;
      };
      return $tool->text_result("Error: $@", 1) if $@;
      my @lines;
      my $i = 0;
      for my $r (@{$out->{results} // []}) {
        $i++;
        my $title = $r->title // '(no title)';
        my $url   = $r->url   // '';
        my $sn    = $r->snippet // '';
        $sn =~ s/\s+/ /g;
        push @lines, "[$i] $title";
        push @lines, "    $url";
        push @lines, "    $sn" if length $sn;
      }
      if (my $errs = $out->{errors}) {
        for my $e (@$errs) {
          push @lines, "(error from $e->{provider}: $e->{error})";
        }
      }
      return $tool->text_result(@lines ? join("\n", @lines) : "No results.");
    },
  );

  $server->tool(
    name         => 'web_fetch',
    description  => 'Fetch a URL and return its body. HTML is flattened to readable text. Binary/large bodies are truncated.',
    input_schema => {
      type       => 'object',
      properties => {
        url    => { type => 'string',  description => 'URL to fetch' },
        as_html => { type => 'boolean', description => 'Keep raw HTML instead of flattening to text (default false)' },
      },
      required => ['url'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $url = $in->{url};
      # A module Net::Async::HTTP fails to load while connecting leaves the
      # host's connection slot taken: every later fetch from it would hang
      # (karr k107).
      if (my $error = connect_error($url)) {
        return $tool->text_result("Error: $error", 1);
      }
      my $req = GET($url);
      $req->header('User-Agent' => 'raider/'.$VERSION);
      # The body is read through on_header and cut off at max_fetch_bytes:
      # the request is cancelled instead of buffering the whole download.
      # The abort runs on the loop's next tick, closing the connection from
      # inside the read handler is not safe (as Langertha's body cap).
      my ( $too_big, $seen );
      my $abort = Future->new;
      my $trip = sub {
        return if $too_big++;
        $loop->later( sub { $abort->done unless $abort->is_ready } );
      };
      # The same holds for every hop of a redirect: a redirect to https
      # fails here, before Net::Async::HTTP connects to it.
      my $f = $http->do_request(
        request       => $req,
        timeout       => $fetch_timeout,
        stall_timeout => $stall_timeout,
        on_header     => sub {
          my ($header) = @_;
          $seen = $header;
          return sub {
            return $header unless @_;
            return if $too_big;
            $header->add_content( $_[0] ) if defined $_[0];
            $trip->() if $header->is_success
              && length( ${ $header->content_ref } ) > $max_fetch_bytes;
            return;
          };
        },
        on_redirect => sub {
          my ( undef, $location ) = @_;
          my $error = connect_error($location);
          die $error."\n" if $error;
        },
      );
      my $resp = eval {
        my $race = Future->wait_any( $f, $abort );
        $loop->await($race);
        $race->get;
      };
      my $err = $@;
      if ($too_big && $seen) {
        $resp = $seen;
        $err  = '';
      }
      return $tool->text_result("Error: $err", 1) if $err;
      unless ($resp->is_success) {
        return $tool->text_result(
          sprintf("HTTP %s for %s", $resp->status_line, $url), 1);
      }
      my $body = eval { $resp->decoded_content } // $resp->content // '';
      if (length($body) > $max_fetch_bytes) {
        $body = substr($body, 0, $max_fetch_bytes) . "\n[truncated]\n";
      }
      my $ctype = $resp->header('Content-Type') // '';
      if (!$in->{as_html} && $ctype =~ m{text/html}i) {
        $body = _flatten_html($body);
      }
      my $header = sprintf("URL: %s\nStatus: %s\nContent-Type: %s\n\n",
        $url, $resp->status_line, $ctype);
      return $tool->text_result($header . $body);
    },
  );

  return $server;
}

1;

=head1 ENVIRONMENT

=env BRAVE_API_KEY

Adds Brave to C<web_search>.

=env SERPER_API_KEY

Adds Serper to C<web_search>.

=env GOOGLE_API_KEY

With L</GOOGLE_CSE_ID>, adds Google Custom Search to C<web_search>.

=env GOOGLE_CSE_ID

The Custom Search engine id for L</GOOGLE_API_KEY>.

=seealso

=over

=item * L<MCP::Server>

=item * L<Net::Async::WebSearch>

=item * L<Net::Async::HTTP>

=back

=cut
