#!/usr/bin/env bats
# Tier 3: ESCAPE tests. Unlike Tier 1/2 these do a REAL launch and assert that
# the IPC escapes of docs/PLAN-007-escape.md stay closed. Tier 1/2 are dump-only
# -- they validate the artifact csb generates, not the boundary it produces --
# which is exactly why F1 (a full escape to the operator's uid, in both modes,
# for the tool's whole life) was invisible to the suite.
#
# NOT part of `make test`: these need nix, a network, and a real launch, and
# they cannot run nested (sandbox-exec refuses to nest). Run as a pre-release
# gate, from a normal terminal:
#
#     make test-escape
#
# Keep this file SMALL. The only reason to grow it is a newly verified escape.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  CSB="${CSB:-$BATS_TEST_DIRNAME/../../bin/csb}"
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # sandbox-exec cannot nest, and bwrap-in-bwrap is not what these assert.
  [[ -z "${CSB_SANDBOX:-}" ]] || skip "already inside csb (nested launch is impossible)"
  command -v nix >/dev/null 2>&1 || skip "nix not on PATH"
}

# csb_run ARGS... -- a real, sandboxed, shell-mode launch in csb's own repo.
# -E keeps it off the operator's namespace; --here avoids creating a worktree.
csb_run() {
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO" \
    "$CSB" -s -E --here -- "$@"
}

@test "escape: open(1) cannot reach LaunchServices (F1)" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only"
  # The escape proper writes a /tmp .app bundle and `open -g`s it; launching
  # ANY app at all is the capability, so this is the cheap equivalent.
  csb_run /usr/bin/open -g -a Calculator
  assert_failure
}

@test "escape: pbpaste cannot read the host clipboard (F2)" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only"
  csb_run /usr/bin/pbpaste
  assert_failure
}

@test "escape: --pasteboard re-allows pbpaste WITHOUT reopening F1 (row PB)" {
  # The blocking prerequisite for the flag existing at all. If a future macOS
  # makes the pasteboard allows hand LaunchServices a route back, this fails
  # and the flag has to go.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only"
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO" \
    "$CSB" -s -E --here --pasteboard -- /usr/bin/open -g -a Calculator
  assert_failure
}

@test "escape: --pasteboard actually restores pbpaste (the flag's own point)" {
  # Without this the flag can rot to a silent no-op: the row PB test above only
  # checks that it does not reopen F1. Byte count only -- never the contents of
  # the operator's clipboard.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only"
  local host; host="$(/usr/bin/pbpaste | wc -c | tr -d ' ')"
  [[ "$host" != "0" ]] || skip "host clipboard is empty; nothing to measure"
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO" \
    "$CSB" -s -E --here --pasteboard -- bash -c '/usr/bin/pbpaste | wc -c'
  assert_success
  assert_output --partial "$host"
}

@test "escape: a unix socket in the sandbox's OWN tree works, one in /tmp does not" {
  # The two halves of the own_roots network-outbound re-allow. In-tree sockets
  # are a real workload (Rails tmp/sockets/puma.sock, spring, pg_ctl -k); /tmp is
  # shared with the host, so a socket there may be a host service -- which is
  # F3's shape and must stay denied.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux cuts sockets by mount, per-path)"
  command -v nc >/dev/null 2>&1 || skip "no nc"
  # AF_UNIX paths are capped near 104 bytes, so keep both short.
  local hostsock="/tmp/csb-esc-host.$$"
  rm -f "$hostsock"
  /usr/bin/nc -lU "$hostsock" >/dev/null 2>&1 &
  local listener=$!
  sleep 1

  csb_run bash -c 'S=./.csb-esc-uds.sock; rm -f $S
    (/usr/bin/nc -lU $S >/dev/null 2>&1 &); sleep 1
    echo hi | /usr/bin/nc -U $S; echo "in-tree=$?"
    echo hi | /usr/bin/nc -U '"$hostsock"'; echo "host-tmp=$?"
    rm -f $S'
  kill "$listener" 2>/dev/null || true
  rm -f "$hostsock"
  assert_output --partial "in-tree=0"
  assert_output --partial "host-tmp=1"
}

@test "escape: the nix daemon socket is unreachable (F3)" {
  # `nix store info` is a daemon round trip. Reach nix by absolute path: the
  # env scrub is not a boundary and PATH absence is not containment.
  local nixbin
  nixbin="$(command -v nix)"
  csb_run "$nixbin" store info
  assert_failure
  # `Trusted:` comes from the daemon, so its absence is the round trip failing.
  # `Store URL:` cannot be used -- nix prints that from config, before connecting.
  refute_output --partial "Trusted:"
}

@test "escape: systemd-run --user cannot spawn outside the namespace (F4)" {
  [[ "$(uname -s)" == Linux ]] || skip "Linux only"
  local sdrun
  sdrun="$(command -v systemd-run || echo /run/current-system/sw/bin/systemd-run)"
  [[ -x "$sdrun" ]] || skip "no systemd-run"
  # Set the vars the escape needs: the env scrub removing them is not the fix.
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO" \
    "$CSB" -s -E --here -- env "XDG_RUNTIME_DIR=/run/user/$(id -u)" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" \
      "$sdrun" --user --wait --unit=csb-escape-test /bin/sh -c 'exit 0'
  systemctl --user reset-failed csb-escape-test 2>/dev/null || true
  assert_failure
  # A nonzero exit alone would also be satisfied by a typo or a missing binary,
  # so assert the SPAWN specifically: systemd-run prints this the moment the user
  # manager accepts the unit, which is the escape itself.
  refute_output --partial "Running as unit"
}

@test "escape: a real launch still works (positive control)" {
  # Without this, every assert_failure above could be a broken harness rather
  # than containment -- the lesson of PLAN-007's four inconclusive probes.
  # /bin/sh, not /bin/echo: NixOS ships almost nothing in /bin, and a missing
  # binary is indistinguishable from containment (which is how this test broke).
  csb_run /bin/sh -c 'echo ok'
  assert_success
  assert_output --partial ok
}
