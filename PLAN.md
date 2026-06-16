# csb (claude sandbox)

We are going to build a tool that automates sandboxing claude on linux.
You can review the prior art in the docs/ directory.

## restore tm but retain generic improvements

I want to restore the ~/bin/tm script to its original functionality.
You can review a duplicate of the file in the docs/ directory: tm_original.
I want to retain any improvements to the script that are unrelated to claude and/or workspaces.
It was a mistake to try to shoehorn additional functionality into the tm script, and I want to separate concerns.

## new script: csb

Some concepts from the original script will be retained.
Linux functionality is required. If there is an alternative tool than jail.nix that works for both linux and macos, we should evaluate that tool.

High level workflow that we need to refine and then build for:

* unlike tm, there does not need to be any tmux integration - tmux can be run and managed by the user - outside the sandbox - only claude it sandboxed.
* in a git repo, use runs `csb [branch-name]`
* the result of running this command should be that a sandboxed claude is running with a working directory that is a worktree for that branch, branched off the current branch
* if the worktree already exists, it should be reused and not recreated
* I imagine that the tm script will be used along side this script to help manage tmux environments in a simple way.

* research needed: We need to be able to define nix development shells along side the claude jailing/sandboxing functionality, so we probably need to keep those separate.
                   Perhaps a repo-specific flake.nix that includes the claude sandboxing utilities so that sandboxing can be pulled in easily when necessary.
* the tools included in the claude sandbox should be the minimum necessary for claude to run effectively, but it does not need to include interactive tools (neovim, tmux, etc) -
  those should be included in the repo-specific flake.nix development shell as necessary. The claude sandbox should be focused on providing a consistent and isolated environment for running claude,
  while the development shell can be more flexible and include additional tools as needed.

---

# Implementation Plan (refined)

## Research & decisions

### Sandbox backend: `agent-sandbox.nix`

We evaluated three options against the PLAN's requirement for a tool that works on
both Linux and macOS:

| | `agent-sandbox.nix` | `jail.nix` (prior art) | `@anthropic-ai/sandbox-runtime` (`srt`) |
|---|---|---|---|
| Cross-platform | ✅ Linux (bwrap) **+ macOS (sandbox-exec)**; tested on `aarch64-darwin` & `x86_64-linux` | ❌ Linux only | ✅ but Node-based |
| Pure Nix flake lib | ✅ `mkSandbox` | ✅ | ❌ |
| Claude-specific | ✅ ships a `claude` template | ❌ | ❌ |
| Secrets masked by default | ✅ `$HOME` is ephemeral tmpfs → `~/.ssh`/`~/.aws` hidden | ❌ manual | ❌ manual |
| Network allowlist | ✅ domain + HTTP-method filtering proxy, DNS blocked | ❌ | ✅ |

