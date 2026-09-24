package App::Raider::Plugin::Situation;
# ABSTRACT: Reserved namespace — the Situation plugin moved to Langertha::Raider::Plugin::Situation
our $VERSION = '0.503';

use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The plugin injecting situational context (time,
timezone, host, user) that used to live here was renamed and now lives in
L<Langertha::Raider::Plugin::Situation> in the
L<langertha-raider|https://metacpan.org/dist/langertha-raider> distribution, which
replaces the former App-Raider distribution. Nothing uses this package; it is
retained only so the C<App::Raider::Plugin::Situation> namespace stays indexed to a
dead stub on CPAN.

=cut
