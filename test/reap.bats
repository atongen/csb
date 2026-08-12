#!/usr/bin/env bats
# Tier 1: --reap. Hermetic on both axes the harness pins: HOME (where proxy
# ownership stamps live, $HOME/.csb/run) and CSB_TMPDIR (where the litter they
# name lives). The proxy pass reaps by stamp and a stamp names the pid it may
# kill, so nothing here can touch a real process. Only the REPORT pass reaches
# the true process table, so its process count is asserted without a number.

load helpers

# A stand-in csb-proxy: a process whose argv is "<...>/csb-proxy <allowlist>",
# which is what the janitor re-checks a stamped pid against before killing it.
# It outlives this function, so it must hold neither the command substitution's
# stdout pipe (which would block the caller until it exits) nor bats' fd 3
# (which would hang the suite at the end) -- the same leak as the real proxy.
fake_proxy() {
  local allow="$1" dir="$TEST_TMP/fake"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nsleep 300\n' >"$dir/csb-proxy"
  chmod +x "$dir/csb-proxy"
  "$dir/csb-proxy" "$allow" >/dev/null 2>&1 3>&- &
  echo $!
}

dead_pid() {
  local p
  bash -c 'exit 0' &
  p=$!
  wait "$p" || true
  echo "$p"
}

# owner pid, proxy pid, allowlist -- the three lines start_egress_proxy writes.
# Stamps live in $HOME/.csb/run, which the harness isolates by pinning HOME.
write_stamp() {
  mkdir -p "$HOME/.csb/run"
  printf '%s\n%s\n%s\n' "$2" "$3" "$4" >"$HOME/.csb/run/csb-owner.$1"
}

@test "--reap takes no BRANCH" {
  run "$CSB" --reap somebranch
  assert_failure
  assert_output --partial "takes no BRANCH"
}

@test "--reap and -d are mutually exclusive" {
  run "$CSB" --reap -d somebranch
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--reap and --list-ns are mutually exclusive" {
  run "$CSB" --reap --list-ns
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--reap deletes a dead-owner HOME, keeps live and unstamped ones" {
  mkdir "$CSB_TMPDIR/csb-home.deadxx" "$CSB_TMPDIR/csb-home.livexx" \
        "$CSB_TMPDIR/csb-home.nostmp"
  bash -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid" || true
  echo "$dead_pid" > "$CSB_TMPDIR/csb-home.deadxx/.csb-owner"
  echo "$$"        > "$CSB_TMPDIR/csb-home.livexx/.csb-owner"

  run "$CSB" --reap
  assert_success
  assert_output --partial "orphaned egress proxy process(es)"
  assert_output --partial "removed 1 dead-session ephemeral HOME(s)"
  assert_output --partial "left 1 csb-home dir(s) with no owner stamp"
  [ ! -d "$CSB_TMPDIR/csb-home.deadxx" ]
  [ -d "$CSB_TMPDIR/csb-home.livexx" ]
  [ -d "$CSB_TMPDIR/csb-home.nostmp" ]
}

@test "--reap ignores a named -E=NAME HOME even with a dead stamp" {
  mkdir "$CSB_TMPDIR/csb-home-shared"
  bash -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid" || true
  echo "$dead_pid" > "$CSB_TMPDIR/csb-home-shared/.csb-owner"

  run "$CSB" --reap
  assert_success
  assert_output --partial "removed 0 dead-session ephemeral HOME(s)"
  [ -d "$CSB_TMPDIR/csb-home-shared" ]
}

@test "--reap treats a malformed stamp as unstamped" {
  mkdir "$CSB_TMPDIR/csb-home.badpid"
  echo "not-a-pid" > "$CSB_TMPDIR/csb-home.badpid/.csb-owner"

  run "$CSB" --reap
  assert_success
  assert_output --partial "removed 0 dead-session ephemeral HOME(s)"
  assert_output --partial "left 1 csb-home dir(s) with no owner stamp"
  [ -d "$CSB_TMPDIR/csb-home.badpid" ]
}

@test "--reap kills a stamped proxy whose owner is gone, and clears its files" {
  local allow="$CSB_TMPDIR/csb-allow.deadxx" pid owner
  echo "example.com" >"$allow"
  pid="$(fake_proxy "$allow")"
  owner="$(dead_pid)"
  write_stamp deadxx "$owner" "$pid" "$allow"

  run "$CSB" --reap
  assert_success
  assert_output --partial "reaped 1 orphaned egress proxy process(es)"
  sleep 1
  ! kill -0 "$pid" 2>/dev/null
  [ ! -f "$allow" ]
  [ ! -f "$HOME/.csb/run/csb-owner.deadxx" ]
}

@test "--reap leaves a stamped proxy whose owner is alive" {
  local allow="$CSB_TMPDIR/csb-allow.livexx" pid
  echo "example.com" >"$allow"
  pid="$(fake_proxy "$allow")"
  write_stamp livexx "$$" "$pid" "$allow"

  run "$CSB" --reap
  assert_success
  assert_output --partial "reaped 0 orphaned egress proxy process(es)"
  kill -0 "$pid"
  [ -f "$allow" ]
  [ -f "$HOME/.csb/run/csb-owner.livexx" ]
  kill "$pid" 2>/dev/null || true
}

# The guard that a PPID test did not need: a recorded pid may have been reused
# by the time the janitor reads it, so the argv must still match before the kill.
@test "--reap does not kill a reused pid whose argv is not the stamped proxy" {
  local allow="$CSB_TMPDIR/csb-allow.reusex" owner
  echo "example.com" >"$allow"
  sleep 300 >/dev/null 2>&1 3>&- &
  local pid=$!
  owner="$(dead_pid)"
  write_stamp reusex "$owner" "$pid" "$allow"

  run "$CSB" --reap
  assert_success
  assert_output --partial "reaped 0 orphaned egress proxy process(es)"
  kill -0 "$pid"
  # The owner is gone, so its litter still goes -- only the kill is withheld.
  [ ! -f "$allow" ]
  [ ! -f "$HOME/.csb/run/csb-owner.reusex" ]
  kill "$pid" 2>/dev/null || true
}

@test "--reap reports a proxy no stamp claims, and does not kill it" {
  local allow="$CSB_TMPDIR/csb-allow.nostmp" pid
  echo "example.com" >"$allow"
  pid="$(fake_proxy "$allow")"

  run "$CSB" --reap
  assert_success
  # No count: the report pass sees the host's real proxies too.
  assert_output --partial "csb-proxy process(es) with no stamp"
  kill -0 "$pid"
  kill "$pid" 2>/dev/null || true
}

@test "--reap reports an allowlist no stamp claims, and does not remove it" {
  local allow="$CSB_TMPDIR/csb-allow.orphan"
  echo "example.com" >"$allow"

  run "$CSB" --reap
  assert_success
  assert_output --partial "left 1 csb-allow file(s) with no stamp"
  [ -f "$allow" ]
}

@test "--reap treats an unreadable proxy stamp as unowned" {
  mkdir -p "$HOME/.csb/run"
  printf 'not-a-pid\n' >"$HOME/.csb/run/csb-owner.badxxx"

  run "$CSB" --reap
  assert_success
  assert_output --partial "reaped 0 orphaned egress proxy process(es)"
  assert_output --partial "left 1 unreadable csb-proxy stamp(s)"
  [ -f "$HOME/.csb/run/csb-owner.badxxx" ]
}
