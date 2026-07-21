# Shared helpers for the csb bats suite (Tier 1: black-box logic tests).
# See docs/PLAN-005-tests.md.
#
# Every test runs the real bin/csb as a subprocess against an ISOLATED HOME and
# XDG_CONFIG_HOME, via --dump-config (or --dump-sandbox for build-time
# validations) so nothing launches and nothing touches the operator's
# ~/.config/csb or ~/.csb/claudes.

CSB="${CSB:-$BATS_TEST_DIRNAME/../bin/csb}"

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/csb-test.XXXXXX")"
  export HOME="$TEST_TMP/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_CACHE_HOME="$HOME/.cache"
  CSB_PROFILES="$XDG_CONFIG_HOME/csb/profiles"
  mkdir -p "$HOME" "$CSB_PROFILES"

  # A clean, deterministic baseline: no env-driven defaults, no host token, no
  # network-reaching --latest. Individual tests opt back in explicitly.
  unset CSB_LATEST CSB_VERBOSE CSB_TMPDIR CLAUDE_CODE_OAUTH_TOKEN
  # Pin bwrap to a placeholder so --dump-sandbox on Linux prints a stable path
  # instead of running `nix build .#bwrap` (nix is not on PATH in the devShell,
  # and the dump never execs it). A no-op on macOS (seatbelt ignores it).
  export CSB_BWRAP_BIN="/csb-test/placeholder/bin/bwrap"
}

teardown() {
  [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# git init a throwaway repo with one commit on branch $1 (default main); echo its
# path. Needed for --dump-sandbox and for --here's namespace-from-HEAD.
fake_repo() {
  local branch="${1:-main}" repo
  repo="$(mktemp -d "$TEST_TMP/repo.XXXXXX")"
  git -C "$repo" init -q -b "$branch"
  git -C "$repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m init
  echo "$repo"
}

# write_profile NAME LINE... -- create ~/.config/csb/profiles/NAME.
write_profile() {
  local name="$1"; shift
  printf '%s\n' "$@" > "$CSB_PROFILES/$name"
}

# dump_config ARGS... -- run `csb --dump-config ARGS`. --dump-config exits before
# any repo lookup, so the current directory is irrelevant (no repo needed). The
# flag goes FIRST so a test's own `-- ARGS` cannot swallow it into claude_args.
dump_config() {
  run "$CSB" --dump-config "$@"
}

# dump_sandbox REPO ARGS... -- run `csb --here --dump-sandbox ARGS` inside REPO.
dump_sandbox() {
  local repo="$1"; shift
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$repo" "$CSB" --here --dump-sandbox "$@"
}
