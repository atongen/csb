#!/usr/bin/env bats
# Tier 1: flag/profile/env precedence. The *_cli tracking is subtle and easy to
# break -- these assert the resolved decision via --dump-config.

load helpers

# --- paranoid ----------------------------------------------------------------

@test "CLI --paranoid beats profile paranoid=false" {
  write_profile p "paranoid=false"
  dump_config -p p --paranoid
  assert_success
  assert_line "paranoid=true"
}

@test "CLI --no-paranoid beats profile paranoid=true" {
  write_profile p "paranoid=true"
  dump_config -p p --no-paranoid
  assert_success
  assert_line "paranoid=false"
}

@test "profile paranoid=true applies with no CLI override" {
  write_profile p "paranoid=true"
  dump_config -p p
  assert_line "paranoid=true"
}

# --- pasteboard (macOS pbcopy/pbpaste; PLAN-007 F2) --------------------------

@test "pasteboard defaults off" {
  dump_config
  assert_success
  assert_line "pasteboard=false"
}

@test "CLI --pasteboard beats profile pasteboard=false" {
  write_profile p "pasteboard=false"
  dump_config -p p --pasteboard
  assert_success
  assert_line "pasteboard=true"
}

@test "CLI --no-pasteboard beats profile pasteboard=true" {
  write_profile p "pasteboard=true"
  dump_config -p p --no-pasteboard
  assert_success
  assert_line "pasteboard=false"
}

@test "profile pasteboard=true applies with no CLI override" {
  write_profile p "pasteboard=true"
  dump_config -p p
  assert_line "pasteboard=true"
}

# --- allow_loopback (widen --filter-egress to every loopback port) -----------

@test "allow_loopback defaults off" {
  dump_config
  assert_success
  assert_line "allow_loopback=false"
}

@test "CLI --allow-loopback beats profile allow_loopback=false" {
  write_profile p "allow_loopback=false"
  dump_config -p p --allow-loopback
  assert_success
  assert_line "allow_loopback=true"
}

@test "CLI --no-allow-loopback beats profile allow_loopback=true" {
  write_profile p "allow_loopback=true"
  dump_config -p p --no-allow-loopback
  assert_success
  assert_line "allow_loopback=false"
}

@test "profile allow_loopback=true applies with no CLI override" {
  write_profile p "allow_loopback=true"
  dump_config -p p
  assert_line "allow_loopback=true"
}

# --- nix_target (which devShells.<system>.NAME to run under) -----------------

@test "nix_target defaults empty, resolving to the flake's default" {
  dump_config
  assert_success
  assert_line "nix_target="
  assert_line "nix_target_effective=default"
}

@test "CLI --nix-target beats a profile nix_target=" {
  write_profile p "nix_target=release"
  dump_config -p p --nix-target ci
  assert_success
  assert_line "nix_target=ci"
  assert_line "nix_target_effective=ci"
}

@test "CLI --no-nix-target clears every profile nix_target key" {
  write_profile p "nix_target=ci" "nix_target_shell=dev" "nix_target_agent=rel"
  dump_config -p p --no-nix-target
  assert_success
  assert_line "nix_target="
  assert_line "nix_target_shell="
  assert_line "nix_target_agent="
  assert_line "nix_target_effective=default"
}

@test "profile nix_target= applies with no CLI override" {
  write_profile p "nix_target=ci"
  dump_config -p p
  assert_line "nix_target_effective=ci"
}

@test "nix_target_agent beats nix_target in agent mode" {
  write_profile p "nix_target=ci" "nix_target_agent=rel"
  dump_config -p p
  assert_line "nix_target_effective=rel"
}

@test "nix_target_shell beats nix_target in shell mode" {
  write_profile p "nix_target=ci" "nix_target_shell=dev"
  dump_config -p p -s
  assert_line "nix_target_effective=dev"
}

@test "a mode-specific nix target does not leak into the other mode" {
  write_profile p "nix_target_shell=dev"
  dump_config -p p
  assert_line "nix_target_effective=default"
  dump_config -p p -s
  assert_line "nix_target_effective=dev"
}

