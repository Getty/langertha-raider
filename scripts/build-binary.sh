#!/usr/bin/env bash
# Build a standalone `raider` binary with PAR::Packer (pp): one file that runs
# on a Linux box with no Perl installed (runtime libs: check-binary-libs.sh --list).
#
# Run from the checkout root. Requires perl with raider's dependencies
# (cpanm --installdeps .), IO::Async::SSL, and PAR::Packer on PATH/PERL5LIB.
#
#   RAIDER_BIN_OUT        output file (default ./raider)
#   RAIDER_BIN_EXTRA_INC  colon-separated extra @INC dirs searched after lib/,
#                         e.g. a langertha checkout's lib/ when the installed
#                         Langertha is older than what raider needs:
#                         RAIDER_BIN_EXTRA_INC=$HOME/dev/langertha/lib
#                         Unset (the default, and what CI does) the build uses
#                         only lib/ and the installed modules.
#
# The pp recipe and its traps are those of karr's binary
# (~/dev/karr/.claude/skills/karr-single-binary/references/pp-recipe.md);
# the raider-specific ones are commented where they are handled.
# scripts/verify-binary.sh is what proves a build: pp exits 0 on a binary
# that only dies at runtime.
set -euo pipefail

OUT="${RAIDER_BIN_OUT:-./raider}"

[ -f bin/raider ] && [ -d share/packs ] \
  || { echo "ERROR: run from the checkout root (no bin/raider or share/packs)" >&2; exit 1; }

inc=(-I lib)
perl_inc=(-Ilib)
extra=()
if [ -n "${RAIDER_BIN_EXTRA_INC:-}" ]; then
  IFS=: read -r -a extra <<< "$RAIDER_BIN_EXTRA_INC"
  for d in "${extra[@]}"; do
    [ -d "$d" ] || { echo "ERROR: RAIDER_BIN_EXTRA_INC: no such directory: $d" >&2; exit 1; }
    inc+=(-I "$d")
    perl_inc+=("-I$d")
  done
fi

# Must load, or the binary is broken in a way no --help shows:
#   IO::Async::SSL        Net::Async::HTTP loads it by string on the first
#                         https:// request -- every cloud API. It is only a
#                         *recommends* of Langertha and Net::Async::HTTP, so a
#                         plain --installdeps does not bring it.
#   Mozilla::CA           the CA bundle IO::Socket::SSL falls back to when the
#                         target's OpenSSL dir has no certificates.
#   LWP::Protocol::https  the https handler of Langertha's synchronous LWP path.
for m in IO::Async::SSL Mozilla::CA LWP::Protocol::https; do
  perl "${perl_inc[@]}" -M"$m" -e1 2>/dev/null \
    || { echo "ERROR: $m is not installed; cpanm $m before building." >&2; exit 1; }
done

# -M only what is installed: -M on an absent module aborts pp.
#   JSON backends  JSON::MaybeXS picks one at runtime by string.
#   IO::Async loop IO::Async::Loop->new loads the best loop class by string
#                  (Epoll/EV when present, else Poll/Select).
#   Mojo reactor   MCP::Server is Mojo-based; Mojo::IOLoop loads its reactor
#                  (EV when present, else Poll) by string.
optional=()
for m in Cpanel::JSON::XS JSON::XS \
         IO::Async::Loop::Epoll IO::Async::Loop::EV EV Mojo::Reactor::EV; do
  perl "${perl_inc[@]}" -M"$m" -e1 >/dev/null 2>&1 && optional+=(-M "$m")
done

# File::ShareDir trees. pp packs none on its own; each goes where an installed
# dist's share lands (auto/share/dist/<Dist> below an @INC dir -- $PAR_TEMP/inc/lib
# at runtime), so File::ShareDir::dist_dir/dist_file find it:
#   Langertha-Raider  share/packs, the bundled packs (Langertha::Raider::Packs).
#                     Its fallback -- share/ next to the lib/ it loaded from --
#                     has no checkout to find inside the binary.
#   Langertha         the OpenAPI specs the engines read via dist_file. From a
#                     langertha checkout on RAIDER_BIN_EXTRA_INC when there is
#                     one (its share/ sits beside its lib/), otherwise from the
#                     installed dist.
langertha_share=
for d in "${extra[@]}"; do
  if [ -f "$d/Langertha.pm" ] && [ -d "$d/../share" ]; then
    langertha_share=$(cd "$d/../share" && pwd)
    break
  fi
done
if [ -z "$langertha_share" ]; then
  langertha_share=$(perl -MFile::ShareDir=dist_dir -e 'print dist_dir("Langertha")')
fi
[ -d "$langertha_share" ] || { echo "ERROR: Langertha share dir not found: $langertha_share" >&2; exit 1; }

# Every module of this dist and of Langertha core, named one by one, because
# much of both is loaded by name at runtime and the static scanner never sees
# it: engines (EngineResolver require_module), plugins (PluginHost use_module),
# specs (use_module), roles (Moose `with` strings). Named from file lists, not
# with a 'Langertha::**' glob: a glob searches all of @INC and drags in
# whatever else lives under Langertha:: there -- sibling dists such as
# Langertha::Knarr with their own dependency trees, or the stale
# Langertha::Raider* an older Langertha release still carried.
#   this dist  every .pm under lib/Langertha (Langertha::Raid* too: the CLI does
#              not load them, but the binary carries the whole engine). The
#              App::Raider* reserved stubs stay out; nothing loads them.
#   core       the installed Langertha's own files, from its .packlist; or,
#              when Langertha loads from a checkout (RAIDER_BIN_EXTRA_INC),
#              every .pm under that checkout's lib/Langertha
pm_to_mod() { sed -e 's#\.pm$##' -e 's#/#::#g'; }
mods=()
while IFS= read -r m; do mods+=(-M "$m"); done \
  < <(cd lib && find Langertha -name '*.pm' | sort | pm_to_mod)
