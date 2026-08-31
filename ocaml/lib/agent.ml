(* The per-agent adapter: every place csb has to know WHICH agent it launches,
   as one table.

   Nothing else in csb branches on the agent -- not resolution, not the emit
   seam, and above all not bin/csb, which consumes the values below as opaque
   strings and instructions. Adding an agent is adding a row here, an
   allowed-hosts.<name> template, and a flake output.

   The rows are deliberately DATA rather than behaviour: a value that bin/csb
   can only splice (a flake attribute, a variable name, a flag) or execute
   through one of four generic seed verbs. That is what keeps the two sides from
   growing a second, disagreeing implementation of the same choice. *)

open Types

let known = "claude"

let of_string ~where = function
  | "claude" -> Claude
  | v -> Err.die "%s: unknown agent '%s' (%s)" where v known

let to_string = function Claude -> "claude"

(* The flake output bin/csb builds the binary from, as `$CSB_SELF#<attr>`, and
   the executable's name under that output's bin/ -- the two need not agree
   (nixpkgs `gemini-cli` installs bin/gemini). *)
let bin_attr = function Claude -> "claude"
let bin_name = function Claude -> "claude"

(* The variable token_cmd's output is exported into, which also joins the env
   scrub's keep list. A layer may name another with token_env=. *)
let token_env = function Claude -> "CLAUDE_CODE_OAUTH_TOKEN"

(* How to obtain one, for the warning bin/csb prints when nothing is set. *)
let token_hint = function
  | Claude -> "generate one once with 'claude setup-token' and export it"

(* How the agent spells "allow every tool call". *)
let yolo_flag = function Claude -> "--dangerously-skip-permissions"

(* The quiet knobs, as the lowest setenv layer: cheap variables that remove
   noise a tight egress allowlist otherwise produces. The agent is pinned by
   nix, so an auto-update can only target a read-only store path, and the
   non-essential traffic is telemetry. Overridable like any other layer's
   setenv. *)
let setenv = function
  | Claude ->
      [ ("DISABLE_AUTOUPDATER", "1");
        ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1") ]

(* Where the agent keeps its state inside the launch HOME, and the variable that
   points it there. Set for every redirected HOME, so the layout is the same
   whether the HOME is a namespace or a throwaway. *)
let config_dir = function Claude -> ".claude"
let config_env = function Claude -> "CLAUDE_CONFIG_DIR"

(* The user-global egress allowlist this agent reads: allowed-hosts.<agent>,
   with the unsuffixed file as the fallback every agent shares. *)
let hosts_file = function Claude -> "allowed-hosts.claude"

(* Whether this agent's per-repo launch HOMEs predate the agent suffix, and so
   whether an unsuffixed repo-<key> dir under the root is one of ITS HOMEs to
   adopt (docs/PLAN-010-agents.md s6a). True only for claude, which is what csb
   ran before it had an axis at all. *)
let ns_migrate = function Claude -> true

let lines = String.concat "\n"

(* hasCompletedOnboarding + per-project trust, so interactive claude starts from
   the forwarded token without a login or trust prompt. ${CSB_WORKTREE} is the
   project key, which only bin/csb knows. *)
let onboarding = function
  | Claude ->
      lines
        [ "{";
          "  \"hasCompletedOnboarding\": true,";
          "  \"projects\": {";
          "    \"${CSB_WORKTREE}\": {";
          "      \"hasTrustDialogAccepted\": true,";
          "      \"projectOnboardingSeenCount\": 1";
          "    }";
          "  }";
          "}" ]

(* What every redirected-HOME launch seeds, before the credential arm below. *)
let seed a =
  match a with
  | Claude ->
      [ { verb = Json_merge; arg = onboarding a;
          dest = Filename.concat (config_dir a) ".claude.json" } ]

(* --seed-creds: the HOST's native session credential, copied into the launch
   HOME so the sandbox presents the operator's live subscription session. The
   source is platform-dependent for exactly the agents that use an OS keyring. *)
let cred_seed ~(env : Env.t) ~darwin = function
  | Claude ->
      let dest = Filename.concat (config_dir Claude) ".credentials.json" in
      if darwin then [ { verb = Keychain; arg = "Claude Code-credentials"; dest } ]
      else
        [ { verb = Copy;
            arg = Filename.concat env.Env.home ".claude/.credentials.json";
            dest } ]

(* The seeded credential bin/csb inspects between launches, and the two jq
   expressions it inspects it with: `usable` must yield the REFRESH token's
   expiry in epoch milliseconds (a launch whose credential can still renew
   itself is left untouched, because the agent rotates it in place and the host
   copy is then the stale one), and `clear` must drop the session credential
   while keeping any other stored auth. Empty disables both checks. *)
let cred_check = function Claude -> Filename.concat (config_dir Claude) ".credentials.json"
let cred_usable_expr = function Claude -> ".claudeAiOauth.refreshTokenExpiresAt // empty"
let cred_clear_expr = function Claude -> "del(.claudeAiOauth)"
