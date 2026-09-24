package App::Raider;
# ABSTRACT: Reserved namespace — the CLI entry point moved to Langertha::Raider::CLI
our $VERSION = '0.503';

use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The CLI entry point that used to live here (the
application class behind the C<raider> command) was renamed and now lives in
L<Langertha::Raider::CLI> in the
L<langertha-raider|https://metacpan.org/dist/langertha-raider> distribution, which
replaces the former App-Raider distribution. Nothing uses this package; it is
retained only so the C<App::Raider> namespace stays indexed to a dead stub on CPAN.

=cut
