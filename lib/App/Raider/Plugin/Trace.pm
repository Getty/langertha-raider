package App::Raider::Plugin::Trace;
# ABSTRACT: Reserved namespace — the Trace plugin moved to Langertha::Raider::Plugin::Trace
our $VERSION = '0.503';

use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The plugin for live ANSI-colored raid progress
output that used to live here was renamed and now lives in
L<Langertha::Raider::Plugin::Trace> in the
L<langertha-raider|https://metacpan.org/dist/langertha-raider> distribution, which
replaces the former App-Raider distribution. Nothing uses this package; it is
retained only so the C<App::Raider::Plugin::Trace> namespace stays indexed to a dead
stub on CPAN.

=cut
