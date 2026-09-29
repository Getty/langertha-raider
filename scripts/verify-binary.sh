#!/usr/bin/env bash
# Smoke-test a built raider binary against the pp runtime traps.
# Usage: verify-binary.sh <raider-binary>
#
# Everything here compares against the checkout this script lives in, so run
# the copy from the checkout the binary was built from, right after the
# build: step 3 loads the packed modules with the perl that built them. Needs
# perl (core modules only), unzip and bash -- present wherever the build ran.
# Nothing reaches the network: the model is a fake OpenAI endpoint on
# 127.0.0.1, and no *_API_KEY is visible to the binary.
set -euo pipefail
BIN=$(realpath "${1:?usage: verify-binary.sh <raider-binary>}")
[ -x "$BIN" ] || { echo "FAIL: not an executable: $BIN" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Short on purpose: the hall's UNIX socket path may not exceed 108 bytes.
work=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# The binary has to run on what it carries: a fresh extraction cache, no
# perl library path, no API key, no personal config, a clean cwd.
export PAR_GLOBAL_TEMP="$work/par"
unset PERL5LIB PERLLIB PERL5OPT PERL_LOCAL_LIB_ROOT PERL_MB_OPT PERL_MM_OPT
while IFS= read -r v; do unset "$v"; done \
  < <(env | sed -n 's/^\([A-Za-z0-9_]*API_KEY[A-Za-z0-9_]*\)=.*/\1/p')
export HOME="$work/home" NO_COLOR=1
mkdir -p "$HOME" "$work/cwd"
cd "$work/cwd"

fail() { echo "FAIL: $*" >&2; exit 1; }
# Every run of the binary is bounded: a module pp missed inside a Future
# chain does not die, it hangs (IO::Async::Internals::Connector did).
tmo=${RAIDER_VERIFY_TIMEOUT:-120}
run() { timeout "$tmo" "$BIN" "$@"; }
# expect DESC PATTERN CMD...: CMD exits 0 and its output matches PATTERN.
# Captured first, never piped into grep -q: that closes the pipe early, and
# under pipefail the writer's SIGPIPE would fail a check that passed.
expect() {
  local desc=$1 pattern=$2 out
  shift 2
  out=$(timeout "$tmo" "$@" 2>&1) || fail "$desc (exit $?; 124 is the ${tmo}s timeout): $out"
  grep -qE -- "$pattern" <<< "$out" || fail "$desc: no /$pattern/ in: $out"
}

# --- 1. startup ----------------------------------------------------------------
# raider has no --version; the version is checked against the packed sources
# in step 3.
expect "--help" '^Usage: raider' "$BIN" --help
echo "startup (--help, fresh cache): OK"

# --- 2. every subcommand's help -------------------------------------------------
# The subcommands dispatch before option parsing (Langertha::Raider::CLI::Main
# ->run): hall and acp load their own CLI classes, config explain and session
# list the config and session store. Each --help loads its code path without
# side effects.
expect "hall --help" '^Usage: raider hall' "$BIN" hall --help
expect "hall help"   '^Usage: raider hall' "$BIN" hall help
for sub in init add-raider start spawn attach logs kill session install; do
  expect "hall $sub --help" "raider hall $sub" "$BIN" hall "$sub" --help
done
expect "acp --help" '^Usage: raider acp' "$BIN" acp --help
for sub in prompt connect; do
  expect "acp $sub --help" "raider acp $sub" "$BIN" acp "$sub" --help
done
expect "config explain" '^engine: +openai' "$BIN" config explain -e openai -k none
expect "session list" 'no sessions' "$BIN" session list
run --export-skill "$work/RAIDER-SKILL.md" >/dev/null 2>&1 && [ -s "$work/RAIDER-SKILL.md" ] \
  || fail "--export-skill"
echo "subcommands (hall: 11, acp: 3, config explain, session list, --export-skill): OK"

# --- 3. the packed module set ---------------------------------------------------
# Much of raider and Langertha loads by name at runtime (engines, plugins,
# loop and JSON backends, TLS), which no run above reaches. So every module
# the archive carries under Langertha:: is required -- with @INC holding
# nothing but the archive's lib/, the same set the binary runs on, and the
# perl that built it (its bundled core included). A module pp missed fails
# here instead of on a user's first run of that engine.
unzip -qq -o "$BIN" -d "$work/archive" 2>/dev/null || [ -d "$work/archive/lib" ] \
  || fail "cannot unpack the PAR archive"
plib="$work/archive/lib"
missing=$(cd "$root/lib" && find Langertha -name '*.pm' | sort | while IFS= read -r f; do
  [ -f "$plib/$f" ] || echo "$f"; done)
[ -z "$missing" ] || fail "not packed: $missing"
want_raider=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" "$root/lib/Langertha/Raider.pm")
want_bin=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" "$root/bin/raider")
got_bin=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" "$work/archive/script/raider")
[ -n "$want_bin" ] && [ "$got_bin" = "$want_bin" ] \
  || fail "packed bin/raider is version '$got_bin', the checkout's is '$want_bin'"
PLIB="$plib" WANT="$want_raider" RAIDER_SHARE="$root/share" perl -e '
  BEGIN { @INC = ( $ENV{PLIB} ) }
  use strict;
  use warnings;
  # Loading the facades on purpose; their deprecation notice is noise here.
  local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /backwards-compatibility facade/ };
  my @fail;
  my $load = sub {
    my ( $m ) = @_;
    ( my $f = $m.".pm" ) =~ s{::}{/}g;
    eval { require $f; 1 } or push @fail, $m.": ".( split /\n/, $@ )[0];
  };
  my @mods;
  open my $find, "-|", "find", "$ENV{PLIB}/Langertha", "-name", "*.pm" or die $!;
  while ( my $f = <$find> ) {
    chomp $f;
    $f =~ s{\A\Q$ENV{PLIB}\E/}{};
    $f =~ s{\.pm\z}{};
    push @mods, join "::", split m{/}, $f;
  }
  $load->($_) for sort @mods;
  $load->($_) for qw(
    IO::Async::Loop IO::Async::SSL IO::Socket::SSL Net::SSLeay Mozilla::CA
    Net::Async::HTTP LWP::UserAgent LWP::Protocol::https
    Net::Async::MCP MCP::Server MCP::Run::Bash
    JSON::MaybeXS YAML::PP YAML::XS Data::MessagePack
    File::ShareDir File::ShareDir::ProjectDistDir
  );
  die join( "\n", "modules that do not load from the archive:", @fail )."\n" if @fail;
  my $v = Langertha::Raider->VERSION;
  die "packed Langertha::Raider is $v, the checkout is $ENV{WANT}\n" unless $v eq $ENV{WANT};
  my $loop = ref IO::Async::Loop->new;
  my $json = JSON::MaybeXS::JSON();
  my $ca   = Mozilla::CA::SSL_ca_file();
  die "Mozilla::CA bundle missing from the archive\n" unless -s $ca && index($ca, $ENV{PLIB}) == 0;
  my $share = File::ShareDir::dist_dir("Langertha-Raider");
  die "dist_dir(Langertha-Raider) is $share, not inside the archive\n" unless index($share, $ENV{PLIB}) == 0;
  system("diff", "-r", "-q", $ENV{RAIDER_SHARE}, $share) == 0
    or die "packed share/ differs from the checkout\n";
  # How the engines find their spec: ProjectDistDir dist_file, per engine.
  my ( undef, $spec ) = Langertha::Engine::OpenAI->openapi_file;
  die "Langertha::Engine::OpenAI spec is $spec, not inside the archive\n"
    unless -s $spec && index($spec, $ENV{PLIB}) == 0;
  printf "modules (%d Langertha::*, Langertha::Raider %s, loop %s, JSON %s): OK\n",
    scalar @mods, $v, $loop, $json;
  print "share (Langertha-Raider = checkout share/, Langertha openai.yaml via the engine, Mozilla::CA): OK\n";
