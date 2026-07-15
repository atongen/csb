# plan 004

Implemented.

## Pre-release audit: findings, fixes, and scope decisions

The final review pass before the first public release. Three parallel audits
(security, README/--help accuracy, flag/interaction coherence) plus a second,
deeper security pass produced a tiered finding list; everything below was
fixed in one batch. This document records what was found, what changed, the
scope decisions made at the same time, and the residual risks that are
documented rather than closed. History: PLAN-002 is the implemented design
this audits; PLAN-003 (VM boundary) remains the roadmap answer to the
residuals named here.

### Tier 1 -- release blockers (all fixed)

1. **`-d` could tear down a non-csb worktree.** Delete mode used
   `find_worktree`, which returns ANY checkout of the branch -- including the
   main tree (`csb -d main`) or a hand-made worktree -- and then ran the
   repo's `down` teardown (DB drops etc.) against it before removing it.
   Fix: delete mode applies the same `.worktrees/`-only guard the launch path
   uses; anything else is refused with a message, and only the namespace
   config is removed.

2. **Agent-authored `.worktreesetup.sh` was a write-sandbox -> host-exec
   escalation.** The worktree is a write-allow root, so a sandboxed agent
   could create or edit `.worktreesetup.sh`; the next `csb <branch>` (via
   `up`) or `csb -d` (via `down`) sourced it host-side, unsandboxed. Fix:
   csb refuses to source the file unless it is git-tracked AND unmodified
   relative to HEAD -- `up` aborts the launch loudly, `down` warns and skips
   so the delete still completes. Only committed (auditable) content ever
   runs. Consequences: a setup script can no longer arrive via
   `.worktreeinclude` (it would be untracked -- commit it instead), and an
   agent can still *commit* a malicious version to its branch; see
   "residuals" below.

3. **`csb -p NAME` listed instead of launching.** The README promised a bare
   `-p NAME` launches; the code fell through to list mode (after needlessly
   running `token_cmd` against the password store). Fix: bare `-p NAME`
   (no BRANCH) now implies `--here` and launches -- suppressed by `--no-here`
   or a profile `here=false` -- and `token_cmd` no longer runs for any
   invocation that only lists.

