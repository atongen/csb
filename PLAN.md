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

---

# Follow-up: running other agents / local models (not just claude-code)

Today the whole pipeline is hardwired to Claude Code. This section scopes what it
would take to run a *different* cloud agent (Codex/OpenAI, Gemini CLI, aider,
opencode, …) or a *local* model (Ollama, llama.cpp, vLLM, LM Studio). The easy
part is swapping the agent; the real curveball is local models vs. the network
jail.

## Where "claude" is hardcoded (the swap surface)

- **`flake.nix`** — `mkClaudeSandbox` pins `pkg = pkgs.claude-code`,
  `binName = "claude"`, `outName = "claude-sandboxed"`, `rwDirs = ["$HOME/.claude"]`,
  `rwFiles = ["$HOME/.claude.json"]`, and the Anthropic-centric `defaultDomains`.
  The `claude-code` overlay is a flake input.
- **`bin/csb`** — launches `#claude-sandboxed`; `--no-sandbox` execs `claude`;
  `-y` injects the Claude-specific `--dangerously-skip-permissions`;
  `ensure_claude_state` creates `~/.claude` + `~/.claude.json`; `print_allowlist`
  hardcodes the Claude defaults.
- **`templates/repo/flake.nix`** — the `claude-sandboxed` package + `mkClaudeSandbox`.

## Step 1 — generalize the wrapper: `mkAgentSandbox` + presets

Refactor `mkClaudeSandbox` into a generic `mkAgentSandbox` and make Claude one
preset among several:

```nix
mkAgentSandbox {
  package;                 # the agent CLI derivation
  binName;                 # "claude" | "codex" | "aider" | ...
  outName ? "${binName}-sandboxed";
  stateDirs ? [ ];         # rw $HOME dirs to persist  (e.g. ["$HOME/.claude"])
  stateFiles ? [ ];        # rw $HOME files to persist (e.g. ["$HOME/.claude.json"])
  domains ? { };           # egress allowlist for THIS agent's API
  yoloArgs ? [ ];          # the allow-all flag(s) for this agent
  allowedPackages ? [ ];
  env ? { };               # NON-secret env only (see secrets note)
}
```

Ship a small registry of presets (the agent name → spec), e.g.:

| agent | pkg | binName | state paths | egress domains | allow-all flag |
|---|---|---|---|---|---|
| claude | `claude-code` | `claude` | `~/.claude`, `~/.claude.json` | anthropic/claude | `--dangerously-skip-permissions` |
| codex | `codex` | `codex` | `~/.codex` | `api.openai.com` | `--full-auto` (verify) |
| gemini | `gemini-cli` | `gemini` | `~/.gemini` | `generativelanguage.googleapis.com` | (verify) |
| aider | `aider-chat` | `aider` | `~/.aider*` | provider-dependent | `--yes` (verify) |
| local | (see below) | varies | model cache dir | none / LAN host | varies |

`mkClaudeSandbox` stays as a thin alias over the `claude` preset for back-compat.
(`agent-sandbox` itself already ships `claude` + `copilot` templates, confirming
this multi-agent shape is the intended use.)

## Step 2 — make `csb` agent-agnostic

- Select the agent via `--agent NAME` (flag), `CSB_AGENT` (env), or a per-repo
  `.csb/agent` file; default `claude`.
- Launch `nix run "$flake#${agent}-sandboxed"` instead of the literal name.
- Keep csb free of a hardcoded per-agent table by having the repo flake expose
  per-agent **metadata** (state paths, `yoloArgs`, `binName`) that csb reads via
  `nix eval --json`. csb then: `mkdir -p` the state paths (agent-sandbox fails
  closed on missing bind targets), map `-y` → that agent's `yoloArgs`, and print
  the agent's allowlist. This generalizes `ensure_claude_state` and
  `print_allowlist` without csb knowing any agent specifics.
- Naming: `csb` = "claude sandbox" — either keep the name and document it as
  agent-generic, or rebrand to "code sandbox".

## Step 3 — the real curveball: local models

