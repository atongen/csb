#!/usr/bin/env bats
# Tier 1: the repo-selected config layer -- ~/.config/csb/config and its
# config.local overlay (docs/PLAN-009-proxy.md section 5).
#
# Sections are selected by the physical main checkout root, which reaches
# csb-config as CSB_MAIN_ROOT: setting it directly is what keeps these tests
# hermetic, needing no repository and no worktree.

load helpers

REPO="/src/work/myrepo"

setup_root() { export CSB_MAIN_ROOT="$REPO"; }

# --- the built-in layer ------------------------------------------------------

@test "with no config file nothing is selected" {
  setup_root
  dump_config
  assert_success
  assert_line "config_sections="
}

@test "the built-in privacy defaults ship as setenv entries" {
  setup_root
  dump_config
  assert_line "setenv=DISABLE_AUTOUPDATER|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
}

@test "a config section replaces a built-in setenv rather than duplicating it" {
  setup_root
  write_config config "[*]" "setenv=DISABLE_AUTOUPDATER=0"
  dump_config
  assert_line "setenv=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_AUTOUPDATER"
}

# --- selectors ---------------------------------------------------------------

@test "[*] applies to every repo" {
  setup_root
  write_config config "[*]" "paranoid = true"
  dump_config
  assert_success
  assert_line "paranoid=true"
  assert_line "config_sections=config[*]"
}

@test "an exact-path section applies to that repo only" {
  write_config config "[$REPO]" "paranoid=true"
  export CSB_MAIN_ROOT="$REPO"
  dump_config
  assert_line "paranoid=true"

  export CSB_MAIN_ROOT="/src/work/other"
  dump_config
  assert_line "paranoid=false"
  assert_line "config_sections="
}

@test "a glob's * crosses / so one syntax serves substring and name matches" {
  setup_root
  write_config config \
    "[*work*]" "allow_host=substring.example.com" \
    "[*/myrepo]" "allow_host=byname.example.com" \
    "[/src/*/myrepo]" "allow_host=bypattern.example.com" \
    "[*/nomatch]" "allow_host=nope.example.com"
  dump_config
  assert_line "allow_host=substring.example.com|byname.example.com|bypattern.example.com"
}

@test "a ~/ selector expands against HOME" {
  export CSB_MAIN_ROOT="$HOME/src/thing"
  write_config config "[~/src/*]" "paranoid=true"
  dump_config
  assert_line "paranoid=true"
}

@test "the selectors that matched are reported in application order" {
  setup_root
  write_config config "[*]" "paranoid=true" "[$REPO]" "yolo=true"
  write_config config.local "[*work*]" "verbose=true"
  dump_config
  assert_line "config_sections=config[*]|config[$REPO]|config.local[*work*]"
}

# --- alternation and exclusion -----------------------------------------------

@test "a comma-separated header applies if any one term matches" {
  write_config config "[/src/other, */myrepo, *nomatch*]" "paranoid=true"

  export CSB_MAIN_ROOT="$REPO"
  dump_config
  assert_line "paranoid=true"

  export CSB_MAIN_ROOT="/src/other"
  dump_config
  assert_line "paranoid=true"

  export CSB_MAIN_ROOT="/src/work/elsewhere"
  dump_config
  assert_line "paranoid=false"
}

@test "a header applies once however many of its terms match" {
  setup_root
  write_config config "[*work*, */myrepo]" "deny_read=/once"
  dump_config
  assert_line "deny_read=/once"
  assert_line "config_sections=config[*work*, */myrepo]"
}

@test "each term of a header expands ~/ on its own" {
  export CSB_MAIN_ROOT="$HOME/src/thing"
  write_config config "[/nope, ~/src/*]" "paranoid=true"
  dump_config
  assert_line "paranoid=true"
}

@test "an exclusion withholds a matching section from one repo" {
  write_config config "[*work*, !*/myrepo]" "paranoid=true"

  export CSB_MAIN_ROOT="$REPO"
  dump_config
  assert_line "paranoid=false"
  assert_line "config_sections="

  export CSB_MAIN_ROOT="/src/work/other"
  dump_config
  assert_line "paranoid=true"
}

@test "an exclusion is the only way to withhold a list grant, which never retracts" {
  write_config config \
    "[*, !*/myrepo]" "allow_host=broad.example.com" \
    "[*]" "allow_host=everywhere.example.com"

  export CSB_MAIN_ROOT="$REPO"
  dump_config
  assert_line "allow_host=everywhere.example.com"

  export CSB_MAIN_ROOT="/src/work/other"
  dump_config
  assert_line "allow_host=broad.example.com|everywhere.example.com"
}

