# plan 002

## Clean up and consolidate functionality.

* remove agent-sandbox from the nix flake: too restrictive for general use
* default mode becomes the `--no-sandbox` mode - the option can be removed
* add deny-list via seatbelt on macos and bubblewrap on linux
  - define a single deny-list for all platforms, and allow users to add to it via a config file
  - retain the env filtering and redirected namespace HOME - stays as-is
* evaluate the remaining cli args for usefulness and consistency, simplify where possible
* overall requirement:
  - client repos need their own flake.nix
  - this tool can run either claude or bash (shell)
  - and either `--here` (no worktree, mututually exclusive with NAME) or with NAME, which provisions a worktree
  - all combinations will end up in the same restricted nix devShell environment
  - network and host access should be generally available so claude and the shell can access local services (db, redis, etc) for testing, etc.
* build and document a "wrapper" script or function that can be run from the host when invoking the sandbox
  - injects short-lived aws role credentials into the sandbox

## existing scripts

Provided here for reference. Can these be made more ergonomic?

```bash
csb_run() {
  local ns="$1" key="$2"
  [[ -n "$ns" ]] || return 1
  [[ -n "$key" ]] || return 1
  shift 2
  token="$(pass "$key/claude/token")"
  [[ -n "$token" ]] || return 1
  CLAUDE_CODE_OAUTH_TOKEN="$token" \
    CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 \
    COLORTERM=truecolor \
    csb \
      --no-sandbox \
      --ns "$ns" \
      --latest \
      -k CLAUDE_CODE_DISABLE_MOUSE_CLICKS \
      -k COLORTERM \
      "$@"
}

# csb drip
csbd() {
  csb_run @drip drip "$@"
}

# csb personal (misc)
csbp() {
  csb_run @personal misc "$@"
}

csb_shell() {
  local ns="$1"
  [[ -n "$ns" ]] || return 1
  shift 1
  COLORTERM=truecolor \
    csb \
      --no-sandbox \
      --ns "$ns" \
      --shell \
      -k COLORTERM \
      "$@" -- \
      bash --rcfile ~/.config/nix-dev-pure.bashrc
}

# csb drip
csbds() {
  csb_shell @drip "$@"
}

# csb personal (misc)
csbps() {
  csb_shell @personal "$@"
}
```

### comprehensive implementation plan

#### decisions (settled 2026-07-07)

1. Wrapper placement: INNERMOST. All nix eval/build/develop runs host-side,
   unrestricted, exactly as today. The deny wrapper (seatbelt/bwrap) wraps only
   the final claude/bash process inside `nix develop --command`. Consequences,
   recorded deliberately:
   - flake input fetching over git+ssh keeps working (nix runs with real HOME);
   - the repo's shellHook and .worktreesetup.sh still execute on the host,
     unsandboxed -- the existing trust model, unchanged by this work.
2. `--ns global` is REMOVED. Every run is namespaced (or ephemeral); the real
   ~/.claude and ~/.claude.json are always denied. `global` stays a reserved
   name that errors with an explanatory message.
3. Deny config: single user-global file, ADD-ONLY. Built-in defaults can never
   be removed via config; the floor is guaranteed.
4. AWS creds: built-in `--aws PROFILE` flag; host-side
   `aws configure export-credentials` with a device-code login fallback.
5. Explicit non-goal: NO network egress restriction. The jail's allowedDomains
   dies with agent-sandbox and is not replaced -- open network is a requirement
   (local db/redis/etc). Accepted consequence: anything the agent can read, it
   can exfiltrate. The deny-list exists to shrink "can read", not to firewall.

#### phase 1: consolidate to a single launch mode

Goal: `--no-sandbox` behavior becomes the only behavior; the jail is deleted.

bin/csb:
- Remove the `--no-sandbox` flag and the `no_sandbox` variable; the devShell
  launch path (current lines ~576-669) becomes the unconditional launch path.
  The trailing jail branch (`nix run CSB_SELF#sandbox_attr`) is deleted.
- Remove `sandbox_attr` and the `claude-sandboxed*` selection in
  setup_namespace().
- Remove the `--ns global` branch in setup_namespace(); replace with a hard
  error: `--ns global was removed in plan-002; every run is namespaced`.
  Keep `global` in the reserved-name validation so nothing recreates it.
- Drop the "requires --no-sandbox" guards for `--shell` and `--keep` (both now
  always apply). Remove their warning branches.
- `warn_if_no_token` stays (token auth is still the only path; HOME is still
  redirected away from any logged-in ~/.claude).
- Usage text and header comment rewritten for the single-mode model.

flake.nix:
- Remove input `agent-sandbox`; remove `lib` output (mkClaudeSandbox,
  readAllowedDomains, defaultDomains), `claude-sandboxed`,
  `claude-sandboxed-global`, and the in-jail claudeSeeded wrapper. Host-side
  seed_claude_config() in bin/csb is now the single seeding path.