core_dir=$(perl "${perl_inc[@]}" -MLangertha -e '(my $d = $INC{"Langertha.pm"}) =~ s{/Langertha\.pm\z}{}; print $d')
core_list() {
  if [ -d "$core_dir/../share" ] && [ -f "$core_dir/../cpanfile" ]; then
    (cd "$core_dir" && find Langertha -name '*.pm')
    return
  fi
  local packlist
  packlist=$(perl -e 'for (@INC) { my $p = "$_/auto/Langertha/.packlist"; if (-f $p) { print $p; last } }')
  [ -n "$packlist" ] || { echo "ERROR: no .packlist for the installed Langertha under @INC" >&2; exit 1; }
  sed -n "s#^$core_dir/\\(Langertha/.*\\.pm\\)\$#\\1#p" "$packlist"
}
core=$(core_list)
[ -n "$core" ] || { echo "ERROR: found no Langertha core modules below $core_dir" >&2; exit 1; }
while IFS= read -r m; do mods+=(-M "$m"); done \
  < <(printf '%s\n' "$core" \
        | grep -v -e '^Langertha/Raider' -e '^Langertha/Raid/' -e '^Langertha/Raid\.pm$' \
        | sort | pm_to_mod)
mods+=(-M Langertha)

# PAR_VERBATIM=1: pp's default PodStrip filter corrupts files whose POD is
#   interleaved with code (=attr/=method under [@Author::GETTY]) -- a module
#   then ends inside POD and "did not return a true value". Verbatim is the fix.
# -I lib: the checkout's modules; raider itself is not installed in CI.
# The dependencies below load what they need by name at runtime:
#   XS::Parse::Sublike/Keyword  Future::AsyncAwait's XS boot requires them.
#   attributes            Cpanel::JSON::XS's XS boot requires it; missing, the
#                         boot dies half-way and the next JSON call segfaults.
#                         pp reaches it only through incidental modules.
#   LWP::Protocol::*      LWP loads the scheme handler by name.
#   MCP::Run::**          the bash tool's server and its compress filters.
#   Metrics::Any::Adapter::**  Net::Async::HTTP's metrics adapter, by name.
#   IO::Async::**         IO::Async::Internals::Connector (every outgoing
#                         connect) and IO::Async::OS::linux load by name; a
#                         binary without them hangs on its first HTTP request.
#   Moose / Class::MOP    their meta classes and traits load by name.
#   MooseX::NonMoose::**  its meta roles, by name (Langertha's engine bases).
#   JSON::Schema::Modern::**, MooX::TypeTiny::**  OpenAPI::Modern (Role::OpenAPI)
#                         loads its vocabularies and Moo accessor roles by name.
#   Path::IsDev::**, Path::FindDev::**  File::ShareDir::ProjectDistDir (every
#                         engine's openapi_file) loads its heuristics by name.
#   Type::Tiny & co.      Types::Standard loads its parametrised types
#                         (Types::Standard::Tuple, ...) on first use, by name.
#   YAML::PP::**          its schema and loader classes, by name.
# -X Term::ReadLine::Gnu: left out on purpose. It links libreadline, which a
#   bare target need not have; the REPL falls back to IO::Prompt::Tiny.
# -X the Brotli codecs and Net::LibIDN: optional extras that HTTP::Message and
#   URI::Escape::XS try inside an eval when installed. Packed, each would add a
#   target lib (libbrotli*, libidn) for nothing raider uses.
# No Net::Async::WebSearch::** glob: WebTools uses its four providers by name
#   (use lines pp sees); the others -- Yandex links libxml2 -- stay out.
PAR_VERBATIM=1 pp -o "$OUT" \
  "${inc[@]}" \
  "${mods[@]}" \
  -X Term::ReadLine::Gnu -X IO::Compress::Brotli -X IO::Uncompress::Brotli -X Net::LibIDN \
  -M JSON::MaybeXS -M JSON::PP -M attributes "${optional[@]}" \
  -M YAML::PP -M 'YAML::PP::**' -M YAML::XS \
  -M Data::MessagePack \
  -M Module::Runtime -M Module::Pluggable::Object \
  -M Future::AsyncAwait -M XS::Parse::Sublike -M XS::Parse::Keyword \
  -M Moose -M 'Moose::**' -M 'Class::MOP::**' -M 'MooseX::NonMoose::**' \
  -M OpenAPI::Modern -M 'JSON::Schema::Modern::**' -M 'MooX::TypeTiny::**' \
  -M 'Type::Tiny::**' -M 'Types::Standard::**' -M 'Type::Coercion::**' -M 'Eval::TypeTiny::**' \
  -M IO::Async::Loop -M 'IO::Async::**' -M IO::Async::SSL \
  -M Net::Async::HTTP -M 'Net::Async::HTTP::**' \
  -M 'Metrics::Any::Adapter::**' \
  -M Net::Async::MCP -M 'Net::Async::MCP::Transport::**' \
  -M Net::Async::WebSearch \
  -M MCP::Server -M MCP::Run -M 'MCP::Run::**' \
  -M Mojo::Reactor::Poll \
  -M IO::Socket::SSL -M Net::SSLeay -M Mozilla::CA \
  -M LWP::UserAgent -M LWP::Protocol::http -M LWP::Protocol::https \
  -M Term::ReadLine \
  -M File::ShareDir -M File::ShareDir::ProjectDistDir -M 'Path::IsDev::**' -M 'Path::FindDev::**' \
  -a "share;lib/auto/share/dist/Langertha-Raider" \
  -a "$langertha_share;lib/auto/share/dist/Langertha" \
  bin/raider

chmod +x "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