@test "one exclusion suppresses a header however many terms matched" {
  setup_root
  write_config config "[*work*, */myrepo, !/src/*/myrepo]" "paranoid=true"
  dump_config
  assert_line "paranoid=false"
}

# --- groups ------------------------------------------------------------------

@test "a group definition matches no repository on its own" {
  setup_root
  write_config config "[group work]" "paranoid=true"
  dump_config
  assert_success
  assert_line "paranoid=false"
  assert_line "config_sections="
}

@test "a used group contributes its lines to the section that names it" {
  setup_root
  write_config config \
    "[group work]" "paranoid=true" "allow_host=api.internal.corp" \
    "[$REPO]" "use = work"
  dump_config
  assert_line "paranoid=true"
  assert_line "allow_host=api.internal.corp"
}

@test "two sections can use the same group, and lists union both times" {
  setup_root
  write_config config \
    "[group db]" "allow_port=5432" \
    "[*work*]" "use=db" \
    "[*/myrepo]" "use=db"
  dump_config
  assert_line "allow_port=5432|5432"
}

@test "a group applies where it is used, so document order still decides a scalar" {
  setup_root
  write_config config \
    "[group g]" "nix_target=fromgroup" \
    "[*]" "nix_target=before" "use=g"
  dump_config
  assert_line "nix_target=fromgroup"

  write_config config \
    "[group g]" "nix_target=fromgroup" \
    "[*]" "use=g" "nix_target=after"
  dump_config
  assert_line "nix_target=after"
}

@test "a group defined in config is usable from config.local" {
  setup_root
  write_config config "[group work]" "accent=magenta"
  write_config config.local "[*]" "use=work"
  dump_config
  assert_line "accent=magenta"
}

@test "a used group is reported where it applied, labelled by the file defining it" {
  setup_root
  write_config config "[group work]" "paranoid=true"
  write_config config.local "[*]" "verbose=true" "use=work"
  dump_config
  assert_line "config_sections=config.local[*]|config[group work]"
}

@test "a group in a section that does not match contributes nothing" {
  export CSB_MAIN_ROOT="/src/work/other"
  write_config config \
    "[group work]" "paranoid=true" \
    "[$REPO]" "use=work"
  dump_config
  assert_success
  assert_line "paranoid=false"
}

# --- ordering ----------------------------------------------------------------

@test "the last matching section to set a scalar wins, not the most specific" {
  setup_root
  write_config config "[$REPO]" "nix_target=release"
  write_config config.local "[*]" "nix_target=ci"
  dump_config
  assert_line "nix_target=ci"
}

@test "lists union across every matching section regardless of order" {
  setup_root
  write_config config "[$REPO]" "deny_read=/from/exact" "[*]" "deny_read=/from/star"
  write_config config.local "[*]" "deny_read=/from/local"
  dump_config
  assert_line "deny_read=/from/exact|/from/star|/from/local"
}

# --- precedence against the layers above -------------------------------------

@test "a profile scalar beats a config section" {
  setup_root
  write_config config "[*]" "accent=blue"
  write_profile p "accent=magenta"
  dump_config -p p
  assert_line "accent=magenta"
}

@test "a CLI flag beats a config section" {
  setup_root
  write_config config "[*]" "paranoid=true"
  dump_config --no-paranoid
  assert_line "paranoid=false"
}

@test "lists union across CLI, profile and config" {
  setup_root
  write_config config "[*]" "allow_host=from.config"
  write_profile p "allow_host=from.profile"
  dump_config -p p --allow-host from.cli
  assert_line "allow_host=from.cli|from.config|from.profile"
}

@test "token_cmd resolves from a config section" {
  setup_root
  write_config config "[$REPO]" "token_cmd=pass show token"
  dump_config
  assert_line "token_cmd=present"
}

@test "a profile naming one HOME selector replaces the config's whole axis" {
  setup_root
  write_config config "[*]" "ns=shared"
  write_profile p "ephemeral=true"
  dump_config -p p
  assert_line "namespace="
  assert_line "ephemeral=true"
}

# --- retraction: an empty value clears the layers below -----------------------

@test "an empty profile value clears a config token_cmd" {
  setup_root
  write_config config "[*]" "token_cmd=op read op://global/token"
  write_profile p "token_cmd="
  dump_config -p p
  assert_line "token_cmd=absent"
}

@test "a profile naming token_cmd replaces the config's, rather than clearing it" {
  setup_root
  write_config config "[*]" "token_cmd=op read op://global/token"
  write_profile p "token_cmd=op read op://work/token"
  dump_config -p p
  assert_line "token_cmd=present"
}