- Keep: `packages.csb`, `packages.claude`, apps, template.
- Add: `packages.bwrap = pkgs.bubblewrap` (Linux systems only) so bin/csb can
  resolve a store path for the wrapper without relying on host PATH.
- Update flake description.

Docs: README rewrite (no jail, no token-in-jail caveats that no longer apply),
template flake.nix comment update (drop the two-mode explanation).

Acceptance: `csb -E --here -- --version` and `csb -s -E --here` work in a repo
with a devShell; `csb --ns global x` errors; `nix flake check` passes; grep
finds no agent-sandbox references.

#### phase 2: deny-list engine

Built-in default deny list (defined in bin/csb, $HOME-relative unless noted;
missing paths are skipped at generation time):

    ~/.ssh              ~/.aws               ~/.gnupg
    ~/.password-store   ~/.claude            ~/.claude.json     (file)
    ~/.csb/claudes      (parent; active namespace re-allowed, see below)
    ~/.netrc  (file)    ~/.config/gh         ~/.config/gcloud
    ~/.kube             ~/.docker            ~/.gitconfig       (file)
    ~/.config/git       ~/.bash_history (f)  ~/.zsh_history     (file)
    ~/Library/Keychains (darwin only)
    ~/.local/share/keyrings (linux only)

User config: `${XDG_CONFIG_HOME:-~/.config}/csb/deny` -- one path per line,
leading `~/` expanded to $HOME, `#` comments and blanks ignored, add-only.
Anything else is a parse error (fail launch loudly; a misparsed deny file must
not silently launch unprotected).

Path handling rules (both platforms):
- Canonicalize each entry with realpath (symlinked HOMEs; seatbelt matches
  resolved paths). Skip entries that do not exist.
- Classify dir vs file: seatbelt uses `(subpath ...)` vs `(literal ...)`;
  bwrap uses `--tmpfs <dir>` vs `--ro-bind /dev/null <file>`.

macOS wrapper (generated per-launch into `mktemp`, e.g. csb-deny.XXXX.sb):

    (version 1)
    (allow default)
    (deny file* (subpath "/Users/me/.ssh"))
    (deny file* (literal "/Users/me/.netrc"))
    ...
    (allow file* (subpath "<active ns_dir>"))   ; last rule wins: re-allow
                                                ; the active namespace under
                                                ; the denied ~/.csb/claudes

  Invocation: `/usr/bin/sandbox-exec -f <profile>` (absolute path; sandbox-exec
  is deprecated-but-stable -- nix's own darwin sandbox uses the same
  libsandbox). Children inherit the profile.

Linux wrapper (store path resolved host-side before the env scrub):

    bwrap=$(nix build "$CSB_SELF#bwrap" --no-link --print-out-paths)/bin/bwrap
    $bwrap --dev-bind / / --proc /proc --die-with-parent \
      --tmpfs ~/.ssh --tmpfs ~/.aws ... \
      --ro-bind /dev/null ~/.netrc ... \
      --tmpfs ~/.csb/claudes --bind <ns_dir> <ns_dir> \
      -- <cmd>

  No --unshare-net / --unshare-ipc (open host access is a requirement). Mount
  ordering matters: tmpfs the ~/.csb/claudes parent first, then bind the
  active namespace back in.

Integration (the innermost decision). Current exec:

    nix develop "$worktree" --ignore-environment "${keep_args[@]}" \
      --command env "${env_overrides[@]}" "$claude_bin" ...

becomes:

    nix develop "$worktree" --ignore-environment "${keep_args[@]}" \
      --command env "${env_overrides[@]}" \
        "${deny_wrapper[@]}" "$claude_bin" ...

where deny_wrapper is `(/usr/bin/sandbox-exec -f $profile)` on darwin and the
bwrap argv on linux. Same wrapping for the `--shell` exec. A single helper
(`build_deny_wrapper`) assembles the argv from defaults + config + ns_dir;
both exec sites consume it. Ephemeral HOMEs live under $TMPDIR -- not under
any denied path -- so they need no re-allow.

Acceptance (run on BOTH platforms; macOS now, NixOS as the gating milestone
for the previously-unverified linux path):

    csb -s -E --here -- cat  ~/.ssh/config           # fails / empty
    csb -s -E --here -- cat  "$HOME/.aws/config"     # absolute path: fails
    csb -s -E --here -- cat  ~/.claude.json          # fails / empty
    csb -s -E --here -- ls   ~/.csb/claudes          # only active ns usable
    csb -s -E --here -- curl -s localhost:<svc>      # local services reachable
    csb -s -E --here -- git  commit --allow-empty -m x   # git works
    csb -E --here                                    # claude launches, auths

