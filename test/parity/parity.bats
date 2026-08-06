#!/usr/bin/env bats
# Differential oracle: bin/csb --dump-config vs csb-config, same argv, same
# isolated environment (docs/PLAN-008-proxy.md section 9).
#
#     make test-parity
#
# Requires csb-config to be built: make ocaml-build
#
# Why this exists alongside the 73 example-based tests in test/: those encode an
# expected value someone typed, so a case costs a decision. Here the expectation
# is bin/csb's own answer at run time, so a case costs one line -- which is what
# makes it cheap enough to sweep the grammar's corners rather than its centre.
# It found the `--accent --` divergence pinned at the bottom of this file.
#
# TEMPORARY BY DESIGN. It compares two implementations of one spec, so it dies
# with the second one: once bin/csb delegates its config resolution to
# csb-config, this compares csb-config to itself. Delete it with the bash
# resolution path.

CSB="${CSB:-$BATS_TEST_DIRNAME/../../bin/csb}"
CSB_CONFIG="${CSB_CONFIG:-$BATS_TEST_DIRNAME/../../ocaml/_build/default/bin/csb_config_cli.exe}"

load ../helpers

setup_file() {
  [[ -x "${CSB_CONFIG:-}" ]] \
    || { echo "csb-config not built: run 'make ocaml-build'" >&2; return 1; }
}

# Both binaries prefix diagnostics with their own basename, which is correct in
# each. Normalize that one difference away rather than assert around it.
strip_prog() {
  sed -e "s|^$(basename "$CSB"): |<csb>: |" \
      -e "s|^$(basename "$CSB_CONFIG"): |<csb>: |"
}

# Run one argv through both implementations; require identical stdout+stderr and
# identical exit status. Called bare, like dump_config -- it captures for itself.
assert_parity() {
  local want got want_rc got_rc
  # Half these cases are die paths, and bats runs a test body under errexit: a
  # bare assignment from a failing command would abort the test instead of
  # recording its status. The || branch is what keeps the exit code comparable.
  want="$("$CSB" --dump-config "$@" 2>&1)" && want_rc=0 || want_rc=$?
  got="$("$CSB_CONFIG" --dump-config "$@" 2>&1)" && got_rc=0 || got_rc=$?
  want="$(printf '%s\n' "$want" | strip_prog)"
  got="$(printf '%s\n' "$got" | strip_prog)"
  if [[ "$want_rc" != "$got_rc" || "$want" != "$got" ]]; then
    {
      echo "argv: $*"
      echo "exit: bin/csb=$want_rc csb-config=$got_rc"
      diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true
    } >&2
    return 1
  fi
}

# --- the -E grammar: the one place csb needs an argv pre-pass ----------------

@test "parity: -E bare" { assert_parity --here -E; }
@test "parity: -E=NAME" { assert_parity --here -E=work; }
@test "parity: -E then BRANCH (the name must not eat the positional)" {
  assert_parity -E feature/foo
}
@test "parity: --ephemeral bare" { assert_parity --here --ephemeral; }
@test "parity: --ephemeral=NAME" { assert_parity --here --ephemeral=work; }
@test "parity: --ephemeral then a word (which is a BRANCH, not a name)" {
  assert_parity --ephemeral work
}

# --- positionals and the -- separator ----------------------------------------

@test "parity: -- ARGS with no BRANCH" { assert_parity --here -- --model opus; }
@test "parity: BRANCH then -- ARGS" { assert_parity feature/foo -- --model opus; }
@test "parity: a bare -- with nothing after it suppresses a profile args=" {
  write_profile p "args=--model sonnet"
  assert_parity -p p --
}
@test "parity: two positionals is an error" { assert_parity one two; }

# --- list accumulation: CLI first, then profile, then the hosts file ---------

@test "parity: repeated CLI list flags keep their order" {
  assert_parity --here --deny-read /a --deny-read /b
}
@test "parity: a list from CLI + profile" {
  write_profile p "deny_read=/from/profile"
  assert_parity -p p --deny-read /from/cli
}
@test "parity: a list from profile base + .local" {
  write_profile p "deny_read=/base/one"
  printf 'deny_read=/local/two\n' >"$CSB_PROFILES/p.local"
  assert_parity -p p
}
@test "parity: allow_host from all three sources, allow_port from two" {
  write_profile p "allow_host=prof.example.com" "allow_port=6379"
  printf 'file.example.com\n# a comment\n*.wild.example.com\n' \
    >"$XDG_CONFIG_HOME/csb/allowed-hosts"
  assert_parity -p p --allow-host cli.example.com --allow-port 5432
}
@test "parity: keep from CLI + profile" {
  write_profile p "keep=P1 P2"
  assert_parity -p p -k C1 -k C2
}
@test "parity: setenv reports names only" {
  write_profile p "setenv=A=1" "setenv=B=2"
  assert_parity -p p
}
@test "parity: the paranoid lists" {
  write_profile p "paranoid_deny_read=/p/one"
  assert_parity -p p --paranoid --paranoid-deny-read /c/one --paranoid-allow-read /c/two
}
@test "parity: a leading ~/ expands the same in both" {
  write_profile p 'allow_write=~/scratch'
  assert_parity -p p --deny-read '~/notes'
}

# --- the launch-HOME axis: three selectors that suppress each other ----------