4. **Deny-floor gaps in the obvious-credential class.** Added:
   `~/.git-credentials` (git's plaintext credential store),
   `~/.config/containers/auth.json` (podman/skopeo registry creds), and the
   second-pass candidates `~/.config/age/keys.txt`, `~/.config/sops`,
   `~/.sops`, `~/.pulumi/credentials.json`. The floor is a blacklist and
   this remains its standing risk (PLAN-002); these were the known holes at
   release time.

5. **macOS: `$TMPDIR` could widen the write policy to `/private`.** The
   per-user temp write root was computed as `dirname(realpath($TMPDIR))`.
   With TMPDIR unset that resolves to `/private`; nix develop itself sets
   TMPDIR to a /tmp subpath, resolving to `/private/tmp`. A stripped-env or
   cron invocation silently got a vastly wider write root. Fix: the dir is
   derived from `getconf DARWIN_USER_TEMP_DIR` and accepted only when it
   resolves under `/var/folders`; otherwise csb warns and allows nothing
   extra. `$TMPDIR` can no longer influence the sandbox boundary.

6. **git hooks/config write-denies were existence-conditional.** The denies
   were only emitted when `.git/hooks` / `.git/config` already existed, so a
   repo using `core.hooksPath` (hooks dir absent) let the sandbox CREATE
   `.git/hooks/pre-commit` -- host code exec that defeats a deliberate deny.
   Fix: denies are emitted unconditionally (seatbelt string-matches, so
   nonexistence costs nothing; on Linux absent targets are materialized as
   inert placeholders so bwrap can ro-bind them). The same treatment now
   covers `config.worktree` -- both the common-dir copy and the linked
   worktree's own gitdir copy -- closing the `extensions.worktreeConfig`
   variant of the same class.

### Tier 2 -- correctness and first-touch accuracy (all fixed)

- `-s -L` (or `-s` with `CSB_LATEST=1`) ran the upstream claude-code check a
  shell never uses. Skipped in shell mode.
- Empty option arguments (`--ns ""`, `--seed-home ""`, `--accent ""`,
  `-p ""`) were accepted with surprising semantics. All rejected now, and
  `--no-ns` / `--no-seed-home` were added so a profile's `ns=`/`seed_home=`
  can be overridden back to the default for one run (joining the existing
  `--no-*` family).
- List mode inside a linked worktree silently showed nothing (it looked
  under the worktree's own root). List and namespace modes now derive the
  main checkout root from the git common dir and work from anywhere.
- `--seed-creds` interactions warn instead of silently doing the unexpected:
  a set `CLAUDE_CODE_OAUTH_TOKEN` wins over the seeded session (warned), and
  `--seed-creds -s` seeds nothing (warned, matching `-y -s`).
- Docs: the README now documents `verbose=` and `accent=` profile keys, all
  four env vars (`CSB_SELF`, `CSB_LATEST`, `CSB_LATEST_TTL`, `CSB_VERBOSE`)
  with the TTL cache semantics, and corrects the `--here` claim -- HOME
  seeding DOES run in `--here`; what is skipped is `.worktreeinclude` and
  `.worktreesetup.sh`.

### Tier 3 -- nits (all fixed, two with bounds)

Documented `--no-accent` and the full accent color set; softened the intro
("flake.nix preferred, not required") to match "What a repo needs: nothing";
corrected the Status note (`make install` needs no remote, launching does);
`.worktreeinclude` copies on every launch, not only into fresh worktrees;
deduped `~/.config/git` in the README deny table; the seatbelt path guard
also refuses backslashes (deny/allow-write/paranoid_deny), and the no-jq
`.claude.json` seed refuses paths that would need JSON escaping instead of
writing broken JSON; non-numeric `CSB_LATEST_TTL` dies cleanly.

Two accepted bounds:

- **The seatbelt profile temp file cannot be removed on the success path**:
  `sandbox-exec` reads it after csb has already exec'd away. An EXIT trap
  now reaps it on abnormal exits; the successful-launch file (path names
  only, no secrets) is left for the OS temp reaper. That is the correct
  maximum, not an oversight.
- **The keychain deny is treated as empirical, not structural** -- see
  residuals.

### Scope decisions

- **Profile `[shared]/[claude]/[shell]` sections: removed wholesale.** The
  most machinery for the least core value (two-pass, file-index-tagged,
  section-bucketed dispatch), and unused in practice since the `.local`
  overlay landed. `shell=` survives as a plain boolean key; mode-specific
  needs are two profile files. Old section headers now fail loudly as
  KEY=VALUE parse errors, so stale profiles self-identify.
- **`--accent` and `-L/--latest`: kept.** Accent is the at-a-glance
  personal-vs-work (and [YOLO]) mistake-avoidance signal; --latest is
  justified by claude-code's release cadence, and the TTL cache bounds its
  cost.
- **Added `--list-ns` / `--prune-ns`** -- the missing complement to `-d`'s
  credential-hygiene rationale. Namespace configs (session history + seeded
  auth) accumulated invisibly: `-d` with a different `--ns` than launched,
  branches deleted outside csb, `--here` use. Launches now stamp
  `<ns>/.csb-ns` with provenance (`kind=branch|ns|shared`). `--list-ns`
  shows this repo's configs classified as active / branch-alive-no-worktree
  / ORPHAN / explicit / unknown, plus `@`-shared ones. `--prune-ns` removes
  ONLY branch-derived orphans whose branch and worktree are both gone.
  Deliberately conservative: explicit `--ns` names are not decodable to a
  branch (pruning "work" would delete real history), `@`-shared namespaces
  are cross-repo by design, and unstamped (pre-004) dirs are listed but
  untouched -- any launch classifies them. The stamp lives in the (agent-
  writable) namespace HOME; forging it only changes prune eligibility of
  the agent's own config, which is harmless.

### Residuals -- documented, deliberately not closed here

- **Committed/tracked host-run files are still a host-exec path.** The
  tracked-and-unchanged gate closes the cheap `.worktreesetup.sh` attack,
  but (a) an agent can commit a malicious setup script to its branch, and
  (b) nix reads *tracked but uncommitted* edits from a dirty worktree, so an
  agent editing the tracked `flake.nix`/shellHook gets host execution on the
  operator's next launch of that branch with no commit at all -- the gate has
  no flake.nix counterpart. Both are now called out in the README threat
  model ("review agent changes to host-run files before relaunching").
  Candidate hardening, not implemented: evaluate the devShell from a
  committed ref (`git+file://<worktree>` pins to HEAD, ignoring dirty
  tracked files) -- it changes launch semantics for operators iterating on
  flake.nix, so it needs a deliberate decision. The full fix is PLAN-003
  (`nix develop` runs inside the guest).
- **Keychain (macOS): file-deny vs the mach path.** The seatbelt profile is
  `(allow default)` minus `file*` operations; it denies reads of
  `~/Library/Keychains` but does NOT deny mach-lookup, and `security` talks
  to `securityd` -- a separate, unsandboxed process -- over mach. Verified
  on the development box with both halves of the probe: in-sandbox,
  `csb -s -E --here -- security find-generic-password -s 'Claude
  Code-credentials' -w` returned "The specified item could not be found in
  the keychain"; outside csb the same query returned the secret. So the
  `security` CLI fails CLOSED under the file deny in practice. The README
  states this as an empirical result, not a structural guarantee: mach is
  not denied as a class, so a different securityd client could behave
  differently. Denying the relevant mach services outright is the structural
  fix if that residual ever matters.

### Verification

`make check` (shellcheck) clean. Behavioral tests ran in a scratch repo with
a scratch HOME: help/list output, worktree prepare, the setup-gate refusals
(untracked, modified; up-abort and down-skip variants), the `-d` non-csb
refusal, `--list-ns` classification of all five states, `--prune-ns`
removing exactly the orphan, list modes from inside a linked worktree,
empty-arg rejections, implied `--here` for bare `-p`, profile section
headers erroring, `--no-ns` overriding a profile `ns=`, and shell mode
skipping the `-L` check and warning on `seed_creds`. The launch path was
driven to its final exec with a stubbed `nix` on PATH and the generated
seatbelt profile inspected: all four git-dir denies emit (including
nonexistent targets and the per-worktree `config.worktree`), the write
roots contain the getconf-derived `/var/folders` dir and no `/private`
root, and the paranoid variant emits its read policy. Not verifiable from
inside a csb-sandboxed session (seatbelt does not nest): an end-to-end
host launch and the keychain control above.
