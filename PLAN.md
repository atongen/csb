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

---

# As-built: sandbox auth & git identity (macOS findings)

Integrating drip (the first real csb target) surfaced a chain of macOS-specific
facts about authenticating the jailed claude. This records the resulting design
and the why, so it isn't relearned.

## Findings

- `agent-sandbox` jails with an **ephemeral tmpfs `$HOME`** — your real
  `~/.claude`, `~/.claude.json`, `~/.ssh`, and the macOS Keychain are all
  invisible inside the jail by default.
- **macOS stores Claude's OAuth token in the login Keychain** (item
  `Claude Code-credentials`), not in a file — and the jail can't reach the
  Keychain. (Linux stores a file credential at `~/.claude/.credentials.json`,
  which *is* bindable — the easy path that simply doesn't exist on macOS.)
- `CLAUDE_CONFIG_DIR` relocates `~/.claude` but **not** `~/.claude.json` (where
  the `hasCompletedOnboarding` marker lives).
- **Token forwarding is the macOS auth path.** `env = { CLAUDE_CODE_OAUTH_TOKEN =
  "$CLAUDE_CODE_OAUTH_TOKEN"; }` — agent-sandbox expands the `"$VAR"` reference in
  the launching shell, so the secret never lands in `/nix/store` (confirmed in its
  source + README; its seatbelt profile also denies `kern.procargs2` to stop the
  jailed process scraping the token from host memory). Generate with
  `claude setup-token`, export on the host; csb passes it through.
- **Headless vs interactive:** `claude -p` authenticates with the token fine. But
  **interactive** claude on an *empty* config runs a first-run onboarding/login
  flow whose OAuth callback server can't bind a port in the jail → fails. Anthropic
  documents no flag to skip it (`--dangerously-skip-permissions` skips only *tool*
  prompts; `--bare` needs `ANTHROPIC_API_KEY`, not the OAuth token).

## As-built design (`mkClaudeSandbox` in csb's flake)

- **Do not bind real `~/.claude` / `~/.claude.json`** → the jail `$HOME` stays
  ephemeral; no personal history or MCP secrets are exposed.
- **Auth:** forward `CLAUDE_CODE_OAUTH_TOKEN` via `env` (runtime-expanded).
- **Onboarding seed:** a thin wrapper (`pkg = writeShellScriptBin "claude"`) writes
  `{"hasCompletedOnboarding":true}` into the jail's tmpfs `~/.claude.json` before
  exec'ing claude, so interactive claude skips login and uses the token. *Verified
  working.* (If claude later also gates on `lastOnboardingVersion`, add it.)
- **git identity:** `roFiles` binds `~/.gitconfig`, `~/.gitignore`,
  `~/.config/git/ignore` read-only so the jailed git has identity + ignores and
  claude can commit. `~/.config/git/config` is omitted (commonly absent; binding a
  missing path fails closed). Override via the `gitConfigFiles` arg.
- **Consequence:** local git + commits work in-jail; push/fetch over SSH stay in
  the unsandboxed shell (keys masked by the tmpfs `$HOME`), as intended.

## Isolation posture (decided)

Three options were weighed: **(A)** bind the real `~/.claude` (agent-sandbox's
stock template — simplest, but exposes your cross-project history + MCP tokens to
the agent); **(B)** a dedicated *shared* sandbox config dir; **(C)** ephemeral +
token + onboarding seed. **Chose C.** Note none of A/B/C isolate sandboxed agents
*from each other* — the only real distinction is whether your personal Claude data
is in reach of a (possibly auto-approved) agent. C excludes it entirely, at the
cost of no persistent session history across runs.

## vs the stock agent-sandbox Claude template

`templates/claude` binds the real `~/.claude` (rwDirs) + `CLAUDE_CONFIG_DIR`,
forwards `CLAUDE_CODE_OAUTH_TOKEN`, and documents a macOS Keychain→file export
(`security dump-keychain … > ~/.claude/.credentials.json`) for the bind path. We
deliberately diverge: **don't** bind `~/.claude`, and **seed** onboarding instead —
stricter isolation, same interactive result. The read-only-gitconfig idea is
borrowed from their template.

## drip dev flake (reference)

The drip repo flake provides a `devShells.default` (toolchain mirroring
`devbox.json` + native-gem deps + `bashInteractive`) for the human (console/tests
against host services, run via `nix-dev-pure.sh`), and `packages.claude-sandboxed`
(via `csb.lib.mkClaudeSandbox`) for the agent. Personal shell ergonomics (prompt,
bash-completion) live in `~/.config/nix-dev-pure.bashrc`, not the repo flake. Key
native-gem prerequisites discovered: `postgresql.pg_config` (its own output now),
`openssh` (gitconfig rewrites https→ssh), `which` (`lib/git.rb`), and a writable
`BUNDLE_PATH=vendor/bundle-nix` (the store ruby is read-only).

---

# Deferred / remaining work

## Sticky per-namespace token (deferred)

Right now `CLAUDE_CODE_OAUTH_TOKEN` must be exported on every launch, even for a
named namespace. Making it sticky (persist once, not required afterward) was
deferred — two approaches, both write the token to disk in plaintext (vs the
current `pass` flow), which is inherent to "sticky":

- **A — claude-native:** write `<ns>/.credentials.json` so claude reads it
  directly. Downsides: the token lands in the bound namespace dir, which the jail
  mounts via the fixed `~/.csb/claudes` parent — so it's readable by agents in
  *other* namespaces (cross-namespace credential theft); and it needs claude's
  exact credential JSON schema (accessToken/refreshToken/expiresAt/scopes)
  reconstructed from just the OAuth token — fragile.
- **B — csb-managed, host-side (preferred):** persist the token *outside* the bind
  (e.g. `~/.csb/tokens/<ns>`, mode `0600`); csb saves it on first `--ns` launch and
  re-forwards it via the env var on later launches. The token file never enters
  the jail filesystem (only the env var, which the agent has anyway); no
  cross-namespace file exposure; no schema guessing.

If/when we do this, prefer **B**. Note the cross-namespace exposure is a property
of the fixed-parent-bind; truly isolating namespaces from each other (per-ns bind)
would require giving up runtime `--ns` switching.

## Remaining features / verification

1. **`global` namespace** — DONE. `--ns global` runs a separate
   `claude-sandboxed-global` variant that binds the real host `~/.claude` +
   `~/.claude.json` and runs `claude` directly (no seed), so csb never mutates the
   real config. Sticky like other namespaces; creates no namespace dir.
2. **`--here` flag** — DONE. Runs the sandbox in the current directory with no
   worktree (skips `ensure_worktree`, cwd = `$PWD`, allowed inside a worktree).
   Caveat surfaced in `--help`: operates on the live checkout (less isolated).
3. **Allow specific local ports** — TODO. Let the jailed claude reach selected
   host `localhost` ports (e.g. Postgres/Redis) so it can run DB-backed tests
   itself, instead of only the human's devShell. This is the host-loopback problem
   from the local-models follow-up (agent-sandbox strips the net namespace + blocks
   loopback); needs investigation of whether agent-sandbox can permit a specific
   host loopback port, and the isolation trade-off of doing so.
4. **Linux verification** — TODO (gated on the push below). Exercise the whole flow
   on `x86_64-linux`: the sandbox build, token-env auth, the onboarding/trust seed,
   git identity, namespaces, `--no-sandbox`-in-devShell, and confirm
   `CLAUDE_CONFIG_DIR` relocation behaves the same (on Linux, file credentials at
   `~/.claude/.credentials.json` also exist, which may make the sticky-token story
   easier than on macOS).
5. **Push csb + flip `CSB_SELF`** — `CSB_SELF` default is now flipped to
   `git+ssh://git@git.grandrew.com/atongen/csb.git` (done). Remaining: **push csb
   to that remote** so it resolves; then Linux verification (#4) can fetch it.
   For local dev against the working tree, override `CSB_SELF=path:/path/to/csb`.

## Remaining capability work (makes the *sandbox* itself useful — M2)

Consolidated, since several threads point here (also see the M1-vs-M2 section):
- **Sticky per-namespace token** — above; prefer option B.
- **Tailored sandbox** — bake the repo's toolchain + egress domains into the jail
  so the *sandboxed* agent can run/verify (today the jail is generic-minimal; full
  capability is only via `--no-sandbox`). Needs: (a) a per-repo config convention
  (globally-gitignored `.csb/` for packages/domains, read from the repo root —
  same pattern `.worktreeinclude` uses, except `.worktreeinclude` is now a
  *tracked, generic* worktree convention), and (b) **host DB/Redis access** (the
  `#3` investigation below: Linux unix-socket bind is the no-patch path; macOS
  needs a seatbelt patch or DB-in-sandbox).
- **Other agents / local models** — the `mkAgentSandbox` generalization +
  local-model networking/GPU/secrets (its own follow-up section earlier).

> Note: `tm` has been **removed from csb** — it's a complementary, standalone tool
> (it lives in your `~/bin` independently). csb now ships only `bin/csb`.

## Reaching host DB/Redis from the jail — investigation result (for #3)

Verified against agent-sandbox source. **Host loopback is blocked unconditionally
on both platforms, and its proxy is HTTP/HTTPS-only** — it cannot tunnel the
Postgres/Redis wire protocol. There is **no built-in knob** to allow a specific
host TCP port (`allowedDomains` is domain/HTTP-method only). Linux uses pasta +
nftables that drop the host-loopback gateway (`10.0.2.2`); macOS seatbelt denies
`network-outbound` to `localhost`. Maintainer's stance: run the service inside the
sandbox, or open an issue.

Options if we ever want the *jailed agent* (not the devShell human) to run
DB-backed tests:

- **A. Run Postgres/Redis inside the sandbox** — add them to `allowedPackages`,
  persist a data dir via `rwDirs`, connect to the jail's own loopback. Works on
  both OSes, best isolation, but it's a separate ephemeral DB, not your real one.
- **B. Unix-domain socket bind-mount (preferred on Linux; no patch).** Connecting
  to an `AF_UNIX` socket is a *filesystem* op on Linux, and agent-sandbox's Linux
  path has **no seccomp/AF_UNIX restriction** — so binding the host PG/Redis
  **socket directory** via `extraRwDirs` (bind the dir, not the socket inode) lets
  the agent reach the *real* host DB over the socket, no networking involved.
  Requires app config to use the socket (`PGHOST=/socketdir`; Redis `unixsocket`).
  **macOS does NOT allow this unpatched:** seatbelt classifies a unix-socket
  `connect()` as `network-outbound (remote unix-socket …)` and denies it
  *independently of filesystem access* (open mode has an explicit
  `(deny network-outbound (remote unix-socket))`, restricted mode lacks any allow
  → `(deny default)`). Their `test-unix-socket-egress-denied.sh` proves a bound
  host socket still fails to connect. macOS parity would need patching the seatbelt
  profile: `(allow network-outbound (remote unix-socket (path-literal "/…/.s.PGSQL.5432")))`.
- **C. Patch agent-sandbox** to allow specific loopback ports (Linux: nftables/
  pasta `-t` flags; macOS: seatbelt rule). Small edits but means maintaining a fork.

No csb changes are needed for **B** — `mkClaudeSandbox` already exposes
`extraRwDirs`/`extraRoDirs`; it's a per-repo flake + app-config pattern. Status:
**deferred / do nothing for now** — under the current design the human runs
DB-backed tests in the devShell; the jailed agent edits code.

## Sandbox toolset is intentionally minimal (NOT the devShell)

The jailed `claude-sandboxed` only gets csb's `defaultAllowedPackages` (coreutils,
bash, git, ripgrep, less, cacert) **plus whatever the repo flake passes as
`allowedPackages`** (drip: just `ruby_3_3` + `nodejs_24`), and **none of the
devShell's `shellHook` env** (no `DYLD_FALLBACK_LIBRARY_PATH`/`LD_LIBRARY_PATH`,
no `BUNDLE_PATH`, etc.). So the agent cannot boot the full Rails app: gems with
native runtime deps (e.g. **ruby-vips** needs `libvips`; also imagemagick, the pg
client lib, libyaml/libffi) aren't present, and even if they were, the DB is
unreachable (above). This is by design — minimal, isolated agent vs. flexible
devShell. If we ever want the agent to run Rails (rubocop, non-DB unit tests,
`rails runner`), expand drip's `mkClaudeSandbox` `allowedPackages` to mirror the
devShell's runtime libs and add the matching lib-path env — a deliberate
toolset-vs-isolation choice, not a bug.