@test "a profile silent on token_cmd leaves the config's standing" {
  setup_root
  write_config config "[*]" "token_cmd=op read op://global/token"
  write_profile p "paranoid=true"
  dump_config -p p
  assert_line "token_cmd=present"
}

@test "config.local clears a scalar set by config" {
  setup_root
  write_config config "[*]" "accent=blue"
  write_config config.local "[*]" "accent="
  dump_config
  assert_line "accent="
}

@test "an empty value clears seed_home and args too" {
  setup_root
  write_config config "[*]" "seed_home=/tmp/tpl" "args=--foo"
  write_profile p "seed_home=" "args="
  dump_config -p p
  assert_line "seed_home="
  assert_line "agent_args="
}

@test "an empty ns= retracts the whole HOME axis, like ephemeral=false" {
  setup_root
  write_config config "[*]" "real_home=true"
  write_profile p "ns="
  dump_config -p p
  assert_line "real_home=false"
  assert_line "namespace="
}

@test "a boolean is cleared by false, not by an empty value" {
  setup_root
  write_config config "[*]" "seed_creds=true"
  write_profile p "seed_creds=false"
  dump_config -p p
  assert_line "seed_creds=false"
}

@test "an empty boolean is still a bad value" {
  setup_root
  write_config config "[*]" "paranoid="
  dump_config
  assert_failure
  assert_output --partial "paranoid needs true or false"
}

@test "an empty list value does not clear the list" {
  setup_root
  write_config config "[*]" "keep=FROM_CONFIG"
  write_profile p "keep="
  dump_config -p p
  assert_line "keep=FROM_CONFIG"
}

@test "a CLI negation still beats a layer that set the scalar" {
  setup_root
  write_config config "[*]" "accent=blue"
  dump_config --no-accent
  assert_line "accent="
}

# --- flag parity: the CLI reaches every configurable key ----------------------

@test "--token-cmd beats a config token_cmd" {
  setup_root
  write_config config "[*]" "token_cmd=op read op://global/token"
  dump_config --token-cmd "pass show other"
  assert_line "token_cmd=present"
}

@test "--no-token-cmd cancels a config token_cmd" {
  setup_root
  write_config config "[*]" "token_cmd=op read op://global/token"
  dump_config --no-token-cmd
  assert_line "token_cmd=absent"
}

@test "--token-cmd and --no-token-cmd are mutually exclusive" {
  setup_root
  dump_config --token-cmd x --no-token-cmd
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--setenv adds to the layered setenv, and the CLI wins a name" {
  setup_root
  write_config config "[*]" "setenv=FROM=config"
  dump_config --setenv FROM=cli --setenv EXTRA=1
  assert_line "setenv=DISABLE_AUTOUPDATER|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|FROM|EXTRA"
}

@test "--setenv requires VAR=VALUE" {
  setup_root
  dump_config --setenv nope
  assert_failure
  assert_output --partial "setenv needs VAR=value"
}

@test "a tmpdir= key resolves like CSB_TMPDIR" {
  setup_root
  mkdir -p "$TEST_TMP/td"
  write_config config "[*]" "tmpdir=$TEST_TMP/td"
  dump_config
  assert_success
  refute_line "cfg_tmpdir="
}

@test "--tmpdir beats a config tmpdir=, and --no-tmpdir cancels it" {
  setup_root
  mkdir -p "$TEST_TMP/td" "$TEST_TMP/td2"
  write_config config "[*]" "tmpdir=$TEST_TMP/td"
  dump_config --tmpdir "$TEST_TMP/td2"
  assert_success
  dump_config --no-tmpdir
  assert_line "cfg_tmpdir="
}

# tmp_base is the RESOLVED answer cfg_tmpdir is only an input to: bin/csb reads
# it back rather than recomputing the fallback, so an operator can ask where csb
# writes on a given host instead of remembering per-platform rules.
@test "tmp_base resolves to the tmpdir when one is set" {
  setup_root
  mkdir -p "$TEST_TMP/td"
  write_config config "[*]" "tmpdir=$TEST_TMP/td"
  dump_config
  assert_success
  # Compared to each other, never to the literal that was written: a tmpdir= is
  # path-resolved, and on macOS /tmp is a symlink to /private/tmp, so the value
  # that comes back is not the string given. The invariant is that a set knob IS
  # the base, whatever spelling it resolved to.
  local cfg base
  cfg="$(printf '%s\n' "$output" | sed -n 's/^cfg_tmpdir=//p')"
  base="$(printf '%s\n' "$output" | sed -n 's/^tmp_base=//p')"
  [ -n "$cfg" ]
  [ "$base" = "$cfg" ]
}

