# csb -- claude sandbox

`csb` runs [Claude Code](https://www.anthropic.com/claude-code) -- or a shell --
in a **per-branch git worktree**, inside the **repo's own nix devShell**, behind
three layers:

1. **env scrub** -- `nix develop --ignore-environment` plus a small allowlist
   (extend with `-k/--keep` or a profile's `keep=`).
2. **private HOME** -- `HOME` is redirected to a per-namespace dir under
   `~/.csb/claudes` (or a throwaway dir with `-E`) for the launched process only.
3. **filesystem sandbox** (`sandbox-exec`/seatbelt on macOS, bubblewrap on
   Linux): **reads** are default-allow minus a deny-list (`~/.ssh`, `~/.aws`,
   the real `~/.claude`, ...), **writes** are default-deny plus an allow-list
   (the worktree, tmp, ...). On Linux the process also runs in its own PID
   namespace. Details in [Filesystem sandbox](#filesystem-sandbox).

**Network and host services stay open by design** so claude (and the `-s` shell)
can reach local db/redis/etc for testing. The sandbox shrinks what can be
read/written; it is **not** an egress firewall -- anything readable is
exfiltratable. Read the [threat model](#threat-model) before relying on it.

**Decoupled by design:** the repo needs no csb-specific files -- just its own
`flake.nix` with `devShells.default`. The claude binary comes from *csb's own*
flake; the repo never imports csb.

> **Status.** Verified end-to-end on `aarch64-darwin` (seatbelt) and on NixOS
> (bubblewrap). Distribution is currently **local-only**: `CSB_SELF` defaults to a self-hosted
> git remote, so `make install` / `nix run` work only where that remote is
> reachable. A public home is pending validation (`docs/TODO.md`).

## Quickstart

```sh
make install                     # copy bin/csb into ~/bin (must be on PATH)
export CLAUDE_CODE_OAUTH_TOKEN=...      # from 'claude setup-token'; or use --seed-creds
cd ~/src/your/repo               # a repo with a flake.nix (see "What a repo needs")
csb feature/foo                  # worktree for feature/foo + claude in the devShell
```

Requires [Nix](https://nixos.org) with flakes (Determinate Nix works out of the
box); `csb` shells out to `nix`. `--aws` additionally needs the `aws` CLI on the
host (only there -- the devShell needs nothing).

Two environment variables tune where csb gets things:

- **`CSB_SELF`** -- the flake ref csb pulls its claude binary (and, on Linux,
  bubblewrap) from. Defaults to the self-hosted remote
  `git+ssh://git@git.grandrew.com/atongen/csb.git`. For local development against
  a working tree, override per-invocation: `CSB_SELF=path:/path/to/csb csb ...`.
- **`CSB_LATEST`** -- if set (non-empty), defaults `-L/--latest` on: each run
  re-locks the `claude-code` flake input to its upstream HEAD instead of the rev
  pinned in `flake.lock`. Trades reproducibility (and a little startup latency)
  for always getting the newest claude. `-L` does the same for a single run.

## Use

```sh
csb feature/foo                  # worktree for feature/foo (off HEAD) + claude in the devShell
csb -y feature/foo               # allow-all (--dangerously-skip-permissions)
csb feature/foo -- --model opus  # everything after -- is passed to claude
csb --here                       # run in the current dir, no worktree (namespace = current branch)
csb -s feature/foo               # interactive shell instead of claude (exact same env)
csb -s -E --here -- cat ~/.ssh/config   # run a command in the agent's env (this one fails: denied)
csb -p work feature/foo          # profile: ns/token/aws/keeps/env from ~/.config/csb/profiles/work
csb --aws work-primary/Admin feature/foo   # inject short-lived aws role creds
csb -k AWS_PROFILE feature/foo   # also keep AWS_PROFILE across the env scrub (repeatable)
csb -L feature/foo               # newest claude (re-lock claude-code to upstream HEAD this run)
csb --ns work feature/foo        # override the namespace (default is the branch)
csb --ns @work feature/foo       # unscoped namespace, shared across repos
csb -E feature/foo               # ephemeral: throwaway config/HOME, no namespace
csb -n feature/foo               # just prepare/reuse the worktree, don't launch (prints its path)
csb -d feature/foo               # remove the worktree AND its namespace config (branch is kept)
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

A namespace partitions the agent's claude config (history/sessions/settings).
**By default the namespace is the branch** (percent-encoded -- `/`->`%2F`, so
`feature/foo`->`feature%2Ffoo`, an injective mapping with no collisions), so
config is deterministic per branch with no hidden state. **Namespaces are scoped
per repo**: they live under `~/.csb/claudes/<repo-key>/<ns>`, where `<repo-key>`
is the basename of the physical main-checkout root plus a short path hash
(`myapp-4f9a11b2`). Equal branch (or `--ns`) names in different repos therefore
never share config -- and `csb -d` in one repo can never delete another's
history. Below, `<rk>` is the current repo's key:

| Invocation | Namespace | Config |
|---|---|---|
| `csb feature/foo` | `feature%2Ffoo` (from the branch) | persistent `~/.csb/claudes/<rk>/feature%2Ffoo/.claude` |
| `csb --here` (on `feature/foo`) | `feature%2Ffoo` (from current HEAD) | persistent, same dir |
| `csb --here` (detached HEAD) | -- | **error: fail fast** |
| `csb --ns work feature/foo` | `work` (explicit override) | persistent `~/.csb/claudes/<rk>/work/.claude` |
| `csb --ns @work feature/foo` | `@work` (unscoped) | persistent `~/.csb/claudes/@work/.claude`, shared across repos |
| `csb -E feature/foo` | none | throwaway (not persisted) |

`HOME` for the launched process is the namespace dir; its config lands at
`<ns>/.claude` (coinciding with claude's default `$HOME/.claude`), so caches that
normally live in `$HOME` (npm, bundler, ...) rebuild there and persist per
namespace. The whole `~/.csb/claudes` tree is denied except the **active**
namespace, so one branch's agent can't read another's history.

- **`-N`, `--ns NAME`** -- named, isolated, repo-scoped config.
- **`--ns @NAME`** -- deliberately **unscoped**: one config shared by every repo
  launched with it. Only an explicit `--ns` can be unscoped; a branch named
  `@NAME` can't alias it. `-d` never auto-removes an `@`-namespace (retire it
  manually: `rm -rf ~/.csb/claudes/@NAME`).
- **`-E`, `--ephemeral`** -- throwaway config/HOME under `$TMPDIR`, no namespace.
  Mutually exclusive with `--ns`.

`csb -d <branch>` removes the worktree **and** its per-branch namespace config
(stale configs hold session history and the auth they were seeded with, a
footprint risk). Pass the same `--ns` you launched with; without it, `-d` only
removes the branch-derived namespace.

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
aws_profile=work-primary/Admin            # as --aws
latest=true                               # as -L/--latest; beats CSB_LATEST, loses to explicit -L
yolo=true                                 # as -y/--yolo (allow-all)
paranoid=true                             # as --paranoid (whitelist reads; see below)
here=true                                 # as --here; an explicit BRANCH wins (with a warning)
ephemeral=true                            # as -E; excludes ns= in the same profile
shell=true                                # as -s/--shell (shared section only)
seed_creds=true                           # as --seed-creds (skipped in -s shell mode)
seed_home=~/.config/csb/home              # as --seed-home; template copied into the launch HOME
args=bash --rcfile ~/.config/my.bashrc    # the ARGS after --: command in -s mode, extra claude
                                          # args otherwise. Whitespace-split, no quoting; a leading
                                          # ~/ or ${HOME} expands to the HOST home.
keep=COLORTERM DIRENV_LOG_FORMAT          # space-separated, appended to --keep
setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 # repeatable; injected post-scrub
```

Note: bare `csb -p NAME` **launches** (it does not list worktrees); plain `csb`
always lists. A failing or empty-output `token_cmd` aborts the launch before any
worktree/namespace side effects.

**Sections -- one profile, both modes.** Lines before any header (or under
`[shared]`) always apply; `[claude]` applies only when claude launches, `[shell]`
only under `-s`. The mode is resolved first (CLI `-s`/`--no-shell` beats a shared
`shell=`), then shared lines, then the active section's -- so a section value
overrides a shared one for scalar keys, while `keep=`/`setenv=` accumulate. In
shell mode `token_cmd=` and `seed_creds=` are skipped (a shell runs no claude).

```
ns=@work
seed_creds=true
latest=true
setenv=COLORTERM=truecolor

[shell]
here=true
args=bash --rcfile ~/.config/nix-dev-pure.bashrc
```

`csb -p work feature/foo` launches claude in a worktree; `csb -p work -s` drops
into the rcfile'd shell in the current dir -- one file, one flag.

**Host-specific overlay.** A profile `NAME` can have a sibling, gitignored
`NAME.local` layered on top after it is read: same syntax/sections, but its
scalar values win and its `keep=`/`setenv=` accumulate. Commit portable profiles
to a dotfiles repo; keep host-specific values (an `aws_profile=`, a `token_cmd=`
path, a `seed_home=`) in the uncommitted `.local`. Precedence: base -> `.local`
-> explicit CLI flags.

```
# ~/.config/csb/profiles/work.local   (gitignored, per-host)
aws_profile=work-primary/AdminOnThisBox
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

These are read from the worktree in worktree mode (not `--here`). All are
repo-controlled and run/inject **host-side, unsandboxed** -- see the
[threat model](#threat-model).

**`.worktreeinclude`** (repo root, `.gitignore` syntax) -- csb copies matching
**gitignored** files (local `.env`s, generated config) into a newly created
worktree; existing files are never overwritten. A generic worktree-tooling
convention, not csb-specific.

**`.worktreesetup.sh`** (in the worktree, executable) -- run after
`.worktreeinclude` with the branch name as `$1` and the worktree as cwd, on
**every** invocation (create, reuse, `csb -n`), so write it **idempotent**. A
non-zero exit aborts csb. csb runs the worktree's *own* copy, so each branch can
carry its own setup. It can generate `.worktreeenv` for branch-parameterized
values:

```bash
#!/usr/bin/env bash
set -euo pipefail
branch="$1"
db="myapp_$(printf '%s' "$branch" | tr -c 'a-z0-9' _)"   # per-branch database
createdb "$db" 2>/dev/null || true
printf 'DATABASE_URL=postgres://localhost/%s\n' "$db" > .worktreeenv
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
is resolved. In `--here` mode an existing `.worktreeenv` is honored, but setup
and seeding are not run.

## `--aws PROFILE`

Injects short-lived role credentials for an aws profile into the launched
environment (also via a profile's `aws_profile=`):

- Host-side `aws configure export-credentials --format env`, with an
  `aws sso login --use-device-code` fallback when creds are missing/expired.
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` /
  `AWS_CREDENTIAL_EXPIRATION` are injected as env overrides (not `--keep`: they
  need not preexist in your shell), plus `AWS_REGION` when configured.
- The credential expiry is printed at launch so staleness is visible.
- **Caveat:** role creds live ~1h and do **not** refresh inside a running
  session -- re-launch csb to refresh. The real `~/.aws` stays denied throughout.

```sh
csb --aws work-primary/Admin -s -E --here -- aws sts get-caller-identity  # the role
csb --aws work-primary/Admin -s -E --here -- cat "$HOME/.aws/config"      # denied
```

## Filesystem sandbox

Two policies for the launched process (and its children):

### Read deny-list

Reads are default-allow minus a deny-list of sensitive paths, blocked **even by
absolute path**. Built-in floor (`$HOME`-relative; missing paths are skipped at
launch):

```
secrets / keys   ~/.ssh  ~/.aws  ~/.gnupg  ~/.password-store  ~/.netrc
                 ~/.azure  ~/.oci  ~/.vault-token  ~/.granted
claude           ~/.claude  ~/.claude.json{,.backup}
                 ~/.csb/claudes  (the active namespace is re-allowed)
cloud / infra    ~/.config/{gh,gcloud,doctl,fly,rclone,op,configstore,git,
                 github-copilot}  ~/.kube  ~/.docker  ~/.gemini
                 ~/.terraformrc  ~/.terraform.d  ~/.databrickscfg{,.bak}
                 ~/.databricks  ~/.mc  ~/.minio  ~/.s3cfg  ~/.boto
packaging creds  ~/.cargo/credentials{,.toml}  ~/.gem/credentials  ~/.pypirc
                 ~/.m2/settings.xml
db creds         ~/.pgpass  ~/.my.cnf
git / vcs        ~/.gitconfig  ~/.config/git
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
may need them): `~/.npmrc`, `~/.bundle/config`, `~/.yarnrc`. Add your own in
`${XDG_CONFIG_HOME:-~/.config}/csb/deny` -- one path per line, leading `~/`
expanded, `#` comments and blanks ignored. **Add-only**: the built-ins can never
be removed via config; any other line is a parse error and the launch aborts
loudly. (Denying `~/Library/Keychains` makes host `security` calls fail inside
the sandbox -- expected, but it may surprise repo tooling that shells out to it.)

### Write allow-list

Writes are **default-denied**; allowed roots:

- the worktree (or the current dir with `--here`)
- the repo's git common dir -- commits from a linked worktree write objects into
  the main repo's `.git` -- **except** `hooks/` and `config` (host code-exec
  vectors), which stay read-only
- the active namespace HOME (or the ephemeral HOME)
- tmp: `/tmp`, the per-user temp/cache dirs (macOS), `/var/tmp` (Linux), and the
  configured `tmpdir` if set
- `/dev` (ptys -- the TUI writes its terminal)

Extra roots go in `${XDG_CONFIG_HOME:-~/.config}/csb/allow-write`, same format
and add-only/parse-error rules. Expected fallout: `git config` writes and hook
installation fail inside the sandbox; tools that write caches to absolute paths
outside `$HOME` need an entry.

### `--paranoid`: whitelist reads

The default read policy is a blacklist. `--paranoid` flips it to a whitelist: the
**real HOME** is read-denied wholesale, and only the write-allow roots (worktree,
git dir, namespace HOME, tmp) are re-allowed for reading. Paths outside HOME
(`/nix`, `/etc`, `/usr`, ...) stay readable so the devShell works.

Because the launched `HOME` is redirected to the namespace dir, tool caches and
config land under that re-allowed dir and keep working -- so `--paranoid` is
rarely disruptive. When something needs a specific real-HOME path, add it to
`allow-write` (write-allow roots are read-allowed too). Enable per run
(`--paranoid` / negate `--no-paranoid`) or per context via a profile's
`paranoid=true`; there is no global toggle.

The deny is scoped to the real HOME, so a source tree that lives *outside* HOME
stays readable -- e.g. a `~/src -> /Volumes/src` symlink resolves to a path that
paranoid never fences. Wall such trees off with `paranoid_deny=` (below); the
write-allow roots are re-allowed on top, so the active worktree stays readable.

### `--paranoid`: ancestor traversal and what it leaks

A re-allowed subtree usually sits *below* a denied root -- the worktree beneath
the real HOME (when repos live under `$HOME`) or beneath a `paranoid_deny=` root
(when the code tree lives outside `$HOME`, e.g. on a separate volume), and the
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

#### paranoid guarantee (and its bound)

`--paranoid` guarantees the sandbox **cannot read file *contents* outside the
allow-list**. It does **not** hide the *existence and entry names* of the
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
with `paranoid_deny=`), only the code-tree names leak and `$HOME` is reached
solely via the metadata-only namespace chain, so it stays un-listable. A symlink
out of `$HOME` resolves to its physical target, so it is the physical location,
not the symlinked path, that determines what leaks.

### Machine config

`${XDG_CONFIG_HOME:-~/.config}/csb/config` -- `KEY=VALUE` lines. A gitignored
`config.local` alongside it is read last (scalar values win, list values
accumulate), so one committed `config` can be shared across hosts with
host-specific overrides layered on top -- the same pattern as profile `.local`
overlays:

```
tmpdir=/scratch/tmp     # tmp dir for the launched process: its TMPDIR, the
                        # ephemeral -E HOMEs, and a write-allow root. For
                        # machines with a scratch device.
paranoid_deny=/Volumes  # under --paranoid, also read-deny this root (write
                        # roots are re-allowed on top). Repeatable. For trees
                        # outside the real HOME that the HOME-scoped deny misses.
```

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
  hatch. Add paths to `~/.config/csb/deny` as you find them.
- **paranoid leaks ancestor names (macOS).** To let path-walking tools reach a
  worktree nested under a denied root, `--paranoid` makes the worktree's ancestor
  directories listable -- so sibling volume/host/org/repo *names* on that one path
  are visible, though sibling *contents* stay denied. Bounded by design; see
  [`--paranoid`: ancestor traversal and what it leaks](#--paranoid-ancestor-traversal-and-what-it-leaks).
- **Host-side trust.** All `nix` eval/build/develop, the repo's
  `flake.nix`/`shellHook`, and `.worktreesetup.sh` run on the host,
  **unsandboxed**. Only the final claude/bash process is wrapped. Don't point csb
  at a repo you don't trust.
- **Single layer.** The seatbelt/bwrap profile *is* the containment -- no
  unprivileged-user boundary underneath. On macOS a second boundary means a
  separate OS user or a VM, not a profile tweak (seatbelt has no
  process-isolation primitive). Linux gets a PID namespace for free.
- `sandbox-exec` is formally deprecated (but stable -- nix's own darwin sandbox
  uses the same libsandbox). The mechanism is isolated in one helper
  (`build_deny_wrapper`) if it needs replacing.

### Hardening for untrusted instructions

If you intend to run instructions you don't fully trust, the two real moves, in
order of leverage:

1. **A second boundary** -- a separate unprivileged OS user, or (cleaner, and the
   documented successor to `sandbox-exec`) a lightweight VM with a controllable
   network. Not implemented today (see `docs/PLAN-003.md`, `docs/TODO.md`).
2. **Restrict egress** -- not natively possible by hostname. A VM makes it
   straightforward; without one, the achievable native step is a `localhost`-only
   egress mode, useful only for tasks that don't need claude's network mid-run.

## What a repo needs

Nothing csb-specific -- just a standard `flake.nix` exposing `devShells.default`
(the repo's full toolchain). Scaffold a minimal standalone dev flake with:

```sh
nix flake init -t git+ssh://git@git.grandrew.com/atongen/csb.git
```

If `flake.nix` is missing, or present but without a
`devShells.default` for your system, csb fails fast with guidance before
launching. nix ignores untracked files, so `git add` a brand-new `flake.nix`
before running.

csb dogfoods itself: its own `flake.nix` exposes a `devShells.default` (git +
shellcheck), so `csb --here` runs claude on the csb repo like any other.

## Files

```
bin/csb                    the orchestrator (worktree + deny-list + launch)
flake.nix                  packages {csb, claude, bwrap (linux)} + apps + templates
templates/repo/            scaffold: a standalone dev-shell flake for a consuming repo
templates/home/            starter seed-home skeleton (copy to ~/.config/csb/home)
Makefile                   install, lint, and build targets (make help)
docs/PLAN-002.md           the implemented design (single mode, deny-list, profiles, --aws)
docs/PLAN-003.md           roadmap: VM second boundary (not implemented)
docs/TODO.md               current state and next steps
```

See `docs/` for design rationale and history (`PLAN-000` ... `PLAN-003`).