## M1 vs M2: where verification happens (and what makes allow-unsafe worth it)

There are two coherent operating models, and they change the value of running the
agent with `--dangerously-skip-permissions` (allow-unsafe / YOLO):

- **M1 (current): agent edits in the jail, the human verifies in the devShell.**
  The sandbox is intentionally minimal (no full toolchain, no DB), so the agent
  can't boot the app / run the suite. Simplest and most isolated, but allow-unsafe
  here is "edit aggressively without prompts, but fly blind" — the safety is real,
  the *autonomy* mostly isn't, because the agent can't close an edit→run→fix loop.
  (It can still do `git diff`, grep, parse/syntax, RuboCop, and pure-Ruby unit
  tests that don't boot Rails or hit the DB.)
- **M2 (target for allow-unsafe to pay off): agent edits AND verifies in a
  full-capability jail.** Give the sandbox the devShell's runtime libs (the
  toolset item above) *and* service access (the unix-socket/DB item above), and
  the agent can run the real suite — making allow-unsafe genuinely valuable:
  contained, credential-isolated, autonomous edit→test→fix loops. Cost: a heavier,
  less-minimal sandbox.

We built M1 (safety first) and deferred capability. The practical takeaway: the
"expand toolset" + "service access" items are not just nice-to-haves — they are
**what converts allow-unsafe from safe-but-blind (M1) into safe-and-autonomous
(M2)**. If allow-unsafe is a priority, those two items should move up.

