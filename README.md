# csb — claude sandbox

`csb` runs [Claude Code](https://www.anthropic.com/claude-code) **sandboxed**, in a
**per-branch git worktree**. You get a fresh, isolated working directory for each
branch and an agent that's jailed to it — with a hardened filesystem and a network
egress allowlist — on both Linux and macOS.

It pairs with [`tm`](./bin/tm) (a thin tmux workspace switcher): you manage tmux
yourself, outside the sandbox; only `claude` is jailed.

## How it works

- The sandbox is provided by [`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix),
  which uses **bubblewrap** on Linux and **`sandbox-exec`** on macOS.
- `csb` creates/reuses a worktree at `<repo>/.worktrees/<branch>` (branched off your
  current `HEAD`), then launches the repo's `claude-sandboxed` package with that
  worktree as the working directory.
- Each repo provides its own `claude-sandboxed` via a small flake (see below), so
  the repo controls the agent's toolchain and network allowlist while keeping its
  interactive dev shell separate.

### Sandbox posture (hardened)

- `$HOME` inside the jail is an ephemeral tmpfs, so `~/.ssh`, `~/.aws`, etc. are
  **not visible**. Only `~/.claude` and `~/.claude.json` are bound back in (for auth
  and config).
- Writable scope = the worktree cwd. The repo's `.git` object store is bound rw so
  `git commit`/`log`/`diff`/`blame` work inside the jail; `.git/hooks` and
  `.git/config` are read-only (no hook-injection escape). The rest of the main repo
  is read-only.
- Network egress is limited to an allowlist (DNS is otherwise blocked). Built-in
  defaults: `anthropic.com`, `claude.com`, `claude.ai`, `registry.npmjs.org`,
  `github.com`, `githubusercontent.com`. Add more per-repo (see below).
- **`git push`/`fetch` over SSH happens in your own shell**, not inside the jail
  (SSH keys are masked by the tmpfs `$HOME`).

## Install

```sh
./install.sh            # symlinks bin/csb and bin/tm into ~/bin
# or: BIN_DIR=~/.local/bin ./install.sh
```

Requires [Nix](https://nixos.org) with flakes enabled (Determinate Nix works out of
the box). `csb` calls `nix run` under the hood.

## Set up a repo

From the repo root:

```sh
nix flake init -t github:atongen/csb
git add flake.nix flake.lock .csb/allowed-domains .gitignore
```

This scaffolds:

- `flake.nix` — a `devShells.default` for your interactive tools (neovim, tmux,
  toolchains) **and** a `packages.claude-sandboxed` built from
  `csb.lib.<system>.mkClaudeSandbox`. Edit `allowedPackages` to match your repo's
  runtime toolchain (e.g. `nodejs`, `cargo`).
- `.csb/allowed-domains` — extra egress domains (one `domain [METHOD...]` per line).
- `.gitignore` — ignores `.worktrees/`.

> Files must be **git-tracked** for the flake (and `.csb/allowed-domains`) to be read.

## Use

```sh
csb feature/foo            # worktree for feature/foo + sandboxed claude (prompts on)
csb -y feature/foo         # allow-all mode (--dangerously-skip-permissions)
csb feature/foo -- --model opus   # pass extra args straight to claude
csb                        # list csb worktrees
csb -d feature/foo         # remove the worktree (branch is kept)
csb --no-sandbox feature/foo      # debugging escape hatch: run claude unjailed
```

Typical workflow with `tm`:

```sh
tm myrepo                  # tmux session/window at the repo
csb feature/foo            # in a pane: worktree + jailed claude
# edit / git push from your own (unsandboxed) shell as usual
csb -d feature/foo         # tear down when done
```

## Per-repo network allowlist

Add domains the agent legitimately needs to `.csb/allowed-domains`:

```
api.mycorp.internal   *
docs.example.com      GET HEAD
```

These merge on top of the built-in defaults. `csb` prints the effective allowlist
on launch.

## `.worktreeinclude`

If a repo has a `.worktreeinclude` file (same syntax as `.gitignore`), `csb` copies
matching **gitignored** files (e.g. local `.env`s) into a newly created worktree.
Existing files are never overwritten.

## Files

```
bin/csb                    orchestrator: worktree + launch
bin/tm                     tmux workspace switcher (no agent logic)
flake.nix                  lib.mkClaudeSandbox / lib.readAllowedDomains + csb app + template
templates/repo/            scaffold for a consuming repo
install.sh                 symlink bin/* into ~/bin
```

See [`PLAN.md`](./PLAN.md) for the design rationale and the research behind the
backend choice.
