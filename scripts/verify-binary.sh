#!/usr/bin/env bash
# Smoke-test a built raider binary against the pp runtime traps.
# Usage: verify-binary.sh <raider-binary>
#
# Everything here compares against the checkout this script lives in, so run
# the copy from the checkout the binary was built from, right after the
# build: step 3 loads the packed modules with the perl that built them. Needs
# perl (core modules only), unzip, git and bash -- present wherever the build
# ran. Nothing reaches the network: the model is a fake OpenAI endpoint on
# 127.0.0.1, the one skill source a file:// git repository, and no *_API_KEY
# is visible to the binary.
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
# --version names the Langertha::Raider the binary runs, which has to be the
# checkout's; step 3 holds its Langertha against the one in the archive.
want_raider=$(sed -n "s/^our \$VERSION = '\(.*\)';/\1/p" "$root/lib/Langertha/Raider.pm")
[ -n "$want_raider" ] || fail "no \$VERSION in $root/lib/Langertha/Raider.pm"
version=$(run --version 2>&1) || fail "--version (exit $?): $version"
[[ $version =~ ^raider\ ([^ ]+)\ \(Langertha\ ([^ ]+)\)$ ]] \
  || fail "--version: not 'raider VERSION (Langertha VERSION)': $version"
[ "${BASH_REMATCH[1]}" = "$want_raider" ] \
  || fail "--version: raider ${BASH_REMATCH[1]}, the checkout is $want_raider"