---

# Nix flake best practices (2025–2026 research) + the csb decoupling plan

Captured so it isn't lost. Sources: nix.dev, flake.parts, NixOS Wiki, nixpkgs
manuals, and assorted well-regarded posts (ayats.org, nixcademy, jade.fyi, flox).

## Flake structure

- **`flake-parts`** is the de-facto modern way to structure a non-trivial,
  multi-output flake you own — it brings the NixOS module system to `flake.nix`
  (typed options, merging, `perSystem` that defines outputs once and transposes
  across systems, `self'`/`inputs'`, composable `flakeModule`s).
- **`flake-utils` / `eachDefaultSystem`** is community-*discouraged* (not formally
  deprecated): no validation, an avoidable eval dep, opaque system coverage.
- **Bare `genAttrs` `forAllSystems`** (what csb + the simple drip flake use) is the
  right *minimalist* choice specifically for flakes meant to be **consumed by
  others** — adds zero deps to their lock.
- Alternatives are mostly complementary: **devenv** (dev shells; ships a flake
  module), **haumea** (fs→attrset loader, below the output layer), snowfall (dotfiles),
  std/divnix (monorepo DevOps), and emerging numtide **Blueprint** / the
  **dendritic** pattern. No official nix.dev endorsement of any framework.

## Dev vs production outputs

