#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long qw( GetOptions );

my %opt = (
  repo => 'Getty/langertha-raider',
);

GetOptions(
  'archive=s' => \$opt{archive},
  'version=s' => \$opt{version},
  'repo=s'    => \$opt{repo},
) or die "Usage: $0 --archive FILE --version VERSION [--repo ORG/REPO]\n";

for my $required (qw( archive version )) {
  die "--$required is required\n" unless defined $opt{$required} && length $opt{$required};
}

my $gh = $ENV{GH_BIN} || 'gh';

sub run_cmd {
  my (@cmd) = @_;
  system @cmd;
  die "command failed: @cmd\n" if $?;
  return;
}

my @view = ($gh, 'release', 'view', $opt{version}, '-R', $opt{repo});
system @view;
if ($?) {
  run_cmd(
    $gh, 'release', 'create', $opt{version},
    '-R', $opt{repo},
    '--title', $opt{version},
    '--notes', 'Dist::Zilla release'
  );
}

run_cmd(
  $gh, 'release', 'upload', $opt{version},
  '-R', $opt{repo},
  $opt{archive},
  '--clobber'
);
