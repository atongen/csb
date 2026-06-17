# csb — claude sandbox

`csb` runs [Claude Code](https://www.anthropic.com/claude-code) in a **per-branch
git worktree**, either **sandboxed** (jailed, isolated) or **unsandboxed inside the
repo's own dev shell** (full toolchain). It's a thin orchestrator over
[`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix) (bubblewrap
on Linux, `sandbox-exec` on macOS) and `nix`.

**Decoupled by design:** a repo needs no csb-specific files or flake. The sandboxed
agent comes from *csb's own* flake (so any git repo works), and `--no-sandbox` runs
claude inside whatever `devShells.default` the repo already has. The repo never
imports csb.

> Status: developed/tested on `aarch64-darwin`. Linux is supported by the
> underlying tooling but not yet verified end-to-end (see `PLAN.md`).

## Install

```sh
./install.sh                 # copies bin/csb into ~/bin
# or: BIN_DIR=~/.local/bin ./install.sh
```

Requires [Nix](https://nixos.org) with flakes (Determinate Nix works out of the
box); `csb` shells out to `nix`.

- **`CSB_SELF`** — the flake ref csb pulls its own claude binaries from. Defaults
  to the network-local remote `git+ssh://git@git.grandrew.com/atongen/csb.git`.
  For local development against a working tree, override per-invocation:
  `CSB_SELF=path:/path/to/csb csb …`.

## Auth

The jailed claude can't reach the macOS Keychain, so authenticate with a token.
Generate one once on the host and export it:

```sh
claude setup-token                       # prints a long-lived sk-ant-oat01-… token
export CLAUDE_CODE_OAUTH_TOKEN=…          # or, e.g.: CLAUDE_CODE_OAUTH_TOKEN=$(pass claude/token) csb …
```

csb forwards it into the sandbox at runtime (never written to the Nix store). The
token is currently needed on **every** launch (sticky per-namespace token storage
is planned — see `PLAN.md`). `ANTHROPIC_API_KEY` works too.

## Use

```sh
csb feature/foo                  # worktree for feature/foo (off HEAD) + sandboxed claude
csb -y feature/foo               # allow-all (--dangerously-skip-permissions)
csb feature/foo -- --model opus  # everything after -- is passed to claude
csb --no-sandbox feature/foo     # run claude UNSANDBOXED in the repo's dev shell (full toolchain)
csb --here                       # run in the current dir, no worktree (namespace = current branch)
csb --ns drip feature/foo        # override the namespace (default is the branch)
csb -E feature/foo               # ephemeral: throwaway config, no namespace
csb -n feature/foo               # just prepare/reuse the worktree, don't launch (prints its path)
csb -d feature/foo               # remove the worktree AND its namespace config (branch is kept)
csb                              # list csb worktrees
```

tmux is yours to manage (e.g. with a separate `tm`): run `csb` in one pane, edit /
`git push` from another. Only `claude` is ever jailed.

## Modes

- **Sandboxed** (`csb <branch>`) — a hardened, **generic** jail from csb's own
  flake. Minimal, language-agnostic toolset (coreutils, bash, git, ripgrep, less,
  cacert); it does **not** include the repo's toolchain, so it's best for editing,
  reading, search, and git — not running the app. The repo flake isn't consulted.
- **`--no-sandbox`** — claude run inside the repo's `devShells.default`
  (`nix develop <worktree> -c claude`): the **full toolchain** and your dev-shell
  env, unjailed. Needs a `flake.nix` with `devShells.default`. This is the mode for
  actually running consoles/tests. (Authenticates via your token; on macOS the nix
  claude may trigger a one-time Keychain-access prompt.)

This split is deliberate: the jail is the safe-but-minimal "editing" mode; full
capability lives in `--no-sandbox`. (See the M1-vs-M2 discussion in `PLAN.md`.)

## Namespaces

A namespace partitions the agent's claude config (history/sessions/settings).
**By default the namespace is the branch** (flattened, `/`→`-`), so config is
deterministic per branch with no hidden state to remember:

| Invocation | Namespace | Config |
|---|---|---|
| `csb feature/foo` | `feature-foo` (from the branch) | persistent `~/.csb/claudes/feature-foo` |
| `csb --here` (on `feature/foo`) | `feature-foo` (from current HEAD) | persistent, same dir |
| `csb --here` (detached HEAD) | — | **error: fail fast** |
| `csb --ns drip feature/foo` | `drip` (explicit override) | persistent `~/.csb/claudes/drip` |
| `csb -E feature/foo` | none | throwaway (not persisted) |
| `csb --ns global feature/foo` | global | your **real** `~/.claude` (csb never mutates it) |

- **(default)** — the namespace is the branch. Reused on every later run for that
  branch; switching branches switches config automatically.
- **`-E`, `--ephemeral`** — throwaway config, no namespace. Mutually exclusive with
  `--ns`.
- **`-N`, `--ns NAME`** — override the default with a named, isolated config under
  `~/.csb/claudes/NAME`.
- **`--ns global`** — use your **real** host `~/.claude` (full history/config); csb
  never mutates it. Honored only as an explicit `--ns`, so a branch literally named
  `global` gets a plain `~/.csb/claudes/global` dir, **not** your real config.

`csb -d <branch>` removes the worktree **and** its per-branch namespace config
(stale configs hold session history and the auth they were seeded with, so leaving
them around is a footprint risk). `-E`/`--ns global` are skipped on delete (nothing
persisted / it's your real config). Namespaces apply to both sandboxed and
`--no-sandbox` launches.

## Sandbox posture (hardened)

- `$HOME` in the jail is an ephemeral tmpfs — `~/.ssh`, `~/.aws`, and your real
  `~/.claude` are **not** visible. Nothing personal leaks in; auth is the forwarded
  token only.
- Interactive first-run login + folder-trust are pre-seeded so claude starts
  straight up; git identity is forwarded from your host `git config`
  (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`) so the agent can commit. Local git works;
  **`git push`/`fetch` over SSH stays in your own shell** (keys are masked).
- Writable scope = the worktree cwd; the repo's `.git` object store is bound so
  commits/log/diff work, with `.git/hooks` and `.git/config` read-only.
- Network egress is limited to an allowlist (DNS otherwise blocked):
  `anthropic.com`, `claude.com`, `claude.ai`, `registry.npmjs.org`, `github.com`,
  `githubusercontent.com`. (Per-repo egress tailoring is a future, tailored-sandbox
  feature; the generic jail uses these defaults.)

## `.worktreeinclude`

If the repo root has a `.worktreeinclude` (same syntax as `.gitignore`), csb copies
matching **gitignored** files (e.g. local `.env`s, generated config) into a newly
created worktree; existing files are never overwritten. It's a generic
worktree-tooling convention (predates csb), not csb-specific.

## What a repo needs

Nothing csb-specific. For `--no-sandbox`, just a standard `flake.nix` exposing
`devShells.default`. `nix flake init -t <csb>` scaffolds a minimal standalone dev
flake to start from.

## Files

```
bin/csb                    the orchestrator (worktree + launch)
flake.nix                  lib.mkClaudeSandbox/readAllowedDomains + packages
                           {csb, claude, claude-sandboxed, claude-sandboxed-global} + template
templates/repo/            scaffold: a standalone dev-shell flake
install.sh                 copy bin/csb into ~/bin
```

See [`PLAN.md`](./PLAN.md) for design rationale, the agent-sandbox research, the
auth model, and remaining work.