- Principle: **devShell = the build-time toolchain + dev tools you *enter*
  (a superset); production = the built package's minimal *runtime closure* you
  *ship*** (or a container of it). Never deploy a devShell.
- Define the app **once** in `nix/package.nix` (`callPackage`), expose as
  `packages.<sys>.default`. The dev shell **reuses** it:
  `mkShellNoCC { inputsFrom = [ self'.packages.default ]; packages = [ dev-only ]; }`
  — single source of truth for build deps.
- `nativeBuildInputs` (build-only) vs `buildInputs` (runtime) is *hygiene, not
  enforcement*: closure membership is determined by actual store-path references.
  Verify with `nix path-info -rsh`; use `makeWrapper` to pin only real runtime deps.
- Output roles: `packages.*` = deployables; `devShells.*` = `nix develop` envs;
  `apps.*` = thin `nix run` pointers.

## Containers & staging-vs-prod

- Minimal OCI images: **`dockerTools.streamLayeredImage`** (streams the tarball,
  no multi-GB store blob — good for a Rails closure) or **`nix2container`** (fast
  incremental pushes). Only the runtime closure ships; reproducible by default.
- **Staging vs prod = build once, promote the same image digest, inject config at
  runtime via env vars (12-factor).** Don't rebuild per environment. For NixOS
  *hosts* instead, the idiom is separate `nixosConfigurations.{staging,production}`
  parameterized at build time via module options/`specialArgs`.
- Deploy tooling (NixOS): `nixos-rebuild --target-host` (simplest/blessed),
  **deploy-rs** (flake-native, auto-rollback), **colmena** (fleets). NixOps is dead.

## DRY / the "contract"

- One `package.nix`; expose **`overlays.default`** (`final: prev: { drip = final.callPackage ./package.nix {}; }`).
  Your own `packages.default` reads back from the same overlay — one definition
  feeds your outputs *and* external consumers.