#### phase 3: profiles config + --aws

> NOTE (2026-07-14): the `--aws` / `aws_profile=` credential-injection feature
> described in this phase was implemented but later REMOVED (no ongoing need).
> The `--aws PROFILE` flag, the `aws_profile=` profile key, and `fetch_aws_creds`
> are gone from bin/csb; the README no longer documents them. The read deny-list
> entry for `~/.aws` is unrelated and stays. This section is retained as
> historical record of the original design.

Profiles config: `${XDG_CONFIG_HOME:-~/.config}/csb/profiles/<name>`, one file
per profile, line-oriented KEY=VALUE with only these keys recognized (anything
else is an error):

    ns=@drip                       # as --ns (optional)
    token_cmd=pass drip/claude/token   # run host-side via bash -c; stdout ->
                                       # CLAUDE_CODE_OAUTH_TOKEN (never echoed)
    aws_profile=drip-primary/Admin # as --aws (optional)
    keep=COLORTERM DIRENV_LOG_FORMAT   # space-separated, appended to --keep
    setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1   # repeatable; appended to
                                                # env_overrides (post-scrub)

bin/csb: add `-p/--profile NAME`. Precedence: explicit CLI flags beat profile
values (profile supplies defaults). token_cmd failure or empty output aborts
the launch before any worktree/namespace side effects. This retires the
csb_run/csbd/csbp/csb_shell/csbds/csbps shell functions; README documents the
equivalent profile files. Tokens no longer transit the interactive shell's
environment.

`--aws PROFILE` (also reachable via profile aws_profile=):

    creds=$(aws configure export-credentials --profile "$P" --format env) || {
      aws sso login --profile "$P" --use-device-code
      creds=$(aws configure export-credentials --profile "$P" --format env)
    }

- Parse the exported AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
  AWS_SESSION_TOKEN / AWS_CREDENTIAL_EXPIRATION into env_overrides (NOT
  --keep: values must not need to preexist in the caller's env).
- Also inject AWS_REGION from `aws configure get region --profile "$P"` when
  set (export-credentials does not emit it).
- Requires the aws CLI on the HOST only; the devShell needs nothing.
- Print the credential expiry at launch so staleness is visible.
- Documented caveat: role creds live ~1h and do NOT refresh inside a running
  session; re-launch csb to refresh. Upgrade path (future, out of scope):
  host-side credential broker + AWS_CONTAINER_CREDENTIALS_FULL_URI, viable
  because sandbox networking is open.

Acceptance:

    csb --aws 'drip-primary/Admin' -s -E --here -- \
      aws sts get-caller-identity          # correct role, while...
    csb --aws 'drip-primary/Admin' -s -E --here -- \
      cat "$HOME/.aws/config"              # ...the real ~/.aws stays denied
    csb -p drip x                          # ns/token/keeps applied from profile

#### phase 4: cli cleanup + docs

- Final flag set: BRANCH | --here, -y, -n, -d, -E, -N/--ns, -s/--shell,
  -k/--keep, -L/--latest, -p/--profile, --aws, -h. Removed: --no-sandbox,
  --ns global. Re-check every pairwise interaction warning in the arg parser
  against this set; delete dead ones.
- README: rewrite around the single mode (deny-list model, what it does and
  does not protect against -- name the open-network exfiltration trade and the
  host-side shellHook/.worktreesetup.sh trust explicitly), profiles, --aws,
  deny config format, NixOS verification status.
- docs/TODO.md: fold in or close items obsoleted by this plan.

#### risks / notes

- Deny-list is a blacklist: completeness is the standing risk. The defaults
  above are the reviewed floor; additions go in the user deny file. Revisit
  after first month of use.
- sandbox-exec is formally deprecated. Mitigation: same engine nix/Chrome use;
  if Apple ever removes it, the linux bwrap shape ports to an endpoint-
  security or VM approach -- isolated in build_deny_wrapper.
- Denying ~/Library/Keychains makes host `security` calls fail inside the
  shell -- expected and desired; may surprise repo tooling that shells out to
  it.
- bwrap flags above assume no user-namespace restrictions; NixOS defaults are
  fine. Non-NixOS linux distros with restricted userns may need setuid bwrap
  (out of scope; document if hit).
- Namespace HOME redirection remains hygiene, not containment; the deny-list
  is the containment. Both layers stay.

#### open questions (non-blocking)

- Debug escape hatch: is an env var (e.g. CSB_DENY=0, loud warning) wanted for
  diagnosing wrapper-induced breakage, or is editing the deny config enough?
  Default: not implemented until a real need appears.
- Should `-d` also offer to delete a profile file? Default: no (profiles are
  user-authored config, not derived state).