`agent-sandbox` removes the network namespace, blocks DNS, and makes **host
loopback unreachable** by default. So a jailed agent **cannot** reach a model
server running on the host's `127.0.0.1` (e.g. Ollama on `:11434`). Three patterns,
roughly increasing in isolation cost:

1. **Network-addressable endpoint via the allowlist (easiest).** Run the model on
   a LAN box or remote host reachable by hostname (self-hosted vLLM/Ollama/
   OpenAI-compatible), add that host to `.csb/allowed-domains`, point the agent's
   `OPENAI_BASE_URL` at it. Then a "local" model is just another API agent. Needs
   confirmation that the proxy allowlist accepts a LAN hostname / `host:port` /
   bare IP, and that name resolution works given DNS is blocked (see Q below).
2. **Model server inside the sandbox.** Add the runtime (ollama/llama.cpp/vLLM) to
   `allowedPackages`, **ro-bind the host weights dir** (e.g. `~/.ollama/models`,
   potentially tens of GB → read-only so it's not re-downloaded), start the server
   on the sandbox's own loopback, and point the agent there. Fully isolated but
   heavyweight, and the server is ephemeral per run (cold start). Likely needs GPU
   access (next bullet).
3. **Permit host loopback.** Investigate whether agent-sandbox can share the host
   net namespace / allow connecting to host `127.0.0.1`. This weakens isolation
   (re-opens an exfil channel — cf. upstream `allowLocalBinding` / issue #88) and
   may not even be supported for *connecting* to host loopback from a separate
   netns. Lowest-effort if supported, but the least safe.

**GPU:** patterns 2 (and any real local inference) need GPU passthrough — on Linux
binding `/dev/nvidia*` / `/dev/dri`, on macOS Metal access from within seatbelt.
Unknown whether agent-sandbox exposes device binds; this gates local-model
feasibility and needs verification.

## Step 4 — secrets / API-key auth (non-Claude)

Claude auths via a file (`~/.claude.json`) we bind in — clean. Key-based agents
read `OPENAI_API_KEY`/`GEMINI_API_KEY`/etc. from the environment, but the sandbox
**clears host env**, and the `env` attr's values are **baked into the world-readable
Nix store**. So: **never put secrets in `env`.** Preferred: bind a *creds file*
(file-based, like Claude). Alternative: a runtime env passthrough — if agent-sandbox
expands shell variables in `env` values (mirroring the `$HOME`-in-paths behavior),
`env.OPENAI_API_KEY = "$OPENAI_API_KEY"` would forward the host value without
storing it. Both need verification.

## Open research questions (verify against agent-sandbox source)

These were going to be confirmed at the source level before finalizing this section
(the verification pass was interrupted by a session limit):

1. **Host loopback:** can a jailed process *connect* to a service on the host's
   `127.0.0.1`? What exactly does `allowLocalBinding` permit (bind own ports vs.
   connect to host)? Any net-namespace-share / host-networking option?
2. **Proxy allowlist granularity:** does it accept `host:port`, bare IPs, and LAN
   hostnames — and does it function with DNS blocked for non-public names?
3. **Runtime env forwarding:** can a host env var reach the sandbox without writing
   the value into `/nix/store`?
4. **GPU/device access:** Linux `/dev/nvidia*` / `/dev/dri` binds; macOS Metal.
5. **Per-agent specifics:** exact state dirs/files and allow-all flags for codex,
   gemini-cli, aider, opencode.

## Effort estimate

- **Another cloud/API agent** (codex, gemini, aider): **small** — add a preset +
  the `--agent` plumbing in csb. The sandbox model is identical to Claude's.
- **Local model via a network endpoint** (pattern 1): **small-to-moderate** —
  mostly an allowlist entry + base-URL env, pending the proxy/DNS confirmation.
- **Local model in-sandbox** (pattern 2): **moderate-to-large** — weights bind,
  bundled runtime, GPU passthrough, cold-start ergonomics.
- **Host-loopback** (pattern 3): gated on an upstream capability that may not exist.
