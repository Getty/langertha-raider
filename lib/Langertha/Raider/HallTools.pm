package Langertha::Raider::HallTools;
our $VERSION = '0.503';
# ABSTRACT: MCP::Server factory with hall-side tools (telegram_reply, hall_status)

use strict;
use warnings;
use MCP::Server;
use IO::Socket::UNIX;
use JSON::MaybeXS ();

use Exporter 'import';
our @EXPORT_OK = qw( build_hall_tools_server );

=func build_hall_tools_server

    my $server = Langertha::Raider::HallTools::build_hall_tools_server(
        socket => $ENV{RAIDER_HALL_SOCKET},
    );

Returns an L<MCP::Server> exposing tools that let a raider running inside
a hall talk back to its hall daemon:

=over

=item * C<telegram_reply(bot, chat_id, text)>

When the raider was spawned for a Telegram message, the hall sets
C<RAIDER_HALL_TELEGRAM_BOT> and C<RAIDER_HALL_TELEGRAM_CHAT_ID> (or pass
C<< telegram => { bot => ..., chat_id => ... } >>). The tool is then bound to
that chat: only C<text> is required, and a different C<bot> or C<chat_id>
is refused.

=item * C<hall_status()>

=item * C<hall_spawn(name, mission)>

=back

Each tool opens a short-lived UNIX-socket command connection to the
hall, sends a single JSON frame, reads the reply, and returns it as
text. Errors surface as text_result with isError=1.

=cut

sub _call {
  my ($sock_path, $cmd, %payload) = @_;

  my $s = IO::Socket::UNIX->new(Peer => $sock_path)
    or return { error => "cannot connect to hall socket $sock_path: $!" };
  $s->autoflush(1);

  my $frame = JSON::MaybeXS->new->encode({
    type => 'command',
    payload => { cmd => $cmd, %payload },
  });
  print $s "$frame\n";

  my $line = <$s>;
  close $s;
  return { error => 'no response from hall' } unless defined $line;
  chomp $line;
  my $resp = eval { JSON::MaybeXS->new->decode($line) };
  return { error => "invalid hall response: $@" } if $@;
  return $resp;
}

sub build_hall_tools_server {
  my (%args) = @_;
  my $sock = $args{socket}
    or die "build_hall_tools_server: socket param required";
  my $bound = $args{telegram}
    // ( $ENV{RAIDER_HALL_TELEGRAM_BOT} && defined $ENV{RAIDER_HALL_TELEGRAM_CHAT_ID}
      ? { bot => $ENV{RAIDER_HALL_TELEGRAM_BOT}, chat_id => $ENV{RAIDER_HALL_TELEGRAM_CHAT_ID} }
      : undef );

  my $server = MCP::Server->new(name => 'app-raider-hall', version => '1.0');

  $server->tool(
    name         => 'telegram_reply',
    description  => $bound
      ? 'Reply to the Telegram chat that sent you this mission. Only text is needed.'
      : 'Send a Telegram message from the hall. Use this to reply to a user that reached you through the hall\'s telegram.in event.',
    input_schema => {
      type       => 'object',
      properties => {
        $bound ? () : (
          bot     => { type => 'string',  description => 'Bot name as configured in .raider-hall.yml' },
          chat_id => { type => 'integer', description => 'Telegram chat id' },
        ),
        text    => { type => 'string',  description => 'Message body (Markdown)' },
      },
      required => $bound ? ['text'] : [qw(bot chat_id text)],
    },
    code => sub {
      my ($tool, $in) = @_;
      my %target = map { $_ => $in->{$_} } qw( bot chat_id );
      if ($bound) {
        for my $key (qw( bot chat_id )) {
          return $tool->text_result('Error: this run can only reply to '
            .$bound->{bot}.' chat '.$bound->{chat_id}, 1)
            if defined $target{$key} && $target{$key} ne $bound->{$key};
          $target{$key} = $bound->{$key};
        }
      }
      my $r = _call($sock, 'telegram_reply', %target, text => $in->{text});
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result('sent');
    },
  );

  $server->tool(
    name         => 'hall_status',
    description  => 'Ask the hall how many raiders are currently running.',
    input_schema => { type => 'object', properties => {} },
    code => sub {
      my ($tool, $in) = @_;
      my $r = _call($sock, 'status');
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result(JSON::MaybeXS->new(canonical => 1)->encode($r));
    },
  );

  $server->tool(
    name         => 'hall_spawn',
    description  => 'Spawn another raider in the same hall (respects 1name singleton queueing).',
    input_schema => {
      type       => 'object',
      properties => {
        name    => { type => 'string', description => 'Raider slot name (e.g. "bjorn" or "1bjorn")' },
        mission => { type => 'string', description => 'One-shot task' },
      },
      required => [qw(name mission)],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $r = _call($sock, 'spawn', name => $in->{name}, mission => $in->{mission});
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result(JSON::MaybeXS->new(canonical => 1)->encode($r));
    },
  );

  return $server;
}

1;

__END__

=head1 SEE ALSO

=over

=item * L<Langertha::Raider::Hall>

=item * L<MCP::Server>

=back

=cut
