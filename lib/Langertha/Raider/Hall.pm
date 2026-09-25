package Langertha::Raider::Hall;
our $VERSION = '0.503';
# ABSTRACT: Hall daemon — spawns and manages raider processes

=head1 SYNOPSIS

    use Langertha::Raider::Hall;
    my $hall = Langertha::Raider::Hall->new(root => Path::Tiny::path('.'));
    $hall->run;   # blocks on the IO::Async loop

From the shell:

    raider hall init --name bjorn
    raider hall start --daemon --acp-port 38421
    raider hall spawn bjorn "summarise today's git log"

=head1 DESCRIPTION

Hall is the multi-raider daemon. It owns a UNIX command/event socket,
spawns named raiders as child processes, enforces C<1name> singleton
slots with persistent FIFO queueing, and wires in optional Slice 4/5
features:

=over

=item * Non-blocking L<Schedule::Cron> scheduler for timed raids.

=item * Multi-bot Telegram long-poll with routing + per-chat history.

=item * ACP (Agent Client Protocol) adapter on a TCP port for Zed and
other ACP-capable clients — see L<Langertha::Raider::Hall::ACP>.

=back

An MCP adapter on C<.raider-hall.mcp> is B<not implemented>:
L<Langertha::Raider::Hall::MCP> describes the hall tools, but no socket is
opened and an C<mcp> section in the config has no effect.

All state flows through the event bus (JSONL pub/sub). Clients
subscribe with C<{type: subscribe, payload: {filter: 'raider.'}}> and
commands are separate frames (C<{type: command, payload: {cmd: ...}}>).

Each raider runs with C<--stream-json>. Its stdout goes to a file of its
own per run, F<.raider-hall/logs/ID.events.jsonl>; its stderr is appended
to the human-readable F<.raider-hall/logs/SLOT.log>. When the process
ends, C<raider.done> carries C<status> and C<response> or C<error> from
the run's last C<run.finished> event. A run that ended without one
(killed, crashed) is C<failed>, with an error saying so.
The hall then appends one line to the slot log,
C<[hall] raider ID STATUS: TEXT> with the response or error cut to 300
characters, so C<raider hall logs> shows the outcome.

Run IDs are C<SLOT-TIME>, with C<.2>, C<.3>, ... appended when a run of the
same slot started in the same second. Only the newest L</keep_events>
events files per slot are kept.

=head1 CONFIG FILE

C<.raider-hall.yml> in the hall root:

    longhouse: false
    preferred_lib_target: .raider-hall/lib
    raiders:
      bjorn:   { engine: anthropic, persona: caveman }
      lagertha:{ engine: openai,    persona: polite, packs: [git-guru] }
    cron:
      - { name: 1bjorn, cron: '*/15 * * * *', mission: 'ping CI' }
    telegram:
      bots:
        ops: { token: '...', allowlist: [42], routing: { '*': lagertha } }
    acp: { port: 38421, host: 127.0.0.1 }
    logs: { keep_events: 20 }

C<engine> on a raider entry is optional. Without it the hall passes no
C<--engine> and the spawned raider decides itself: the engine from its
F<.raider.yml> first, then autodetection from the API keys in the
environment.

=head1 SEE ALSO

L<Langertha::Raider::CLI>, L<Langertha::Raider::Hall::ACP>, L<Langertha::Raider::HallTools>,
L<Langertha::Raider::Hall::CLI>.

=cut

use strict;
use warnings;
use Path::Tiny;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Timer;
use JSON::MaybeXS;
use POSIX qw(WNOHANG);
use YAML::PP;
use Moose;
use namespace::autoclean;
use IO::Async::Listener;
use IO::Async::Process;
use IO::Async::Timer::Countdown;
use IO::Socket::UNIX;
use File::Which ();
use Net::Async::HTTP;
use Langertha::Raider::Hall::ACP;
use Langertha::Raider::Hall::Cron;
use Langertha::Raider::Hall::MCP;
use Langertha::Raider::Hall::Protocol;
use Langertha::Raider::Hall::Raider;
use Langertha::Raider::Hall::Telegram;

