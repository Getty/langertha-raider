use strict;
use warnings;
use Test2::V0;
use Path::Tiny;
use File::Temp qw( tempdir );
use Langertha::Raider::Hall::CLI;

# Regression: GetOptions consumed @ARGV but the subcommands kept working on
# the untouched argument list, so options placed before positional arguments
# leaked into them (k14). Options must work before AND after positionals.

my $orig_cwd = path('.')->absolute;

# Run a hall subcommand inside a fresh hall dir with a fake socket and a
# captured _send_command. Returns the payload sent to the hall.
sub run_cmd {
  my ( @argv ) = @_;
  my $tmp = tempdir( CLEANUP => 1 );
  path($tmp)->child('.raider-hall.socket')->touch;
  chdir $tmp or die "chdir $tmp: $!";

  my $sent;
  no warnings 'redefine';
  local *Langertha::Raider::Hall::CLI::_send_command = sub {
    my ( $socket, $msg ) = @_;
    $sent = $msg->{payload};
    return { id => 'r1', pid => 1, slot => 's1', log_path => 'x', log => '' };
  };
  my $out = '';
  {
    local *STDOUT;
    open STDOUT, '>', \$out or die $!;
    Langertha::Raider::Hall::CLI->main(@argv);
  }
  chdir $orig_cwd or die "chdir $orig_cwd: $!";
  return $sent;
}

subtest 'start: DIR is honoured with options before it' => sub {
  my $hall_dir = tempdir( CLEANUP => 1 );
  for my $argv (
    [ 'start', '--daemon', $hall_dir ],
    [ 'start', $hall_dir, '--daemon' ],
    [ 'start', '--acp-port', '4711', $hall_dir ],
  ) {
    my $root;
    no warnings 'redefine';
    local *Langertha::Raider::Hall::new = sub {
      my ( $class, %arg ) = @_;
      $root = "$arg{root}";
      die "stop before run\n";
    };
    local $ENV{RAIDER_HALL_ACP_PORT};
    local $ENV{RAIDER_HALL_ACP_HOST};
    like(
      dies { Langertha::Raider::Hall::CLI->main(@$argv) },
      qr/stop before run/, 'reached Hall->new: '.join(' ', @$argv)
    );
    is( $root, path($hall_dir)->absolute->stringify,
      'root is DIR: '.join(' ', @$argv) );
  }
};

subtest 'spawn: --attach does not leak into the mission' => sub {
  for my $argv (
    [ 'spawn', 'Bjorn', 'raid', 'the', 'coast', '--attach' ],
    [ 'spawn', '--attach', 'Bjorn', 'raid', 'the', 'coast' ],
  ) {
    my $p = run_cmd(@$argv);
    is( $p, {
      cmd     => 'spawn',
      name    => 'Bjorn',
      mission => 'raid the coast',
      attach  => 1,
    }, join(' ', @$argv) );
  }
  my $p = run_cmd( 'spawn', 'Bjorn', 'raid' );
  is( $p->{attach}, 0, 'attach off without the flag' );
};

subtest 'attach: ID is the positional, not an option' => sub {
  for my $argv (
    [ 'attach', 'r42' ],
    [ 'attach', '--', 'r42' ],
  ) {
    my $p = run_cmd(@$argv);
    is( $p, { cmd => 'attach', id => 'r42' }, join(' ', @$argv) );
  }
};

subtest 'logs: --follow before or after ID' => sub {
  for my $argv (
    [ 'logs', '--follow', 'r42' ],
    [ 'logs', 'r42', '--follow' ],
  ) {
    my $p = run_cmd(@$argv);
    is( $p, { cmd => 'logs', id => 'r42' }, join(' ', @$argv) );
  }
};

subtest 'kill: ID after --' => sub {
  my $p = run_cmd( 'kill', '--', 'r42' );
  is( $p, { cmd => 'kill', id => 'r42' }, 'kill -- r42' );
};

done_testing;
