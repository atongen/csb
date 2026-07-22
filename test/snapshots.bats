#!/usr/bin/env bats
# Tier 2: sandbox-spec snapshot tests. For a fixed set of inputs, the generated
# sandbox artifact (seatbelt profile text on macOS, bwrap argv on Linux) is
# normalized and diffed against a committed per-platform golden under
# test/snapshots/<platform>/. A mismatch makes every change to the emitted
# profile visible in review; accept an intentional change with `make test-update`
# (or SNAPSHOT_UPDATE=1 make test) on that platform.

load helpers

@test "snapshot: baseline (--here, branch-derived namespace)" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo"
  assert_success
  assert_snapshot baseline "$repo"
}

@test "snapshot: --paranoid" {
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" --paranoid
  assert_success
  assert_snapshot paranoid "$repo"
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
  # to run claude unsandboxed).
  local repo; repo="$(fake_repo feature/x)"
  dump_sandbox_snapshot "$repo" -s --no-sandbox
  assert_success
  assert_snapshot no-sandbox "$repo"
}