**Decision: use [`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix).**
It is the only candidate that is simultaneously cross-platform, a pure-Nix flake
library (matching the "repo-specific flake.nix that includes the claude
sandboxing utilities" requirement), and agent-aware. It supersedes the
`jail.nix` prior art in `docs/flake-original.nix`.

Caveats accepted: macOS relies on Apple-deprecated `sandbox-exec` (works today);
the upstream license carries a non-standard "human person" clause (worth a quick
legal glance, not a blocker). Claude Code's own `/sandbox` is **not** sufficient —
it only confines the Bash tool's subprocesses, not the whole process.

### Other decisions
- **Sandbox posture: hardened + network allowlist.** `$HOME` tmpfs masks
  `~/.ssh`/`~/.aws`; writable scope = worktree cwd + `~/.claude*` + the repo
  `.git`; egress limited to a domain allowlist with DNS blocked.
- **`git push` stays outside the sandbox.** Accepted trade-off: SSH keys are
  masked inside the jail, so the user pushes/fetches from their own
  non-sandboxed shell. Only `claude` is sandboxed.
- **`tm` restore: keep generic improvements.** Revert all claude/worktree/agent
  logic; keep the enhanced no-args visibility view + `2>/dev/null` guards.
- **`csb` surface: launch + cleanup + list.**

## Repo layout

```
csb
├── bin/csb                  # orchestrator script (bash)
├── bin/tm                   # restored tm (generic improvements kept)
├── flake.nix                # lib (mkClaudeSandbox, readAllowedDomains) + generic sandboxed claude + csb pkg + template
├── templates/repo/flake.nix # scaffold for a consuming repo (devShell + sandboxed claude)
├── install.sh               # symlink bin/* into ~/bin
└── README.md
docs/                        # unchanged prior art
```

## 1. Restore `tm` (`bin/tm`, and overwrite `~/bin/tm`)

Start from `docs/tm_original`; re-add only the **generic** pieces from `docs/tm`:
- The no-args visibility view (`Sessions:` + `Windows:` via
  `tmux list-windows -a -F '#S:#W  #{pane_current_path}'`) guarded with
  `2>/dev/null || true`.
- Drop everything claude/worktree/agent-related: all git/worktree helpers, `-d`
  delete mode, `setup_agent_pane`, `.worktreeinclude`, the agent-window branch,
  the worktree header docs. `CMD` pass-through restored exactly.

## 2. `bin/csb` — orchestrator (bash, mirrors tm's style)

Commands: `csb [branch]`, `csb -d <branch>`, `csb` (no args → list).

- **`csb <branch>` (launch):**
  1. Resolve repo root from cwd; refuse if cwd is itself a worktree (no nesting).
  2. `ensure_worktree`: reuse if `git worktree list` already has the branch; else
     `git worktree add -b <branch> <repo>/.worktrees/<flattened>` off current HEAD
     (existing branch → `worktree add` without `-b`). Reuses tm's helper logic
     (`flatten_branch`, `find_worktree`, `branch_exists`).
  3. `process_worktreeinclude` (carried over from tm — workspace plumbing belongs
     here): copy gitignored+included files into new worktrees, never overwriting.
  4. **Launch the sandbox** rooted at the worktree (see §4). Foreground exec in
     the current terminal — no tmux; the user manages panes/windows with `tm`.
- **`csb -d <branch>`:** `git worktree remove` the worktree (branch not deleted);
  idempotent; prints `--force` hint on failure.
- **No args:** `git worktree list` filtered to `.worktrees/*`.

## 3. Nix flake (`flake.nix`)

Inputs: `nixpkgs`, `agent-sandbox` (`github:archie-judd/agent-sandbox.nix`),
`claude-code` (sadjow overlay for fresh official binaries).

Outputs:
- **`lib.${system}.mkClaudeSandbox`** — wrapper over `agent-sandbox`'s `mkSandbox`
  encoding hardened defaults:
  - `pkg = pkgs.claude-code`, `binName = "claude"`, `outName = "claude-sandboxed"`.
  - `allowedPackages` = **minimal runtime only**: `coreutils bash git ripgrep less
    cacert` (+ toolchains passed in by the consumer). `git` is included so claude
    can inspect history (`log`/`diff`/`blame`/`show`) and commit. **No**
    neovim/tmux/interactive tools — those live in the devShell.
  - **rw-bind `~/.claude` + `~/.claude.json`** (auth/config persistence — needed
    because `$HOME` is tmpfs).
  - **Worktree `.git` is handled automatically by `agent-sandbox`** — its wrapper
    runs `git rev-parse --git-common-dir` in cwd at launch and binds the resolved
    shared `<repo>/.git` (rw object store; `hooks/`+`config` forced read-only to
    block hook-injection). It also ro-binds the main repo root, so claude can
    *read* the whole repo + sibling worktrees (read-only), not just its cwd. No
    impurity or path-passing needed — this is why the pure repo-flake model holds.
  - Local git (incl. `commit`) works inside the jail; **push/fetch over SSH stays
    in the non-sandboxed shell** (keys are masked by the tmpfs `$HOME`).
  - `allowedDomains` = hardened defaults ⊕ caller's `extraDomains`.
  - Wrapped binary forwards all args to `claude`, so permission/CLI flags
    (e.g. `--dangerously-skip-permissions`) pass straight through (see §7).
- **`lib.${system}.readAllowedDomains`** — parses a `.csb/allowed-domains` file
  into the `agent-sandbox` domain attrset (see §5).
- **`packages.${system}.claude-sandboxed`** — generic sandbox (cwd-only) for repos
  without their own flake.
- **`packages.${system}.csb` + `apps`** — the script, for `nix run`.
- **`templates.default`** → `templates/repo/flake.nix`.

## 4. Sandbox resolution in csb (the launch step)

Keeps repo dev-shells and claude jailing as separate concerns. **A repo flake is
mandatory** — there is no generic/impure fallback:
1. The repo flake must expose `packages.<system>.claude-sandboxed` →
   `cd <worktree> && nix run <repo>#claude-sandboxed -- <claude-args>` (repo injects
   its own toolchains/domains).
2. If that output is missing, csb errors with a hint to run
   `nix flake init -t <csb>` and wire up `mkClaudeSandbox`.
3. `--no-sandbox` escape hatch runs `claude` unjailed for debugging.

## 5. Per-repo domain allowlist (in scope)

**Convention: `.csb/allowed-domains` in the repo root.** Line-based, `#` comments,
`domain [METHODS...]` (methods default to `*`):

```
api.mycorp.internal   *
docs.example.com      GET HEAD
```

- **`csb.lib.readAllowedDomains <path>`** parses the file into the attrset
  `agent-sandbox` expects. Effective allowlist =
  hardened built-in defaults ⊕ `.csb/allowed-domains` ⊕ `CSB_EXTRA_DOMAINS` env.
- The repo template wires
  `extraDomains = csb.lib.readAllowedDomains ./.csb/allowed-domains` — add a domain
  by editing a tracked file, no flake edits. Read purely at eval time (the repo
  flake is mandatory, so there is no impure path to worry about).
- csb echoes the effective allowlist on launch for transparency.

## 6. Consuming-repo template (`templates/repo/flake.nix`)

`nix flake init -t <csb>` scaffolds a `flake.nix` that:
- Defines `devShells.default` with **interactive tools** (neovim, tmux, toolchains)
  — for the human.
- Defines `packages.claude-sandboxed = csb.lib.mkClaudeSandbox {
  allowedPackages = [ <repo toolchains> ];
  extraDomains = csb.lib.readAllowedDomains ./.csb/allowed-domains; }` — for the agent.

This is the separation the PLAN asks for: devShell = flexible/interactive;
sandbox = minimal/isolated.

## 7. Permission mode (allow-all inside the sandbox)

The sandbox is the security boundary, so running claude with its own prompts
disabled is the intended pattern. The wrapped binary forwards args to `claude`:
- `csb <branch> -- <args...>` passes `<args...>` straight to claude
  (e.g. `csb feature/foo -- --dangerously-skip-permissions`).
- `csb -y <branch>` (alias `--yolo`) injects `--dangerously-skip-permissions`.
- **Default: OFF** — claude runs with its normal permission prompts unless you
  opt in with `-y` (or pass the flag after `--`). Residual risk when you do opt
  in, even jailed: claude can still modify/destroy the worktree cwd (uncommitted
  work) and reach allowlisted domains.

## Workflow

```
tm myrepo               # human: tmux session at the repo (restored tm)
csb feature/foo         # in a pane: worktree + hardened sandboxed claude (prompts on)
csb -y feature/foo      # ...or allow-all mode (--dangerously-skip-permissions)
# git push happens in your own shell, outside the sandbox
csb -d feature/foo      # tear down the worktree when done
```

## Testing checklist

- Fresh-branch create; reuse existing worktree; reuse after window killed; remote
  branch; refuse nested worktree; `.worktreeinclude` copy; `csb -d` idempotency.
- Local git works inside the sandbox from within a worktree — `log`/`diff`/`show`
  read prior versions, `commit` succeeds (verifies `agent-sandbox`'s
  `--git-common-dir` auto-bind); SSH push from inside is blocked (keys masked).
- Network allowlist: allowed domain works, others blocked; `.csb/allowed-domains`
  picked up via the repo flake.
- Default mode shows permission prompts; `csb -y` / `-- --dangerously-skip-permissions`
  enables allow-all.
- Missing `claude-sandboxed` output → csb errors with the `nix flake init` hint.
- Launch on `aarch64-darwin` (this machine) and `x86_64-linux` (target).

## Out of scope (future)

- `csb -D` to also delete the branch.
- macOS `sandbox-exec` deprecation contingency.
