# csb — claude sandbox

`csb` runs [Claude Code](https://www.anthropic.com/claude-code) — or a shell — in a
**per-branch git worktree**, inside the **repo's own nix devShell** (full
toolchain), behind three layers:

1. **env scrub** — `nix develop --ignore-environment` plus a small allowlist
   (extend with `-k/--keep` or a profile's `keep=`).
2. **private HOME** — `HOME` is redirected to a per-namespace dir under
   `~/.csb/claudes` (or a throwaway dir with `-E`) for the launched process only.
3. **filesystem sandbox** (`sandbox-exec`/seatbelt on macOS, bubblewrap on
   Linux) with two policies:
   - **reads**: default-allow minus a deny-list — `~/.ssh`, `~/.aws`,
     `~/.gnupg`, the real `~/.claude`, other namespaces, browser profiles,
     packaging credentials — blocked **even by absolute path**. Extend via
     `~/.config/csb/deny` (add-only; the built-in floor can't be removed).
     `--paranoid` inverts this to a whitelist: the real HOME becomes read-deny
     except the write-allow roots (see below), so only paths csb explicitly
     grants are readable.
   - **writes**: default-deny plus an allow-list — the worktree, the repo's git
     dir (minus `hooks/` and `config`), the namespace HOME, tmp dirs, `/dev`.
     Extend via `~/.config/csb/allow-write`. This blocks the persistence
     vectors a read deny-list can't: `~/.zshrc`, `~/bin`, LaunchAgents, your
     *other* checkouts.

   On Linux the process additionally runs in its own PID namespace
   (`--unshare-pid`): other processes are invisible and unsignalable. macOS
   seatbelt has no workable equivalent (verified empirically — signal filtering
   doesn't hold and `process-info` denial breaks child spawning).

**Network and host services stay open by design**: claude and the `-s` shell can
reach local db/redis/etc for testing. See
[what this does and does not protect against](#what-it-does-and-does-not-protect-against).

**Decoupled by design:** the repo needs no csb-specific files — just its own
`flake.nix` with `devShells.default`. The claude binary comes from *csb's own*
flake; the repo never imports csb.

> Status: developed/verified on `aarch64-darwin`. The Linux (bubblewrap) deny
> path is implemented to plan but **not yet verified end-to-end** — NixOS
> verification is the gating milestone (see `docs/PLAN-002.md`). Non-NixOS
> distros with restricted user namespaces may need a setuid bwrap (out of scope).

## Install

```sh
make install                 # copies bin/csb into ~/bin
# or: make install BIN_DIR=~/.local/bin
```

`make help` lists the other targets.

Requires [Nix](https://nixos.org) with flakes (Determinate Nix works out of the
box); `csb` shells out to `nix`. `--aws` additionally needs the `aws` CLI on the
host (only there — the devShell needs nothing).

- **`CSB_SELF`** — the flake ref csb pulls its claude binary (and, on Linux,
  bubblewrap) from. Defaults to the network-local remote
  `git+ssh://git@git.grandrew.com/atongen/csb.git`. For local development against
  a working tree, override per-invocation: `CSB_SELF=path:/path/to/csb csb …`.
- **`CSB_LATEST`** — if set (non-empty), defaults `-L/--latest` on: each run
  re-locks the `claude-code` flake input to its upstream HEAD (and refreshes
  nix's flake cache) instead of using the rev pinned in `flake.lock`. Trades
  reproducibility and a little startup latency for always getting the newest
  claude. Per-invocation `-L` does the same for a single run.

## Auth

claude runs with a private HOME and the real `~/.claude` denied, so a host login
is never visible. Two ways in:

- **`--seed-creds` / `seed_creds=true` (recommended)** — csb copies your native
  claude session credential (macOS keychain item / Linux
  `~/.claude/.credentials.json`) into the launch config, host-side, on every
  launch. The sandbox then presents your **live subscription session** — same
  account, same model entitlements as native claude. Caveat: sandbox and native
  share one refresh-token family, so occasional mutual re-login prompts are
  possible. Requires a native login for the wanted account on the host.
- **Token** — `claude setup-token` once, then `CLAUDE_CODE_OAUTH_TOKEN` (or,
  better, `token_cmd=pass …/claude/token` in a profile, fetched host-side so it
  never transits your interactive shell). Caveat: long-lived tokens carry the
  entitlements from **mint time** — they can lag newly released model tiers
  until regenerated, and may not carry new-tier access at all.

## Use

```sh
csb feature/foo                  # worktree for feature/foo (off HEAD) + claude in the devShell
csb -y feature/foo               # allow-all (--dangerously-skip-permissions)
csb feature/foo -- --model opus  # everything after -- is passed to claude
csb --here                       # run in the current dir, no worktree (namespace = current branch)
csb -s feature/foo               # interactive shell instead of claude (exact same env)
csb -s -E --here -- cat ~/.ssh/config   # run a command in the agent's env (this one fails: denied)
csb -p drip feature/foo          # profile: ns/token/aws/keeps/env from ~/.config/csb/profiles/drip
csb --aws drip-primary/Admin feature/foo   # inject short-lived aws role creds
csb -k AWS_PROFILE feature/foo   # also keep AWS_PROFILE across the env scrub (repeatable)
csb -L feature/foo               # newest claude (re-lock claude-code to upstream HEAD this run)
csb --ns drip feature/foo        # override the namespace (default is the branch)
csb --ns @drip feature/foo       # unscoped namespace, shared across repos
csb -E feature/foo               # ephemeral: throwaway config/HOME, no namespace
csb -n feature/foo               # just prepare/reuse the worktree, don't launch (prints its path)
csb -d feature/foo               # remove the worktree AND its namespace config (branch is kept)
csb                              # list csb worktrees
```

`BRANCH` and `--here` are mutually exclusive: either csb provisions a worktree
for `BRANCH`, or it runs in the current directory as-is. All combinations of
{claude, `-s` shell} × {worktree, `--here`} land in the same restricted devShell
environment. tmux is yours to manage: run `csb` in one pane, edit / `git push`
from another.

## What it does and does not protect against

**Threat model — read this first.** csb assumes a **trusted operator running
trusted instructions**. It is built to (a) prevent *accidental* damage and
*accidental* exposure of the obvious credentials, and (b) keep separate work
(namespaces, other repos) from bleeding into each other. Every trade-off below
is defensible under that assumption. It is a **weaker** story against
*untrusted instructions* — prompt injection from a fetched page, a malicious
dependency, a poisoned issue/PR — because the two capabilities csb deliberately
keeps open (broad filesystem *reads* and open *network egress*) are exactly the
exfiltration primitive: anything the agent can read, injected instructions can
read, and anything readable can be shipped off-box. csb does not defend against
a hostile agent; if you run untrusted instructions, see
[hardening](#hardening-for-untrusted-instructions).

Named trade-offs, accepted deliberately (see `docs/PLAN-002.md`):

- **Open network egress.** Unrestricted outbound; `curl`/`ssh`/`openssl` are on
  PATH. This is the price of claude reaching local services (db, redis, …) for
  real testing. It cannot be narrowed to "just github + registries" cheaply:
  seatbelt filters network by ip/port only, **not by hostname** (verified:
  `sandbox-exec: host must be * or localhost in network address`), so
  host-based egress control needs a filtering proxy — the `allowedDomains`
  subsystem plan-002 deliberately removed. `localhost`-only egress *is*
  natively expressible and is the basis of the opt-in lockdown mode below.
- **Read deny-list is a blacklist — it fails open.** The floor below is the
  reviewed set; anything *not* on it under your real HOME (a stray `.env`, files
  under `~/Documents` or `~/Library/Application Support`, a dotfile for a tool
  the floor didn't anticipate) is readable. A read *allow*-list (only the
  project tree + agent home) would close this but is deferred: interactive
  toolchains read enormously, so it is weeks of breakage whack-a-mole (it's why
  nix only default-denies reads for hermetic *builds*). Add paths to
  `~/.config/csb/deny` as you find them.
- **Host-side trust.** All `nix` eval/build/develop runs on the host,
  unrestricted — the repo's `flake.nix`/`shellHook` and `.worktreesetup.sh`
  execute **unsandboxed**, exactly as before. Only the final claude/bash process
  is wrapped. Don't point csb at a repo you don't trust.
- **Single layer, privileged account.** The seatbelt/bwrap profile *is* the
  containment — there is no unprivileged-user boundary underneath it, so the
  profile is a single point of failure rather than defense-in-depth. On macOS
  this is not a quick fix: seatbelt has **no** process-isolation primitive
  (verified — signal-deny doesn't hold, `process-info`-deny breaks child
  spawning), so a second boundary means a separate OS user or a VM, not a
  profile tweak. Linux gets a PID namespace (`--unshare-pid`) for free.
- **HOME redirection is hygiene, not containment** — it steers `~`-relative
  lookups; the deny-list is what blocks absolute paths. Both layers stay.
- **Shell wrapper scratch in `/tmp`.** claude's shell integration writes a
  predictable `/tmp/claude-<pid>-cwd` and sources a snapshot from the config
  dir. World-readable `/tmp` is a minor *local*-tamper surface (not remotely
  exploitable); pointing `tmpdir=` (below) at a private dir moves it out of
  shared `/tmp`.
- `sandbox-exec` is formally deprecated (but stable — nix's own darwin sandbox
  uses the same libsandbox). The mechanism is isolated in one helper
  (`build_deny_wrapper`) if it ever needs replacing; the VM path is its
  eventual successor and also the natural home for a real network boundary.

### Hardening for untrusted instructions

If you intend to run instructions you don't fully trust, the denylist-plus-open-
network posture is not enough, and patching the read denylist file-by-file is
unwinnable. The two real moves, in order of leverage:

1. **A second boundary.** A separate unprivileged OS user, or (cleaner, and the
   documented succession path for sandbox-exec) a lightweight VM with a
   controllable network. This is the only thing that addresses both the
   single-point-of-failure and the exfil-under-injection concerns at once.
   Neither is implemented today (see `docs/TODO.md`).
2. **Restrict egress.** Not natively possible by hostname (above). A VM makes it
   straightforward; without one, the achievable native step is a `localhost`-only
   egress mode (local db/redis still reachable, external DNS blocked) — useful
   only for tasks that don't need claude's own network mid-run.

### The read deny list

Built-in defaults (`$HOME`-relative; missing paths are skipped at launch):

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

Deliberately **not** in the floor (in-sandbox installs against private
registries may need them): `~/.npmrc`, `~/.bundle/config`, `~/.yarnrc`. Add
them to your personal deny file if your repos don't. Or use `--paranoid`, which
denies the whole real HOME by default (see below).

Add your own in `${XDG_CONFIG_HOME:-~/.config}/csb/deny` — one path per line,
leading `~/` expanded, `#` comments and blank lines ignored. **Add-only**: the
built-ins can never be removed via config. Any other line is a parse error and
the launch aborts loudly (a misparsed deny file must not silently launch
unprotected).

Denying `~/Library/Keychains` makes host `security` calls fail inside the
sandbox — expected and desired; it may surprise repo tooling that shells out
to it.

### The write allow list

Writes are **default-denied**; allowed roots:

- the worktree (or the current dir with `--here`)
- the repo's git common dir — commits from a linked worktree write objects into
  the main repo's `.git` — **except** `hooks/` and `config`, which stay
  read-only (they execute code on your host)
- the active namespace HOME (or the ephemeral HOME)
- tmp: `/tmp`, the per-user temp/cache dirs (macOS), `/var/tmp` (Linux), and
  the configured `tmpdir` if set
- `/dev` (ptys — the TUI writes its terminal)

Extra roots go in `${XDG_CONFIG_HOME:-~/.config}/csb/allow-write`, same format
and same add-only/parse-error rules as the deny file. Expected fallout:
`git config` writes and hook installation fail inside the sandbox; tools that
write caches to absolute paths outside `$HOME` need an `allow-write` entry.

### `--paranoid`: whitelist reads

The default read policy is a blacklist (the floor above): everything is
readable except the listed secrets. `--paranoid` flips it to a whitelist — the
**real HOME** is read-denied wholesale, and only the write-allow roots (the
worktree, git dir, namespace HOME, tmp) are re-allowed for reading. Paths
outside HOME (`/nix`, `/etc`, `/usr`, ...) stay readable so the devShell works.

Because the launched process's `HOME` is redirected to the namespace dir, tool
caches and config (`~/.cache`, `~/.config/...` *as the process sees them*) land
under that re-allowed namespace and keep working — so `--paranoid` is rarely
disruptive in practice. When something does need to read a specific real-HOME
path, add it to `allow-write` (write-allow roots are read-allowed too).

Enable per run with `--paranoid` (negate with `--no-paranoid`), or per context
with `paranoid=true` in a profile. There is no env/global toggle — profiles are
the vehicle for a persistent default.

### Machine config

`${XDG_CONFIG_HOME:-~/.config}/csb/config` — `KEY=VALUE` lines:

```
tmpdir=/scratch/tmp   # tmp dir for the launched process: its TMPDIR, the
                      # ephemeral -E HOMEs, and a write-allow root. For
                      # machines with a scratch device.
```

## Profiles

`${XDG_CONFIG_HOME:-~/.config}/csb/profiles/<name>` — one file per profile,
`KEY=VALUE` lines (`#` comments allowed). Recognized keys (anything else is an
error):

```
ns=@drip                                  # as --ns (optional)
token_cmd=pass drip/claude/token          # run host-side via bash -c;
                                          # stdout -> CLAUDE_CODE_OAUTH_TOKEN (never echoed)
aws_profile=drip-primary/Admin            # as --aws (optional)
latest=true                               # as -L/--latest; beats the CSB_LATEST
                                          # env default, loses to an explicit -L
yolo=true                                 # as -y/--yolo (allow-all)
paranoid=true                             # as --paranoid: reads default-deny under
                                          # the real HOME, allowlist re-allows
here=true                                 # as --here; an explicit BRANCH argument
                                          # wins (with a warning)
ephemeral=true                            # as -E; excludes ns= in the same profile
shell=true                                # as -s/--shell
seed_creds=true                           # as --seed-creds: seed the host claude
                                          # session into the launch config
seed_home=~/.config/csb/home              # as --seed-home: template dir copied
                                          # (non-overwriting) into the launch HOME
                                          # each run so in-sandbox claude sees your
                                          # CLAUDE.md/settings.json/rules; leading
                                          # ~/ is the HOST home; --reseed overwrites
args=bash --rcfile ~/.config/my.bashrc    # the ARGS after --: the command in -s
                                          # mode, extra claude args otherwise.
                                          # Whitespace-split, no quoting. A
                                          # leading ~/ or literal ${HOME} in a
                                          # word expands to the HOST home (args
                                          # reference host files — portable
                                          # across macOS/Linux; contrast
                                          # .worktreeenv, where ${HOME} is the
                                          # sandbox home)
keep=COLORTERM DIRENV_LOG_FORMAT          # space-separated, appended to --keep
setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 # repeatable; injected post-scrub
```

Launch with `-p/--profile NAME`. Profile values are **defaults**: explicit CLI
flags beat them, including explicit `-- ARGS` (which replace `args=`) and the
negating `--no-yolo` / `--no-here` / `--no-shell` / `--no-ephemeral` /
`--no-latest` / `--no-seed-creds` flags for the booleans. A profile with `here=true` still yields
to an explicit `BRANCH` argument (worktree mode, with a warning) — and note
bare `csb -p NAME` then launches instead of listing worktrees; plain `csb`
always lists. A failing (or empty-output) `token_cmd` aborts the launch before
any worktree/namespace side effects.

**Host-specific overlay.** A profile `NAME` can have a sibling
`~/.config/csb/profiles/NAME.local` that is layered on top of `NAME` after it is
read: same syntax and sections, but its scalar values win and its `keep=` /
`setenv=` accumulate on top. This lets you commit portable profiles to a
dotfiles repo while keeping host-specific values (an `aws_profile=`, a
`token_cmd=` path, a `seed_home=`) in the uncommitted, gitignored `.local`.
Precedence is base → `.local` → explicit CLI flags (CLI still wins). For
example, commit `profiles/drip` with the portable defaults and gitignore
`profiles/*.local`, then per host:

```
# ~/.config/csb/profiles/drip.local   (gitignored, per-host)
aws_profile=drip-primary/AdminOnThisBox
seed_home=~/dotfiles/csb-home
```

Profiles replace wrapper shell functions. The old

```bash
csbd() {
  CLAUDE_CODE_OAUTH_TOKEN="$(pass drip/claude/token)" \
    COLORTERM=truecolor \
    csb --no-sandbox --ns @drip --latest -k COLORTERM "$@"
}
```

becomes `~/.config/csb/profiles/drip`:

```
ns=@drip
token_cmd=pass drip/claude/token
latest=true
setenv=COLORTERM=truecolor
setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1
```

and `csb -p drip feature/foo` (or `alias csbd='csb -p drip'`).

### Sections: one profile, both modes

A profile can carry mode-specific values in `[claude]` / `[shell]` sections;
lines before any header (or under `[shared]`) always apply. The mode is
resolved first — CLI `-s`/`--no-shell` beats a `shell=` in the shared section —
then shared lines apply, then the active section's, so a section value
overrides a shared one (`keep=`/`setenv=` accumulate across both). `shell=` is
only valid in the shared section (it selects which section applies). In shell
mode, `token_cmd=` and `seed_creds=` are skipped entirely — a shell runs no
claude, so it gets no credential dance.

```
ns=@drip
seed_creds=true
latest=true
setenv=COLORTERM=truecolor

[shell]
here=true
args=bash --rcfile ~/.config/nix-dev-pure.bashrc
```

`csb -p drip feature/foo` launches claude in a worktree; `csb -p drip -s`
drops into the rcfile'd shell in the current dir — one file, one flag.

## `--aws PROFILE`

Injects short-lived role credentials for an aws profile into the launched
environment (also reachable via a profile's `aws_profile=`):

- Host-side `aws configure export-credentials --format env`, with an
  `aws sso login --use-device-code` fallback when creds are missing/expired.
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` /
  `AWS_CREDENTIAL_EXPIRATION` are injected as env overrides (not `--keep`: they
  need not preexist in your shell), plus `AWS_REGION` from
  `aws configure get region` when configured.
- The credential expiry is printed at launch so staleness is visible.
- **Caveat:** role creds live ~1h and do **not** refresh inside a running
  session — re-launch csb to refresh. The real `~/.aws` stays denied throughout.

```sh
csb --aws drip-primary/Admin -s -E --here -- aws sts get-caller-identity  # the role
csb --aws drip-primary/Admin -s -E --here -- cat "$HOME/.aws/config"      # denied
```

## Namespaces

A namespace partitions the agent's claude config (history/sessions/settings).
**By default the namespace is the branch** (percent-encoded — `/`→`%2F`, so
`feature/foo`→`feature%2Ffoo` — an injective mapping, no two branches collide),
so config is deterministic per branch with no hidden state to remember.
**Namespaces are scoped per repo**: they live under
`~/.csb/claudes/<repo-key>/<ns>`, where `<repo-key>` is the basename of the
physical main-checkout root plus a short path hash (`drip-4f9a11b2`). Equal
branch (or `--ns`) names in different repos therefore never share a config —
and `csb -d` in one repo can never delete another repo's history. Below,
`<rk>` stands for the current repo's key:

| Invocation | Namespace | Config |
|---|---|---|
| `csb feature/foo` | `feature%2Ffoo` (from the branch) | persistent `~/.csb/claudes/<rk>/feature%2Ffoo/.claude` |
| `csb --here` (on `feature/foo`) | `feature%2Ffoo` (from current HEAD) | persistent, same dir |
| `csb --here` (detached HEAD) | — | **error: fail fast** |
| `csb --ns drip feature/foo` | `drip` (explicit override) | persistent `~/.csb/claudes/<rk>/drip/.claude` |
| `csb --ns @drip feature/foo` | `@drip` (unscoped) | persistent `~/.csb/claudes/@drip/.claude`, shared across repos |
| `csb -E feature/foo` | none | throwaway (not persisted) |

`HOME` for the launched process is the namespace dir itself; its config lands at
`<ns>/.claude` — coinciding with claude's default `$HOME/.claude` — so caches
that normally live in `$HOME` (npm, bundler, …) rebuild there on first run and
persist per namespace. The whole `~/.csb/claudes` tree is denied except the
**active** namespace, so one branch's agent can't read another's history.

- **(default)** — the namespace is the branch. Reused on every later run for that
  branch; switching branches switches config automatically.
- **`-E`, `--ephemeral`** — throwaway config and HOME (under `$TMPDIR`), no
  namespace. Mutually exclusive with `--ns`.
- **`-N`, `--ns NAME`** — override the default with a named, isolated config under
  `~/.csb/claudes/<repo-key>/NAME` (repo-scoped like the default).
- **`--ns @NAME`** — deliberately **unscoped**: one config at `~/.csb/claudes/@NAME`
  shared by every repo launched with it (e.g. one claude home for all work repos).
  Only an explicit `--ns` can be unscoped — branch-derived names always stay under
  the repo key, so a branch named `@NAME` can't alias it. `-d` never auto-removes
  an `@`-namespace (shared lifecycle is manual: `rm -rf ~/.csb/claudes/@NAME`).
- **`global`** — reserved. `--ns global` (the old "use my real `~/.claude`" mode)
  was **removed**: every run is namespaced or ephemeral, and the real `~/.claude`
  is always denied. A branch literally named `global` still gets a plain per-repo
  dir (derived names are never special).

`csb -d <branch>` removes the worktree **and** its per-branch namespace config
(stale configs hold session history and the auth they were seeded with, so leaving
them around is a footprint risk). Pass the same `--ns` you launched with; without
it, `-d` only removes the branch-derived namespace (csb keeps no record of how you
ran, so it can't guess an override).

## Seeding the sandbox HOME

Inside the sandbox, claude runs with a redirected `HOME` (the namespace dir) and
the real `~/.claude` is denied — so your **user-level** files (`~/.claude/CLAUDE.md`,
`settings.json`, `rules/`) are invisible. To carry them in, put copies in a
template dir and csb seeds them into the launch HOME on **every** launch, so
freshly-created namespaces get them on first use:

```
~/.config/csb/home/          # the default template dir
├── .claude/
│   ├── CLAUDE.md            # your user memory, now visible in-sandbox
│   ├── settings.json
│   └── rules/…
└── …                        # anything else you want under the sandbox HOME
```

The template's contents are copied into the launch HOME **non-overwriting** —
existing files (including ones claude wrote itself) are kept. Point at a different
dir with `--seed-home DIR` or a profile's `seed_home=`; force overwrites with
`--reseed`. This is deliberately a **template you curate**, not a sweep of your
real `$HOME` — only what you place here crosses into the sandbox, so it never
re-exposes what the deny-list protects. A template-provided `.claude.json` is
merged with csb's onboarding seed rather than clobbered.

For **project-level** instructions, you usually don't need this at all: a
`CLAUDE.md` at the worktree root is read directly (the worktree is always
readable), and a gitignored one can ride in via `.worktreeinclude` (below).

## `.worktreeinclude`

If the repo root has a `.worktreeinclude` (same syntax as `.gitignore`), csb copies
matching **gitignored** files (e.g. local `.env`s, generated config) into a newly
created worktree; existing files are never overwritten. It's a generic
worktree-tooling convention (predates csb), not csb-specific.

## `.worktreesetup.sh`

After `.worktreeinclude` is processed, if the worktree contains an executable
`.worktreesetup.sh`, csb runs it with the branch name as `$1` and the worktree as
its working directory. It runs on **every** worktree invocation (initial create,
reuse, and `csb -n`), so write it to be **idempotent**. A non-zero exit aborts
csb — claude is not launched in a half-set-up worktree.

csb runs the worktree's *own* copy of the script, so each branch can carry its own
setup logic. The script may be committed (present in every checkout) or gitignored
and seeded via `.worktreeinclude`. Like the repo's `flake.nix`, it executes
repo-controlled code on the host, **unsandboxed** — it runs before the deny
wrapper starts. It does not run in `--here` mode (which, like
`.worktreeinclude`, skips worktree seeding).

## `.worktreeenv`

At launch, if the worktree contains `.worktreeenv`, its dotenv-style `VAR=value`
lines (blank lines and `#` comments skipped, names validated) are injected into
the scrubbed environment via the same `env` wrapper that redirects HOME — so
they apply after `--ignore-environment`, inside the devShell, identically for
claude and `-s` shell sessions, without touching the `--keep` allowlist. Values
win over anything the shellHook or dotenv-style loaders would otherwise supply
only if those respect existing environment variables (Rails dotenv does by
default). A profile's `setenv=` values are injected after `.worktreeenv`, so
user config beats the repo file when both set a var.

Like `.worktreesetup.sh`, the file is repo-controlled: commit it, seed it via
`.worktreeinclude`, or — for branch-parameterized values (per-worktree database
names, redis db numbers) — generate it from `.worktreesetup.sh`, which runs
before launch and receives the branch name. A literal `${HOME}` in a value is
expanded at injection time to the launch's *effective* home — the namespace
dir (or throwaway dir with `-E`). Generators run on the host before the
namespace is resolved, so this is the only way to anchor a value to the sandbox
HOME (e.g. a per-namespace cache). In `--here` mode an existing `.worktreeenv`
in the current directory is honored (setup/seeding are not run).

## What a repo needs

Nothing csb-specific — just a standard `flake.nix` exposing `devShells.default`
(the repo's full toolchain). `nix flake init -t <csb>` scaffolds a minimal
standalone dev flake to start from. If `flake.nix` is missing, or present but
without a `devShells.default` for your system, csb fails fast with guidance
before launching. nix ignores untracked files, so `git add` a brand-new
`flake.nix` before running.

csb dogfoods itself: its own `flake.nix` exposes a `devShells.default` (git +
shellcheck), so `csb --here` (or `csb <branch>`) runs claude on the csb repo
like any other. See `docs/TODO.md` for current dogfooding state and next steps.

## Files

```
bin/csb                    the orchestrator (worktree + deny-list + launch)
flake.nix                  packages {csb, claude, bwrap (linux)} + apps + template
templates/repo/            scaffold: a standalone dev-shell flake
Makefile                   install, lint, and build targets (make help)
docs/PLAN-002.md           the current design (single mode, deny-list, profiles, --aws)
```

See `docs/` for design rationale and history (`PLAN-000` … `PLAN-002`).