' || fail "packed module set"

# --- 4. the bundled packs, at runtime --------------------------------------------
# The same share/ as step 3, now found by the binary itself through
# File::ShareDir: every pack under share/packs has to resolve as shipped.
# One pack per run: the persona packs are an exclusive group.
packs=()
for d in "$root"/share/packs/*/; do packs+=("$(basename "$d")"); done
[ "${#packs[@]}" -gt 0 ] || fail "no packs under $root/share/packs"
for p in "${packs[@]}"; do
  expect "pack $p resolves as shipped (is share/ bundled? build-binary.sh -a share)" \
    "^ +$p +active +shipped" "$BIN" -e openai -k none --no-detect --pack "$p" config explain
done
echo "packs (${packs[*]}): OK"

# --- 5. an offline raid ------------------------------------------------------------
# A real run end to end: engine resolution and loading by name, Net::Async::HTTP,
# the Langertha tool loop, the in-process MCP tool servers (read_file and
# MCP::Run::Bash), the session journal and --json output. The model is a
# fake OpenAI endpoint that asks for the two tool calls, then answers with
# what they returned.
cat > "$work/fake-openai.pl" <<'FAKE'
use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP;
my ( $portfile ) = @ARGV;
my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1 )
  or die "listen: $!";
open my $pf, '>', $portfile.'.tmp' or die $!;
print $pf $srv->sockport;
close $pf;
rename $portfile.'.tmp', $portfile or die $!;
my $json  = JSON::PP->new->canonical;
my @calls = (
  [ read_file => { path => 'smoke.txt' } ],
  [ bash      => { command => 'echo raider-bash-$((6*7))' } ],
  [ web_fetch => { url => 'http://127.0.0.1:'.$srv->sockport.'/page' } ],
);
while ( my $c = $srv->accept ) {
  local $/ = "\r\n";
  my $line = <$c> // next;
  my %h;
  while ( my $l = <$c> ) {
    last if $l eq "\r\n";
    $h{ lc $1 } = $2 if $l =~ /^([^:]+):\s*(.*?)\r\n/;
  }
  my $body = '';
  read $c, $body, $h{'content-length'} // 0;
  my $in = eval { $json->decode($body) } || {};
  my $out;
  if ( $line =~ m{^GET /page } ) {
    my $html = '<html><body><p>raider-web-ok</p></body></html>';
    print $c "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
      .length($html)."\r\nConnection: close\r\n\r\n".$html;
    close $c;
    next;
  }
  if ( $line =~ m{/embeddings } ) {
    $out = { object => 'list', model => 'fake', data => [ { object => 'embedding', index => 0,
      embedding => [ 0.1, 0.2, 0.3 ] } ], usage => { prompt_tokens => 1, total_tokens => 1 } };
  }
  else {
    my @tool = grep { ( $_->{role} // '' ) eq 'tool' } @{ $in->{messages} || [] };
    my $msg = @tool < @calls
      ? { role => 'assistant', content => undef, tool_calls => [ { id => 'call_'.scalar @tool,
          type => 'function', function => { name => $calls[@tool][0],
          arguments => $json->encode( $calls[@tool][1] ) } } ] }
      : { role => 'assistant', content => 'SMOKE-DONE '.join ' | ',
          map { ref $_->{content} ? $json->encode( $_->{content} ) : $_->{content} } @tool };
    $out = { id => 'fake', object => 'chat.completion', created => time, model => 'fake',
      choices => [ { index => 0, message => $msg, finish_reason => $msg->{tool_calls} ? 'tool_calls' : 'stop' } ],
      usage => { prompt_tokens => 1, completion_tokens => 1, total_tokens => 2 } };
  }
  my $res = $json->encode($out);
  print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    .length($res)."\r\nConnection: close\r\n\r\n".$res;
  close $c;
}
FAKE
perl "$work/fake-openai.pl" "$work/port" &
pids+=($!)
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || fail "fake OpenAI endpoint did not start"
port=$(cat "$work/port")
mkdir "$work/project"
echo "raider-smoke-marker-$$" > "$work/project/smoke.txt"
out=$(run -r "$work/project" -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" \
        --bare --json "read smoke.txt, run the bash check, fetch the page") \
  || fail "offline raid exited $?: $out"
grep -q "SMOKE-DONE" <<< "$out" || fail "offline raid: no final answer in: $out"
grep -q "raider-smoke-marker-$$" <<< "$out" || fail "offline raid: read_file result missing: $out"
grep -q "raider-bash-42" <<< "$out" || fail "offline raid: bash result missing: $out"
grep -q "raider-web-ok" <<< "$out" || fail "offline raid: web_fetch result missing: $out"
expect "offline raid: session journal" '.' "$BIN" session list -r "$work/project"
echo "offline raid (fake OpenAI endpoint, read_file + bash + web_fetch tools, session journal, --json): OK"

# The REPL on a pipe: Term::ReadLine without Gnu (left out of the build),
# slash commands, one raid.
repl=$(printf '/help\n/packs\ngo\n/quit\n' \
  | timeout "$tmo" "$BIN" -r "$work/project" -e openai -k fake -m fake \
      -o "url=http://127.0.0.1:$port/v1" --bare --no-session -i 2>&1) \
  || fail "REPL exited $?: $repl"
grep -q "SMOKE-DONE" <<< "$repl" || fail "REPL: no raid answer in: $repl"
echo "REPL (piped: /help, /packs, a raid, /quit): OK"

# --- 6. hall and ACP ----------------------------------------------------------------
# A daemon hall with its ACP port: the UNIX control socket (status, ps), the
# ACP server and client (acp ping), the systemd unit, and one raider it
# spawns.
mkdir "$work/hall"
(
  cd "$work/hall"
  run hall init --name bjorn >/dev/null
  run hall add-raider astrid >/dev/null
  grep -q astrid .raider-hall.yml || fail "hall add-raider"
  expect "hall install --stdout" '^ExecStart=.* hall start' "$BIN" hall install --host --stdout
  if run hall status >/dev/null 2>&1; then fail "hall status without a hall"; fi
  acp_port=$(perl -MIO::Socket::INET -e 'print IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0)->sockport')
  run hall start --daemon --acp-port "$acp_port" --acp-host 127.0.0.1 >/dev/null
  for _ in $(seq 100); do [ -S .raider-hall.socket ] && [ -s .raider-hall.pid ] && break; sleep 0.1; done
  [ -S .raider-hall.socket ] || fail "hall start: no control socket"
  hall_pid=$(cat .raider-hall.pid)
  trap 'kill "$hall_pid" 2>/dev/null || true' EXIT
  expect "hall status" '"running"' "$BIN" hall status
  expect "hall ps" 'No running raiders' "$BIN" hall ps
  expect "acp ping" '"protocolVersion"' "$BIN" acp ping "127.0.0.1:$acp_port"
  # The hall starts its raider with the binary itself, never as
  # "perl <binary>" (k105); the raider finds the fake endpoint of step 5 in
  # the hall root's .raider.yml and runs its three tools there.
  echo "raider-hall-marker-$$" > smoke.txt
  printf 'engine: openai\nopenai:\n  url: http://127.0.0.1:%s/v1\n  api_key: fake\n  model: fake\n' \
    "$port" > .raider.yml
  # On failure the raider's own stderr, the slot log, says why.
  spawned=$(run hall spawn --attach astrid "read smoke.txt, run the bash check, fetch the page" 2>&1) \
    || fail "hall spawn --attach (exit $?): $spawned"
  grep -qE "SMOKE-DONE raider-hall-marker-$$.*raider-bash-42.*raider-web-ok.*\"status\":\"completed\".*\"type\":\"run.finished\"" \
    <<< "$spawned" \
    || fail "hall spawn --attach: no completed run in: $spawned
slot log: $(tail -n 20 .raider-hall/logs/astrid.log 2>&1)"
  run hall stop >/dev/null
  for _ in $(seq 100); do kill -0 "$hall_pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$hall_pid" 2>/dev/null; then fail "hall stop: PID $hall_pid still running"; fi
) || exit 1
echo "hall + acp (init, add-raider, install, start --daemon, status, ps, acp ping, spawn --attach, stop): OK"

echo "verify: OK"
