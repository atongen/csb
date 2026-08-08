#!/usr/bin/env bats
# Tier 1: the repo-selected config layer -- ~/.config/csb/config and its
# config.local overlay (docs/PLAN-008-proxy.md section 5).
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
