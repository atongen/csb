#!/usr/bin/env bats
# Tier 1: the five read/write/socket lists accumulate from CLI flags, profile vars,
# and both together (CLI first, then profile); leading ~/ expands to $HOME.
#
# The two pair-valued keys below invert that order deliberately: for a path list
# the order is immaterial (they are rules, not steps), but a setenv_cmd= and a
# seed_merge= are APPLIED in order, so the higher layer has to come last to win.

load helpers

# --- accumulation sources (deny_read as the representative) ------------------

@test "deny_read from CLI only" {
  dump_config --here --deny-read /a --deny-read /b
  assert_line "deny_read=/a|/b"
}

@test "deny_read from profile only" {
  write_profile p "deny_read=/a" "deny_read=/b"
  dump_config -p p
  assert_line "deny_read=/a|/b"
}

@test "deny_read from CLI + profile (CLI first)" {
  write_profile p "deny_read=/from/profile"
  dump_config -p p --deny-read /from/cli
  assert_line "deny_read=/from/cli|/from/profile"
}

# --- each of the five lists accumulates CLI + profile ------------------------

@test "allow_write accumulates CLI + profile" {
  write_profile p "allow_write=/from/profile"
  dump_config -p p --allow-write /from/cli
  assert_line "allow_write=/from/cli|/from/profile"
}

@test "allow_socket accumulates CLI + profile" {
  write_profile p "allow_socket=/from/profile.sock"
  dump_config -p p --allow-socket /from/cli.sock
  assert_line "allow_socket=/from/cli.sock|/from/profile.sock"
}

@test "paranoid_deny_read accumulates CLI + profile" {
  write_profile p "paranoid_deny_read=/from/profile"
  dump_config -p p --paranoid --paranoid-deny-read /from/cli
  assert_line "paranoid_deny_read=/from/cli|/from/profile"
}

@test "paranoid_allow_read accumulates CLI + profile" {
  write_profile p "paranoid_allow_read=/from/profile"
  dump_config -p p --paranoid --paranoid-allow-read /from/cli
  assert_line "paranoid_allow_read=/from/cli|/from/profile"
}

# --- normalization -----------------------------------------------------------

@test "a leading ~/ expands to \$HOME (CLI)" {
  dump_config --here --deny-read '~/notes'
  assert_line "deny_read=$HOME/notes"
}

@test "a leading ~/ expands to \$HOME (profile)" {
  write_profile p 'allow_write=~/scratch'
  dump_config -p p
  assert_line "allow_write=$HOME/scratch"
}

@test "an absolute path is passed through unchanged" {
  dump_config --here --deny-read /etc/hosts
  assert_line "deny_read=/etc/hosts"
}

# --- the two keys that carry a pair, not a path ------------------------------

@test "setenv_cmd accumulates CLI + profile, the CLI winning a name" {
  # Same dedupe rule as setenv=: one VAR, kept at its last (highest) mention.
  write_profile p "setenv_cmd=FROM_PROFILE=printf a" "setenv_cmd=SHARED=printf b"
  dump_config -p p --setenv-cmd 'FROM_CLI=printf c' --setenv-cmd 'SHARED=printf d'
  assert_line "setenv_cmd=FROM_PROFILE|FROM_CLI|SHARED"
}

@test "seed_merge accumulates CLI + profile (profile first)" {
  # Unlike setenv_cmd these do NOT dedupe: two merges into one destination is a
  # composition, applied in order, not a conflict.
  printf '{"a":1}\n' > "$TEST_TMP/a.json"
  printf '{"b":2}\n' > "$TEST_TMP/b.json"
  write_profile p "seed_merge=.claude/x.json=$TEST_TMP/a.json"
  dump_config -p p --seed-merge ".claude/x.json=$TEST_TMP/b.json"
  assert_line "seed_merge=.claude/x.json=$TEST_TMP/a.json|.claude/x.json=$TEST_TMP/b.json"
}

