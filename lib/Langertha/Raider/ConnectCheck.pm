package Langertha::Raider::ConnectCheck;
# ABSTRACT: Internal check that Net::Async::HTTP can open a connection to a URL
our $VERSION = '0.503';

use strict;
use warnings;
use Module::Runtime qw( use_module );
use URI;

use Exporter 'import';
our @EXPORT_OK = qw( connect_error );

=description

B<Internal module.> Its interface may change without notice.

L<Net::Async::HTTP> loads some modules only when it opens a connection:
L<IO::Async::Internals::Connector> for every connection, L<IO::Async::SSL>
(with L<IO::Socket::SSL>, L<Net::SSLeay> and the system's libssl) for https.
When such a load dies, Net::Async::HTTP 0.50 keeps the connection slot for
that host taken, and every later request to the host waits forever (karr
k107). Raider asks this module before it sends, so a missing module is an
error with its name instead of a hang.

=func connect_error

    my $error = connect_error('https://api.example.com/v1');

Returns C<undef> when the modules a connection to the URL needs load, else
a one-line message that names the target (scheme, host and port), the
module and the first line of its load error. A URL without a scheme counts
as http; a bare scheme (C<https:>) checks what any URL of it needs.

=cut

sub connect_error {
  my ( $url ) = @_;
  my $uri = URI->new($url);
  my $scheme = lc( $uri->scheme // 'http' );
  # Scheme, host and port only: a query or userinfo may carry a key.
  my $target = !$uri->can('host') ? $url
    : defined $uri->host ? $scheme.'://'.$uri->host_port
    : $scheme.' URLs';
  my @needed = ( [ 'IO::Async::Internals::Connector', 'every HTTP connection needs it' ] );
  push @needed, [ 'IO::Async::SSL', 'https needs it, with IO::Socket::SSL, Net::SSLeay and the system libssl' ]
    if $scheme eq 'https';
  for my $need (@needed) {
    my ( $module, $why ) = @$need;
    next if eval { use_module($module); 1 };
    my ( $reason ) = split /\n/, $@;
    return 'Cannot connect to '.$target.': '.$module.' failed to load ('.$reason.'); '.$why;
  }
  return;
}

1;
