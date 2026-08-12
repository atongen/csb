#!/usr/bin/env bats
# Tier 3, the other half: the IPC denies of docs/PLAN-007-escape.md must leave a
# WORKING sandbox. escape.bats asserts the escapes stay closed; this file asserts
# the mach-lookup whitelist still covers what real work needs.
#
# It exists because both names in that whitelist were established by measuring a
# probe harness, and a probe harness only exercises what someone thought to
# probe. DNS was load-bearing and nearly dropped (plan runs 4/5); uid->name
# resolution was missing outright and shipped broken, because no probe called
# getpwuid -- `psql` then failed over EVERY transport with "local user with ID
# 1000 does not exist". Both failures are invisible to Tier 1/2: the dump-only
# tiers validate the profile TEXT, not what the profile permits.
#
# So: one assertion per re-allowed name. Adding a name to the whitelist means
# adding the assertion that justifies it here.
#
#     make test-escape
#
# Real launches, so this cannot run nested and is not part of `make test`.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  CSB="${CSB:-$BATS_TEST_DIRNAME/../../bin/csb}"
  # pwd -P: see escape.bats -- a symlinked ancestor under the real HOME makes
  # the absolute path unreadable from inside the sandbox.
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

  [[ -z "${CSB_SANDBOX:-}" ]] || skip "already inside csb (nested launch is impossible)"
  command -v nix >/dev/null 2>&1 || skip "nix not on PATH"
}

# 3>&- on every launch below: under --filter-egress csb leaves its proxy running
# for the next launch's janitor to reap, and an inherited fd 3 is bats' output
# channel -- the suite would then wait for an EOF the surviving proxy never
# sends. csb must not know that fd 3 means anything, so the harness closes it.
csb_run() {
  run bash -c 'cd "$1" || exit 1; shift; exec "$@" 3>&-' _ "$REPO" \
    "$CSB" -s -E --here -- "$@"
}

@test "usable: uid resolves to a username (opendirectoryd.libinfo)" {
  # getpwuid is a mach service. Without its allow, `id -un` prints the raw uid
  # and libpq refuses to connect at all -- over TCP as well as over a socket.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux carries /etc/passwd in the namespace)"
  local host; host="$(id -un)"
  csb_run /usr/bin/id -un
  assert_success
  # assert_line, not --partial: nix writes warnings to stderr and `run` merges
  # them in, and --partial would match the username inside the repo PATH in one
  # of those warnings -- passing even if resolution had failed.
  assert_line "$host"
}

@test "usable: DNS resolves (dnssd.service + mDNSResponder)" {
  # The two DNS names, plus the mDNSResponder UNIX socket literals the
  # network-outbound class deny would otherwise cut -- measured as load-bearing:
  # the class deny looked unshippable until those literals were added.
  # dscacheutil can exit 0 without resolving anything, so assert on the answer.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux has no seatbelt network filter to break)"
  csb_run /usr/bin/dscacheutil -q host -a name api.anthropic.com
  assert_success
  assert_output --partial "ip_address"
}

@test "usable: --allow-socket reaches a named HOST unix socket" {
  # The flag's own point, and the other half of escape.bats' "/tmp stays denied":
  # a dev setup built on unix sockets (postgres .s.PGSQL.5432) is unreachable
  # under the network-outbound class deny until the operator names the path.
  # Without this assertion the flag can rot to a silent no-op.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux leaves such sockets reachable)"
  command -v nc >/dev/null 2>&1 || skip "no nc"
  # AF_UNIX paths are capped near 104 bytes, so keep it short and out of TMPDIR.
  local hostsock="/tmp/csb-as-host.$$"
  rm -f "$hostsock"
  /usr/bin/nc -lU "$hostsock" >/dev/null 2>&1 &
  local listener=$!
  sleep 1
  run bash -c 'cd "$1" || exit 1; shift; exec "$@" 3>&-' _ "$REPO" \
    "$CSB" -s -E --here --allow-socket "$hostsock" -- \
    bash -c 'echo hi | /usr/bin/nc -U '"$hostsock"'; echo "named=$?"'
  kill "$listener" 2>/dev/null || true
  rm -f "$hostsock"
  assert_output --partial "named=0"
}

@test "usable: --allow-loopback reaches a loopback port nothing named" {
  # The flag's own point: under --filter-egress a kernel-assigned port cannot be
  # named by --allow-port, so a test runner talking to its helper over 127.0.0.1
  # is refused (macOS) or dropped (Linux, hence the timeout). Without this
  # assertion the flag can rot to a silent no-op.
  #
  # Both ends run INSIDE the sandbox, which is the case the flag exists for and
  # the only one that holds on Linux, where the namespace's loopback is private
  # -- a host-side listener is unreachable there no matter what nft allows.
  # csb-proxy is the listener because the repo already builds one that binds
  # 127.0.0.1:0 and announces its port; a CONNECT to a host its allowlist does
  # not name is answered without dialling anything, so the 403 proves a complete
  # loopback round trip and nothing else.
  local proxy="$REPO/ocaml/_build/default/bin/csb_proxy_cli.exe"
  [[ -x "$proxy" ]] || skip "proxy not built: run 'make ocaml-build'"
  local probe="$REPO/test/escape/loopback-probe.sh"

  # listener=up is asserted in BOTH runs, so the negative below means "the dial
  # was blocked" rather than "the probe fell over before dialling".
  run bash -c 'cd "$1" || exit 1; shift; exec "$@" 3>&-' _ "$REPO" \
    "$CSB" -s -E --here --filter-egress --allow-host api.anthropic.com -- \
    bash "$probe" "$proxy"
  assert_output --partial "listener=up"
  refute_output --partial "reply=HTTP/1.1 403"

  run bash -c 'cd "$1" || exit 1; shift; exec "$@" 3>&-' _ "$REPO" \
    "$CSB" -s -E --here --filter-egress --allow-host api.anthropic.com \
    --allow-loopback -- bash "$probe" "$proxy"
  assert_output --partial "listener=up"
  assert_output --partial "reply=HTTP/1.1 403"
}

@test "usable: outbound TCP+TLS to the claude API works" {
  # The point of re-allowing IP egress under the network-outbound deny. Any HTTP
  # status proves DNS + TCP + TLS; the endpoint 404s without a token, and curl
  # reports 000 when it never got a response at all.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux has no seatbelt network filter to break)"
  csb_run /usr/bin/curl -sS -o /dev/null -w '%{http_code}' https://api.anthropic.com/
  assert_success
  refute_output "000"
}