- `overlays.default` + `nixosModules.default` (plural names) + `packages.default`
  are the standardized contract other flakes consume. `lib` output for pure helpers.

## Rails specifics (+ gotchas)

- Build with **`bundlerEnv`** + **`bundix`** (`gemset.nix`, committed).
  `defaultGemConfig` handles pg/nokogiri/ffi; extend per-gem as needed.
- **Restrict gem groups for prod** (`groups = [ "default" "production" ]`) — naive
  all-groups was ~2 GB vs <200 MB.
- Assets: **importmap-rails (Rails 7+ default) = no JS build / no Node**; if using
  jsbundling/shakapacker, pre-fetch JS deps in a fixed-output derivation
  (`fetchYarnDeps`/`pnpm.fetchDeps`) — the build sandbox has no network.
  Precompile with `SECRET_KEY_BASE_DUMMY=1`.
- Minimal image: `cacert` + `tzdata` + `dockerTools.fakeNss` + writable `tmp/`
  (store is read-only); migrations as a separate one-shot, not the puma entrypoint.
- Gotchas: `BUNDLED WITH` mismatch (override bundler in an overlay — already hit);
  **pin a specific `ruby_3_y`** and verify vs your nixpkgs rev (default trails the
  tree); `BUNDLE_FORCE_RUBY_PLATFORM=true bundle lock` (`force_ruby_platform`) so
  Nix builds gems from source; `mkYarnPackage`/`yarn2nix` are **removed** (use the
  hook-based JS tooling); bundix is dormant but works.

## Recommended multi-env skeleton

```
flake.nix          # flake-parts; imports ./nix/*; own nixpkgs
nix/package.nix    # the app derivation (bundlerEnv + asset FOD)
nix/overlay.nix    # overlays.default → drip
nix/devshell.nix   # mkShellNoCC { inputsFrom = [ self'.packages.default ]; packages = [dev-only]; }
nix/container.nix  # streamLayeredImage of the runtime closure
nix/nixos/…        # nixosModules.default + nixosConfigurations.{staging,production}
```

## Opt-in integration: consumer-pulls (the csb decoupling)

The idiomatic way to keep an integration opt-in is **consumer-pulls**: the
external tool imports the repo as an input and reads its standard outputs/overlay;
**the repo never imports the tool.** Overlays are the preferred decoupling
mechanism (the consumer merges your package into *its own* nixpkgs); plural output
names; `inputs.repo.inputs.nixpkgs.follows` keeps it cheap.

### DECIDED DIRECTION: fully decouple csb from the repo flake

- **The repo flake (drip) is a normal standalone flake** — own `nixpkgs`,
  `devShells`, and (later) `packages.default` + `overlays.default`. It has **no
  csb input and no `claude-sandboxed*` outputs.** Usable by anyone (dev/CI/prod)
  with zero knowledge of csb. *(Done: drip's `flake.nix` is now just the dev shell
  on its own nixpkgs; package/overlay/container outputs to be added later per the
  skeleton above.)*
- **csb is a pure consumer — AS BUILT.** csb supplies the claude binaries from
  its OWN flake via `CSB_SELF` (default: the network-local remote
  `git+ssh://git@git.grandrew.com/atongen/csb.git`; override `CSB_SELF=path:…`
  for local dev against a working tree). Two modes:
  - **Sandboxed** (`csb <branch>`) → `nix run "$CSB_SELF#claude-sandboxed[-global]"`
    — csb's **generic** jail (minimal, language-agnostic toolset). The repo flake
    is not consulted, so any git repo works.
  - **`--no-sandbox`** → `nix develop "<worktree>" --command "$CSB_SELF#claude"`
    — claude inside the repo's **own devShell** (full toolchain; works where host
    claude isn't on PATH). Namespacing applies in both modes.
- **Status: DONE.** drip flake standalone (done); csb-side consumer (done:
  `CSB_SELF`, generic sandbox, devShell `--no-sandbox`, `packages.claude`; template
  is now a plain devShell flake). **Note:** we deliberately did NOT build the
  earlier ephemeral-flake / "repo-toolchain-into-the-jail" idea — instead the
  sandbox is generic and full capability comes from `--no-sandbox` in the devShell
  (the M1/M2 split). A repo-*tailored sandbox* (toolchain + domains baked into the
  jail, via a `.csb/` convention or a repo overlay) is **deferred** — see below.
