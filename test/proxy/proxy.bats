#!/usr/bin/env bats
# Egress-proxy tests (docs/PLAN-007-agent-sandbox-again.md section 2).
#
# NOT part of `make test`: that tier is dump-only and hermetic. These start a
# real csb-proxy and drive curl through it. Most cases are still offline -- a
# refused CONNECT never dials upstream -- so only the two ALLOW cases need a
# network, and they skip without one.
#
#     make test-proxy
#
# Requires the proxy to be built: make ocaml-build

bats_require_minimum_version 1.5.0

PROXY="${PROXY:-$BATS_TEST_DIRNAME/../../ocaml/_build/default/bin/csb_proxy_cli.exe}"

setup_file() {
  [[ -x "$PROXY" ]] || { echo "proxy not built: run 'make ocaml-build'" >&2; return 1; }
  DIR="$(mktemp -d "${TMPDIR:-/tmp}/csb-proxy-test.XXXXXX")"
  export DIR
  printf '# a comment\nraw.githubusercontent.com\n*.github.com\n' >"$DIR/allow"
  mkfifo "$DIR/portfifo"
  "$PROXY" "$DIR/allow" >"$DIR/portfifo" 2>"$DIR/log" &
  echo $! >"$DIR/pid"
  # Blocks until the proxy announces its port -- the same handshake the launcher
  # uses, and it needs no sleep.
  PORT="$(head -1 <"$DIR/portfifo")"
  echo "$PORT" >"$DIR/port"
  export PORT
}

teardown_file() {
  [[ -f "$DIR/pid" ]] && kill "$(cat "$DIR/pid")" 2>/dev/null
  rm -rf "$DIR"
}

setup() {
  DIR="$DIR"; PORT="$(cat "$DIR/port")"
}

# Echo curl's HTTP status, or its error text when the tunnel is refused.
via_proxy() {
  curl -sS -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' \
    --max-time 20 "$@" 2>&1
}

have_net() {
  curl -sS --max-time 10 -o /dev/null https://raw.githubusercontent.com/ 2>/dev/null
}

@test "allowed exact host tunnels a real TLS request" {
  have_net || skip "no network"
  run via_proxy https://raw.githubusercontent.com/atongen/csb/HEAD/README.md
  [[ "$output" == *200* ]]
}

@test "allowed wildcard *.github.com matches a subdomain" {
  have_net || skip "no network"
  run via_proxy https://api.github.com/
  [[ "$output" == *200* ]]
}

@test "an unlisted host is refused" {
  run via_proxy https://example.com/
  [[ "$output" == *403* ]]
  grep -q 'DENY host not allowed: example.com' "$DIR/log"
}

@test "an IP literal is refused even though it needs no name lookup" {
  run via_proxy https://1.1.1.1/
  [[ "$output" == *403* ]]
  grep -q 'DENY IP literal not allowed: 1.1.1.1' "$DIR/log"
}

@test "a port other than 443 is refused on an allowed host" {
  run via_proxy https://raw.githubusercontent.com:8443/
  [[ "$output" == *403* ]]
  grep -q 'DENY port not allowed: raw.githubusercontent.com:8443' "$DIR/log"
}

@test "a non-CONNECT (plain http) request is refused" {
  run via_proxy http://raw.githubusercontent.com/
  [[ "$output" == *403* ]]
  grep -q 'DENY only CONNECT is proxied (got GET)' "$DIR/log"
}

@test "the wildcard does not match the bare parent domain" {
  run via_proxy https://github.com/
  [[ "$output" == *403* ]]
  grep -q 'DENY host not allowed: github.com' "$DIR/log"
}

@test "a comment line in the allowlist is not a host" {
  run via_proxy https://comment/
  [[ "$output" == *403* ]]
}
