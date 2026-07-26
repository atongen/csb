# csb -- claude sandbox

`csb` runs [Claude Code](https://www.anthropic.com/claude-code) -- or a shell --
in a **per-branch git worktree**, inside the **repo's own nix devShell**, behind
three layers:

1. **env scrub** -- `nix develop --ignore-environment` plus a small allowlist
   (extend with `-k/--keep` or a profile's `keep=`).
2. **private HOME** -- `HOME` is redirected to a per-namespace dir under
   `~/.csb/claudes` (one per repo by default, shared across its branches; or a
   throwaway dir with `-E`) for the launched process only.
3. **filesystem sandbox** (`sandbox-exec`/seatbelt on macOS, bubblewrap on
   Linux): **reads** are default-allow minus a deny-list (`~/.ssh`, `~/.aws`,
   the real `~/.claude`, ...), **writes** are default-deny plus an allow-list
   (the worktree, tmp, ...). On Linux the process also runs in its own PID
   namespace. Details in [Filesystem sandbox](#filesystem-sandbox).

> ### READ THE [THREAT MODEL](#threat-model) FIRST
>
> csb assumes a **trusted operator running trusted instructions**. It exists to
> prevent *accidents* -- accidental damage, accidental exposure of the obvious
> credentials, work bleeding between repos. It is **not** a boundary against a
> hostile agent or against prompt injection, and it should not be relied on as
> one.
>
> Two reasons, both deliberate and both load-bearing:
>
> - **Network and host services stay open by design**, so claude (and the `-s`
>   shell) can reach local db/redis/etc for testing. csb is not an egress
>   firewall: anything readable is exfiltratable.
> - **The sandbox constrains filesystem operations, and IPC only where it can.**
>   A host service that acts on the sandboxed process's behalf does its work
>   *outside* the sandbox, as you. Verified escapes of this shape existed on
>   both platforms and are now closed, but the class is not exhausted -- see
>   [Known gaps](#known-gaps) for what is closed, what stays open, and what is
>   accepted as unfixable.

**Decoupled by design:** the repo needs no csb-specific files. Its own
`flake.nix` with `devShells.default` is preferred, not required -- csb falls
back to a generic devShell otherwise (see [What a repo needs](#what-a-repo-needs)).
The claude binary comes from *csb's own* flake; the repo never imports csb.

> **Status.** Verified end-to-end on `aarch64-darwin` (seatbelt) and on NixOS
> (bubblewrap). Published at `github:atongen/csb`, which is `CSB_SELF`'s default,
> so `make install` and `nix run github:atongen/csb` work out of the box. Override
> `CSB_SELF` (`CSB_SELF=path:/path/to/csb`) only for local development against a
> working tree.
>
> **Use at your own risk.** This is a single-maintainer tool with no stability
> promise and no security guarantee (MIT, no warranty -- see `LICENSE`). Flags,
> defaults, profile keys, the sandbox policy and the containment approach itself
> **can and probably will change at any time**, including in ways that break
> your setup or that tighten or loosen what the sandbox permits. Pin a rev if
> that matters to you, read the [threat model](#threat-model) before relying on
> it for anything, and re-read it after upgrading.

## Quickstart

```sh
make install                     # copy bin/csb into ~/bin (must be on PATH)
export CLAUDE_CODE_OAUTH_TOKEN=...      # from 'claude setup-token'; or use --seed-creds
cd ~/src/your/repo               # a repo with a flake.nix (see "What a repo needs")
csb feature/foo                  # worktree for feature/foo + claude in the devShell
```

Requires [Nix](https://nixos.org) with flakes (Determinate Nix works out of the
box); `csb` shells out to `nix`.

Five environment variables tune csb:

- **`CSB_SELF`** -- the flake ref csb pulls its claude binary (and, on Linux,
  bubblewrap) from. Defaults to the public GitHub remote `github:atongen/csb`.
  For local development against a working tree, override per-invocation:
  `CSB_SELF=path:/path/to/csb csb ...`.
- **`CSB_LATEST`** -- if set (non-empty), defaults `-L/--latest` on: re-lock the
  `claude-code` flake input to its upstream HEAD instead of the rev pinned in
  `flake.lock`. Trades reproducibility for always getting the newest claude.
  `-L` does the same for a single run.
- **`CSB_LATEST_TTL`** -- seconds to reuse a cached upstream rev under
  `-L`/`CSB_LATEST` before re-checking (default `86400` = daily; `0` = check
  every run). Within the window the rev is pinned, so launches stay fully
  cached and reproducible.
- **`CSB_VERBOSE`** -- if set (non-empty), defaults `-v/--verbose` on. Launches
  are otherwise quiet: csb's routine narration and nix's own progress are
  suppressed (warnings and errors always print).
- **`CSB_TMPDIR`** -- host scratch/temp dir for the launched process: its
  `TMPDIR`, the base for ephemeral/named HOMEs, and a write-allow root (e.g. a
  scratch device). Must be an existing directory. Host-scoped, so it lives here
  rather than in a profile.

## Use

```sh
csb feature/foo                  # worktree for feature/foo (off HEAD) + claude in the devShell
csb -y feature/foo               # allow-all (--dangerously-skip-permissions)
csb feature/foo -- --model opus  # everything after -- is passed to claude
csb --here                       # run in the current dir, no worktree (per-repo namespace)
csb -s feature/foo               # interactive shell instead of claude (exact same env)
csb -s -E --here -- cat ~/.ssh/config   # run a command in the agent's env (this one fails: denied)
csb -s --no-sandbox --real-home --here -k SSH_AUTH_SOCK   # deploy shell: same devShell
                                 # + env scrub, but full fs + real HOME (see Filesystem sandbox)
csb -p work feature/foo          # profile: ns/token/keeps/env from ~/.config/csb/profiles/work
csb -k AWS_PROFILE feature/foo   # also keep AWS_PROFILE across the env scrub (repeatable)
csb -L feature/foo               # newest claude (re-lock claude-code to upstream HEAD this run)
csb --ns work feature/foo        # shared, cross-repo HOME (default is per-repo)
csb --ns @work feature/foo       # same thing -- the @ is optional (work == @work)
csb -E feature/foo               # ephemeral: throwaway config/HOME, no namespace
csb -E=work --here               # named ephemeral: reusable throwaway HOME (attach a shell)
csb -n feature/foo               # just prepare/reuse the worktree, don't launch (prints its path)
csb -d feature/foo               # remove the worktree (branch and per-repo HOME are kept)
csb --list-ns                    # list csb namespace configs (per-repo + shared @)
csb                              # list csb worktrees
```

`BRANCH` and `--here` are mutually exclusive: either csb provisions a worktree
for `BRANCH`, or it runs in the current directory as-is. All combinations of
{claude, `-s` shell} x {worktree, `--here`} land in the same restricted devShell.
tmux is yours to manage: run `csb` in one pane, edit / `git push` from another.

`csb --help` prints the full flag reference. `make help` lists the build/install
targets.

## Auth

claude runs with a private HOME and the real `~/.claude` denied, so a host login
is never visible. Two ways in:

- **`--seed-creds` / `seed_creds=true` (recommended)** -- csb copies your native
  claude session credential (macOS keychain item / Linux
  `~/.claude/.credentials.json`) into the launch config, host-side, on every
  launch. The sandbox then presents your **live subscription session** -- same
  account, same model entitlements as native claude. Caveat: sandbox and native
  share one refresh-token family, so occasional mutual re-login prompts are
  possible. Requires a native login for the wanted account on the host.
- **Token** -- `claude setup-token` once, then `CLAUDE_CODE_OAUTH_TOKEN` (or,
  better, `token_cmd=pass .../claude/token` in a profile, fetched host-side so it
  never transits your interactive shell). Caveat: long-lived tokens carry the
  entitlements from **mint time** -- they can lag newly released model tiers
  until regenerated.

## Namespaces

A namespace is just **which `HOME` the sandboxed process gets** -- and with it
the agent's claude config (history/sessions/settings), caches, and anything else
that lives in `$HOME`. `-N`, `-E`, and `--real-home` are three mutually-exclusive
choices for that HOME; the default is a per-repo redirected HOME. They differ in
*persistence* and in whether that HOME is *writable* inside the sandbox:

| Choice | HOME | Persistent | Writable in sandbox | Seeded |
|---|---|---|---|---|
| **default** | `~/.csb/claudes/repo-<key>` (per repo) | yes | yes | yes |
| **`-N NAME`** | `~/.csb/claudes/@NAME` (shared across repos) | yes | yes | yes |
| **`-E`** | a throwaway dir under tmp | no | yes | yes |
| **`--real-home`** | your real `$HOME` | n/a | **no** (reads obey the deny-list) | no |

**By default the namespace is the repo, not the branch.** One persistent HOME is
shared by every branch and worktree of the repo, living flat at
`~/.csb/claudes/repo-<key>`, where `<key>` is the basename of the physical
main-checkout root plus a short path hash (`myapp-4f9a11b2`). The hash keeps two
different repos that share a basename from ever sharing a HOME. Because the
default is derived from the repo every run, `csb <branch>` is deterministic with
no hidden state.

| Invocation | Namespace | HOME |
|---|---|---|
| `csb feature/foo` | `repo-<key>` (this repo) | persistent `~/.csb/claudes/repo-<key>` |
| `csb --here` | `repo-<key>` (this repo) | persistent, same dir |
| `csb --ns work feature/foo` | `@work` (shared) | persistent `~/.csb/claudes/@work` |
| `csb --ns @work feature/foo` | `@work` -- identical to the line above | persistent `~/.csb/claudes/@work` |
| `csb -E feature/foo` | none | throwaway (not persisted) |

`HOME` for the launched process is the namespace dir; its config lands at
`<ns>/.claude` (coinciding with claude's default `$HOME/.claude`), so caches that
normally live in `$HOME` (npm, bundler, ...) rebuild there and persist. The whole
`~/.csb/claudes` tree is denied except the **active** namespace.

> **Parallel sessions share one HOME.** Two `csb` sessions on different branches
> of the same repo now share the per-repo HOME (config, history, `.claude.json`)
> with no locking. This is exactly the situation you already get running native
> `claude` twice against one real `~/.claude`; the old per-branch default was
> *more* isolated than native. Want per-branch isolation back for a repo? Launch
> with an explicit name, e.g. `csb --ns "$(git branch --show-current)" <branch>`.

- **`-N`, `--ns NAME`** -- a named HOME shared across **all** repos launched with
  it (the classic use: one `--ns @work` for every work repo). `NAME` and `@NAME`
  are equivalent -- the `@` is optional and always added, which also keeps user
  names in their own space so none can collide with a `repo-<key>` default. `-d`
  never auto-removes it (retire it manually: `rm -rf ~/.csb/claudes/@NAME`).
- **`-E`, `--ephemeral`** -- throwaway config/HOME under `$TMPDIR`, no namespace.
  Mutually exclusive with `--ns`. A bare `-E` mints a random throwaway dir, so
  there is nothing a second invocation can reattach to.
- **`-E=NAME`, `--ephemeral=NAME`** -- a **named** ephemeral: the throwaway HOME
  is `$TMPDIR/csb-home-NAME` (deterministic) instead of random, so a sibling
  shell in another pane can attach to the exact same environment:

  ```sh
  csb -E=work --here          # claude, in a reusable ephemeral HOME
  csb -s -E=work --here       # a shell in the identical env (other pane)
  ```

  It is still *ephemeral*, not a namespace: it lives in tmp (OS-reaped, gone on
  reboot/tmp-clean), leaves no `~/.csb/claudes` entry, and is untracked by
  `--list-ns`. Both panes must resolve the same tmp base for the paths to
  coincide -- set `CSB_TMPDIR` for a fixed base, or keep `$TMPDIR` stable across
  your shells. (For a shareable env that *persists*, use a `--ns NAME` instead.)
  The name is a single path component: letters, digits, `. _ -`.

`csb -d <branch>` removes only the worktree; the branch is kept, and so is the
launch HOME -- the per-repo default is shared by every branch, and a `--ns`
namespace is shared across repos, so neither is tied to the branch being
deleted. Retire a namespace deliberately with `rm -rf ~/.csb/claudes/<name>`.
Only worktrees csb created under `.worktrees/` are ever torn down/removed -- a
branch checked out in the main tree or a hand-made worktree is left alone.

`csb --list-ns` lists the namespace configs under `~/.csb/claudes`: the per-repo
default (`repo-<key>`), any others from sibling repos, and the shared `@` ones.
None are ever auto-removed. Dirs left over from the pre-0.3 per-branch layout are
flagged as legacy; remove them manually when convenient.

## Profiles

`${XDG_CONFIG_HOME:-~/.config}/csb/profiles/<name>` -- one file per profile,
`KEY=VALUE` lines (`#` comments allowed). Profile values are **defaults**:
explicit CLI flags beat them, including `-- ARGS` (which replace `args=`) and the
negating `--no-*` flags. Launch with `-p/--profile NAME`. Recognized keys
(anything else is an error):

```
ns=@work                                  # as --ns
token_cmd=pass work/claude/token          # run host-side via bash -c;
                                          # stdout -> CLAUDE_CODE_OAUTH_TOKEN (never echoed)
latest=true                               # as -L/--latest; beats CSB_LATEST, loses to explicit -L
verbose=true                              # as -v/--verbose; beats CSB_VERBOSE, loses to explicit -v
yolo=true                                 # as -y/--yolo (allow-all)
paranoid=true                             # as --paranoid (whitelist reads; see below)
sandbox=false                             # as --no-sandbox (shell only; drops the fs lockdown)
real_home=true                            # as --real-home; excludes ns=/ephemeral= (HOME axis)
here=true                                 # as --here; an explicit BRANCH wins (with a warning)
ephemeral=true                            # as -E; excludes ns= in the same profile
shell=true                                # as -s/--shell
seed_creds=true                           # as --seed-creds (skipped in -s shell mode, with a warning)
seed_home=~/.config/csb/home              # as --seed-home; template copied into the launch HOME
accent=magenta                            # as --accent; statusline tint (csb --help lists the colors)
args=bash --rcfile ~/.config/my.bashrc    # the ARGS after --: command in -s mode, extra claude
                                          # args otherwise. Whitespace-split, no quoting; a leading
                                          # ~/ or ${HOME} expands to the HOST home.
keep=COLORTERM DIRENV_LOG_FORMAT          # space-separated, appended to --keep
setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 # repeatable; injected post-scrub
deny_read=~/notes                         # as --deny-read: extra read deny (both modes); repeatable
allow_write=~/scratch                     # as --allow-write: extra write root (both modes); repeatable
paranoid_deny_read=/Volumes               # as --paranoid-deny-read: extra deny under --paranoid; repeatable
paranoid_allow_read=~/ref                 # as --paranoid-allow-read: re-expose read-only under --paranoid;
                                          # repeatable; rejected if it overlaps a deny
```

Note: bare `csb -p NAME` (no BRANCH) **launches** in the current dir --
`--here` is implied, unless the CLI or the profile says otherwise; plain `csb`
always lists. A failing or empty-output `token_cmd` aborts the launch before
any worktree/namespace side effects. In `-s` shell mode `token_cmd=` is skipped
and `seed_creds=` is ignored with a warning (a shell runs no claude).

**Host-specific overlay.** A profile `NAME` can have a sibling, gitignored
`NAME.local` layered on top after it is read: same syntax/sections, but its
scalar values win and its list values (`keep=`, `setenv=`, `deny_read=`,
`allow_write=`, `paranoid_deny_read=`, `paranoid_allow_read=`) accumulate.
Commit portable profiles
to a dotfiles repo; keep host-specific values (a `token_cmd=` path, a
`seed_home=`) in the uncommitted `.local`. Precedence: base -> `.local`
-> explicit CLI flags.

```
# ~/.config/csb/profiles/work.local   (gitignored, per-host)
token_cmd=pass work/claude/token-on-this-box
seed_home=~/dotfiles/csb-home
```

For a shorthand, alias the profile: `alias csbw='csb -p work'`.

## Seeding the sandbox HOME

Inside the sandbox, claude runs with a redirected `HOME` and the real `~/.claude`
denied -- so your **user-level** files (`~/.claude/CLAUDE.md`, `settings.json`,
`rules/`) are invisible. To carry them in, put copies in a template dir; csb
seeds them into the launch HOME on **every** launch (so fresh namespaces get
them on first use), **non-overwriting** (existing files, including ones claude
wrote, are kept; `--reseed` forces overwrite).

```
~/.config/csb/home/          # the default template dir
+-- .claude/
|   +-- CLAUDE.md            # your user memory, now visible in-sandbox
|   +-- settings.json
|   +-- rules/...
+-- ...                      # anything else you want under the sandbox HOME
```

Point at a different dir with `--seed-home DIR` or a profile's `seed_home=`. This
is deliberately a **template you curate**, not a sweep of your real `$HOME` --
only what you place here crosses in, so it never re-exposes what the deny-list
protects. A template-provided `.claude.json` is merged with csb's onboarding
seed, not clobbered.

A minimal starter lives at [`templates/home/`](templates/home) in this repo --
copy it to `~/.config/csb/home` and edit:

```sh
cp -r "$(git rev-parse --show-toplevel)/templates/home" ~/.config/csb/home
```

For **project-level** instructions you usually don't need this: a `CLAUDE.md` at
the worktree root is read directly, and a gitignored one can ride in via
`.worktreeinclude`.

## Per-repo worktree files

These are read from the worktree in worktree mode (not `--here`).

**`.worktreeinclude`** (repo root, `.gitignore` syntax) -- csb copies matching
**gitignored** files (local `.env`s, generated config, a personal
`.worktreesetup.sh`) into the worktree on **every** launch/prepare, **host-side,
unsandboxed**; existing files are never overwritten. A generic worktree-tooling
convention, not csb-specific.

**`.worktreesetup.sh`** (in the worktree, executable) -- a library of shell
functions that csb **sources** (cwd = worktree) and dispatches by name; the
branch is passed as `$1`. Define either or both:

- **`up`** -- provisioning. Runs after `.worktreeinclude` on **every**
  invocation (create, reuse, `csb -n`), so write it **idempotent**. A non-zero
  exit aborts csb. It can generate `.worktreeenv` for branch-parameterized values.
- **`down`** -- teardown. Runs on `csb -d`/`--delete`, *before* the worktree is
  removed, so it can release whatever `up` provisioned. A non-zero exit only
  warns; the delete still proceeds. `down` gets only the branch (delete does not
  load `.worktreeenv`), so re-derive any state from it exactly as `up` did.

Unlike `.worktreeinclude`, this file runs **sandboxed**: csb sources it (cwd =
worktree) and calls the requested function inside the repo's own devShell,
behind the *same* deny-list containment and env scrub (`--ignore-environment` +
`--keep`) the eventual claude/`-s` launch gets -- so it has no more host access
than the agent's own sandboxed shell already would. It needs no git-tracking or
commit -- gitignore it, or bring in a personal copy via `.worktreeinclude`, if
it's specific to your machine. `up` failures abort the launch; `down` failures
only warn (`--delete` still completes). Local (network-reachable) services like Postgres/Redis stay
reachable from inside the sandbox exactly as they do for claude itself --
[network stays open by design](#threat-model).

Top-level code in the script runs at source time on both `up` and `down` --
keep the real work inside the functions.

```bash
#!/usr/bin/env bash
set -euo pipefail

db() { printf 'myapp_%s' "$(printf '%s' "$1" | tr -c 'a-z0-9' _)"; }

up() {                                  # provision: per-branch database
  createdb "$(db "$1")" 2>/dev/null || true
  printf 'DATABASE_URL=postgres://localhost/%s\n' "$(db "$1")" > .worktreeenv
}

down() {                                # teardown: drop it on --delete
  dropdb --if-exists "$(db "$1")"
}
```

**`.worktreeenv`** (in the worktree, dotenv-style) -- `VAR=value` lines (blank
and `#` lines skipped, names validated) injected into the scrubbed environment
via the same `env` wrapper that redirects HOME, after `--ignore-environment`,
inside the devShell, identically for claude and `-s`:

```
DATABASE_URL=postgres://localhost/myapp_dev
REDIS_URL=redis://localhost:6379/0
```

A profile's `setenv=` is injected *after* `.worktreeenv`, so user config wins
when both set a var. A literal `${HOME}` in a value expands to the launch's
*effective* home (the namespace dir, or throwaway dir with `-E`) -- the only way
to anchor a value to the sandbox HOME, since generators run before the namespace
is resolved. In `--here` mode an existing `.worktreeenv` is honored, but
`.worktreeinclude` and `.worktreesetup.sh` are not run ([seeding the sandbox
HOME](#seeding-the-sandbox-home) still happens on every launch).

## Filesystem sandbox

Two policies for the launched process (and its children):

### Read deny-list

Reads are default-allow minus a deny-list of sensitive paths, blocked **even by
absolute path**. Built-in floor (`$HOME`-relative; missing paths are skipped at
launch):

```
secrets / keys   ~/.ssh  ~/.aws  ~/.gnupg  ~/.password-store  ~/.netrc
                 ~/.azure  ~/.oci  ~/.vault-token  ~/.granted
                 ~/.config/age/keys.txt  ~/.config/sops  ~/.sops
claude           ~/.claude  ~/.claude.json{,.backup}
                 ~/.csb/claudes  (the active namespace is re-allowed)
cloud / infra    ~/.config/{gh,gcloud,doctl,fly,rclone,op,configstore,
                 github-copilot}  ~/.config/containers/auth.json
                 ~/.kube  ~/.docker  ~/.gemini  ~/.pulumi/credentials.json
                 ~/.terraformrc  ~/.terraform.d  ~/.databrickscfg{,.bak}
                 ~/.databricks  ~/.mc  ~/.minio  ~/.s3cfg  ~/.boto
packaging creds  ~/.cargo/credentials{,.toml}  ~/.gem/credentials  ~/.pypirc
                 ~/.m2/settings.xml
db creds         ~/.pgpass  ~/.my.cnf
git / vcs        ~/.gitconfig  ~/.config/git  ~/.git-credentials
shell / REPL     ~/.bash_history  ~/.zsh_history  ~/.python_history
history          ~/.node_repl_history  ~/.irb_history  ~/.rdbg_history
                 ~/.pry_history  ~/.rediscli_history  ~/.mysql_history
                 ~/.psql_history{,.d}  ~/.sqlite_history  ~/.scala_history{,_jline3}
                 ~/.dotty_history  ~/.utop-history  ~/.ammonite  ~/.hivehistory
                 ~/.lesshst  ~/.viminfo  ~/.local/share/{nvim/shada,fish/fish_history}
macOS: ~/Library/Keychains  ~/Library/Cookies  ~/Library/Safari
       ~/Library/Application Support/{Google/Chrome,Firefox}  ~/.zsh_sessions
Linux: ~/.local/share/keyrings  ~/.mozilla
       ~/.config/{google-chrome,chromium}
```

Deliberately **not** in the floor (in-sandbox installs against private registries
may need them): `~/.npmrc`, `~/.bundle/config`, `~/.yarnrc`. Add your own with
`--deny-read PATH` (repeatable) or a profile's `deny_read=` (accumulates across
`NAME` + `NAME.local`); each is an absolute or leading-`~/` path. **Add-only**:
these extend the floor and can never remove a built-in.

**Keychain caveat (macOS).** Denying `~/Library/Keychains` blocks direct file
reads of the keychain DB, and in practice the `security` CLI **fails closed**
under it (verified: an item present on the host returns "could not be found"
in-sandbox). The guarantee is empirical, not structural: `security` talks to
`securityd` -- a separate, unsandboxed process -- over mach, and this profile
does **not** deny mach lookups, so a different client of that service could
behave differently. Re-check your box with
`csb -s -E --here -- security find-generic-password -s '<item-name>' -w`
(conclusive only if the same command outside csb returns the secret).

### Write allow-list

Writes are **default-denied**; allowed roots:

- the worktree (or the current dir with `--here`)
- the repo's git common dir -- commits from a linked worktree write objects into
  the main repo's `.git` -- **except** `hooks/` and `config`/`config.worktree`
  (host code-exec vectors), which stay read-only *even when they don't exist
  yet* (an existence-conditional deny could be bypassed by creating them)
- the active namespace HOME (or the ephemeral HOME)
- tmp: `/tmp`, the per-user `/var/folders/...` temp/cache dir (macOS; derived
  via `getconf`, never from `$TMPDIR` -- a stripped or nix-set `TMPDIR` must
  not widen the write policy), `/var/tmp` (Linux), and `CSB_TMPDIR` if set
- `/dev` (ptys -- the TUI writes its terminal)

Extra roots go via `--allow-write PATH` (repeatable) or a profile's
`allow_write=`, add-only. Expected fallout: `git config` writes and hook
installation fail inside the sandbox; tools that write caches to absolute paths
outside `$HOME` need an entry.

### `--no-sandbox` and `--real-home`: the deploy shell

Two independent axes let you loosen the environment when you're the one driving
it. They compose; the common pairing is a shell that can actually deploy.

- **`--no-sandbox`** drops the filesystem lockdown entirely -- no seatbelt/bwrap
  wrapper, so the read deny-list and the write allow-list do not apply and the
  process has full host filesystem access. Everything *else* is unchanged: the
  worktree, the repo's devShell, the env scrub (`--ignore-environment` +
  `--keep`), and the HOME policy. It is **shell only** -- csb refuses to run
  claude unsandboxed (hard error) -- and with it `--paranoid` and the
  deny/allow lists are inert (csb says so). Also via a profile's `sandbox=false`.
- **`--real-home`** points the launched `HOME` at your *real* home instead of a
  redirected one. It is a third launch-HOME choice, mutually exclusive with
  `--ns` and `-E` (all three select where HOME comes from). The real HOME is
  **not** seeded and is **not** made writable -- under the sandbox its
  credential paths stay denied; it's `--no-sandbox` that opens them. Also via a
  profile's `real_home=true`.

Why both for a deployment: `--no-sandbox` alone (with the default redirected
HOME) opens the filesystem, but `~/.ssh/known_hosts`, `~/.ssh/config` host
aliases, `~/.kube`, `~/.aws` still resolve under the *namespace* HOME, where
they don't exist. `--real-home` makes `~` your real home so those resolve, and
`--keep SSH_AUTH_SOCK` forwards your agent for the actual auth:

```sh
csb -s --no-sandbox --real-home --here -k SSH_AUTH_SOCK -- ./deploy.sh
```

All four combinations are valid. `--sandbox --real-home` (the default sandbox,
real HOME) is the interesting middle: your own home is readable, but the
credential deny-list still fences `~/.ssh`, `~/.aws`, `~/.claude`, etc.

### `--paranoid`: whitelist reads

The default read policy is a blacklist. `--paranoid` flips it to a whitelist: the
**real HOME** is read-denied wholesale, and only the write-allow roots (worktree,
git dir, namespace HOME, tmp) are re-allowed for reading. Paths outside HOME
(`/nix`, `/etc`, `/usr`, ...) stay readable so the devShell works.

Because the launched `HOME` is redirected to the namespace dir, tool caches and
config land under that re-allowed dir and keep working -- so `--paranoid` is
rarely disruptive. When something needs a specific real-HOME path, re-expose it
read-only with `--paranoid-allow-read PATH` (or a profile's `paranoid_allow_read=`),
or make it writable with `--allow-write` (write-allow roots are read-allowed too).
A `paranoid_allow_read` that overlaps a deny root (the floor, a `deny_read`, or a
`paranoid_deny_read`) is rejected, so an allow can never silently re-expose a
denied path. Enable per run (`--paranoid` / negate `--no-paranoid`) or per
context via a profile's `paranoid=true`; there is no global toggle.

The deny is scoped to the real HOME, so a source tree that lives *outside* HOME
stays readable -- e.g. a `~/src -> /Volumes/src` symlink resolves to a path that
paranoid never fences. Wall such trees off with `--paranoid-deny-read` (or a
profile's `paranoid_deny_read=`); the write-allow roots are re-allowed on top, so
the active worktree stays readable.

### `--paranoid`: ancestor traversal and what it leaks

A re-allowed subtree usually sits *below* a denied root -- the worktree beneath
the real HOME (when repos live under `$HOME`) or beneath a `paranoid_deny_read=`
root (when the code tree lives outside `$HOME`, e.g. on a separate volume), and the
namespace beneath the denied `~/.csb/claudes`. Reaching it means traversing the
denied ancestor directories in between, which per-component path resolution does
constantly: canonicalizing a path `lstat`s every component, and a directory glob
`opendir`s each -- so a fully denied ancestor makes the operation fail with
`EPERM` even though the target file is allowed. csb re-allows just enough of the ancestor
chain (each ancestor by `literal`, up to the first one under no deny root) for
traversal to pass through. Two chains get two levels of access:

- **worktree / write-root chain**: ancestors are made *listable* (`opendir`),
  because tools routinely scan upward for a project root or config file.
- **namespace / HOME chain**: ancestors are `lstat`-only (**not** listable), so
  your home directory and other namespaces cannot be enumerated.

#### paranoid guarantee (and its bounds)

**Bound 1, and it is the important one: this is a *filesystem* guarantee, and
the filesystem is not the only way out.** Within the filesystem policy,
`--paranoid` makes reads default-deny. It does not by itself stop the sandboxed
process from asking a *host service* to do work on its behalf -- work that runs
outside the sandbox, as you, with your real HOME. The verified routes of that
shape are closed (separately from `--paranoid`, in both modes), but the class is
not exhausted, so treat `--paranoid` as bounding what an *accident* can read
rather than what a determined reader can reach. See
[Known gaps](#known-gaps).

**Bound 2.** Within the filesystem policy, `--paranoid` prevents reading file
*contents* outside the allow-list. It does **not** hide the *existence and entry
names* of the
directories on the worktree's own ancestor path. Concretely, for a worktree at
`<root>/<org>/<repo>`, the sandbox can `ls` `<root>` and `<root>/<org>` and the
other directories up the chain -- learning the names of neighbouring entries
(sibling repos, orgs, mount points) -- but **cannot open any file inside a
sibling, nor list a sibling's own contents**. Names/structure along the one
ancestor path leak; data never does.

This is a deliberate, bounded weakening (chosen so ancestor-scanning tools work
under `--paranoid` without a per-syscall exception for each one). If your threat
model requires that even the *names* of neighbouring repos stay hidden, run those
tools without `--paranoid` -- the read deny-list still blocks every credential --
and reserve `--paranoid` for when sibling-*data* isolation is the point.

**Platform asymmetry.** On Linux the sandbox binds the worktree over a tmpfs, so
its ancestors appear *empty* -- traversal works and no sibling names leak. macOS
seatbelt cannot present a directory as empty (only allow or deny), so restoring
traversal necessarily exposes the real ancestor listings. The name leak is
therefore macOS-only.

**What leaks depends on where the code lives.** The listing follows the
worktree's *physical* ancestor chain. If repos live under `$HOME`, that chain
runs through your home directory, so its entry names -- including which dotfiles
and credential *directories* exist -- become listable (contents still denied). If
the code tree instead lives outside `$HOME` (e.g. on a separate volume fenced
with `paranoid_deny_read=`), only the code-tree names leak and `$HOME` is reached
solely via the metadata-only namespace chain, so it stays un-listable. A symlink
out of `$HOME` resolves to its physical target, so it is the physical location,
not the symlinked path, that determines what leaks.

### Where the lists live

All four read/write lists are set per launch, via CLI flags or profile vars
(no machine-wide config file) -- add-only, absolute or leading-`~/` paths:

| List | CLI flag | Profile var | Modes |
|---|---|---|---|
| extra read deny | `--deny-read` | `deny_read=` | both |
| extra write root | `--allow-write` | `allow_write=` | both |
| extra paranoid read deny | `--paranoid-deny-read` | `paranoid_deny_read=` | `--paranoid` |
| paranoid read re-allow (read-only) | `--paranoid-allow-read` | `paranoid_allow_read=` | `--paranoid` |

### `--pasteboard` (macOS)

`pbcopy`/`pbpaste` are a mach service, so the IPC denies that close the
LaunchServices escape (see [Known gaps](#known-gaps)) remove in-sandbox
copy/paste too. `--pasteboard` (or a profile's `pasteboard=true`) puts it back. This is the only
capability the IPC denies take away that has a flag; everything else they remove
is listed under [Known gaps](#known-gaps).

**Default off**, because the pasteboard is a read channel around the *entire*
file deny-list: it is shared with every host app, so a secret copied out of a
password manager while an agent is running is readable by that agent. Re-allowing
it was measured not to reopen the escape, and `test/escape/escape.bats` keeps
that a regression guard. No-op on Linux (an X11/Wayland concern) and under
`--no-sandbox`.

## Choosing the nix target

By default csb runs in the repo's `devShells.<system>.default`. Point it at a
different closure -- a leaner `ci`, a `release` shell -- with `--nix-target NAME`
(profile `nix_target=`), which resolves `devShells.<system>.NAME` from the
repo's own flake.

The two launch modes can differ: `--nix-target-shell NAME` and
`--nix-target-claude NAME` (profile `nix_target_shell=` / `nix_target_claude=`)
each apply to one mode only and beat the shared `--nix-target` when that mode is
the one running. `--no-nix-target` clears all three. Whichever target wins also
applies to `.worktreesetup.sh`, which runs in the same devShell.

A *named* target never falls back: if the repo's flake has no such attribute the
launch fails, because csb's generic fallback devShell only ever provides
`default` and silently substituting it would run the wrong closure.

```sh
csb --nix-target ci feature/foo            # both modes in devShells.<system>.ci
csb --nix-target-shell dev --nix-target-claude ci feature/foo
```

Each flag is repeatable; profile vars accumulate across `NAME` + `NAME.local`.
The host tmp/scratch dir is the `CSB_TMPDIR` env var (see [Quickstart](#quickstart)).

## Inspecting the config and sandbox (dry-run)

Two read-only flags resolve a launch and print what it *would* use, then exit
before any launch, HOME seeding, credential seeding, or `token_cmd`. Both are
safe to run anywhere and never print a secret, so they double as the seam the
test suite (`docs/PLAN-005-tests.md`) drives.

- `--dump-config` -- print the resolved knobs as stable `KEY=VALUE` lines
  (flags + profile + `.local` + env, after all precedence). Git-free: it exits
  before locating the repo, so the default (per-repo) namespace shows as an empty
  `namespace=` plus `branch=`. `token_cmd` is reported `present`/`absent` (never
  run), and `setenv` lists VAR names only (never their values).

  ```
  $ csb -p work --paranoid --dump-config
  mode=launch
  here=true
  paranoid=true
  namespace=@work
  token_cmd=present
  claude_args=--model|opus
  ...
  ```

- `--dump-sandbox` -- print the generated sandbox artifact: the seatbelt profile
  text on macOS, or the `bwrap` argv (one token per line) on Linux. It runs the
  real build path (`build_deny_paths` / `build_write_roots` and every path
  validation), so build-time errors -- a `"`/`\` in a path, a
  `--paranoid-allow-read` that overlaps a deny -- surface here too. Drive it with
  `--here` inside a git repo so no `.worktrees/` checkout is created:

  ```
  $ csb --here --paranoid --dump-sandbox
  ```

  On Linux, `--dump-sandbox` resolves the `bwrap` binary; set `CSB_BWRAP_BIN` to
  a path to use it verbatim instead of building it via nix (hermetic dumps/tests).

## Threat model

**Read this first.** csb assumes a **trusted operator running trusted
instructions**. It is built to (a) prevent *accidental* damage and *accidental*
exposure of the obvious credentials, and (b) keep separate work (namespaces,
other repos) from bleeding into each other. It is **weaker** against *untrusted
instructions* -- prompt injection from a fetched page, a malicious dependency, a
poisoned issue/PR -- because the two capabilities csb deliberately keeps open
(broad filesystem *reads* and open *network egress*) are exactly the exfiltration
primitive: anything the agent can read, injected instructions can read, and
anything readable can be shipped off-box. csb does not defend against a hostile
agent.

Named trade-offs, accepted deliberately (see `docs/PLAN-002.md`):

- **Open network egress.** Unrestricted outbound. This is the price of claude
  reaching local services for real testing. seatbelt filters by ip/port only,
  **not by hostname**, so host-based egress control needs a filtering proxy
  (deliberately out of scope). `localhost`-only egress *is* natively expressible
  and is the basis of the possible lockdown mode below.
- **Read deny-list fails open.** Anything not on the floor under your real HOME
  (a stray `.env`, files under `~/Documents`, a dotfile the floor didn't
  anticipate) is readable. A read allow-list would close this but breaks
  interactive toolchains pervasively; `--paranoid` is the opt-in whitelist escape
  hatch. Add paths with `--deny-read` / a profile's `deny_read=` as you find them.
- **paranoid leaks ancestor names (macOS).** To let path-walking tools reach a
  worktree nested under a denied root, `--paranoid` makes the worktree's ancestor
  directories listable -- so sibling volume/host/org/repo *names* on that one path
  are visible, though sibling *contents* stay denied. Bounded by design; see
  [`--paranoid`: ancestor traversal and what it leaks](#--paranoid-ancestor-traversal-and-what-it-leaks).
- **Host-side trust (flake.nix/shellHook, and see Known gaps).** All `nix` eval/build/develop,
  and the repo's `flake.nix`/`shellHook`, run on the host, **unsandboxed** --
  nix itself is out of scope for containment. `.worktreesetup.sh` is not in
  this bucket: its `up`/`down` run *inside* the deny-list wrapper, in the same
  devShell and with the same env scrub the eventual claude/`-s` launch gets
  (see [Per-repo worktree files](#per-repo-worktree-files)), so a malicious or
  agent-modified copy has no more reach than the agent's own sandboxed shell.
  The host-side surface is **not** limited to these: the nix daemon socket and
  host IPC brokers are reachable from inside the sandbox too, which is what
  [Known gaps](#known-gaps) covers. Within the *repo's own files*, the
  genuinely host-side surface is `flake.nix`/`shellHook`: the worktree is
  **agent-writable**, and nix reads *tracked but uncommitted* edits from a
  dirty worktree -- no commit required -- so an agent could get host execution
  on your **next launch** of that branch by editing either. Don't point csb at
  a repo you don't trust, and review agent changes to `flake.nix`/`shellHook`
  before relaunching a branch an agent has worked on. `.git/hooks` / `config` /
  `config.worktree` are write-denied even when absent, closing that adjacent
  host-exec path.
- **Single layer, and it is a *filesystem* layer.** The seatbelt/bwrap profile
  *is* the containment -- no unprivileged-user boundary underneath -- and it
  filters file operations, so it is porous to anything that gets work done by
  IPC rather than by syscall (see [Known gaps](#known-gaps)). On macOS a second
  boundary means a separate OS user, a container or a VM, not a profile tweak
  (seatbelt has no process-isolation primitive). Linux gets a PID namespace for
  free.
- **`--no-sandbox` removes the layer.** The escape-hatch shell (see
  [`--no-sandbox` and `--real-home`](#--no-sandbox-and---real-home-the-deploy-shell))
  runs with no filesystem containment at all -- it exists for operator-driven,
  trusted work (a deployment) where you *want* full host access. It is refused
  for claude and confined to `-s/--shell` precisely because it drops the one
  boundary csb has; treat that shell as ordinary host access, not a sandbox.
- `sandbox-exec` is formally deprecated (but stable -- nix's own darwin sandbox
  uses the same libsandbox). The mechanism is isolated in one helper
  (`build_deny_wrapper`) if it needs replacing.

### Known gaps

**The sandbox constrains filesystem operations and nothing else.** Any host
service that acts on the sandboxed process's behalf runs *outside* the sandbox,
as your own uid, with your real HOME -- and neither `PATH` nor the env scrub is
a boundary against reaching one (exec is unrestricted and a sandboxed process
sets its own environment).

All of these were verified against a live sandbox, in `--paranoid` as well as
normal mode. Full detail, evidence and reproductions in
[`docs/PLAN-007-escape.md`](docs/PLAN-007-escape.md).

| Gap | Platform | Effect | Status |
|---|---|---|---|
| `open` -> LaunchServices launches a `/tmp` `.app` via launchd | macOS | full escape to your uid, real HOME readable | **closed** |
| `pbpaste` reads the live host clipboard | macOS | read channel around the whole file deny-list | **closed**; opt back in with `--pasteboard` |
| session dbus -> `systemd-run --user` spawns a unit outside the namespace | Linux | full escape to your uid | **closed** |
| nix daemon socket -> builds run outside the sandbox as `_nixbld1` | both | code exec outside the profile; reads anything other-readable | **closed** (in-sandbox `nix` no longer reaches the daemon at all) |
| host unix sockets generally (tmux, editor IPC, docker, ssh-agent) | both | not exhaustively probed, but the same shape as the nix daemon | macOS: **closed as a class**. Linux: **open, accepted** |
| `task_for_pid` / debugger attach to host processes | macOS | code injection into a process outside the sandbox | **closed** |
| `sysctl kern.procargs2` reads other processes' argv + environment | macOS | discloses secrets from your other shells and dev servers -- disclosure, not execution | **open, accepted**: denying it broke `ps` |
| Linux abstract unix sockets (e.g. X11) | Linux | keystroke injection into your session | **open, unfixable** without closing network egress |

The macOS fixes work by flipping whole seatbelt filter *classes* to
deny-by-default rather than by blacklisting service names -- a name blacklist
was measured ineffective. Two classes are denied: `mach-lookup` (mach and XPC
named services) and `network-outbound` with IP egress re-allowed (which is how
unix sockets are governed, so it cuts every host socket at once, the nix daemon
included).

Consequences worth knowing before you upgrade: the macOS keychain, the browser
login flow, `git`'s `osxkeychain` credential helper, system-configured HTTP
proxies, and local dev services reached over a **unix socket** all become
unreachable in-sandbox. TCP to localhost is unaffected, which covers most local
services. Authenticate with `--seed-creds` or `CLAUDE_CODE_OAUTH_TOKEN`.

On Linux there is no socket filter -- the only lever is removing sockets from
the mount namespace, which is per-path and cannot be made complete.

One gap is left open on purpose. macOS exposes every same-uid process's argv
*and environment* via `sysctl kern.procargs2`, so a sandboxed agent can read
secrets out of your other shells and dev servers. Denying the `kern.proc`
sysctl prefix closes it and breaks `ps` outright, which is too high a price for
a disclosure fix; a narrower `kern.procargs` prefix would likely do better and
has not been measured. Until it is, treat anything in another process's
environment as visible to the sandbox.

"Closed" means that specific route is closed and has a test
(`make test-escape`). It does **not** mean the class of brokered escapes is
exhausted: two independent escapes were found in a single afternoon by someone
not looking hard, and only two of seatbelt's filter classes are deny-by-default.

On Linux the only lever is the mount namespace, so the fix is per-path and
cannot be made complete. Both platforms therefore keep a residual. Closing it
would take a second boundary rather than more profile work -- which is not
implemented and not promised:

### Hardening for untrusted instructions

If you intend to run instructions you don't fully trust, the two real moves, in
order of leverage:

1. **A second boundary** -- a separate unprivileged OS user, a container, or a
   lightweight VM with a controllable network (the last being the documented
   successor to the deprecated `sandbox-exec`). **None of this is implemented,
   scheduled, or promised** -- it is the direction that would be needed, sketched
   in `docs/PLAN-003.md` and `docs/TODO.md`, and it may never be built. Assume it
   will not be.
2. **Restrict egress** -- not natively possible by hostname. A VM makes it
   straightforward; without one, the achievable native step is a `localhost`-only
   egress mode, useful only for tasks that don't need claude's network mid-run.

## What a repo needs

Nothing. If the repo has no `flake.nix` (or one without a `devShells.default`
for your system), csb falls back to a generic devShell from its own flake so the
sandbox still runs, logging a note on launch. nix ignores untracked files, so a
brand-new `flake.nix` counts as absent until you `git add` it -- csb falls back
in that case too.

The fallback aims to be genuinely comfortable for both claude and an
interactive `csb -s` shell -- a language-agnostic toolset with no project
toolchain:

- **gnu toolset** (shadows macOS BSD `/usr/bin` variants, matches Linux):
  `coreutils`, `gnused`, `gnugrep`, `gawk`, `findutils`, `gnutar`,
  `diffutils`, `gnumake`
- **vcs + repo/agent staples:** `git`, `ripgrep`, `fd`, `jq`, `yq-go`,
  `curl`, `tree`
- **interactive shell:** `bashInteractive`, `bash-completion`, `neovim`,
  `less` (the shellHook exports `BASH_COMPLETION` for a seeded rc to source)
- **convenience:** `gzip`, `xz`, `zstd`, `unzip`, `delta`, `bat`

**`~/bin` on PATH.** For both claude and the shell, if `$HOME/bin` exists (in
whichever HOME the launch uses -- real under `--real-home`, otherwise the
namespace/ephemeral HOME) it is **prepended** to `PATH`, so your own scripts
(e.g. deploy wrappers) take precedence -- ahead of the devShell toolchain. This
happens inside the launched process only; host-side `nix` runs first with the
real PATH, so the trust model is unaffected.

For a project-specific toolchain, expose a standard `flake.nix` with
`devShells.default` (the repo's full toolchain); csb prefers it over the
fallback. Scaffold a minimal standalone dev flake with:

```sh
nix flake init -t github:atongen/csb
```

csb dogfoods itself: its own `flake.nix` exposes a `devShells.default` (git +
shellcheck), so `csb --here` runs claude on the csb repo like any other.

## Files

```
bin/csb                    the orchestrator (worktree + deny-list + launch)
LICENSE                    MIT
flake.nix                  packages {csb, claude, bwrap (linux)} + apps + templates
templates/repo/            scaffold: a standalone dev-shell flake for a consuming repo
templates/home/            starter seed-home skeleton (copy to ~/.config/csb/home)
Makefile                   install, lint, test, and build targets (make help)
test/                      bats test suite (make test); see docs/PLAN-005-tests.md
docs/PLAN-002.md           the implemented design (single mode, deny-list, profiles)
docs/PLAN-003.md           roadmap: VM second boundary (not implemented)
docs/PLAN-004.md           the pre-release audit: findings, fixes, scope decisions
docs/PLAN-005-tests.md     the test-suite plan (dump seams + bats tiers)
docs/TODO.md               current state and next steps
```

See `docs/` for design rationale and history (`PLAN-000` ... `PLAN-005`).

## License

MIT -- see [LICENSE](LICENSE). Do what you like with it.
