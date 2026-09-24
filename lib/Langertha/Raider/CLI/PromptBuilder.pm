package Langertha::Raider::CLI::PromptBuilder;
# ABSTRACT: Internal prompt-builder sub-agent of the raider CLI (/prompt)
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use utf8;
use Path::Tiny;
use Langertha::Raider;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    Langertha::Raider::CLI::PromptBuilder->new(app => $app, output => $out)->run;

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The C</prompt> REPL command and C<--customize-prompt>: a second raider on the
same engine whose only job is to write F<.raider.md> with the user. It reads
lines from L</in> until C</done> (reload the mission and return) or
C</cancel>.

=attr app

The L<Langertha::Raider::CLI> whose F<.raider.md> is edited. Required.

=attr output

The L<Langertha::Raider::CLI::Output> to print to. Required.

=attr in

Filehandle the conversation is read from. Defaults to C<STDIN>.

=cut

has app => (
  is       => 'ro',
  isa      => 'Langertha::Raider::CLI',
  required => 1,
);

has output => (
  is       => 'ro',
  isa      => 'Langertha::Raider::CLI::Output',
  required => 1,
);

has in => (
  is      => 'ro',
  default => sub { \*STDIN },
);

sub _mission {
  my ( $self, $file ) = @_;
  my $current = -f $file ? $file->slurp_utf8 : '(no .raider.md yet — Langertha default persona is active)';
  return <<"EOM";
You are the raider prompt-builder. Your only job right now is to help the user
craft a .raider.md file that customizes the persona and instructions of
"raider" (the CLI agent; the default persona is Langertha, a viking
shield-maiden).

Current .raider.md content:
---
$current
---

Rules:
  - Converse naturally with the user. Ask what persona, tone, rules or
    constraints they want.
  - When the user is satisfied, use write_file to save to:
      @{[ $file ]}
  - After writing, confirm what you saved and tell the user they can type
    "/done" to return to the main agent (the main agent will auto-reload the
    new persona).
  - If the user asks you to cancel, do not write anything; just confirm.
  - Do NOT call bash or any tool other than read_file / write_file / edit_file
    during this session.
EOM
}

=method run

Runs the prompt-builder conversation until C</done>, C</cancel> or the end
of L</in>.

=cut

sub run {
  my ($self) = @_;
  my $app  = $self->app;
  my $out  = $self->output;
  my $file = path($app->root)->child('.raider.md');

  my $builder_raider = Langertha::Raider->new(
    engine         => $app->_engine,
    mission        => $self->_mission($file),
    max_iterations => 20,
  );

  $out->say_meta('entering prompt-builder. /done to return, /cancel to discard.');
  my $in = $self->in;

  while (1) {
    $out->emit('raider:prompt> ');
    my $line = <$in>;
    last unless defined $line;
    chomp $line;
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;

    if ($line =~ m{^/(?:done|back|exit|quit)$}i) {
      my $new = $app->reload_mission;
      $out->say_meta('prompt-builder finished. mission reloaded ('.length($new).' chars).');
      last;
    }
    if ($line =~ m{^/cancel$}i) {
      $out->say_meta('prompt-builder cancelled.');
      last;
    }

    my $f = $builder_raider->raid_f($line);
    $app->loop->await($f);
    my $r = eval { $f->get };
    if ($@) {
      my $err = $@; chomp $err;
      $out->say_error($err);
      next;
    }
    $out->say_agent("$r");
  }
  return;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI::Commands>

=back

=cut