@test "--nix-target-shell only takes effect under -s" {
  dump_config --nix-target-shell dev
  assert_line "nix_target_effective=default"
  dump_config --nix-target-shell dev -s
  assert_line "nix_target_effective=dev"
}

# --- sandbox (--no-sandbox / profile sandbox=) -------------------------------

@test "CLI --sandbox beats profile sandbox=false" {
  write_profile p "sandbox=false" "shell=true"
  dump_config -p p --sandbox
  assert_success
  assert_line "sandbox=true"
}

@test "CLI --no-sandbox beats profile sandbox=true (shell)" {
  write_profile p "sandbox=true" "shell=true"
  dump_config -p p --no-sandbox
  assert_success
  assert_line "sandbox=false"
}

@test "profile sandbox=false applies with no CLI override" {
  write_profile p "sandbox=false" "shell=true"
  dump_config -p p
  assert_success
  assert_line "sandbox=false"
}

# --- real_home (--real-home / profile real_home=) ----------------------------

@test "CLI --real-home beats profile real_home=false" {
  write_profile p "real_home=false"
  dump_config -p p --real-home
  assert_line "real_home=true"
}

@test "CLI --per-repo beats profile real_home=true" {
  write_profile p "real_home=true"
  dump_config -p p --per-repo
  assert_line "real_home=false"
}

@test "profile real_home=true applies with no CLI override" {
  write_profile p "real_home=true"
  dump_config -p p
  assert_line "real_home=true"
}

@test "CLI --real-home suppresses a profile ns= (same HOME axis)" {
  write_profile p "ns=fromprofile"
  dump_config -p p --real-home
  assert_line "real_home=true"
  assert_line "namespace="
}

# --- latest (also CSB_LATEST env default) ------------------------------------

@test "CSB_LATEST defaults latest on" {
  export CSB_LATEST=1
  dump_config --here
  assert_line "latest=true"
}

@test "--no-latest overrides the CSB_LATEST default" {
  export CSB_LATEST=1
  dump_config --here --no-latest
  assert_line "latest=false"
}

@test "-L overrides a profile latest=false" {
  write_profile p "latest=false"
  dump_config -p p -L
  assert_line "latest=true"
}

# --- verbose (same shape as latest) ------------------------------------------

@test "CSB_VERBOSE defaults verbose on" {
  export CSB_VERBOSE=1
  dump_config --here
  assert_line "verbose=true"
}

@test "--no-verbose overrides the CSB_VERBOSE default" {
  export CSB_VERBOSE=1
  dump_config --here --no-verbose
  assert_line "verbose=false"
}

# --- namespace ---------------------------------------------------------------

@test "--ns NAME beats a profile ns=" {
  write_profile p "ns=fromprofile"
  dump_config -p p --ns fromcli
  assert_line "namespace=fromcli"
}

@test "--per-repo clears a profile ns=" {
  write_profile p "ns=fromprofile"
  dump_config -p p --per-repo
  assert_line "namespace="
}

@test "--per-repo retracts whichever selector the layer below used" {
  write_profile p "ephemeral=true"
  dump_config -p p --per-repo
  assert_line "ephemeral=false"
  assert_line "namespace="
  assert_line "real_home=false"
}