@test "parity: bare -p NAME implies --here" {
  write_profile p "ns=x"
  assert_parity -p p
}
@test "parity: a profile here=false suppresses the implication" {
  write_profile p "here=false"
  assert_parity -p p
}
@test "parity: --no-ephemeral suppresses a profile real_home=true" {
  # The quirk worth pinning: --no-ephemeral touches the HOME axis, so it takes
  # the profile's real_home= out of play even though it names a different key.
  write_profile p "real_home=true"
  assert_parity -p p --no-ephemeral
}
@test "parity: --real-home suppresses a profile ns=" {
  write_profile p "ns=fromprofile"
  assert_parity -p p --real-home
}
@test "parity: --ns with a leading @" { assert_parity --here --ns @shared; }
@test "parity: --no-ns clears a profile ns=" {
  write_profile p "ns=fromprofile"
  assert_parity -p p --no-ns
}
@test "parity: a profile here=true loses to a BRANCH, with a warning" {
  write_profile p "here=true"
  assert_parity -p p feature/foo
}

# --- modes, env defaults, nix targets ----------------------------------------

@test "parity: delete mode" { assert_parity -d somebranch; }
@test "parity: no BRANCH and no --here is the worktree listing" { assert_parity; }
@test "parity: --list-ns" { assert_parity --list-ns; }
@test "parity: -n/--no-launch" { assert_parity --here -n; }
@test "parity: CSB_LATEST defaults latest on" {
  export CSB_LATEST=1
  assert_parity --here
}
@test "parity: a profile latest=false beats CSB_LATEST" {
  export CSB_LATEST=1
  write_profile p "latest=false"
  assert_parity -p p
}
@test "parity: CSB_VERBOSE and an explicit -v agree" {
  export CSB_VERBOSE=1
  assert_parity --here -v
}
@test "parity: the mode-specific nix target wins under -s" {
  write_profile p "nix_target=ci" "nix_target_shell=dev"
  assert_parity -p p -s
}
@test "parity: --no-nix-target clears the profile's whole set" {
  write_profile p "nix_target=ci" "nix_target_shell=dev" "nix_target_claude=rel"
  assert_parity -p p --no-nix-target
}

# --- profile scalars ----------------------------------------------------------

@test "parity: profile args= is word-split and expanded" {
  write_profile p 'args=--model sonnet ~/x ${HOME}/y'
  assert_parity -p p
}
@test "parity: token_cmd reports present, never its value" {
  write_profile p "token_cmd=echo hi"
  assert_parity -p p
}
@test "parity: profile seed_home= expands ~/" {
  write_profile p "seed_home=~/seed"
  assert_parity -p p
}
@test "parity: a .local scalar wins over the base profile" {
  write_profile p "paranoid=false" "ns=base"
  printf 'paranoid=true\n' >"$CSB_PROFILES/p.local"
  assert_parity -p p
}

# --- warnings and the sandbox/egress interlocks -------------------------------

@test "parity: -y with --shell warns and adds nothing" { assert_parity --here -y -s; }
@test "parity: -y for claude prepends the skip flag" { assert_parity --here -y; }
@test "parity: --no-sandbox with a shell warns about the inert knobs" {
  assert_parity --here -s --no-sandbox --paranoid --deny-read /x
}
@test "parity: --no-sandbox without a shell is refused" { assert_parity --here --no-sandbox; }
@test "parity: --no-sandbox with --filter-egress warns that egress is not filtered" {
  assert_parity --here -s --no-sandbox --filter-egress --allow-host a.example.com
}
@test "parity: a profile filter_egress=true" {
  write_profile p "filter_egress=true"
  assert_parity -p p --allow-host a.example.com
}

# --- die paths: the message text is the contract ------------------------------

@test "parity: a relative path to a list flag" { assert_parity --here --deny-read rel/path; }
@test "parity: an invalid host" { assert_parity --allow-host 'bad host'; }
@test "parity: an out-of-range port" { assert_parity --allow-port 99999; }
@test "parity: a non-numeric port" { assert_parity --allow-port abc; }
@test "parity: an invalid namespace" { assert_parity --ns 'bad/name'; }
@test "parity: an invalid ephemeral name" { assert_parity -E=bad/name; }
@test "parity: an invalid accent" { assert_parity --accent notacolor; }
@test "parity: an invalid nix target" { assert_parity --nix-target 'bad#name'; }
@test "parity: --here with a BRANCH" { assert_parity --here somebranch; }
@test "parity: --ns with -E" { assert_parity --ns foo -E; }
@test "parity: --real-home with -E" { assert_parity --real-home -E; }
@test "parity: a missing profile" { assert_parity -p nosuch; }
@test "parity: an unknown profile key" {
  write_profile p "boguskey=1"
  assert_parity -p p
}
@test "parity: a profile bool with a non-bool value" {
  write_profile p "paranoid=maybe"
  assert_parity -p p
}
@test "parity: a profile line with no '='" {
  write_profile p "justakey"
  assert_parity -p p
}
@test "parity: a bad host in the allowed-hosts file" {
  printf 'ok.example.com\nnot a host\n' >"$XDG_CONFIG_HOME/csb/allowed-hosts"
  assert_parity
}
@test "parity: a profile ns= with ephemeral=true" {
  write_profile p "ns=foo" "ephemeral=true"
  assert_parity -p p
}
@test "parity: CSB_TMPDIR pointing at a nonexistent dir" {
  export CSB_TMPDIR="$TEST_TMP/does-not-exist"
  assert_parity --here
}

# --- the one known divergence, pinned ----------------------------------------

# bin/csb takes `--` as the accent value and fails its own validation; cmdliner
# applies its end-of-options rule first and reports a missing value. Different
# wording, same refusal -- and no VALID csb value begins with '-', so the only
# reachable difference is the text of an error. Asserted as the property that
# survives, so a change in either direction fails here.
@test "a value that looks like an option is refused by both (texts differ)" {
  run "$CSB" --dump-config --here --accent --
  assert_failure
  assert_output --partial "accent"
  run "$CSB_CONFIG" --dump-config --here --accent --
  assert_failure
  assert_output --partial "accent"
}
