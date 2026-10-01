use strict;
use warnings;

use Test::More;
use Path::Tiny;

my $dockerfile = path('Dockerfile')->slurp_utf8;
my $dist_ini   = path('dist.ini')->slurp_utf8;
my $release    = path('maint/release-after.pl')->slurp_utf8;
my $ignore     = path('.dockerignore')->slurp_utf8;

unlike($dockerfile, qr/Langertha-Raider-\$\{RAIDER_VERSION\}\.tar\.gz/,
  'Dockerfile does not require a release tarball in the build context');

like($dockerfile, qr/RUN\b[^\n]*curl\b[^\n]*skaji\/cpm/s,
  'Dockerfile installs cpm explicitly');
like($dockerfile, qr/cpm install\b.*--cpanfile cpanfile/s,
  'Dockerfile installs dependencies through cpm from the cpanfile');
like($dockerfile, qr/cpm install\b.*--resolver metacpan/s,
  'Dockerfile uses the MetaCPAN resolver');
like($dockerfile, qr/ARG RAIDER_VERSION=dev/,
  'Dockerfile has a dev-safe version build arg');
like($dockerfile, qr/WORKDIR\s+\$\{RAIDER_SRC\}/,
  'Dockerfile builds from a stable source directory');

like($dist_ini, qr/^run_after_release = %x %o\/maint\/release-after\.pl --archive %a --version %v$/m,
  'release hook delegates archive and version to the maint script');
like($dist_ini, qr/^docker_image = raudssus\/raider$/m,
  'the bundle builds and pushes raudssus/raider');
like($dist_ini, qr/^docker_tags = latest %V %v$/m,
  'the image is tagged latest, major and version');
like($dist_ini, qr/^docker_default = 0$/m,
  'the automatic Docker section, which would build the last stage, is off');

my @docker_sections = $dist_ini =~ /^\[\@Author::GETTY::Docker\b[^\]]*\]\n((?:(?!\[).*\n?)*)/mg;
is(scalar @docker_sections, 1, 'exactly one Docker image section');
like($docker_sections[0], qr/^target = runtime-root$/m,
  'the published image is the runtime-root stage');
like($docker_sections[0], qr/^build_arg = RAIDER_VERSION=%v$/m,
  'the image is built with the release version as RAIDER_VERSION');
unlike($dist_ini, qr/^run_after_release\b.*\bdocker\b/mi,
  'no release hook shells out to docker');

like($release, qr/\$gh, 'release', 'create'/,
  'maint script creates the GitHub release');
like($release, qr/\$gh, 'release', 'upload'.*\$opt\{archive\}/s,
  'maint script uploads the archive to the GitHub release');
unlike($release, qr/docker/i,
  'maint script does not build or push the Docker image');

SKIP: {
  # README.md lives in the repository only; the built distribution ships the
  # generated README instead.
  skip 'README.md not present (built distribution)', 1 unless -e 'README.md';
  like(path('README.md')->slurp_utf8,
    qr/Dockerfile installs from the Dist::Zilla-built distribution directory/,
    'README documents the Dist::Zilla distribution directory build');
}

for my $manifest_file (qw( .dockerignore .gitignore Dockerfile .claude README )) {
  unlike($ignore, qr/^\Q$manifest_file\E$/m,
    ".dockerignore does not exclude MANIFEST file $manifest_file");
}

done_testing;
