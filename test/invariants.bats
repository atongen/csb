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
