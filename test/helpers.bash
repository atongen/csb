# Shared helpers for the csb bats suite (Tier 1: black-box logic tests).
# See docs/PLAN-005-tests.md.
#
# Every test runs the real bin/csb as a subprocess against an ISOLATED HOME and
# XDG_CONFIG_HOME, via --dump-config (or --dump-sandbox for build-time
# validations) so nothing launches and nothing touches the operator's
# ~/.config/csb or ~/.csb/claudes.

# `run --separate-stderr` (used by the snapshot helper) needs bats >= 1.5.
bats_require_minimum_version 1.5.0

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
  unset CSB_LATEST CSB_VERBOSE CLAUDE_CODE_OAUTH_TOKEN
  # Pin bwrap to a placeholder so --dump-sandbox on Linux prints a stable path
  # instead of running `nix build .#bwrap` (nix is not on PATH in the devShell,
  # and the dump never execs it). A no-op on macOS (seatbelt ignores it).
  export CSB_BWRAP_BIN="/csb-test/placeholder/bin/bwrap"
  # A deterministic scratch/temp dir under the isolated TEST_TMP: it becomes a
  # write root and the base for the -E ephemeral HOME, so the Tier-2 snapshots
  # stay stable (the normalizer maps it to <TMP>).
  export CSB_TMPDIR="$TEST_TMP/tmp"
  mkdir -p "$CSB_TMPDIR"
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
# $output is combined stdout+stderr (validation tests grep the stderr message).
dump_sandbox() {
  local repo="$1"; shift
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$repo" "$CSB" --here --dump-sandbox "$@"
}

# --- Tier 2: sandbox-spec snapshot helpers -----------------------------------

# platform -- the golden subdir for the current OS (matches uname -s).
platform() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux)  echo linux ;;
    *)      echo "unknown-$(uname -s)" ;;
  esac
}

# dump_sandbox_snapshot REPO ARGS... -- like dump_sandbox but keeps stdout
# (the profile/argv) separate from stderr (csb's notes), so $output is the
# artifact alone, ready to normalize.
dump_sandbox_snapshot() {
  local repo="$1"; shift
  run --separate-stderr \
    bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$repo" "$CSB" --here --dump-sandbox "$@"
}

# _sed_escape STR -- escape the sed BRE metacharacters (and the # delimiter) in
# STR so it can be used as a literal left-hand side in `s#...#...#`. Done in pure
# bash, char by char: a sed bracket-expression escape is a quoting minefield
# (`[.` reads as a POSIX collating symbol). `/` is not a metacharacter here (the
# normalizer uses # as its delimiter), so it is left alone.
_sed_escape() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '.'|'*'|'['|']'|'^'|'$'|'\'|'#') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# normalize_sandbox REPO -- read $output (the stdout of a --dump-sandbox run) and
# replace volatile, host-specific strings with stable placeholders, echoing the
# result. Fed the concrete values the harness created (HOME, REPO, CSB_TMPDIR)
# plus the namespace dir(s) csb stamped and the macOS per-user temp parent.
# Most-specific paths are replaced first (the namespace dir and the ephemeral
# HOME sit under HOME/TMP, so they must go before them).
normalize_sandbox() {
  local repo="$1" rhome rrepo rtmp vartmp stamp nsdir prog=""
  rhome="$(realpath "$HOME")"
  rrepo="$(realpath "$repo")"
  rtmp="$(realpath "$CSB_TMPDIR")"

  # Namespace dirs, located by the .csb-ns stamp csb writes (covers both the
  # branch/ns-scoped <repo-key>/<ns> form and the @unscoped form). Replace the ns
  # dir itself with <NS>, and -- for the scoped form -- its <repo-key> parent
  # (whose name embeds a volatile path hash) with <NSKEY>, since csb emits an
  # ancestor-metadata rule for that parent. The ns dir (longer) goes first.
  local keydir
  while IFS= read -r stamp; do
    nsdir="$(dirname "$stamp")"
    keydir="$(dirname "$nsdir")"
    prog+="s#$(_sed_escape "$nsdir")#<NS>#g;"
    [[ "$keydir" != "$rhome/.csb/claudes" ]] && prog+="s#$(_sed_escape "$keydir")#<NSKEY>#g;"
  done < <(find "$rhome/.csb/claudes" -name .csb-ns -type f 2>/dev/null)

  # The -E ephemeral HOME (random mktemp suffix under CSB_TMPDIR): stabilize the
  # suffix before CSB_TMPDIR itself is mapped to <TMP>.
  prog+="s#csb-home\.[A-Za-z0-9][A-Za-z0-9]*#csb-home.<X>#g;"
  prog+="s#$(_sed_escape "$rrepo")#<REPO>#g;"
  prog+="s#$(_sed_escape "$rtmp")#<TMP>#g;"
  prog+="s#$(_sed_escape "$rhome")#<HOME>#g;"

  # macOS per-user temp parent (the getconf-derived write root csb adds), which
  # is per-machine. Computed exactly as build_write_roots does.
  if [[ "$(uname -s)" == Darwin ]]; then
    local dtmp
    dtmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    if [[ -n "$dtmp" && -d "$dtmp" ]]; then
      vartmp="$(dirname "$(realpath "$dtmp")")"
      prog+="s#$(_sed_escape "$vartmp")#<VARTMP>#g;"
    fi
  fi

  # Linux: the bwrap binary (pinned to the CSB_BWRAP_BIN placeholder).
  prog+="s#$(_sed_escape "$CSB_BWRAP_BIN")#<BWRAP>#g;"

  printf '%s\n' "$output" | sed "$prog"
}

# assert_snapshot NAME REPO -- normalize the just-captured --dump-sandbox $output
# and compare it to test/snapshots/<platform>/NAME. With SNAPSHOT_UPDATE=1 the
# golden is (re)written instead; a missing golden fails with how to generate it.
assert_snapshot() {
  local name="$1" repo="$2" golden actual
  golden="$BATS_TEST_DIRNAME/snapshots/$(platform)/$name"
  actual="$(normalize_sandbox "$repo")"

  if [[ "${SNAPSHOT_UPDATE:-}" == "1" ]]; then
    mkdir -p "$(dirname "$golden")"
    printf '%s\n' "$actual" > "$golden"
    return 0
  fi
  if [[ ! -f "$golden" ]]; then
    echo "no golden for this platform: ${golden#"$BATS_TEST_DIRNAME"/}" >&2
    echo "generate it on a $(platform) host: SNAPSHOT_UPDATE=1 make test" >&2
    return 1
  fi
  if ! diff -u "$golden" <(printf '%s\n' "$actual"); then
    echo "snapshot mismatch: $name -- if intended, accept with: make test-update" >&2
    return 1
  fi
}