has root => (
  is => 'ro',
  isa => 'Path::Tiny',
  required => 1,
);

has loop => (
  is => 'ro',
  lazy => 1,
  builder => '_build_loop',
);

has _loop => (
  is => 'ro',
  init_arg => undef,
  default => sub { IO::Async::Loop->new },
);

sub _build_loop { $_[0]->_loop }

has config => (
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  builder => '_build_config',
);

sub _build_config {
  my ($self) = @_;
  my $yml_file = $self->root->child('.raider-hall.yml');
  return {} unless -f $yml_file;
  YAML::PP->new->load_string($yml_file->slurp_utf8);
}

has socket_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_socket_path',
);

sub _build_socket_path {
  my ($self) = @_;
  $self->root->child('.raider-hall.socket')->stringify;
}

has mcpserver_socket_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_mcpserver_socket_path',
);

sub _build_mcpserver_socket_path {
  my ($self) = @_;
  $self->root->child('.raider-hall.mcp')->stringify;
}

has longhouse_lib_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_longhouse_lib_path',
);

sub _build_longhouse_lib_path {
  my ($self) = @_;
  $self->root->child('longhouse', 'lib');
}

has state_dir => (
  is => 'ro',
  lazy => 1,
  builder => '_build_state_dir',
);

sub _build_state_dir {
  my ($self) = @_;
  my $d = $self->root->child('.raider-hall', 'state');
  $d->mkpath unless -d $d;
  $d;
}

has raiders => (
  is => 'ro',
  default => sub { {} },
);

has singleton_queues => (
  is => 'ro',
  default => sub { {} },
);

has cron_scheduler => (
  is => 'ro',
  lazy => 1,
  builder => '_build_cron_scheduler',
);

sub _build_cron_scheduler {
  my ($self) = @_;
  Langertha::Raider::Hall::Cron->new(hall => $self);
}

has telegram => (
  is => 'ro',
  lazy => 1,
  builder => '_build_telegram',
);

sub _build_telegram {
  my ($self) = @_;
  Langertha::Raider::Hall::Telegram->new(hall => $self);
}

has mcp_adapter => (
  is => 'ro',
  lazy => 1,
  builder => '_build_mcp_adapter',
);

sub _build_mcp_adapter {
  my ($self) = @_;
  Langertha::Raider::Hall::MCP->new(hall => $self);
}

has acp_adapter => (
  is => 'ro',
  lazy => 1,
  builder => '_build_acp_adapter',
);

