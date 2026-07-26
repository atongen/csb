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
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  [[ -z "${CSB_SANDBOX:-}" ]] || skip "already inside csb (nested launch is impossible)"
  command -v nix >/dev/null 2>&1 || skip "nix not on PATH"
}

csb_run() {
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO" \
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

@test "usable: outbound TCP+TLS to the claude API works" {
  # The point of re-allowing IP egress under the network-outbound deny. Any HTTP
  # status proves DNS + TCP + TLS; the endpoint 404s without a token, and curl
  # reports 000 when it never got a response at all.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux has no seatbelt network filter to break)"
  csb_run /usr/bin/curl -sS -o /dev/null -w '%{http_code}' https://api.anthropic.com/
  assert_success
  refute_output "000"
}
