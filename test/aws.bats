#!/usr/bin/env bats
# Tier 1: the aws credential-injection axis -- aws_profile= / --aws / --no-aws,
# the variables the injection owns, and the refusals that keep a second source
# from naming one of them (docs/PLAN-011-aws.md).
#
# What the launch itself does with the resolved profile -- run the aws CLI,
# refuse credentials that do not expire, inject the session -- is not reachable
# from a dump seam and is verified by hand; see PLAN-011 section 6.

load helpers

# --- resolution and precedence -----------------------------------------------

@test "no aws profile is configured by default" {
  dump_config --here
  assert_line "aws_profile="
}

@test "--aws names the profile" {
  dump_config --here --aws agent-view-only
  assert_line "aws_profile=agent-view-only"
}

@test "a profile's aws_profile= is how -p activates the injection" {
  write_profile aws "aws_profile=agent-view-only"
  dump_config -p aws
  assert_line "aws_profile=agent-view-only"
}

@test "--aws beats a profile's aws_profile=" {
  write_profile aws "aws_profile=from-profile"
  dump_config -p aws --aws from-cli
  assert_line "aws_profile=from-cli"
}

@test "an empty aws_profile= retracts the layer below" {
  write_config config "[*]" "aws_profile=from-config"
  write_profile aws "aws_profile="
  export CSB_MAIN_ROOT="/src/work/myrepo"
  dump_config -p aws
  assert_line "aws_profile="
}

@test "--no-aws cancels a configured aws_profile=" {
  write_profile aws "aws_profile=agent-view-only"
  dump_config -p aws --no-aws
  assert_line "aws_profile="
}

@test "--aws and --no-aws together are refused" {
  dump_config --here --aws p --no-aws
  assert_failure
  assert_output --partial "--aws and --no-aws are mutually exclusive"
}

@test "--aws without a value dies" {
  dump_config --here --aws
  assert_failure
  assert_output --partial "--aws requires a PROFILE"
}

@test "an aws profile name is held to the aws CLI's own charset" {
  dump_config --here --aws 'two words'
  assert_failure
  assert_output --partial "invalid aws profile"
}

@test "a granted-sso style name with a slash is accepted" {
  dump_config --here --aws 'work-primary/ViewOnly'
  assert_line "aws_profile=work-primary/ViewOnly"
}

# --- the variables the injection owns ----------------------------------------

@test "an injection pins the SDK's config files away from the denied ~/.aws" {
  dump_config --here --aws agent-view-only
  assert_line "setenv=DISABLE_AUTOUPDATER|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|AWS_CONFIG_FILE|AWS_SHARED_CREDENTIALS_FILE"
}

@test "no injection means no pins" {
  dump_config --here
  assert_line "setenv=DISABLE_AUTOUPDATER|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
}

@test "setenv naming an injected variable is refused" {
  dump_config --here --aws p --setenv AWS_REGION=us-east-1
  assert_failure
  assert_output --partial "aws_profile injects AWS_REGION; setenv may not also name it"
}

@test "setenv_cmd naming an injected variable is refused" {
  dump_config --here --aws p --setenv-cmd 'AWS_SESSION_TOKEN=printf x'
  assert_failure
  assert_output --partial "aws_profile injects AWS_SESSION_TOKEN; setenv_cmd may not also name it"
}

@test "token_env naming an injected variable is refused" {
  dump_config --here --aws p --token-env AWS_SESSION_TOKEN
  assert_failure
  assert_output --partial "aws_profile injects AWS_SESSION_TOKEN; token_env may not also name it"
}

@test "keeping an injected variable across the scrub is refused" {
  dump_config --here --aws p -k AWS_ACCESS_KEY_ID
  assert_failure
  assert_output --partial "aws_profile injects AWS_ACCESS_KEY_ID; keep may not also name it"
}

@test "keeping AWS_PROFILE alongside an injection is refused" {
  # It names a profile whose definition lives in the denied ~/.aws, so the SDK
  # would fail looking for it while holding a working session.
  dump_config --here --aws p -k AWS_PROFILE
  assert_failure
  assert_output --partial "aws_profile and keep=AWS_PROFILE are mutually exclusive"
}

@test "the same variables are free when nothing is injected" {
  dump_config --here --setenv AWS_REGION=us-east-1 -k AWS_PROFILE
  assert_success
  assert_line "keep=AWS_PROFILE"
}

# --- the egress hint ----------------------------------------------------------

@test "an injection under --filter-egress with no AWS host warns" {
  dump_config --here --aws p --filter-egress --allow-host api.anthropic.com
  assert_success
  assert_output --partial "no allow_host covers *.amazonaws.com"
}

@test "an allow_host covering the AWS endpoints silences the hint" {
  dump_config --here --aws p --filter-egress --allow-host '*.amazonaws.com'
  assert_success
  refute_output --partial "no allow_host covers"
}

@test "the hint does not fire without --filter-egress" {
  dump_config --here --aws p
  assert_success
  refute_output --partial "no allow_host covers"
}

@test "the hint does not fire without an injection" {
  dump_config --here --filter-egress --allow-host api.anthropic.com
  assert_success
  refute_output --partial "no allow_host covers"
}

# --- the emit seam ------------------------------------------------------------

@test "the variable names bin/csb extracts ride the seam, not bash" {
  emit_records --here --aws agent-view-only
  assert_line "aws_profile=agent-view-only"
  assert_line "aws_cred_var=AWS_ACCESS_KEY_ID"
  assert_line "aws_cred_var=AWS_SECRET_ACCESS_KEY"
  assert_line "aws_cred_var=AWS_SESSION_TOKEN"
  assert_line "aws_cred_var=AWS_CREDENTIAL_EXPIRATION"
  assert_line "aws_region_var=AWS_REGION"
  assert_line "aws_region_var=AWS_DEFAULT_REGION"
  assert_line "aws_expiry_var=AWS_CREDENTIAL_EXPIRATION"
}

@test "no injection emits no variable names to extract" {
  emit_records --here
  assert_line "aws_profile="
  refute_line "aws_cred_var=AWS_ACCESS_KEY_ID"
  refute_line "aws_region_var=AWS_REGION"
}

# bin/csb dies on an emitted key it has no reader for, so a launch-path run is
# what proves the new records are adopted rather than merely produced.
# bats test_tags=dump-sandbox
@test "bin/csb adopts the aws records" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --aws agent-view-only
  assert_success
  refute_output --partial "unknown key"
}
