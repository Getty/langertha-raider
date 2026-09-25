package Langertha::Raider::CLI::Output;
# ABSTRACT: Internal terminal renderer of the raider CLI
our $VERSION = '0.503';
use Moose;
use namespace::autoclean;
use JSON::MaybeXS ();
use Term::ANSIColor qw( colored color );

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $out = Langertha::Raider::CLI::Output->new;

    $out->say_meta('history cleared.');
    $out->say_error('something failed');
    $out->say_agent($result);
    $out->config_report($app->explain_config);

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

Everything the F<raider> CLI prints for a human goes through here: the
blue/yellow palette, the agent/meta/error lines and the C<raider config
explain> report. The machine output (C<--json> and friends) is
L<Langertha::Raider::CLI::Machine>.

=cut

# Palette: blue tones + yellow accents.
my %PALETTE = (
  brand  => 'bold bright_blue',
  title  => 'bold blue',
  prompt => 'bold cyan',
  agent  => 'bright_green',
  meta   => 'bright_black',
  accent => 'yellow',
  warn   => 'yellow',
  err    => 'red',
);

=attr out

Filehandle everything is printed to. Defaults to C<STDOUT>.

=cut

has out => (
  is      => 'ro',
  default => sub { \*STDOUT },
);

=attr color

Whether to emit ANSI colors. Defaults to true when L</out> is a terminal;
C<ANSI_COLORS_DISABLED> switches them off as well.

=cut

has color => (
  is      => 'ro',
  isa     => 'Bool',
  lazy    => 1,
  builder => '_build_color',
);

sub _build_color { -t $_[0]->out ? 1 : 0 }

=method c

    my $text = $out->c(meta => 'some', ' text');

The text in the palette color C<meta>, C<title>, C<agent>, ... -- plain
when L</color> is off.

=cut

sub c {
  my ( $self, $key, @text ) = @_;
  my $text = join '', @text;
  return $self->color ? colored([ $PALETTE{$key} ], $text) : $text;
}

=method emit

Prints its arguments to L</out>.

=cut

sub emit {
  my ( $self, @text ) = @_;
  print { $self->out } @text;
  return;
}

=method say_agent

=method say_meta

=method say_error

One line of agent output (inline C<`code`> highlighted), of meta
information, or an C<error:> line.

=cut

sub say_agent { $_[0]->emit($_[0]->c(agent => $_[0]->render_inline_code($_[1])), "\n") }
sub say_meta  { $_[0]->emit($_[0]->c(meta => $_[1]), "\n") }
sub say_error { $_[0]->emit($_[0]->c(err => 'error: '), $_[0]->c(warn => $_[1]), "\n") }

=method error_text

    my $text = $out->error_text($@);

An exception as one line for the user: without the trailing newline and
the Perl source location C<croak> appends, also the form Moose adds for a
constructor or accessor.

=cut

sub error_text {
  my ( $self, $error ) = @_;
  $error = "$error";
  $error =~ s/ at (?:\w+ \S+ \(defined at .+ line \d+\)|(?:(?! at ).)+) line \d+\.?\n?\z//s;
  chomp $error;
  return $error;
}

=method render_inline_code

Wraps C<`...`> spans in a darker background when colors are on. Triple
backticks stay untouched so fenced code blocks keep their own flow.

=cut

sub render_inline_code {
  my ( $self, $text ) = @_;
  return $text unless $self->color && !$ENV{ANSI_COLORS_DISABLED};
  my $code_on  = color('on_grey3');
  my $agent_on = color($PALETTE{agent});
  my $reset    = color('reset');
  $text =~ s{(?<!`)`([^`\n]+?)`(?!`)}{$code_on$1$reset$agent_on}g;
  return $text;
}

=method config_report

Prints a report of L<Langertha::Raider::CLI/explain_config>: one line per
setting with its value, source, what it overrides and whether it applies to
the engine or to raider; the instructions source (C<-M>, C<.raider.md>,
C<default>) with C<(bare)> under C<--bare>; each pack with its state, the
kind of place it was found in (C<project>, C<home>, C<shipped>, C<env>)
and why it is on or off; the pack directories that were skipped, and why.

=cut

sub config_report {
  my ( $self, $report ) = @_;
  my $json = JSON::MaybeXS->new(canonical => 1, allow_nonref => 1);
  $self->emit($self->c(meta => 'file:   '), $self->c(title => $report->{file}),
    $self->c(meta => $report->{exists} ? '' : ' (not present)'), "\n");
  $self->emit($self->c(meta => 'engine: '), $self->c(title => $report->{engine}), "\n");
  $self->emit($self->c(meta => 'instructions: '), $self->c(title => $report->{instructions}),
    $self->c(meta => $report->{bare} ? ' (bare)' : ''), "\n") if defined $report->{instructions};
  for my $v (@{ $report->{values} }) {
    my $value = ref $v->{value} ? $json->encode($v->{value}) : $v->{value} // '';
    my $from  = 'from '.$v->{source};
    $from .= ', overrides '.join(', ', @{ $v->{shadowed} }) if @{ $v->{shadowed} // [] };
    $from .= ', merged' if $v->{merged};
    $self->emit(sprintf("  %s %s  %s\n", $self->c(title => sprintf('%-22s', $v->{key})), $value,
      $self->c(meta => '('.$from.'; '.$v->{applies_to}.')')));
  }
  for my $ign (@{ $report->{ignored} }) {
    $self->emit('  ', $self->c(warn => 'ignored '.$ign->{key}.': '.$ign->{reason}), "\n");
  }
  if (my $packs = $report->{packs}) {
    $self->emit($self->c(meta => 'packs:  '), $self->c(meta => '(detection '.$report->{detection}.')'), "\n");
    for my $p (@$packs) {
      $self->emit(sprintf("  %s %-8s  %-7s  %s\n", $self->c(title => sprintf('%-20s', $p->{name})),
        $p->{active} ? 'active' : 'inactive', $p->{origin} // '',
        $self->c(meta => $self->pack_reason($p, rule => 1))));
      $self->emit('    ', $self->c(warn => 'note: '.$_), "\n") for @{ $p->{detection}{notes} // [] };
    }
  }
  for my $s (@{ $report->{skipped_packs} // [] }) {
    $self->emit('  ', $self->c(warn => 'skipped pack '.$s->{name}.' ('.$s->{origin}.' '.$s->{path}.'): '.$s->{reason}), "\n");
  }
  if (my $perl = $report->{perl_tools}) {
    $self->emit($self->c(meta => 'perl tools: '), $perl->{enabled} ? 'on' : 'off',
      '  ', $self->c(meta => '('.$perl->{reason}.')'), "\n");
  }
  return;
}

=method pack_reason

    my $text = $out->pack_reason($entry, rule => 1);

Why a pack of L<Langertha::Raider::Packs::Collection/activation_report> is
on or off: C<SOURCE: REASON> (C<detected: must file=cpanfile (cpanfile)>,
C<flag: --no-pack>), or the detection outcome of an inactive pack
(C<not matched: ...>). With C<rule> the origin of a detection rule is
appended (C<[rule: pack default]>).

=cut

sub pack_reason {
  my ( $self, $p, %opt ) = @_;
  my $d = $p->{detection};
  my $text = defined $p->{source} ? $p->{source}.( defined $p->{reason} ? ': '.$p->{reason} : '' )
           : $d                   ? $d->{result}.': '.$d->{reason}
           :                        '';
  $text .= ' [rule: '.$d->{rule_from}.']'
    if $opt{rule} && $d && ( !defined $p->{source} || $p->{source} eq 'detected' );
  return $text;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::CLI>

=back

=cut