@test "a seed_merge appends a json_merge instruction after the agent's own" {
  # Order is the whole point: the agent's onboarding merges first, so an
  # operator key lands on top of it rather than under it.
  printf '{"a":1}\n' > "$TEST_TMP/a.json"
  dump_config --seed-merge ".claude/settings.json=$TEST_TMP/a.json"
  assert_line "seed=json_merge:.claude/.claude.json|json_merge:.claude/settings.json"
}

@test "with no seed_merge the seed list is the agent's alone" {
  dump_config --here
  assert_line "seed=json_merge:.claude/.claude.json"
  assert_line "seed_merge="
}

# --- the emit wire: what bin/csb actually receives ----------------------------
#
# The dumps report a seed's SHAPE. These assert the CONTENT crosses, which is
# the whole of what seed_merge= adds: csb-config reads the host file at
# resolution time so the launch carries the bytes, not a path the sandbox would
# have to reach.

@test "a seed_merge's file content rides the wire as the instruction's arg" {
  printf '{"mcpServers":{"rag":{"command":"x"}}}\n' > "$TEST_TMP/mcp.json"
  emit_records --here --seed-merge ".claude/.claude.json=$TEST_TMP/mcp.json"
  assert_success
  assert_line 'seed_arg={"mcpServers":{"rag":{"command":"x"}}}'
  assert_line "seed_verb=json_merge"
  assert_line "seed_dest=.claude/.claude.json"
}

@test "a seed_merge source keeps its placeholders for bin/csb to substitute" {
  # All three are resolved at LAUNCH, by the only side that knows their values,
  # so they must survive resolution untouched.
  printf '{"cwd":"${CSB_WORKTREE}","home":"${CSB_HOME}","real":"${CSB_REAL_HOME}"}\n' \
    > "$TEST_TMP/ph.json"
  emit_records --here --seed-merge ".claude/x.json=$TEST_TMP/ph.json"
  assert_success
  assert_line 'seed_arg={"cwd":"${CSB_WORKTREE}","home":"${CSB_HOME}","real":"${CSB_REAL_HOME}"}'
}

@test "a multi-line seed_merge source crosses whole" {
  printf '{\n  "a": 1,\n  "b": 2\n}\n' > "$TEST_TMP/multi.json"
  emit_records --here --seed-merge ".claude/x.json=$TEST_TMP/multi.json"
  assert_success
  # One record, newlines intact: only NUL separates records, which is why a NUL
  # in the content is refused.
  assert_output --partial 'seed_arg={'
  assert_output --partial '  "a": 1,'
  assert_output --partial '  "b": 2'
}

@test "the seed triples stay aligned when a seed_merge is added" {
  # bin/csb reads verb/arg/dest back into three arrays and refuses a run whose
  # lengths differ; two instructions must therefore emit two of each.
  printf '{"a":1}\n' > "$TEST_TMP/a.json"
  emit_records --here --seed-merge ".claude/x.json=$TEST_TMP/a.json"
  assert_success
  local verbs dests
  verbs="$(printf '%s\n' "$output" | grep -c '^seed_verb=')"
  dests="$(printf '%s\n' "$output" | grep -c '^seed_dest=')"
  [ "$verbs" -eq 2 ]
  [ "$dests" -eq 2 ]
}

@test "setenv_cmd rides the wire as VAR=command, unredacted" {
  # Emit is the adoption seam, not the operator seam: it redacts nothing, which
  # is why it goes to a private file the caller unlinks.
  emit_records --here --setenv-cmd 'VAULT_TOKEN=op read op://vault/secret'
  assert_success
  assert_line "setenv_cmd=VAULT_TOKEN=op read op://vault/secret"
}

@test "every -p rides the wire as its own profile record" {
  write_profile a "accent=blue"
  write_profile b "paranoid=true"
  emit_records --here -p a -p b
  assert_success
  assert_line "profile=a"
  assert_line "profile=b"
}
