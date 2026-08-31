#!/usr/bin/env bats
# Tier 2: sandbox-spec snapshot tests. For a fixed set of inputs, the generated
# sandbox artifact (seatbelt profile text on macOS, bwrap argv on Linux) is
# normalized and diffed against a committed per-platform golden under
# test/snapshots/<platform>/. A mismatch makes every change to the emitted
# profile visible in review; accept an intentional change with `make test-update`
# (or SNAPSHOT_UPDATE=1 make test) on that platform.

load helpers

@test "snapshot: baseline (--here, per-repo namespace)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo"
  assert_success
  assert_snapshot baseline "$repo"
}

# --filter-egress replaces the blanket IP-egress allow with the proxy port and the
# named local ports. The port is emitted as the stable <PROXY_PORT> placeholder in
# dump mode, so no proxy starts and the golden is reproducible. On macOS that is a
# seatbelt rule change; on Linux (docs/PLAN-009-proxy.md section 4) bwrap gets
# wrapped in a pasta netns plus an nft ruleset, so linux/filter-egress is no longer
# byte-identical to `baseline` the way linux/pasteboard and linux/allow-socket
# still are -- it needs regenerating (`make test-update`, host-side) now that the
# flag enforces there instead of declining.
@test "snapshot: --filter-egress (proxy port + allowed local port)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --filter-egress \
    --allow-host api.anthropic.com --allow-port 5432
  assert_success
  assert_snapshot filter-egress "$repo"
}

# --allow-loopback widens that same case to every loopback port, and the golden is
# what shows the per-port rules going away rather than accumulating: one loopback
# answer per platform, the seatbelt wildcard or the nft `oif "lo" accept`.
@test "snapshot: --allow-loopback (every loopback port, no per-port rules)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --filter-egress \
    --allow-host api.anthropic.com --allow-port 5432 --allow-loopback
  assert_success
  assert_snapshot allow-loopback "$repo"
}

@test "linux: --filter-egress remaps the payload off pasta's uid 0" {
  # pasta spawns its user namespace with the caller mapped to root, so bwrap has
  # to map back or the payload runs as uid 0 (which claude refuses to combine with
  # --dangerously-skip-permissions). The golden holds placeholders; the concrete
  # ids are asserted here, along with their absence when no netns is spawned.
  [[ "$(uname -s)" == Linux ]] || skip "Linux only (macOS filters egress without a netns)"
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --filter-egress
  assert_success
  assert_line "--unshare-user"
  assert_line "--uid"
  assert_line "$(id -u)"
  assert_line "--gid"
  assert_line "$(id -g)"

  dump_sandbox_snapshot "$repo"
  assert_success
  refute_line "--unshare-user"
  refute_line "--uid"
  refute_line "--gid"
}

@test "linux: every IPC broker path present on this host gets a --tmpfs" {
  # The goldens collapse this block to <IPC-TMPFS> because csb emits a --tmpfs
  # only for the paths that exist, which differs per host (a NixOS box has all
  # three; a CI runner often has none). So assert the behaviour here instead of
  # freezing one host's answer into a golden. See PLAN-007 F3/F4.
  [[ "$(uname -s)" == Linux ]] || skip "Linux only (macOS cuts sockets by profile, not by mount)"
  local repo p; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo"
  assert_success
  for p in "/run/user/$(id -u)" /run/dbus /nix/var/nix/daemon-socket; do
    if [[ -d "$p" ]]; then assert_line "$p"; else refute_line "$p"; fi
  done
}

@test "snapshot: --paranoid" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --paranoid
  assert_success
  assert_snapshot paranoid "$repo"
}

@test "snapshot: --pasteboard (macOS re-allows pbcopy/pbpaste; no-op on Linux)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --pasteboard
  assert_success
  assert_snapshot pasteboard "$repo"
}

@test "snapshot: --allow-socket DIR (macOS re-allows the sockets under it; no-op on Linux)" {
  # The path is passed ALREADY realpath'd on purpose: csb emits the resolved
  # spelling plus the as-given one when they differ, and on macOS $HOME sits under
  # the /tmp -> /private/tmp symlink, so the as-given form would carry this run's
  # random mktemp suffix into the golden. Both-spelling emission is asserted
  # behaviourally below instead.
  local repo rhome; repo="$(fake_repo feature/x)"
  rhome="$(realpath "$HOME")"
  mkdir -p "$rhome/sockets"
  dump_sandbox_snapshot "$repo" --allow-socket "$rhome/sockets"
  assert_success
  assert_snapshot allow-socket "$repo"
}

@test "macOS: --allow-socket emits both spellings when they differ" {
  # Seatbelt matches the RESOLVED path, so /private/tmp is the load-bearing rule;
  # the as-given spelling is the cheap half of the mDNSResponder lesson. Asserted
  # on the path strings rather than subpath-vs-literal, so a host that happens to
  # run a postgres on this socket does not change the answer.
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux emits nothing for this flag)"
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --allow-socket /tmp/.s.PGSQL.5432
  assert_success
  assert_output --partial '"/private/tmp/.s.PGSQL.5432"'
  assert_output --partial '"/tmp/.s.PGSQL.5432"'
}

@test "snapshot: --paranoid --paranoid-allow-read DIR" {
  local repo; repo="$(fake_repo feature/x)"
  mkdir -p "$HOME/exposed"
  dump_sandbox_snapshot "$repo" --paranoid --paranoid-allow-read "$HOME/exposed"
  assert_success
  assert_snapshot paranoid-allow-read "$repo"
}

@test "snapshot: --paranoid --paranoid-deny-read DIR" {
  local repo; repo="$(fake_repo feature/x)"
  mkdir -p "$HOME/hidden"
  dump_sandbox_snapshot "$repo" --paranoid --paranoid-deny-read "$HOME/hidden"
  assert_success
  assert_snapshot paranoid-deny-read "$repo"
}

@test "snapshot: --deny-read P --allow-write P (normal mode)" {
  local repo; repo="$(fake_repo feature/x)"
  mkdir -p "$HOME/scratch"
  dump_sandbox_snapshot "$repo" --deny-read "$HOME/scratch" --allow-write "$HOME/scratch"
  assert_success
  assert_snapshot deny-read-allow-write "$repo"
}

@test "snapshot: -E ephemeral (no namespace)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" -E
  assert_success
  assert_snapshot ephemeral "$repo"
}

@test "snapshot: @unscoped namespace" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --ns @shared
  assert_success
  assert_snapshot unscoped-ns "$repo"
}

@test "snapshot: --real-home (real HOME, sandbox on)" {
  # No namespace, no HOME redirect: the deny-list still fences the real HOME,
  # but there is no namespace re-allow and the real HOME is NOT a write root.
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --real-home
  assert_success
  assert_snapshot real-home "$repo"
}

@test "snapshot: --no-sandbox emits no profile (shell only)" {
  # The launch degrades to `env ... path_shim cmd`; --dump-sandbox prints a
  # sentinel instead of a seatbelt profile / bwrap argv. Needs -s (csb refuses
  # to run an agent unsandboxed).
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" -s --no-sandbox
  assert_success
  assert_snapshot no-sandbox "$repo"
}
