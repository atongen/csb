#!/usr/bin/env bats
# Tier 1: source-level invariants. Properties of bin/csb that no launch can
# demonstrate, so they are asserted against the script text instead.

load helpers

CSB_SRC="${CSB_SRC:-$BATS_TEST_DIRNAME/../bin/csb}"

# csb reads the host keychain to seed a session credential but never writes it:
# a bad read fails closed, a bad write corrupts the native login. See the Auth
# section of README.md.

@test "csb makes exactly one keychain call and it is a read" {
  local all reads
  all=$(grep -cE '\bsecurity[[:space:]]+[a-z]' "$CSB_SRC" || true)
  reads=$(grep -cE '\bsecurity[[:space:]]+find-generic-password\b' "$CSB_SRC" || true)
  [ "$reads" -eq 1 ]
  [ "$all" -eq "$reads" ]
}

@test "csb names no keychain-write verb" {
  run grep -nE '(add|delete)-(generic|internet)-password|set-generic-password-partition-list' "$CSB_SRC"
  assert_failure
}

# The aws CLI runs on the HOST, with the operator's own identity: csb reads a
# session out of it and changes nothing there. Three read-only verbs -- the
# export, the sso login that makes the export possible, and the region lookup --
# and no fourth. See docs/PLAN-011-aws.md.

@test "csb runs only the three read-only aws verbs" {
  # A command position, so the quoted commands csb echoes back in its own
  # diagnostics are not miscounted as invocations.
  local body cmd='(^|[(;|&[:space:]])aws[[:space:]]+' all allowed
  body=$(grep -vE '^[[:space:]]*#' "$CSB_SRC")
  all=$(printf '%s\n' "$body" | grep -cE "$cmd[a-z]" || true)
  allowed=$(printf '%s\n' "$body" \
    | grep -cE "$cmd(configure export-credentials|configure get region|sso login)" || true)
  [ "$all" -eq "$allowed" ]
  [ "$all" -gt 0 ]
}