@test "tmp_base falls back to TMPDIR, then to /tmp" {
  setup_root
  mkdir -p "$TEST_TMP/systmp"
  # No knob: the plain environment answers, and cfg_tmpdir stays empty -- the
  # two are input and resolved answer, not synonyms. The fallback is taken
  # VERBATIM, unlike a tmpdir= above: it is never validated, so an operator's
  # stale TMPDIR cannot make every launch fatal, and it is not path-resolved
  # either. That asymmetry is the reason this asserts a literal and the test
  # above does not.
  TMPDIR="$TEST_TMP/systmp" dump_config --no-tmpdir
  assert_success
  assert_line "cfg_tmpdir="
  assert_line "tmp_base=$TEST_TMP/systmp"

  TMPDIR= dump_config --no-tmpdir
  assert_success
  assert_line "tmp_base=/tmp"
}

@test "a tmpdir that does not exist is fatal" {
  setup_root
  write_config config "[*]" "tmpdir=$TEST_TMP/missing"
  dump_config
  assert_failure
  assert_output --partial "does not exist or is not a directory"
}

# --- failure modes -----------------------------------------------------------

@test "a KEY=VALUE before any section header is an error" {
  setup_root
  write_config config "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "KEY=VALUE outside a [SELECTOR] section"
}

@test "an unknown key is fatal even in a section that does not match" {
  export CSB_MAIN_ROOT="/src/work/other"
  write_config config "[$REPO]" "paranoidd=true"
  dump_config
  assert_failure
  assert_output --partial "unknown key 'paranoidd'"
}

@test "a bad value is fatal even in a section that does not match" {
  export CSB_MAIN_ROOT="/src/work/other"
  write_config config "[$REPO]" "allow_port=nope"
  dump_config
  assert_failure
  assert_output --partial "not a port from 1 to 65535"
}

@test "an empty [] selector is refused rather than matching nothing" {
  setup_root
  write_config config "[]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "[] selects nothing"
}

@test "a header of only exclusions is refused" {
  setup_root
  write_config config "[!*/scratch]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "only excludes (add a positive term"
}

@test "an empty term in a header is refused" {
  setup_root
  write_config config "[*work*, , */myrepo]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "empty term in [*work*, , */myrepo]"
}

@test "a bare ! with no pattern is refused" {
  setup_root
  write_config config "[*, !]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "'!' with no pattern"
}

@test "a use= naming no group is fatal, forward reference included" {
  setup_root
  write_config config "[*]" "use=work" "[group work]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "no [group work] defined above this line"
}

@test "an undefined group is fatal even in a section that does not match" {
  export CSB_MAIN_ROOT="/src/work/other"
  write_config config "[$REPO]" "use=typo"
  dump_config
  assert_failure
  assert_output --partial "no [group typo] defined above this line"
}

@test "a bad key in a group nobody uses is still fatal" {
  setup_root
  write_config config "[group work]" "paranoidd=true"
  dump_config
  assert_failure
  assert_output --partial "unknown key 'paranoidd'"
}

@test "a duplicate group definition is refused" {
  setup_root
  write_config config "[group work]" "paranoid=true" "[group work]" "yolo=true"
  dump_config
  assert_failure
  assert_output --partial "group 'work' is already defined"
}

@test "a group cannot use another group" {
  setup_root
  write_config config \
    "[group base]" "paranoid=true" \
    "[group work]" "use=base"
  dump_config
  assert_failure
  assert_output --partial "[group work]: use= cannot name another group"
}

@test "[group] with no name is refused" {
  setup_root
  write_config config "[group]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "[group] needs a name"
}

@test "an invalid group name is refused" {
  setup_root
  write_config config "[group two words]" "paranoid=true"
  dump_config
  assert_failure
  assert_output --partial "invalid group name 'two words'"
}

@test "a use= with no group name is refused" {
  setup_root
  write_config config "[*]" "use="
  dump_config
  assert_failure
  assert_output --partial "use= needs a group name"
}

@test "one section naming two HOME selectors is refused" {
  setup_root
  write_config config "[*]" "ns=shared" "[$REPO]" "real_home=true"
  dump_config
  assert_failure
  assert_output --partial "config: ns, ephemeral=true, and real_home=true are mutually exclusive"
}

@test "outside a repository nothing is selected, and it says so" {
  export CSB_MAIN_ROOT=""
  write_config config "[*]" "paranoid=true"
  dump_config
  assert_success
  assert_line "paranoid=false"
  assert_line "config_sections="
  assert_output --partial "no git repository here"
}
