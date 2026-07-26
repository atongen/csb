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

@test "escape: the nix daemon socket is unreachable (F3)" {
  # `nix store info` is a daemon round trip. Reach nix by absolute path: the
  # env scrub is not a boundary and PATH absence is not containment.
  local nixbin
  nixbin="$(command -v nix)"
  csb_run "$nixbin" store info
  assert_failure
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
      "$sdrun" --user --wait --unit=csb-escape-test /bin/true
  systemctl --user reset-failed csb-escape-test 2>/dev/null || true
  assert_failure
}

@test "escape: a real launch still works (positive control)" {
  # Without this, every assert_failure above could be a broken harness rather
  # than containment -- the lesson of PLAN-007's four inconclusive probes.
  csb_run /bin/echo ok
  assert_success
  assert_output --partial ok
}
