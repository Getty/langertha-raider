package Langertha::Raider::Hall::Telegram;
our $VERSION = '0.503';
# ABSTRACT: Multi-bot Telegram long-poll adapter for the raider hall

=head1 DESCRIPTION

Long-polls every Telegram bot configured for a L<Langertha::Raider::Hall>,
routes incoming messages to raiders and sends replies.

=cut

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use URI;
use HTTP::Request::Common ();
use IO::Async::Timer::Countdown;
use Scalar::Util qw( weaken );
use Net::Async::HTTP;

has hall => (
  is => 'ro',
  isa => 'Langertha::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has _workers => (
  is => 'ro',
  default => sub { {} },
);

has _history_dir => (
  is => 'ro',
  lazy => 1,
  builder => '_build_history_dir',
);

sub _build_history_dir {
  my ($self) = @_;
  my $d = $self->hall->state_dir->child('telegram');
  $d->mkpath unless -d $d;
  $d;
}

sub setup_bots {
  my ($self) = @_;
  my $conf = $self->hall->config->{telegram} // {};
  my $bots = $conf->{bots} // {};
  for my $name (keys %$bots) {
    $self->_start_bot($name, $bots->{$name});
  }
}

sub _start_bot {
  my ($self, $name, $bot_conf) = @_;
  my $token = $bot_conf->{token} // return;
  my $allowlist = $bot_conf->{allowlist} // [];
  my $routing = $bot_conf->{routing} // {};

  my $ua = Net::Async::HTTP->new(
    max_connections_per_host => 1,
    timeout => 60,
  );
  $self->hall->loop->add($ua);

  $self->_workers->{$name} = {
    token => $token,
    allowlist => $allowlist,
    routing => $routing,
    ua => $ua,
    offset => 0,
    active => 1,
  };

  $self->_poll($name);
}

sub _poll {
  my ($self, $name) = @_;
  my $worker = $self->_workers->{$name} or return;
  return unless $worker->{active};

  my $ua = $worker->{ua};
  my $token = $worker->{token};

  my $uri = URI->new("https://api.telegram.org/bot$token/getUpdates");
  my %q = (timeout => 30);
  $q{offset} = $worker->{offset} if $worker->{offset};
  $uri->query_form(%q);

  my $f = $ua->GET($uri);
  $worker->{poll_future} = $f;
  weaken(my $weak = $self);
  $f->on_done(sub {
    my $self = $weak or return;
    delete $worker->{poll_future};
    my ($resp) = @_;
    my $updates = eval {
      JSON::MaybeXS->new->decode($resp->decoded_content)->{result} // []
    } // [];
    for my $update (@$updates) {
      $self->_handle_update($name, $update);
      $worker->{offset} = $update->{update_id} + 1;
    }
    $self->hall->loop->later(sub { $self->_poll($name) });
  });
  $f->on_fail(sub {
    my $self = $weak or return;
    delete $worker->{poll_future};
    $self->hall->_emit('telegram.poll_error', { bot => $name, error => "$_[0]" });
    # Back off a bit on failure so we don't hot-loop against a dead network.
    my $timer = IO::Async::Timer::Countdown->new(
      delay => 5,
      on_expire => sub { $self->_poll($name) },
    );
    $self->hall->loop->add($timer);
    $timer->start;
  });
}

sub _handle_update {
  my ($self, $bot_name, $update) = @_;
  my $worker = $self->_workers->{$bot_name} or return;
  my $msg = $update->{message} // $update->{edited_message} // return;

  my $chat_id = $msg->{chat}{id} // return;
  my $text = $msg->{text} // '';

  my $allowlist = $worker->{allowlist};
  if (@$allowlist && !grep { $_ eq $chat_id } @$allowlist) {
    return;
  }

  my $routing = $worker->{routing};
  my $target_raider = $routing->{$chat_id} // $routing->{'*'} // undef;

  $self->hall->_emit('telegram.in', {
    bot => $bot_name,
    chat_id => $chat_id,
    text => $text,
    first_name => $msg->{chat}{first_name} // '',
    username => $msg->{chat}{username} // '',
    update_id => $update->{update_id},
  });

  $self->_save_history($bot_name, $chat_id, $update);

  if ($target_raider) {
    $self->hall->spawn(
      name => $target_raider,
      mission => $text,
    );
  }
}

sub _save_history {
  my ($self, $bot_name, $chat_id, $update) = @_;
  my $dir = $self->_history_dir->child($bot_name);
  $dir->mkpath unless -d $dir;
  my $file = $dir->child("$chat_id.json");
  my $history = eval { JSON::MaybeXS->new->decode($file->slurp_utf8) } // [];
  push @$history, $update;
  $file->spew_utf8(JSON::MaybeXS->new->encode($history));
}

sub send_message {
  my ($self, %args) = @_;
  my $bot_name = $args{bot} // return { error => 'bot name required' };
  my $chat_id = $args{chat_id} // return { error => 'chat_id required' };
  my $text = $args{text} // return { error => 'text required' };

  my $worker = $self->_workers->{$bot_name} or return { error => "bot $bot_name not running" };
  my $token = $worker->{token};
  my $ua = $worker->{ua};

  my $uri = URI->new("https://api.telegram.org/bot$token/sendMessage");
  my $req = HTTP::Request::Common::POST($uri, [
    chat_id => $chat_id,
    text => $text,
    parse_mode => 'Markdown',
  ]);

  # Fire-and-forget: return the Future so callers can await if they want.
  my $f = $ua->do_request(request => $req);
  my $id = time . '-' . int(rand(1_000_000));
  $worker->{send_futures}{$id} = $f;
  weaken(my $weak = $self);
  $f->on_done(sub {
    delete $worker->{send_futures}{$id};
  });
  $f->on_fail(sub {
    my $self = $weak or return;
    delete $worker->{send_futures}{$id};
    $self->hall->_emit('telegram.send_error', {
      bot => $bot_name, chat_id => $chat_id, error => "$_[0]",
    });
  });
  return { ok => 1, future => $f };
}

sub stop {
  my ($self) = @_;
  $_->{active} = 0 for values %{$self->_workers};
}

__PACKAGE__->meta->make_immutable;

1;