@test "--per-repo and an explicit HOME selector are mutually exclusive" {
  dump_config --per-repo --real-home
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "a positive CLI selector still takes the whole axis from a profile" {
  write_profile p "real_home=true"
  dump_config -p p --ns fromcli
  assert_line "namespace=fromcli"
  assert_line "real_home=false"
}

# --- .local overlay ----------------------------------------------------------

@test "a scalar in .local wins over the base profile" {
  write_profile p "paranoid=false" "ns=base"
  printf 'paranoid=true\n' > "$CSB_PROFILES/p.local"
  dump_config -p p
  assert_line "paranoid=true"
  assert_line "namespace=base"
}

@test "list keys accumulate base + .local (base first)" {
  write_profile p "deny_read=/base/one"
  printf 'deny_read=/local/two\n' > "$CSB_PROFILES/p.local"
  dump_config -p p
  assert_line "deny_read=/base/one|/local/two"
}

# --- args --------------------------------------------------------------------

@test "-- ARGS on the CLI replaces a profile args=" {
  write_profile p "args=--model sonnet"
  dump_config -p p -- --model opus
  assert_line "agent_args=--model|opus"
}

@test "profile args= is used when no -- ARGS are given" {
  write_profile p "args=--model sonnet"
  dump_config -p p
  assert_line "agent_args=--model|sonnet"
}

# --- a launch naming no BRANCH is a launch HERE -------------------------------

@test "bare csb (no BRANCH, no flags) resolves to --here" {
  dump_config
  assert_success
  assert_line "mode=launch"
  assert_line "here=true"
  assert_line "branch="
}

@test "bare -p NAME (no BRANCH) resolves to --here" {
  write_profile p "ns=x"
  dump_config -p p
  assert_line "here=true"
  assert_line "namespace=x"
}

@test "a launch-only flag with no BRANCH resolves to --here too" {
  # -s used to be silently dropped here: the run listed worktrees and ignored
  # the flag that said a shell was wanted.
  dump_config -s
  assert_success
  assert_line "here=true"
  assert_line "shell=true"
}

@test "an explicit BRANCH still wins over the implication" {
  dump_config somebranch
  assert_success
  assert_line "here=false"
  assert_line "branch=somebranch"
}

@test "a profile here=false with no BRANCH is refused, not silently listed" {
  # The implication is declined and nothing answers "what should run", so the
  # resolution dies naming the flag that does answer it.
  write_profile p "here=false"
  dump_config -p p
  assert_failure
  assert_output --partial "nothing to launch"
  assert_output --partial "-l/--list"
}

@test "--no-here with no BRANCH is refused the same way" {
  write_profile p "ns=x"
  dump_config -p p --no-here
  assert_failure
  assert_output --partial "nothing to launch"
}

@test "here=false is honoured, not refused, when a BRANCH answers the question" {
  write_profile p "here=false"
  dump_config -p p somebranch
  assert_success
  assert_line "here=false"
  assert_line "branch=somebranch"
}

# --- -l/--list: the worktree listing, now a mode of its own -------------------

@test "-l/--list selects the worktree list mode" {
  dump_config --list
  assert_success
  assert_line "mode=list_wt"
  assert_line "here=false"
  assert_line "branch="

  dump_config -l
  assert_success
  assert_line "mode=list_wt"
}

@test "--list takes no BRANCH" {
  dump_config --list somebranch
  assert_failure
  assert_output --partial "takes no BRANCH argument"
}

@test "--list and --here are mutually exclusive" {
  dump_config --list --here
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--list and the other list/delete modes are mutually exclusive" {
  dump_config --list --list-ns
  assert_failure
  assert_output --partial "mutually exclusive"

  dump_config --list -d somebranch
  assert_failure
  assert_output --partial "mutually exclusive"

  dump_config --list --reap
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--list is unaffected by a profile here=true" {
  # A profile is a launch config; naming a mode on the CLI is not a launch.
  write_profile p "here=true"
  dump_config -p p --list
  assert_success
  assert_line "mode=list_wt"
}

# --- agent (which agent CLI runs) --------------------------------------------

@test "the agent defaults to claude, and the adapter answers with it" {
  dump_config
  assert_success
  assert_line "agent=claude"
  assert_line "agent_bin_attr=claude"
  assert_line "token_env=CLAUDE_CODE_OAUTH_TOKEN"
  assert_line "seed=json_merge:.claude/.claude.json"
}

@test "a profile agent= is honoured" {
  write_profile p "agent=claude"
  dump_config -p p
  assert_success
  assert_line "agent=claude"
}

@test "CLI --agent beats a profile agent=" {
  write_profile p "agent=claude"
  dump_config -p p --agent claude
  assert_success
  assert_line "agent=claude"
}

@test "the agent's quiet knobs are the lowest setenv layer" {
  write_profile p "setenv=DISABLE_AUTOUPDATER=0"
  dump_config -p p
  assert_success
  # A named VAR goes to the highest layer that sets it -- and to that layer's
  # position, so the overridden knob moves to the end -- and the other survives.
  assert_line "setenv=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_AUTOUPDATER"
}

# --- token_env (which variable carries the credential) -----------------------

@test "a profile token_env= replaces the agent's own variable" {
  write_profile p "token_env=OPENROUTER_API_KEY"
  dump_config -p p
  assert_success
  assert_line "token_env=OPENROUTER_API_KEY"
}

@test "CLI --token-env beats a profile token_env=" {
  write_profile p "token_env=FROM_PROFILE"
  dump_config -p p --token-env FROM_CLI
  assert_success
  assert_line "token_env=FROM_CLI"
}

@test "--no-token-env falls back to the agent's own variable" {
  write_profile p "token_env=FROM_PROFILE"
  dump_config -p p --no-token-env
  assert_success
  assert_line "token_env=CLAUDE_CODE_OAUTH_TOKEN"
}

# --- multiple -p: each its own layer, folded left to right --------------------

@test "two profiles both apply, the later one winning a scalar" {
  write_profile a "accent=blue" "paranoid=true"
  write_profile b "accent=magenta"
  dump_config -p a -p b
  assert_success
  assert_line "accent=magenta"
  assert_line "paranoid=true"
  assert_line "profile=a|b"
}

@test "reversing the order reverses which profile wins the scalar" {
  write_profile a "accent=blue"
  write_profile b "accent=magenta"
  dump_config -p b -p a
  assert_line "accent=blue"
  assert_line "profile=b|a"
}

@test "lists union across every profile, in the order named" {
  write_profile a "allow_host=from.a" "deny_read=/from/a"
  write_profile b "allow_host=from.b" "deny_read=/from/b"
  dump_config -p a -p b
  assert_line "allow_host=from.a|from.b"
  assert_line "deny_read=/from/a|/from/b"
}

@test "a later profile's HOME selector replaces an earlier profile's whole axis" {
  # The axis rule is unchanged by there being several profiles: each -p is a
  # layer, and a layer naming any key on the axis retracts the ones below it.
  write_profile a "ns=shared"
  write_profile b "ephemeral=true"
  dump_config -p a -p b
  assert_line "namespace="
  assert_line "ephemeral=true"
}

@test "an earlier profile's HOME selector stands when the later is silent" {
  write_profile a "ns=shared"
  write_profile b "accent=magenta"
  dump_config -p a -p b
  assert_line "namespace=shared"
}

@test "a later profile retracts an earlier profile's scalar with an empty value" {
  write_profile a "token_cmd=op read op://a/token"
  write_profile b "token_cmd="
  dump_config -p a -p b
  assert_line "token_cmd=absent"
}

@test "each profile brings its own .local overlay" {
  write_profile a "accent=blue"
  write_profile a.local "accent=cyan"
  write_profile b "paranoid=true"
  dump_config -p a -p b
  assert_line "accent=cyan"
  assert_line "paranoid=true"
}

@test "the CLI still beats every profile in the stack" {
  write_profile a "accent=blue"
  write_profile b "accent=magenta"
  dump_config -p a -p b --accent green
  assert_line "accent=green"
}

@test "a profile file and a config block stack like two files" {
  write_profile file_p "accent=blue" "allow_port=5432"
  write_config config "[profile block_p]" "accent=magenta" "allow_port=6379"
  export CSB_MAIN_ROOT="/src/work/myrepo"
  dump_config -p file_p -p block_p
  assert_line "accent=magenta"
  assert_line "allow_port=5432|6379"
  assert_line "profile=file_p|block_p"
}

@test "naming the same profile twice is not an error, it just folds twice" {
  # Scalars are idempotent and lists are add-only, so a repeat is harmless
  # rather than a state worth refusing.
  write_profile a "accent=blue" "allow_port=5432"
  dump_config -p a -p a
  assert_success
  assert_line "accent=blue"
  assert_line "allow_port=5432|5432"
}

@test "one missing profile in a stack aborts the whole resolution" {
  write_profile a "accent=blue"
  dump_config -p a -p missing
  assert_failure
  assert_output --partial "profile not found"
}

@test "several -p with no BRANCH still imply --here" {
  write_profile a "accent=blue"
  write_profile b "paranoid=true"
  dump_config -p a -p b
  assert_line "here=true"
}
