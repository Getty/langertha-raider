package Langertha::Raider::Hall::Protocol;
our $VERSION = '0.503';
# ABSTRACT: Control-socket command handlers for the raider hall

=head1 DESCRIPTION

Registers the JSON line commands (spawn, ps, attach, kill, logs, status,
session_reset, telegram_reply) on a L<Langertha::Raider::Hall> control
socket. C<telegram_reply> takes an optional C<message_thread_id> to answer
in a forum topic.

=cut

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;

has hall => (
  is => 'ro',
  isa => 'Langertha::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

sub setup_handlers {
  my ($self) = @_;
  my $hall = $self->hall;

  $hall->_register_cmd(spawn => sub {
    my ($hall, $stream, $payload) = @_;
    my $name = $payload->{name} // '';
    my $mission = $payload->{mission} // '';
    my $attach = $payload->{attach} // 0;
    my $result = $hall->spawn(name => $name, mission => $mission, attach => $attach);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(ps => sub {
    my ($hall, $stream, $payload) = @_;
    my @list = $hall->ps;
    $stream->write(JSON::MaybeXS->new->encode({raiders => \@list}) . "\n");
  });

  $hall->_register_cmd(attach => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $info = $hall->attach($id);
    $stream->write(JSON::MaybeXS->new->encode($info) . "\n");
  });

  $hall->_register_cmd(kill => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $result = $hall->kill_raider($id);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(logs => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $result = $hall->logs(id => $id);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(status => sub {
    my ($hall, $stream, $payload) = @_;
    $stream->write(JSON::MaybeXS->new->encode({
      running => scalar(keys %{$hall->raiders}),
      root => $hall->root->stringify,
      slots => $hall->_running_slots,
    }) . "\n");
  });

  $hall->_register_cmd(session_reset => sub {
    my ($hall, $stream, $payload) = @_;
    my $result = $hall->reset_session($payload->{binding});
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(telegram_reply => sub {
    my ($hall, $stream, $payload) = @_;
    my $bot = $payload->{bot} // '';
    my $chat_id = $payload->{chat_id};
    my $text = $payload->{text} // '';
    my $result;
    if (!$bot || !defined $chat_id || !length $text) {
      $result = { error => 'telegram_reply requires bot, chat_id, text' };
    }
    elsif (!$hall->config->{telegram} || !$hall->config->{telegram}{bots}) {
      $result = { error => 'telegram not configured in .raider-hall.yml' };
    }
    else {
      $result = $hall->telegram->send_message(
        bot => $bot, chat_id => $chat_id, text => $text,
        defined $payload->{message_thread_id}
          ? ( message_thread_id => $payload->{message_thread_id} ) : (),
      );
      # Strip the Future before serialising.
      delete $result->{future};
    }
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });
}

__PACKAGE__->meta->make_immutable;

1;