sub _build_acp_adapter {
  my ($self) = @_;
  my $conf = $self->config->{acp} // {};
  Langertha::Raider::Hall::ACP->new(
    hall => $self,
    port => ($ENV{RAIDER_HALL_ACP_PORT} // $conf->{port} // 0),
    host => ($ENV{RAIDER_HALL_ACP_HOST} // $conf->{host} // '127.0.0.1'),
  );
}

has protocol => (
  is => 'ro',
  lazy => 1,
  builder => '_build_protocol',
);

sub _build_protocol {
  my ($self) = @_;
  my $p = Langertha::Raider::Hall::Protocol->new(hall => $self);
  $p->setup_handlers;
  $p;
}

sub BUILD {
  my ($self) = @_;
  $self->root->mkpath unless -d $self->root;
}

sub run {
  my ($self) = @_;
  my $loop = $self->loop;

  $self->_setup_socket;
  $self->_setup_mcp_socket if $self->_want_mcp_socket;
  $self->_setup_event_broadcaster;
  $self->_load_singleton_queues;
  $self->_setup_signal_handlers;
  $self->protocol;
  $self->_setup_cron;
  $self->_setup_telegram;
  $self->_setup_acp;

  $self->_emit('hall.started', { root => $self->root->stringify });

  $loop->run;
}

sub _want_mcp_socket {
  my ($self) = @_;
  my $conf = $self->config;
  return $conf->{mcp} && $conf->{mcp}{enable};
}

sub _setup_socket {
  my ($self) = @_;
  my $loop = $self->loop;
  my $path = $self->socket_path;

  my $sock = IO::Socket::UNIX->new(
    Local => $path,
    Listen => 1,
  ) or die "Cannot create UNIX socket at $path: $!";

  chmod 0600, $path or die "Cannot chmod 0600 $path: $!";

  my $listener = IO::Async::Listener->new(
    on_accept => sub {
      my ($listener, $sock, $peeraddr) = @_;
      $self->_handle_client($sock);
    },
  );

  $loop->add($listener);

  $listener->listen(handle => $sock);
  $self->{_listener} = $listener;
}

sub _setup_mcp_socket {
  my ($self) = @_;
}

sub _setup_event_broadcaster {
  my ($self) = @_;
  $self->{_subscribers} = [];
}

sub _setup_cron {
  my ($self) = @_;
  return unless $self->config->{cron} && @{$self->config->{cron}};
  $self->cron_scheduler->start;
}

sub _setup_telegram {
  my ($self) = @_;
  return unless $self->config->{telegram} && $self->config->{telegram}{bots};
  $self->telegram->setup_bots;
}

sub _setup_acp {
  my ($self) = @_;
  my $enabled = $ENV{RAIDER_HALL_ACP_PORT}
    || ($self->config->{acp} && $self->config->{acp}{port});
  return unless $enabled;
  $self->acp_adapter->start;
}

sub _acp_running {
  my ($self) = @_;
  return $ENV{RAIDER_HALL_ACP_PORT}
    || ($self->config->{acp} && $self->config->{acp}{port});
}

sub _handle_client {
  my ($self, $sock) = @_;
  my $stream = IO::Async::Stream->new(
    handle => $sock,
    on_read => sub {
      my ($stream, $bufref, $eof) = @_;
      $self->_process_client_frames($stream, $bufref, $eof);
    },
    on_closed => sub {
      my ($stream) = @_;
      $self->_unsubscribe_stream($stream);
    },
  );
  $self->loop->add($stream);
  push @{$self->{_client_streams}}, $stream;
}

sub _process_client_frames {
  my ($self, $stream, $bufref, $eof) = @_;
  return unless $$bufref =~ s/^(.*?)\n//;
  my $line = $1;
  return if $line eq '';

  my $msg = eval { JSON::MaybeXS->new->decode($line) };
  if (!$msg || $@) {
    my $err = JSON::MaybeXS->new->encode({error => "invalid JSON: $@"});
    $stream->write("$err\n");
    return;
  }

  my $type = $msg->{type} // '';
  my $payload = $msg->{payload} // {};

  if ($type eq 'subscribe') {
    push @{$self->{_subscribers}}, { stream => $stream, filter => $payload->{filter} // '' };
    return;
  }

  if ($type eq 'command') {
    $self->_handle_command($stream, $payload);
    return;
  }

  my $err = JSON::MaybeXS->new->encode({error => "unknown message type: $type"});
  $stream->write("$err\n");
}

sub _handle_command {
  my ($self, $stream, $payload) = @_;
  my $cmd = $payload->{cmd} // '';

  my $handler = $self->{_cmd_handlers}{$cmd};
  if (!$handler) {
    my $err = JSON::MaybeXS->new->encode({error => "unknown command: $cmd"});
    $stream->write("$err\n");
    return;
  }

  eval { $handler->($self, $stream, $payload) };
  if ($@) {
    my $err = JSON::MaybeXS->new->encode({error => "command failed: $@"});
    $stream->write("$err\n");
  }
}

sub _emit {
  my ($self, $type, $data) = @_;
  $data->{type} = $type;
  $data->{ts} //= time();

  my $json = JSON::MaybeXS->new->encode($data);
  my @alive;
  for my $sub (@{$self->{_subscribers}}) {
    my $filter = $sub->{filter} // '';
    next if $filter ne '' && substr($type, 0, length($filter)) ne $filter;
    my $stream = $sub->{stream};
    if ($stream && $stream->handle && $stream->handle->opened) {
      eval { $stream->write("$json\n") };
      push @alive, $sub;
    }
  }
  $self->{_subscribers} = \@alive;
}

sub _broadcast_to_socket {
  my ($self, $type, $data) = @_;
  $self->_emit($type, $data);
}

sub _unsubscribe_stream {
  my ($self, $stream) = @_;
  @{$self->{_subscribers}} = grep { $_->{stream} ne $stream } @{$self->{_subscribers}};
  @{$self->{_client_streams}} = grep { $_ ne $stream } @{$self->{_client_streams}};
}

sub _register_cmd {
  my ($self, $name, $handler) = @_;
  $self->{_cmd_handlers}{$name} = $handler;
}

sub _load_singleton_queues {
  my ($self) = @_;
  my $state_dir = $self->state_dir;
  return unless -d $state_dir;

  for my $queue_file ($state_dir->children) {
    next unless $queue_file->basename =~ /^.*\.queue\.json$/;
    my $slot = $queue_file->basename;
    $slot =~ s/\.queue\.json$//;
    next unless $slot =~ /^\d+/;
    my $q = eval { JSON::MaybeXS->new->decode($queue_file->slurp_utf8) } // [];
    $self->singleton_queues->{$slot} = $q;
  }
}

sub _persist_queue {
  my ($self, $slot) = @_;
  my $queue = $self->singleton_queues->{$slot} // [];
  my $file = $self->state_dir->child("$slot.queue.json");
  $file->spew_utf8(JSON::MaybeXS->new->encode($queue));
}

sub _setup_signal_handlers {
  my ($self) = @_;
  my $loop = $self->loop;

  # CHLD is handled per-process via IO::Async::Process->on_finish; no
  # global watcher needed (and mixing would double-reap).

  $loop->watch_signal(TERM => sub { $self->shutdown });
  $loop->watch_signal(INT  => sub { $self->shutdown });
}

sub _reap_raider {
  my ($self, $pid, $status) = @_;
  my $raider = $self->_find_raider_by_pid($pid);
  return unless $raider;

  my $slot = $raider->slot_name;
  my $result = $self->_raider_result($raider, $status);
  # Before the raider leaves the table: logs --follow stops once it is gone.
  $self->_log_result($raider, $result);
  $self->_emit('raider.done', {
    id => $raider->id,
    slot => $slot,
    pid => $pid,
    exit_code => $status >> 8,
    signaled => ($status & 127) ? 1 : 0,
    %$result,
  });

  delete $self->raiders->{$slot};
  $self->_prune_events($slot);

  if ($slot =~ /^\d+(.+)$/) {
    my $base = $1;
    my $queue = $self->singleton_queues->{$slot} // [];
    if (@$queue) {
      my $next = shift @$queue;
      $self->singleton_queues->{$slot} = $queue;
      $self->_persist_queue($slot);
      $self->_spawn_next_in_queue($slot, $base, $next);
    }
  }
}

# The run's outcome for raider.done: status plus response or error, taken
# from the last run.finished event of the run. Without one (killed, crashed
# before it could write it) the run counts as failed, with an error that
# says so instead of whatever text the process left behind.
sub _raider_result {
  my ($self, $raider, $status) = @_;
  if (my $doc = $raider->run_finished) {
    return {
      status => $doc->{status} // 'failed',
      defined $doc->{response} ? ( response => $doc->{response} ) : (),
      defined $doc->{error}    ? ( error    => $doc->{error} )    : (),
    };
  }
  my $how = ($status & 127) ? 'killed by signal '.($status & 127)
                            : 'exit code '.($status >> 8);
  return {
    status => 'failed',
    error  => 'raider '.$raider->id.' ended without a result ('.$how.')',
  };
}

# One human-readable line per finished run at the end of the slot log, so
# logs and logs --follow show the outcome next to the raider's stderr. The
# full response stays in raider.done and the events file.
sub _log_result {
  my ($self, $raider, $result) = @_;
  my $text = $result->{status} eq 'completed' ? $result->{response} : $result->{error};
  $text = join ' ', split ' ', $text // '';
  $text = substr($text, 0, 300).'...' if length $text > 300;
  $raider->log_path->append_utf8(
    '[hall] raider '.$raider->id.' '.$result->{status}.': '.$text."\n");
}

=attr keep_events

How many F<SLOT-TIME.events.jsonl> files the hall keeps per slot; older ones
are removed when a run of that slot ends. From C<logs: { keep_events: N }>
in F<.raider-hall.yml>, default 20; 0 keeps all of them. Slot logs
(F<SLOT.log>) are not pruned.

=cut

has keep_events => (
  is => 'ro',
  lazy => 1,
  builder => '_build_keep_events',
);

sub _build_keep_events {
  my ($self) = @_;
  my $logs = $self->config->{logs} // {};
  return $logs->{keep_events} // 20;
}

sub _log_dir { $_[0]->root->child('.raider-hall', 'logs') }

sub _prune_events {
  my ($self, $slot) = @_;
  my $keep = $self->keep_events;
  my $dir = $self->_log_dir;
  return unless $keep > 0 && -d $dir;
  # SLOT-TIME or SLOT-TIME.N: the hyphen before TIME keeps SLOT-x-TIME of
  # another slot out.
  my @runs = sort { $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] }
    map { $_->basename =~ /^\Q$slot\E-(\d+)(?:\.(\d+))?\.events\.jsonl$/ ? [ $_, $1, $2 // 1 ] : () }
    $dir->children;
  $_->[0]->remove for @runs[ 0 .. $#runs - $keep ];
}

sub _find_raider_by_pid {
  my ($self, $pid) = @_;
  for my $r (values %{$self->raiders}) {
    return $r if $r->pid && $r->pid == $pid;
  }
  return;
}

sub _spawn_next_in_queue {
  my ($self, $slot, $base_name, $mission) = @_;
  my ($attach, $telegram);
  if (ref $mission eq 'HASH') {
    $attach = $mission->{attach};
    $telegram = $mission->{telegram};
    $mission = $mission->{mission};
  }
  $self->_spawn_raider($slot, $base_name, $mission, $attach, $telegram);
}

sub spawn {
  my ($self, %args) = @_;
  my $name = $args{name} // '';
  my $mission = $args{mission} // '';
  my $attach = $args{attach} // 0;
  my $telegram = $args{telegram};

  my ($slot, $base_name) = $self->_parse_name($name);

  if ($slot && $self->raiders->{$slot}) {
    if ($slot =~ /^\d+(.+)$/) {
      push @{$self->singleton_queues->{$slot} //= []}, {
        mission => $mission,
        attach => $attach,
        $telegram ? ( telegram => $telegram ) : (),
      };
      $self->_persist_queue($slot);
      $self->_emit('raider.queued', {
        slot => $slot,
        queue_depth => scalar @{$self->singleton_queues->{$slot}},
      });
      return { queued => 1, slot => $slot };
    }
    my $err = JSON::MaybeXS->new->encode({error => "slot $slot already occupied"});
    return { error => $err };
  }

  return $self->_spawn_raider($slot // $name, $base_name // $name, $mission, $attach, $telegram);
}

sub _parse_name {
  my ($self, $name) = @_;
  if ($name =~ /^(\d+)([a-z][-a-z0-9]*)$/) {
    return ($1.$2, $2);
  }
  return (undef, $name);
}

sub _spawn_raider {
  my ($self, $slot, $base_name, $mission, $attach, $telegram) = @_;

  my $raider_config = $self->config->{raiders}{$base_name} // {};
  # No engine configured: leave it to raider (.raider.yml, then key autodetection).
  my $engine = $raider_config->{engine};
  my $model = $raider_config->{model};
  my $packs = $raider_config->{packs} // [];
  my $mcp = $raider_config->{mcp} // [];
  my $isolated = $raider_config->{isolated} // 0;

  my $raider_bin = $self->_raider_bin;
  my @cmd = ($^X, $raider_bin, '--stream-json');
  push @cmd, '--engine', $engine if $engine;
  push @cmd, '--model', $model if $model;
  push @cmd, '--pack', $_ for @$packs;
  push @cmd, '--root', $self->root->stringify;
  # Mission is one single argv (bin/raider does join(' ', @ARGV)).
  push @cmd, '--', $mission;

  my $log_dir = $self->_log_dir;
  $log_dir->mkpath unless -d $log_dir;

  # stderr is the human-readable log, appended across runs of the slot;
  # stdout is the event stream, a fresh file per run. The ID is SLOT-TIME,
  # SLOT-TIME.2 and up when that one is taken in the same second; touching
  # the file reserves it before the child opens it.
  my $log_path = $log_dir->child("${slot}.log");
  my $id = my $base_id = "$slot-" . time;
  my $n = 1;
  $id = $base_id.'.'.++$n while -e $log_dir->child("${id}.events.jsonl");
  my $events_path = $log_dir->child("${id}.events.jsonl");
  $events_path->touch;

  my $lib_path = $self->_raider_lib_path($base_name);
  my $extra_perl5lib = join ':', grep { defined && length } ($lib_path,
    ($self->config->{longhouse} ? $self->longhouse_lib_path->stringify : ()));

  # The Telegram chat this raider answers; telegram_reply is bound to it.
  # Never inherited from the hall's own env.
  my %env = %ENV;
  delete @env{qw( RAIDER_HALL_TELEGRAM_BOT RAIDER_HALL_TELEGRAM_CHAT_ID )};
  if ($telegram) {
    $env{RAIDER_HALL_TELEGRAM_BOT}     = $telegram->{bot};
    $env{RAIDER_HALL_TELEGRAM_CHAT_ID} = $telegram->{chat_id};
  }

  my $process = IO::Async::Process->new(
    command => \@cmd,
    setup => [
      stdin  => [ 'open', '<', '/dev/null' ],
      stdout => [ 'open', '>', "$events_path" ],
      stderr => [ 'open', '>>', "$log_path" ],
      env => {
        %env,
        RAIDER_HALL_MODE   => '1',
        RAIDER_HALL_ROOT   => $self->root->stringify,
        RAIDER_HALL_SLOT   => $slot,
        RAIDER_HALL_SOCKET => $self->socket_path,
        PERL5LIB => join(':', grep { defined && length }
                          ($ENV{PERL5LIB}, $extra_perl5lib)),
      },
    ],
    on_finish => sub {
      my ($proc, $exitcode) = @_;
      my $pid = $proc->pid;
      $self->loop->later(sub { $self->_reap_raider($pid, $exitcode) });
    },
  );

  $self->loop->add($process);

  my $raider = Langertha::Raider::Hall::Raider->new({
    id => $id,
    pid => $process->pid,
    slot_name => $slot,
    base_name => $base_name,
    log_path => $log_path,
    events_path => $events_path,
    mission => $mission,
  });
  $self->raiders->{$slot} = $raider;

  $self->_emit('raider.spawned', {
    id => $id,
    pid => $process->pid,
    slot => $slot,
    base_name => $base_name,
  });

  return { id => $id, pid => $process->pid, slot => $slot };
}

sub _raider_bin {
  my ($self) = @_;
  # Explicit override wins — useful in tests and non-standard installs.
  return $ENV{RAIDER_HALL_RAIDER_BIN}
    if $ENV{RAIDER_HALL_RAIDER_BIN} && -x $ENV{RAIDER_HALL_RAIDER_BIN};

  # Otherwise: next to the currently-running script (raider-hall lives
  # alongside raider in a normal install), then $PATH.
  my $here = path($0)->absolute;
  my $sibling = $here->parent->child('raider');
  return $sibling->stringify if -x $sibling;
  my $which = File::Which::which('raider');
  return $which if $which;
  die "Cannot find 'raider' binary (set RAIDER_HALL_RAIDER_BIN or put it in \$PATH)";
}

sub _raider_lib_path {
  my ($self, $base_name) = @_;
  if ($self->config->{longhouse}) {
    return $self->longhouse_lib_path->stringify;
  }
  return $self->root->child('.raider-hall', 'raiders', $base_name, 'lib')->stringify;
}

sub ps {
  my ($self) = @_;
  my @list;
  for my $slot (sort keys %{$self->raiders}) {
    my $r = $self->raiders->{$slot};
    push @list, {
      slot => $slot,
      pid => $r->pid,
      base_name => $r->base_name,
      mission => $r->mission,
      id => $r->id,
    };
  }
  return @list;
}

sub attach {
  my ($self, $id) = @_;
  for my $r (values %{$self->raiders}) {
    next unless $r->id eq $id;
    return {
      id => $r->id,
      slot => $r->slot_name,
      pid => $r->pid,
      log_path => $r->log_path->stringify,
      $r->has_events_path ? ( events_path => $r->events_path->stringify ) : (),
    };
  }
  return { error => 'raider not found' };
}

sub kill_raider {
  my ($self, $id) = @_;
  for my $r (values %{$self->raiders}) {
    next unless $r->id eq $id;
    kill 'TERM', $r->pid if $r->pid;
    return { killed => 1, id => $id };
  }
  return { error => 'raider not found' };
}

sub logs {
  my ($self, %args) = @_;
  my $id = $args{id};
  my $slot;
  if ($id) {
    for my $s (keys %{$self->raiders}) {
      $slot = $s if $self->raiders->{$s}->id eq $id;
    }
  }
  return { error => 'raider not found' } unless $slot;

  my $log_path = $self->raiders->{$slot}->log_path;
  return { log => '' } unless -f $log_path;
  return { log => $log_path->slurp_utf8 };
}

sub shutdown {
  my ($self) = @_;
  $self->_emit('hall.stopping', {});

  if ($self->_acp_running) {
    eval { $self->acp_adapter->stop };
  }

  if ($self->telegram) {
    eval { $self->telegram->stop };
  }

  for my $r (values %{$self->raiders}) {
    kill 'TERM', $r->pid if $r->pid && $r->pid > 0;
  }

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 5,
    on_expire => sub {
      for my $r (values %{$self->raiders}) {
        kill 'KILL', $r->pid if $r->pid && $r->pid > 0;
      }
      $self->loop->stop;
    },
  );
  $self->loop->add($timer);
  $timer->start;

  # With no children running, stop immediately rather than waiting the
  # full 5s grace period.
  if (!keys %{$self->raiders}) {
    $self->loop->later(sub { $self->loop->stop });
  }
}

sub _write_pidfile {
  my ($self) = @_;
  my $pidfile = $self->root->child('.raider-hall.pid');
  $pidfile->spew_utf8("$$\n");
}

sub _remove_pidfile {
  my ($self) = @_;
  return unless $self->root;
  my $pidfile = $self->root->child('.raider-hall.pid');
  $pidfile->remove if -f $pidfile;
}

sub DEMOLISH {
  my ($self) = @_;
  $self->_remove_pidfile if $self;
}

__PACKAGE__->meta->make_immutable;

1;
