package App::Raider::FileTools;
# ABSTRACT: Reserved namespace — the filesystem MCP tools moved to Langertha::Raider::FileTools
our $VERSION = '0.503';

use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The MCP::Server factory with local filesystem tools
that used to live here was renamed and now lives in L<Langertha::Raider::FileTools>
in the L<langertha-raider|https://metacpan.org/dist/langertha-raider> distribution,
which replaces the former App-Raider distribution. Nothing uses this package; it is
retained only so the C<App::Raider::FileTools> namespace stays indexed to a dead
stub on CPAN.

=cut