bin_langertha=${BASH_REMATCH[2]}
expect "--help" '^Usage: raider' "$BIN" --help
echo "startup (--version: $version, fresh cache; --help): OK"

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
# provider inspect loads Langertha::Manifest and resolves the host through
# IO::Async's resolver (IO::Async::Resolver, loaded by name, runs lookups
# in a forked worker). localhost:443 resolves offline, and to loopback, so
# the fetch is refused before any connection: exit 1 and a refused document.
# The port is what makes it a host: a bare name is a provider alias (k170).
expect "provider inspect --help" '^Usage: raider provider inspect' "$BIN" provider inspect --help
rc=0
prov=$(run provider inspect localhost:443 --json 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "provider inspect localhost:443: exit $rc, not 1 (124 is the ${tmo}s timeout): $prov"
grep -q '"status" : "refused"' <<< "$prov" && grep -q 'loopback address' <<< "$prov" \
  || fail "provider inspect localhost:443: no refused loopback document: $prov"
# --provider runs the same fetch through Langertha::Raider::Provider::Activation
# before any engine class is loaded: refused the same way, exit 1.
rc=0
prov=$(run --provider localhost:443 -k none --no-session "hi" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "--provider localhost:443: exit $rc, not 1 (124 is the ${tmo}s timeout): $prov"
grep -q '^raider --provider: refused: .*loopback address' <<< "$prov" \
  || fail "--provider localhost:443: not refused as loopback: $prov"
echo "subcommands (hall: 11, acp: 3, config explain, session list, --export-skill, provider inspect, --provider): OK"

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
PLIB="$plib" BIN_LANGERTHA="$bin_langertha" RAIDER_SHARE="$root/share" perl -e '
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
  # Skilletor (the briefing resolver over skilletor.json sources): every
  # module of it the archive carries; step 7 runs it against a git source.
  my @skilletor = ( "Skilletor" );
  open $find, "-|", "find", "$ENV{PLIB}/Skilletor", "-name", "*.pm" or die $!;
  while ( my $f = <$find> ) {
    chomp $f;
    $f =~ s{\A\Q$ENV{PLIB}\E/}{};
    $f =~ s{\.pm\z}{};
    push @skilletor, join "::", split m{/}, $f;
  }
  $load->($_) for sort @skilletor;
  # File::Temp: Path::Tiny requires it inside tempdir(), where the bash tool
  # (Langertha::Raider::BashTools) keeps the output file of each command.
  $load->($_) for qw(
    IO::Async::Loop IO::Async::SSL IO::Socket::SSL Net::SSLeay Mozilla::CA
    Net::Async::HTTP LWP::UserAgent LWP::Protocol::https
    Net::Async::MCP MCP::Server File::Temp
    Langertha JSON::MaybeXS YAML::PP YAML::XS Data::MessagePack
    File::ShareDir File::ShareDir::ProjectDistDir
    Skilletor::Source::Git Skilletor::Source::Url Skilletor::Source::Local
    HTTP::Tiny Compress::Raw::Zlib Unicode::Normalize
  );
  die join( "\n", "modules that do not load from the archive:", @fail )."\n" if @fail;
  # What Skilletor loads by name or from data at runtime: HTTP::Tiny requires
  # IO::Socket::SSL, Net::SSLeay and Mozilla::CA when a source is https://;
  # a tarball goes through Compress::Raw::Zlib; a host name through
  # Unicode::Normalize, whose tables (unicore) are data files.
  my ( $ssl, $why ) = HTTP::Tiny->can_ssl;
  die "HTTP::Tiny cannot do https from the archive: $why\n" unless $ssl;
  my ( $z ) = Compress::Raw::Zlib::Deflate->new( -WindowBits => Compress::Raw::Zlib::WANT_GZIP(), -AppendOutput => 1 );
  my ( $plain, $gz ) = ( "skilletor-gzip", "" );
  $z->deflate( $plain, $gz );
  $z->flush($gz);
  die "Skilletor::Gzip: no round trip from the archive\n"
    unless Skilletor::Gzip::gunzip_sync($gz) eq "skilletor-gzip";
  die "Unicode::Normalize: NFC broken in the archive\n"
    unless Unicode::Normalize::NFC("e\x{301}") eq "\x{e9}";
  my $url = Skilletor::URL::parse_url("https://B\x{fc}cher.example/skills");
  die "Skilletor::URL: no punycode host from the archive\n"
    unless ref $url && ( $url->{hostname} // "" ) eq "xn--bcher-kva.example";
  my $v = Langertha::Raider->VERSION;
  my $core = Langertha->VERSION;
  die "--version reports Langertha $ENV{BIN_LANGERTHA}, the archive packs $core\n"
    unless $core eq $ENV{BIN_LANGERTHA};
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
  printf "modules (%d Langertha::*, %d Skilletor*, Langertha::Raider %s, Langertha %s, loop %s, JSON %s): OK\n",
    scalar @mods, scalar @skilletor, $v, $core, $loop, $json;
  print "skilletor runtime (HTTP::Tiny https, gunzip, NFC + punycode): OK\n";
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
# bash, Langertha::Raider::BashTools), the session journal and --json output. The model is a
# fake OpenAI endpoint that asks for tool calls one by one, then answers
# "SMOKE-DONE " with what they returned. Which calls: a prompt (any user
# message) naming scenario=NAME gets those of $work/scenarios/NAME.json, a
# list of [ tool, arguments ]; any other prompt read_file, bash, web_fetch.
# The answer ends in CTX[...] when the system or user messages carry
# VERIFY-* markers: what reached the model's context, not a tool result.
mkdir "$work/scenarios"
cat > "$work/fake-openai.pl" <<'FAKE'
use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP;
my ( $portfile, $scenarios ) = @ARGV;
my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1 )
  or die "listen: $!";
open my $pf, '>', $portfile.'.tmp' or die $!;
print $pf $srv->sockport;
close $pf;
rename $portfile.'.tmp', $portfile or die $!;
my $json  = JSON::PP->new->canonical;
my @default = (
  [ read_file => { path => 'smoke.txt' } ],
  [ bash      => { command => 'echo raider-bash-$((6*7))' } ],
  [ web_fetch => { url => 'http://127.0.0.1:'.$srv->sockport.'/page' } ],
);
my $text = sub { my ( $c ) = @_; return ref $c ? $json->encode($c) : $c // '' };
my $calls_for = sub {
  my ( $messages ) = @_;
  for my $m ( grep { ( $_->{role} // '' ) eq 'user' } @$messages ) {
    next unless $text->( $m->{content} ) =~ /\bscenario=([\w-]+)/;
    open my $fh, '<', "$scenarios/$1.json" or die "scenario $1: $!";
    local $/;
    return $json->decode(<$fh>);
  }
  return \@default;
};
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
    my @messages = @{ $in->{messages} || [] };
    my @calls = @{ $calls_for->( \@messages ) };
    my @tool = grep { ( $_->{role} // '' ) eq 'tool' } @messages;
    my %ctx = map { $_ => 1 } map { $text->( $_->{content} ) =~ /\b(VERIFY-[A-Z0-9-]+)/g }
      grep { ( $_->{role} // '' ) =~ /\A(?:system|developer|user)\z/ } @messages;
    my $msg = @tool < @calls
      ? { role => 'assistant', content => undef, tool_calls => [ { id => 'call_'.scalar @tool,
          type => 'function', function => { name => $calls[@tool][0],
          arguments => $json->encode( $calls[@tool][1] ) } } ] }
      : { role => 'assistant', content => 'SMOKE-DONE '.join( ' | ', map { $text->( $_->{content} ) } @tool )
          .( %ctx ? ' CTX['.join( ' ', sort keys %ctx ).']' : '' ) };
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
perl "$work/fake-openai.pl" "$work/port" "$work/scenarios" &
pids+=($!)
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || fail "fake OpenAI endpoint did not start"
port=$(cat "$work/port")
mkdir "$work/project"
echo "raider-smoke-marker-$$" > "$work/project/smoke.txt"
# bypassPermissions: in the default mode a run with nobody to ask refuses
# bash and web_fetch (ADR 0021; step 7 checks that refusal).
out=$(run -r "$work/project" -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" \
        --bare --permission-mode bypassPermissions --json "read smoke.txt, run the bash check, fetch the page") \
  || fail "offline raid exited $?: $out"
grep -q "SMOKE-DONE" <<< "$out" || fail "offline raid: no final answer in: $out"
grep -q "raider-smoke-marker-$$" <<< "$out" || fail "offline raid: read_file result missing: $out"
grep -q "raider-bash-42" <<< "$out" || fail "offline raid: bash result missing: $out"
grep -q "raider-web-ok" <<< "$out" || fail "offline raid: web_fetch result missing: $out"
expect "offline raid: session journal" '.' "$BIN" session list -r "$work/project"
echo "offline raid (fake OpenAI endpoint, read_file + bash + web_fetch tools, session journal, --json): OK"

# Background shells (ADR 0024): bash forks, execs bash in a process group of
# its own and leaves it to the loop's watch_process -- fork in the packed
# perl, the output file in a Path::Tiny tempdir. bash_1 ends on its own and
# bash_output waits for it; bash_2 would sleep for minutes under a name of
# its own (exec -a) until kill_shell stops its process group.
cat > "$work/scenarios/bg.json" <<JSON
[ ["bash", {"command": "echo raider-bg-\$((6*7))", "run_in_background": true}],
  ["bash", {"command": "exec -a raider-bg-sleep-$$ sleep 300", "run_in_background": true}],
  ["bash_output", {"bash_id": "bash_1", "block": true, "timeout": 30}],
  ["kill_shell", {"shell_id": "bash_2"}],
  ["bash_output", {"bash_id": "bash_2"}] ]
JSON
out=$(run -r "$work/project" -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" \
        --bare --no-session --permission-mode bypassPermissions --json "scenario=bg") \
  || fail "background-shell raid exited $?: $out"
for want in 'SMOKE-DONE Command running in background with ID: bash_1\.' \
            'Command running in background with ID: bash_2\.' \
            '<status>completed</status>[^|]*<exit_code>0</exit_code>[^|]*raider-bg-42' \
            'Successfully stopped task: bash_2 \(exec -a raider-bg-sleep-' '<status>killed</status>'; do
  grep -qE -- "$want" <<< "$out" || fail "background-shell raid: no /$want/ in: $out"
done
# No pgrep (procps) needed: a process whose argv[0] is the name, from /proc.
perl -e 'for (glob "/proc/[0-9]*/cmdline") { open my $f, "<", $_ or next; local $/;
  exit 1 if index( <$f> // "", $ARGV[0] ) == 0 }' "raider-bg-sleep-$$" \
  || fail "kill_shell: raider-bg-sleep-$$ still running after the raid"
echo "background shells (run_in_background, bash_output --block, kill_shell of the process group): OK"

# The REPL on a pipe: Term::ReadLine without Gnu (left out of the build),
# slash commands, one raid.
repl=$(printf '/help\n/packs\ngo\n/quit\n' \
  | timeout "$tmo" "$BIN" -r "$work/project" -e openai -k fake -m fake \
      -o "url=http://127.0.0.1:$port/v1" --bare --no-session --dangerously-skip-permissions -i 2>&1) \
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
  run hall add-raider sigrid >/dev/null
  grep -q astrid .raider-hall.yml || fail "hall add-raider"
  # astrid runs everything (the hall passes --permission-mode); sigrid keeps
  # the default mode and asks.
  perl -0pi -e 's/^  astrid:\n/  astrid:\n    permission_mode: bypassPermissions\n/m' .raider-hall.yml
  grep -q 'permission_mode: bypassPermissions' .raider-hall.yml || fail "cannot set astrid's permission_mode"
  expect "hall install --stdout" "^ExecStart=$BIN hall start" "$BIN" hall install --host --stdout
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
  # read_file numbers its lines (ADR 0023): the marker follows "1\t".
  grep -qE "SMOKE-DONE 1[^ ]*raider-hall-marker-$$.*raider-bash-42.*raider-web-ok.*\"status\":\"completed\".*\"type\":\"run.finished\"" \
    <<< "$spawned" \
    || fail "hall spawn --attach: no completed run in: $spawned
slot log: $(tail -n 20 .raider-hall/logs/astrid.log 2>&1)"
  # A run of an ACP session asks its client (ADR 0021): the hall hands the
  # raider a socket in a directory of its own under the temp dir
  # (--permission-channel), the raider asks there before write_file, the hall
  # forwards it as session/request_permission, and acp prompt -- nobody to
  # ask -- rejects. The reason reaching the model proves the whole way; a
  # broken channel would say "permission channel: ..." instead.
  printf '[["write_file",{"path":"acp-out.txt","content":"x"}]]' > "$work/scenarios/acp.json"
  asked=$(run acp prompt "127.0.0.1:$acp_port" --raider sigrid "scenario=acp" 2>&1) \
    || fail "acp prompt (exit $?): $asked"
  grep -q "SMOKE-DONE The user doesn't want to proceed with this tool use" <<< "$asked" \
    && grep -q 'the client rejected the call' <<< "$asked" \
    || fail "acp prompt: write_file not refused by the ACP client in: $asked
slot log: $(tail -n 20 .raider-hall/logs/sigrid.log 2>&1)"
  [ ! -e acp-out.txt ] || fail "acp prompt: write_file ran although the client rejected it"
  run hall stop >/dev/null
  for _ in $(seq 100); do kill -0 "$hall_pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$hall_pid" 2>/dev/null; then fail "hall stop: PID $hall_pid still running"; fi
) || exit 1
echo "hall + acp (init, add-raider, install, start --daemon, status, ps, acp ping, spawn --attach, acp prompt with a permission request, stop): OK"

# --- 7. the Claude Code flow ----------------------------------------------------------
# One Claude project (CLAUDE.md, .claude/) under a home of its own, run
# against the fake endpoint of step 5: Claude mode and its memory, settings,
# project and plugin skills (ADR 0019, the body a message of its own: ADR
# 0026), glob/grep and the loadguard gate (ADR 0018), the task tools and
# enter_plan_mode (ADR 0025), read before write and multi_edit (ADR 0023),
# permission modes and plan mode (ADR 0021), hooks (ADR 0022),
# agent files, the agent tool and the briefing preload, also from a
# skilletor.json source over git (ADR 0020). Each check names the marker it
# looks for: a VERIFY-* string placed in one file of the project.
cc="$work/cc"
cchome="$work/cchome"
mkdir -p "$cc/.claude/skills/proj-skill" "$cc/.claude/agents" "$cc/sub" "$cc/hooks" \
  "$cchome/.claude/skilletor"
echo "Project memory: VERIFY-CLAUDEMD" > "$cc/CLAUDE.md"
echo "Nested memory: VERIFY-NESTED" > "$cc/sub/CLAUDE.md"
echo "grep-needle-$$" > "$cc/sub/file.txt"
printf 'alpha\nbeta\n' > "$cc/edit.txt"
printf -- '---\nname: proj-skill\ndescription: A project skill.\n---\nVERIFY-PROJ-SKILL-BODY\n' \
  > "$cc/.claude/skills/proj-skill/SKILL.md"
# A user-scoped plugin, enabled in the home's settings: its skills are
# vplug:<dir> (Langertha::Raider::Context::Plugins).
plug="$cchome/.claude/plugins/cache/vm/vplug/1.0"
mkdir -p "$plug/skills/plug-skill" "$plug/.claude-plugin"
printf -- '---\nname: plug-skill\ndescription: A plugin skill.\n---\nVERIFY-PLUGIN-SKILL-BODY\n' \
  > "$plug/skills/plug-skill/SKILL.md"
printf '{"name":"vplug"}' > "$plug/.claude-plugin/plugin.json"
printf '{"version":2,"plugins":{"vplug@vm":[{"scope":"user","installPath":"%s","version":"1.0"}]}}' \
  "$plug" > "$cchome/.claude/plugins/installed_plugins.json"
printf '{"enabledPlugins":{"vplug@vm":true}}' > "$cchome/.claude/settings.json"
# A skill only a skilletor.json source has: a git repository, cloned by
# Skilletor (git on PATH) into the home's cache when the briefing needs it.
command -v git >/dev/null || fail "git is not on PATH (the skilletor source of step 7 is a git repository)"
src="$work/skillsrc"
mkdir -p "$src/skills/brief-skill"
printf -- '---\nname: brief-skill\ndescription: From skilletor.\n---\nVERIFY-SKILLETOR-SKILL-BODY\n' \
  > "$src/skills/brief-skill/SKILL.md"
git -C "$src" init -q
git -C "$src" add -A
git -C "$src" -c user.name=verify -c user.email=verify@localhost commit -qm skills
printf '{"sources":{"vsrc":{"git":"file://%s"}},"install":{"skills":["brief-skill@vsrc"]}}' \
  "$src" > "$cc/.claude/skilletor.json"
printf '{"vsrc":{"kind":"git","address":"file://%s"}}' "$src" > "$cchome/.claude/skilletor/trust.json"
printf -- '---\nname: briefed\ndescription: Verify agent.\nbriefing:\n  skills: [ proj-skill, brief-skill ]\n---\nVERIFY-AGENT-BODY\n' \
  > "$cc/.claude/agents/briefed.md"
# Hooks: SessionStart and UserPromptSubmit add context, PreToolUse refuses a
# bash command that names hook-deny-me, PostToolUse logs what it got.
printf '#!/bin/sh\nin=$(cat)\ncase "$in" in *hook-deny-me*) echo VERIFY-HOOK-DENY >&2; exit 2;; esac\nexit 0\n' \
  > "$cc/hooks/pre"
printf '#!/bin/sh\ncat >> "$CLAUDE_PROJECT_DIR/post-tool.jsonl"\necho >> "$CLAUDE_PROJECT_DIR/post-tool.jsonl"\n' \
  > "$cc/hooks/post"
chmod +x "$cc/hooks/pre" "$cc/hooks/post"
cat > "$cc/.claude/settings.json" <<'JSON'
{"hooks":{
  "SessionStart":[{"hooks":[{"type":"command","command":"cat >/dev/null; echo VERIFY-SESSIONSTART"}]}],
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"cat >/dev/null; echo VERIFY-PROMPTSUBMIT"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/hooks/pre"}]}],
  "PostToolUse":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/hooks/post"}]}]
}}
JSON
# grep without ripgrep: the Perl search. A PATH of links to everything on
# PATH but rg.
nopath=$PATH
if command -v rg >/dev/null; then
  mkdir "$work/norg"
  IFS=: read -r -a pathdirs <<< "$PATH"
  for d in "${pathdirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      [ "$b" != rg ] && [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$work/norg/$b" ] && ln -s "$f" "$work/norg/$b"
    done
  done
  nopath="$work/norg"
fi
ccrun() { ( cd "$cc" && HOME="$cchome" PATH="$nopath" timeout "$tmo" "$BIN" "$@" ); }

explain=$(ccrun config explain -e openai -k none 2>&1) || fail "claude: config explain (exit $?): $explain"
for want in 'layout: claude' 'memory CLAUDE\.md \(project\)' 'proj-skill +listed +\.claude/skills' \
            'vplug:plug-skill +listed +plugin vplug' 'briefed +\.claude/agents' \
            'skills proj-skill, brief-skill \(skilletor:vsrc\)' \
            'hooks: PostToolUse \(1\), PreToolUse \(1\), SessionStart \(1\), UserPromptSubmit \(1\)' \
            'enabled plugins: vplug@vm'; do
  grep -qE -- "$want" <<< "$explain" || fail "claude: config explain: no /$want/ in: $explain"
done
echo "claude: config explain (CLAUDE.md, settings, hooks, project + plugin skills, agent with a skilletor skill): OK"

# The tools, in Claude mode with bypassPermissions (the hooks still decide):
# the two skills (each body a user message after the tool result), a read
# that pulls in sub/CLAUDE.md (Plugin::NestedMemory), glob, grep, the task
# tools, a write to edit.txt refused because it was not read, the read,
# multi_edit and edit_file on it, bash refused by the PreToolUse hook, a heavy bash
# command refused by loadguard -- one heavy slot (LOADGUARD_HEAVY_SLOTS=1),
# held by a "prove" below a process that calls itself raider -- and the
# agent tool starting "briefed", whose child run (scenario=child) sees the
# agent's body and both briefed skills in its context.
cat > "$work/scenarios/claude.json" <<'JSON'
[ ["skill", {"skill": "vplug:plug-skill"}],
  ["skill", {"skill": "proj-skill"}],
  ["read_file", {"path": "sub/file.txt"}],
  ["glob", {"pattern": "**/*.txt"}],
  ["grep", {"pattern": "grep-needle", "output_mode": "content"}],
  ["task_create", {"subject": "Verify the binary", "description": "Run every tool once", "activeForm": "Verifying"}],
  ["task_update", {"taskId": "1", "status": "in_progress"}],
  ["task_list", {}],
  ["write_file", {"path": "edit.txt", "content": "unread"}],
  ["read_file", {"path": "edit.txt"}],
  ["multi_edit", {"path": "edit.txt", "edits": [{"old_string": "alpha", "new_string": "ALPHA"}, {"old_string": "beta", "new_string": "BETA"}]}],
  ["edit_file", {"path": "edit.txt", "old_string": "BETA", "new_string": "GAMMA"}],
  ["bash", {"command": "echo hook-deny-me"}],
  ["bash", {"command": "prove -l t"}],
  ["agent", {"description": "verify", "prompt": "scenario=child", "subagent_type": "briefed"}] ]
JSON
printf '[["glob",{"pattern":"sub/*.txt"}]]' > "$work/scenarios/child.json"
perl -e '$0 = "raider"; my $pid = fork // die "fork: $!"; exec { "sleep" } "prove", 300 unless $pid;
  $SIG{TERM} = sub { kill TERM => $pid; exit 0 }; waitpid $pid, 0' &
pids+=($!)
holder=$!
sleep 0.5
out=$(LOADGUARD_HEAVY_SLOTS=1 ccrun -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" \
        --permission-mode bypassPermissions --json "scenario=claude") \
  || fail "claude raid exited $?: $out"
kill "$holder" 2>/dev/null || true
for want in 'SMOKE-DONE Launching skill: [^|]*plug-skill \| Launching skill: proj-skill \|' \
            'CTX\[[^]]*VERIFY-PLUGIN-SKILL-BODY[^]]*VERIFY-PROJ-SKILL-BODY[^]]*VERIFY-PROMPTSUBMIT' \
            'grep-needle-'"$$" 'VERIFY-NESTED' 'sub/file\.txt' \
            'Task #1 created successfully: Verify the binary' 'Updated task #1 status' \
            '#1 \[in_progress\] Verify the binary' \
            'File has not been read yet\. Read it first before writing to it\.' \
            'Applied 2 edits to [^ ]*/edit\.txt' \
            'VERIFY-HOOK-DENY' 'refused by loadguard' \
            'CTX\[[^]]*VERIFY-AGENT-BODY[^]]*VERIFY-PROJ-SKILL-BODY[^]]*VERIFY-SKILLETOR-SKILL-BODY' \
            'CTX\[[^]]*VERIFY-CLAUDEMD[^]]*VERIFY-PROMPTSUBMIT[^]]*VERIFY-SESSIONSTART'; do
  grep -qE -- "$want" <<< "$out" || fail "claude raid: no /$want/ in: $out"
done
[ "$(cat "$cc/edit.txt")" = "$(printf 'ALPHA\nGAMMA')" ] \
  || fail "claude raid: edit.txt is not ALPHA/GAMMA after multi_edit and edit_file: $(cat "$cc/edit.txt")"
grep -q '"tool_name":"Glob"' "$cc/post-tool.jsonl" 2>/dev/null \
  || fail "claude raid: PostToolUse hook did not log the glob call: $(cat "$cc/post-tool.jsonl" 2>&1)"
echo "claude: raid (skill tool on a plugin and a project skill, nested CLAUDE.md, glob, grep without rg, task tools, read before write, multi_edit + edit_file, hooks, loadguard gate, agent tool with skilletor briefing): OK"

# Permissions without anyone to ask: plan mode refuses a write and cannot
# leave plan mode; default mode refuses bash and enter_plan_mode -- each in
# Claude Code's words, raider's reason after them.
cat > "$work/scenarios/plan.json" <<'JSON'
[ ["write_file", {"path": "plan-out.txt", "content": "x"}],
  ["exit_plan_mode", {"plan": "write plan-out.txt"}] ]
JSON
printf '[["bash",{"command":"touch default-out.txt"}],["enter_plan_mode",{}]]' > "$work/scenarios/default.json"
out=$(ccrun -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" --no-session \
        --permission-mode plan --json "scenario=plan") || fail "plan-mode raid exited $?: $out"
grep -qE "SMOKE-DONE Permission to use write_file has been denied\. Reason: plan mode: .* \| Permission to use exit_plan_mode has been denied\. Reason: nobody can approve the plan in this run" <<< "$out" \
  || fail "plan-mode raid: write_file and exit_plan_mode not refused in: $out"
[ ! -e "$cc/plan-out.txt" ] || fail "plan mode: write_file ran"
out=$(ccrun -e openai -k fake -m fake -o "url=http://127.0.0.1:$port/v1" --no-session \
        --json "scenario=default") || fail "default-mode raid exited $?: $out"
grep -qE "SMOKE-DONE Permission to use bash with command touch default-out\.txt has been denied\. Reason: default mode asks .*nobody can approve it in this run.* \| Permission to use enter_plan_mode has been denied\. Reason: default mode asks before this call: enter_plan_mode switches the session to plan mode.*nobody can approve it in this run" <<< "$out" \
  || fail "default-mode raid: bash and enter_plan_mode not refused in: $out"
[ ! -e "$cc/default-out.txt" ] || fail "default mode, nobody to ask: bash ran"
echo "claude: permissions (plan mode refuses write_file and exit_plan_mode, default mode refuses bash and enter_plan_mode): OK"

# LOADGUARD_CONFINE=1: the raider starts itself again in a systemd user scope
# -- the binary itself, never "perl <binary>" -- and its bash runs in there.
# Needs a user manager with the memory controller; a build container has
# none, then the check is skipped and says so.
ctl="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if command -v systemd-run >/dev/null && [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ] \
   && grep -qw memory "$ctl" 2>/dev/null; then
  printf '[["bash",{"command":"cat /proc/self/cgroup"}]]' > "$work/scenarios/confine.json"
  out=$(LOADGUARD_CONFINE=1 run -r "$work/project" -e openai -k fake -m fake \
          -o "url=http://127.0.0.1:$port/v1" --bare --no-session --permission-mode bypassPermissions \
          --json "scenario=confine") \
    || fail "confined raid exited $?: $out"
  grep -q 'loadguard-raider-' <<< "$out" || fail "LOADGUARD_CONFINE=1: bash did not run in the scope: $out"
  echo "loadguard confine (restart in a systemd user scope): OK"
else
  echo "loadguard confine: SKIPPED (no systemd user manager with the memory controller here)"
fi

# --- 8. a configured MCP stdio server (ADR 0029) ----------------------------------
# The packed raider starts a server from `mcp:` of the home config: fork and
# exec of `perl` found on PATH -- the server is a program of its own, never
# the binary run as perl ($^X is not a perl in here) -- the handshake over its
# pipes in the packed IO::Async loop, tools/list, and from tools running
# inside the Future chain: tools/call, and the resource tools
# (list_mcp_resources, read_mcp_resource: Langertha::Raider::MCP::Resources,
# which waits on the loop from inside a tool callback). The server is a
# fake of core modules only (JSON::PP), as the fake OpenAI endpoint is.
cat > "$work/fake-mcp.pl" <<'FAKE'
use strict;
use warnings;
use JSON::PP;
my $json = JSON::PP->new->canonical;
$| = 1;
open my $pf, '>', $ARGV[0] or die $!;
print $pf $$;
close $pf;
sub reply { print $json->encode( $_[0] )."\n" }
while ( my $line = <STDIN> ) {
  my $msg = eval { $json->decode($line) } or next;
  my ( $id, $method ) = @{$msg}{qw( id method )};
  next unless defined $id && defined $method;
  my $r;
  if ( $method eq 'initialize' ) {
    $r = { protocolVersion => $msg->{params}{protocolVersion},
      capabilities => { tools => {}, resources => {} }, serverInfo => { name => 'verify-mcp', version => '1' } };
  }
  elsif ( $method eq 'tools/list' ) {
    $r = { tools => [ { name => 'echo', description => 'Echoes a word',
      inputSchema => { type => 'object', properties => { word => { type => 'string' } } } } ] };
  }
  elsif ( $method eq 'tools/call' ) {
    $r = { content => [ { type => 'text', text => 'mcp-echo:'.( $msg->{params}{arguments}{word} // '' ).':'.( $ENV{VERIFY_MCP_ENV} // '(unset)' ) } ] };
  }
  elsif ( $method eq 'resources/list' ) {
    $r = { resources => [ { uri => 'file:///verify.txt', name => 'verify.txt', mimeType => 'text/plain' } ] };
  }
  elsif ( $method eq 'resources/read' ) {
    $r = { contents => [ { uri => $msg->{params}{uri}, mimeType => 'text/plain', text => 'mcp-resource-body' } ] };
  }
  else {
    reply({ jsonrpc => '2.0', id => $id, error => { code => -32601, message => "Method '$method' not found" } });
    next;
  }
  reply({ jsonrpc => '2.0', id => $id, result => $r });
}
FAKE
command -v perl >/dev/null || fail "perl is not on PATH (the MCP server of step 8 is run by it)"
mcphome="$work/mcphome"
mkdir -p "$mcphome/.raider" "$work/mcpcwd"
cat > "$mcphome/.raider/config.yml" <<YAML
mcp:
  vm:
    command: perl
    args: [ "$work/fake-mcp.pl", "$work/mcp.pid" ]
    env: { VERIFY_MCP_ENV: from-config }
YAML
cat > "$work/scenarios/mcp.json" <<'JSON'
[ ["mcp__vm__echo", {"word": "ping"}],
  ["list_mcp_resources", {}],
  ["read_mcp_resource", {"server": "vm", "uri": "file:///verify.txt"}] ]
JSON
out=$(cd "$work/mcpcwd" && HOME="$mcphome" run -r "$work/mcpcwd" -e openai -k fake -m fake \
        -o "url=http://127.0.0.1:$port/v1" --no-session --permission-mode bypassPermissions \
        --json "scenario=mcp") \
  || fail "MCP raid exited $?: $out"
for want in 'SMOKE-DONE mcp-echo:ping:from-config' 'file:///verify\.txt' 'mcp-resource-body'; do
  grep -qE -- "$want" <<< "$out" || fail "MCP raid: no /$want/ in: $out"
done
[ -s "$work/mcp.pid" ] || fail "MCP raid: the server never started"
mcp_pid=$(cat "$work/mcp.pid")
for _ in $(seq 50); do kill -0 "$mcp_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$mcp_pid" 2>/dev/null; then fail "MCP raid: server PID $mcp_pid still running after the run"; fi
echo "mcp stdio (home config server via PATH perl, handshake, tools/call, list_mcp_resources + read_mcp_resource, server stopped with the run): OK"

echo "verify: OK"
