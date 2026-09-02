# csb -- code sandbox

`csb` runs a coding agent -- [Claude
Code](https://www.anthropic.com/claude-code) today, selected by
[`agent=`](#choosing-the-agent---agent) -- or a shell, in a **per-branch git
worktree**, inside the **repo's own nix devShell**, behind three layers:

1. **env scrub** -- `nix develop --ignore-environment` plus a small allowlist
   (extend with `-k/--keep` or a profile's `keep=`).
2. **private HOME** -- `HOME` is redirected to a per-namespace dir under
   `~/.csb/agents` (one per repo and agent by default, shared across the repo's
   branches; or a throwaway dir with `-E`) for the launched process only.
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
> - **Network and host services stay open by default**, so the agent (and the `-s`
>   shell) can reach local db/redis/etc for testing -- anything readable is
>   exfiltratable. [`--filter-egress`](#filtering-egress---filter-egress) narrows
>   outbound traffic to an allowlist, but it is off unless you ask for it and it
>   costs you WebFetch for every host you don't list.
> - **The sandbox constrains filesystem operations, and IPC only where it can.**
>   A host service that acts on the sandboxed process's behalf does its work
>   *outside* the sandbox, as you. Verified escapes of this shape existed on
>   both platforms and are now closed, but the class is not exhausted -- see
>   [Known gaps](#known-gaps) for what is closed, what stays open, and what is
>   accepted as unfixable.

**Decoupled by design:** the repo needs no csb-specific files. Its own
`flake.nix` with `devShells.default` is preferred, not required -- csb falls
back to a generic devShell otherwise (see [What a repo needs](#what-a-repo-needs)).
The agent binary comes from *csb's own* flake; the repo never imports csb.

> **Status.** Verified end-to-end on `aarch64-darwin` (seatbelt) and on NixOS
> (bubblewrap). **Not published:** csb lives on a private remote, which is
> `CSB_SELF`'s default, and nix must be able to fetch it (ssh access) at launch.
> Override `CSB_SELF` (`CSB_SELF=path:/path/to/csb`) for local development
> against a working tree, or point it at your own fork's remote.
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
make install                     # csb -> ~/bin (on PATH); csb-config -> ~/.csb/bin
export CLAUDE_CODE_OAUTH_TOKEN=...      # from 'claude setup-token'; or use --seed-creds
cd ~/src/your/repo               # a repo with a flake.nix (see "What a repo needs")
csb feature/foo                  # worktree for feature/foo + the agent in the devShell
```

Requires [Nix](https://nixos.org) with flakes (Determinate Nix works out of the
box); `csb` shells out to `nix`.

csb installs as two programs. `csb` orchestrates -- git, nix, the sandbox
profile, the launch -- and `csb-config` owns the flag grammar, the profiles,
their validation, `--help` and `--dump-config`.

They land in different places on purpose. `csb` is a portable shell script and
goes in your `bin` dir (`BIN_DIR`, default `~/bin`), which is commonly under
version control. `csb-config` is a native per-platform binary, so it goes in
csb's own `~/.csb/bin` (`TOOLS_DIR`) instead -- out of a versioned bin dir, and
outside every sandbox write root, which matters because csb-config decides
policy and runs unsandboxed.

csb finds it by searching, in order: `CSB_CONFIG_BIN` (a verbatim path), a
`csb-config` beside the `csb` script, this repo's own `ocaml/_build` when you
run `./bin/csb` from a checkout, `~/.csb/bin`, then `PATH`. If you override
`TOOLS_DIR`, put that directory on `PATH` or set `CSB_CONFIG_BIN`; `make
install` warns when neither holds.

Five environment variables tune csb:

- **`CSB_SELF`** -- the flake ref csb pulls its agent binary (and, on Linux,
  bubblewrap) from. Defaults to the private remote
  `git+ssh://git@git.grandrew.com/atongen/csb.git`, so a launch needs ssh access
  to it. For local development against a working tree, override per-invocation:
  `CSB_SELF=path:/path/to/csb csb ...`.
- **`CSB_LATEST`** -- if set (non-empty), defaults `-L/--latest` on: re-lock the
  `claude-code` flake input to its upstream HEAD instead of the rev pinned in
  `flake.lock`. Trades reproducibility for always getting the newest claude.
  Specific to the `claude-code` flake; other agents track csb's `nixpkgs` input.
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
csb feature/foo                  # worktree for feature/foo (off HEAD) + the agent in the devShell
csb -y feature/foo               # allow-all (the agent's skip-every-prompt flag)
csb feature/foo -- --model opus  # everything after -- is passed to the agent
csb --here                       # run in the current dir, no worktree (per-repo namespace)
csb -s feature/foo               # interactive shell instead of the agent (exact same env)
csb -s -E --here -- cat ~/.ssh/config   # run a command in the agent's env (this one fails: denied)
csb -s --no-sandbox --real-home --here -k SSH_AUTH_SOCK   # deploy shell: same devShell
                                 # + env scrub, but full fs + real HOME (see Filesystem sandbox)
csb -p work feature/foo          # profile: ns/token/keeps/env from ~/.config/csb/profiles/work
csb -k AWS_PROFILE feature/foo   # also keep AWS_PROFILE across the env scrub (repeatable)
csb -L feature/foo               # newest claude (re-lock claude-code to upstream HEAD this run)
csb --agent claude feature/foo   # which agent runs (claude is the default)
csb --ns work feature/foo        # shared, cross-repo HOME (default is per repo and agent)
csb --ns @work feature/foo       # same thing -- the @ is optional (work == @work)
csb -E feature/foo               # ephemeral: throwaway config/HOME, no namespace
csb -E=work --here               # named ephemeral: reusable throwaway HOME (attach a shell)
csb -n feature/foo               # just prepare/reuse the worktree, don't launch (prints its path)
csb -d feature/foo               # remove the worktree (branch and per-repo HOME are kept)
csb --list-ns                    # list csb namespace configs (per repo+agent, shared @)
csb --reap                       # reclaim what dead sessions left (proxies, ephemeral HOMEs)
csb                              # list csb worktrees
```

`BRANCH` and `--here` are mutually exclusive: either csb provisions a worktree
for `BRANCH`, or it runs in the current directory as-is. All combinations of
{agent, `-s` shell} x {worktree, `--here`} land in the same restricted devShell.
tmux is yours to manage: run `csb` in one pane, edit / `git push` from another.

`csb --help` prints the full flag reference. `make help` lists the build/install
targets.

## Choosing the agent (`--agent`)

`agent=` (CLI `--agent NAME`, or the key in a config section or profile) selects
which agent CLI a launch runs. `claude` is the default and, today, the only
value.

The agent is one axis with one answer, and it decides everything csb has to know
about the tool it launches: the flake output the binary comes from, the variable
that carries the credential (`token_env`), the flag `-y/--yolo` becomes, the
quiet knobs injected as the lowest `setenv` layer, the files seeded into the
launch HOME, the state dir inside it, the `--seed-creds` source, and which
`allowed-hosts.<agent>` file the egress allowlist is read from. That table lives
in one place, `ocaml/lib/agent.ml`; `bin/csb` receives its values as opaque
strings and seed instructions and never branches on the agent itself.

`--dump-config` reports the resolved answer and what it implied:

```
agent=claude
agent_bin_attr=claude
token_env=CLAUDE_CODE_OAUTH_TOKEN
seed=json_merge:.claude/.claude.json
cred_seed=keychain:.claude/.credentials.json
```

Two knobs are deliberately agent-specific rather than generic:

- **`-L/--latest`** re-locks the `claude-code` flake input, so it means nothing
  for any other agent -- their currency comes from bumping csb's own `nixpkgs`
  input.
- **the shared `@NAME` namespace** is not agent-suffixed; see
  [Namespaces](#namespaces).

## Auth

The agent runs with a private HOME and its real state dir denied, so a host
login is never visible. Two ways in:

- **`--seed-creds` / `seed_creds=true` (recommended)** -- csb copies your native
  session credential for the agent (for claude: the macOS keychain item, or
  `~/.claude/.credentials.json` elsewhere) into the launch HOME, host-side. The
  sandbox
  then presents your **live subscription session** -- same account, same model
  entitlements as native claude. The copy is skipped while the launch config
  already holds a credential that can still renew itself -- gated on the
  **refresh** token's expiry, not the access token's, because claude renews the
  access token in place and rotates the refresh token when it does. After the
  first rotation the sandbox's copy is the current one and the host's is stale,
  so re-seeding would replace a working session with a dead one. Caveat: sandbox
  and native share one refresh-token family, so a refresh in either can log the
  other out -- expect that with several sessions running at once. Requires a
  native login for the wanted account on the host.
- **Token** -- `claude setup-token` once, then the agent's credential variable
  (`CLAUDE_CODE_OAUTH_TOKEN`; `--token-env VAR` / `token_env=` names another) --
  or, better, `token_cmd=pass .../claude/token` in a profile, fetched host-side
  so it never transits your interactive shell. A forwarded token wins over a seeded
  session credential, and the launch removes any seeded credential left in the
  config so nothing stale can take over if the token is later unset. The token
  supersedes only the session credential, so other stored auth in that file
  (MCP connector grants) is preserved. Caveat:
  long-lived tokens carry the entitlements from **mint time** -- they can lag
  newly released model tiers until regenerated (unverified; see docs/TODO.md).

## Namespaces

A namespace is just **which `HOME` the sandboxed process gets** -- and with it
the agent's own state dir (history/sessions/settings), caches, and anything else
that lives in `$HOME`. `-N`, `-E`, and `--real-home` are three mutually-exclusive
choices for that HOME; the default is a redirected HOME per repo and agent. They
differ in *persistence* and in whether that HOME is *writable* inside the sandbox:

| Choice | HOME | Persistent | Writable in sandbox | Seeded |
|---|---|---|---|---|
| **default** | `~/.csb/agents/repo-<key>-<agent>` (per repo and agent) | yes | yes | yes |
| **`-N NAME`** | `~/.csb/agents/@NAME` (shared across repos *and* agents) | yes | yes | yes |
| **`-E`** | a throwaway dir under tmp | no | yes | yes |
| **`--real-home`** | your real `$HOME` | n/a | **no** (reads obey the deny-list) | no |

`--per-repo` names the default explicitly, which is how one run declines an
`ns=`, `ephemeral=` or `real_home=` set by a config section or a profile. Since
the four are one axis it retracts whichever of the three a lower layer chose;
there is no per-key negation, and naming two selectors at once is an error.

**By default the namespace is the repo and the agent, not the branch.** One
persistent HOME is shared by every branch and worktree of the repo, living flat
at `~/.csb/agents/repo-<key>-<agent>`, where `<key>` is the basename of the
physical main-checkout root plus a short path hash (`myapp-4f9a11b2`). The hash
keeps two different repos that share a basename from ever sharing a HOME, and
the trailing agent name keeps two agents from sharing one -- so retirement,
seeding, `--reseed` and seeded credentials stay per-agent, and one agent's
sessions are never readable by another. The suffix sits *after* the hash, so it
cannot be confused with a repo basename that happens to end in an agent's name.
Because the default is derived from the repo every run, `csb <branch>` is
deterministic with no hidden state.

| Invocation | Namespace | HOME |
|---|---|---|
| `csb feature/foo` | `repo-<key>-claude` (this repo, this agent) | persistent `~/.csb/agents/repo-<key>-claude` |
| `csb --here` | `repo-<key>-claude` (this repo, this agent) | persistent, same dir |
| `csb --ns work feature/foo` | `@work` (shared) | persistent `~/.csb/agents/@work` |
| `csb --ns @work feature/foo` | `@work` -- identical to the line above | persistent `~/.csb/agents/@work` |
| `csb -E feature/foo` | none | throwaway (not persisted) |

`HOME` for the launched process is the namespace dir, and csb also points the
agent's own state-dir variable (claude: `CLAUDE_CONFIG_DIR`) at `<ns>/.claude`,
so the layout inside the launch HOME is the same whether it is a namespace or a
throwaway. Caches that normally live in `$HOME` (npm, bundler, ...) rebuild
there and persist. The whole `~/.csb/agents` tree is denied except the **active**
namespace.

> **Parallel sessions share one HOME.** Two `csb` sessions on different branches
> of the same repo now share the per-repo HOME (config, history, `.claude.json`)
> with no locking. This is exactly the situation you already get running native
> `claude` twice against one real `~/.claude`; the old per-branch default was
> *more* isolated than native. Want per-branch isolation back for a repo? Launch
> with an explicit name, e.g. `csb --ns "$(git branch --show-current)" <branch>`.

- **`-N`, `--ns NAME`** -- a named HOME shared across **all** repos launched with
  it (the classic use: one `--ns @work` for every work repo). `NAME` and `@NAME`
  are equivalent -- the `@` is optional and always added, which also keeps user
  names in their own space so none can collide with a `repo-<key>` default. It is
  deliberately **not** agent-suffixed: naming a namespace is already an explicit
  sharing decision, and `--ns work-codex` is how you keep two agents apart. `-d`
  never auto-removes it (retire it manually: `rm -rf ~/.csb/agents/@NAME`).
- **`-E`, `--ephemeral`** -- throwaway config/HOME under `$TMPDIR`, no namespace.
  Mutually exclusive with `--ns`. A bare `-E` mints a random throwaway dir, so
  there is nothing a second invocation can reattach to; once its session ends,
  the next launch (or `csb --reap`) deletes it -- it may hold a seeded
  credential, so it does not wait on the OS temp reaper.
- **`-E=NAME`, `--ephemeral=NAME`** -- a **named** ephemeral: the throwaway HOME
  is `$TMPDIR/csb-home-NAME` (deterministic) instead of random, so a sibling
  shell in another pane can attach to the exact same environment:

  ```sh
  csb -E=work --here          # the agent, in a reusable ephemeral HOME
  csb -s -E=work --here       # a shell in the identical env (other pane)
  ```

  It is still *ephemeral*, not a namespace: it lives in tmp (OS-reaped, gone on
  reboot/tmp-clean), leaves no `~/.csb/agents` entry, and is untracked by
  `--list-ns`. Both panes must resolve the same tmp base for the paths to
  coincide -- set `CSB_TMPDIR` for a fixed base, or keep `$TMPDIR` stable across
  your shells. (For a shareable env that *persists*, use a `--ns NAME` instead.)
  The name is a single path component: letters, digits, `. _ -`.

`csb -d <branch>` removes only the worktree; the branch is kept, and so is the
launch HOME -- the per-repo default is shared by every branch, and a `--ns`
namespace is shared across repos, so neither is tied to the branch being
deleted. Retire a namespace deliberately with `rm -rf ~/.csb/agents/<name>`.
Only worktrees csb created under `.worktrees/` are ever torn down/removed -- a
branch checked out in the main tree or a hand-made worktree is left alone.

`csb --list-ns` lists the namespace configs under `~/.csb/agents`: this repo's
and agent's default (`repo-<key>-<agent>`), any others from sibling repos or
agents, and the shared `@` ones. None are ever auto-removed. Dirs left over from
the pre-0.3 per-branch layout are flagged as legacy; remove them manually when
convenient.

### Migrating off the pre-agent layout

The launch HOMEs used to live at `~/.csb/claudes/repo-<key>`, from when claude
was the only agent csb could run. The first launch after this change migrates
them, in two lossless `mv`s within one filesystem:

- the **root**, `~/.csb/claudes` -> `~/.csb/agents`, whole, with every `@NAME`
  namespace riding along unchanged; and
- this repo's **dir**, `repo-<key>` -> `repo-<key>-claude`.

Both are one-shot and idempotent by construction -- the old path is gone
afterwards -- and the migrated HOME is byte-identical, only addressed
differently. A pre-agent dir is adopted only by claude, and only when its
`.csb-ns` stamp says `kind=repo`; anything else is left where it is and reported
by `--list-ns`.

`csb --reap` reclaims what sessions that no longer exist left behind: orphaned
`csb-proxy` processes (each is killed and its allowlist file removed) and random
`-E` HOMEs whose owning session is gone. Every launch runs the same pass
quietly, so leftovers live at most until the next launch; `--reap` is the
on-demand form and reports what it did. A live session is never touched: a
running proxy has a live parent, and a random HOME carries its owner's pid in
`.csb-owner` -- a dir without that stamp is only reported, never deleted.

## Config layers

Four layers answer every knob. Lowest first:

1. **the agent's own defaults**
2. **`${XDG_CONFIG_HOME:-~/.config}/csb/config`**, then the gitignored
   **`config.local`** beside it -- the sections matching this repository
3. **the profile** named by `-p NAME`, then its gitignored `NAME.local`
4. **the command line**

Layer 1 is the resolved [agent](#choosing-the-agent---agent)'s quiet knobs. For
claude that is `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`: the agent is pinned by nix, so an
auto-update could only target a read-only store path, and the non-essential
traffic is telemetry. Both are plain `setenv=` entries any layer above can
override. Note the ordering consequence: which knobs layer 1 supplies depends on
`agent=`, which the layers above it decide, so the agent axis is resolved first
and its setenv applied underneath everything else.

A scalar or boolean goes to the highest layer that sets it. Every list
(`keep=`, `setenv=`, `deny_read=`, `allow_write=`, `allow_socket=`,
`allow_host=`, `allow_port=`, `paranoid_deny_read=`, `paranoid_allow_read=`)
**unions across all four**, so a global `allow_port=5432` and a per-repo
`allow_port=6379` give the sandbox both.

The config files take the same `KEY=VALUE` grammar and the same keys as a
profile (listed below), plus [`use =`](#groups), grouped under `[SELECTOR]`
section headers:

```ini
# ~/.config/csb/config          (shared, commit it to your dotfiles)
[*]
paranoid = true

[*work*, !*work/legacy]
allow_host = api.internal.corp

[/Volumes/src/work/api]
nix_target = release

# ~/.config/csb/config.local    (gitignored, this machine only)
[*]
nix_target = ci                 # wins: the last matching section to set it
```

A selector is matched against the repository's **physical main checkout root**,
so a linked worktree selects its repository's sections rather than its own path.
A header is a **comma-separated list of terms**, and the section applies when
**some term matches and no exclusion does**. Within a term, `*` matches any
characters **including `/`**, and nothing else is special -- which is all three
shapes at once: `[*]` is every repo, `[*work*]` and `[*/csb]` are patterns, and
a term with no `*` is one exact path (`~/` expands, per term).

A term prefixed with `!` **excludes**: `[*, !*/scratch]` is every repo but that
one. This is the only way to withhold a broad section from one repo, since a
list value (`allow_host=`, `deny_read=`, ...) unions at every layer and has no
retraction anywhere. A header of exclusions alone is an error -- write the
positive term you mean, `[*, !...]` for all-but.

**Every matching section applies, in document order** -- `config` in full, then
`config.local`, top to bottom. The last one to set a scalar wins; lists union
regardless of order. Order is *not* by specificity, so a machine-local `[*]`
overrides a shared exact-path section rather than losing to it. A selector that
matches nothing is silent, so `--dump-config` reports the ones that did, each
header verbatim:

```
$ csb --here --dump-config | grep config_sections
config_sections=config[*]|config[*work*, !*work/legacy]|config.local[*]
```

### Groups

A selector can only collect repos that share a path shape. When the grouping you
want is a concept instead -- "needs postgres", "talks to the corp API" -- name a
bundle with a `[group NAME]` header and pull it in with `use = NAME`:

```ini
[group corp]
allow_host = api.internal.corp
allow_host = git.internal.corp
paranoid = true

[group pg]
allow_port = 5432

[*work*]
use = corp
use = pg

[/Volumes/src/oss/analytics]
use = pg
nix_target = release
```

A `[group NAME]` section **matches no repository** on its own; it does nothing
until a section uses it. `use = NAME` **splices the group's lines in at that
point**, so precedence is exactly what writing them inline would give -- a
scalar the group sets beats one set above the `use`, and loses to one set below
it. Lists union each time the group is used.

The group must be **defined above** the line that uses it (`config` is read
before `config.local`, so a group defined in the shared file is usable from the
machine-local one). Groups do not nest: `use =` inside a `[group]` is an error.
A group's lines are validated even if nothing uses them, and `use =` naming an
undefined group is fatal even in a section that did not match -- the same rule
as everywhere else here, so a typo cannot lie dormant until the day the repo it
belongs to is the one launching.

`use =` is a config-file key only; it is not a profile key. A used group appears
in `--dump-config` where it applied, labelled by the file that defined it:

```
$ csb --here --dump-config | grep config_sections
config_sections=config[*work*]|config[group corp]|config[group pg]
```

Keys on the same **axis** move together: a layer that names any of `ns=`,
`ephemeral=`, `real_home=` (which HOME) replaces all three below it, and the
same holds for the three `nix_target*` keys. On the command line that axis is
one flag's worth of surface too: three positive selectors plus `--per-repo`. Per-repo config lives here and not
in the repo itself, deliberately: the repo is writable inside the sandbox, so an
in-repo `.csb/config` would let a launch edit the policy of the next one.

## Profiles

Named variants for one repo -- a work token versus a personal one, a yolo
variant -- chosen per invocation. Everything keyed to the repo itself belongs in
the config layer above.

`${XDG_CONFIG_HOME:-~/.config}/csb/profiles/<name>` -- one file per profile,
`KEY=VALUE` lines (`#` comments allowed). Profile values are **defaults**:
explicit CLI flags beat them, including `-- ARGS` (which replace `args=`) and the
negating `--no-*` flags. Launch with `-p/--profile NAME`. Recognized keys
(anything else is an error):

```
agent=claude                              # as --agent: which agent CLI runs (default claude)
ns=@work                                  # as --ns
token_cmd=pass work/claude/token          # as --token-cmd; run host-side via bash -c;
                                          # stdout -> $token_env (never echoed)
token_env=OPENROUTER_API_KEY              # as --token-env; defaults to the agent's own variable
latest=true                               # as -L/--latest; beats CSB_LATEST, loses to explicit -L
verbose=true                              # as -v/--verbose; beats CSB_VERBOSE, loses to explicit -v
yolo=true                                 # as -y/--yolo (allow-all)
paranoid=true                             # as --paranoid (whitelist reads under HOME; see below)
pasteboard=true                           # as --pasteboard (macOS pbcopy/pbpaste)
sandbox=false                             # as --no-sandbox (shell only; drops the fs lockdown)
nix_target=release                        # as --nix-target: devShells.<system>.NAME
nix_target_shell=dev                      # as --nix-target-shell; beats nix_target for -s runs
nix_target_agent=ci                       # as --nix-target-agent; beats nix_target for agent runs
real_home=true                            # as --real-home; excludes ns=/ephemeral= (HOME axis)
here=true                                 # as --here; an explicit BRANCH wins (with a warning)
ephemeral=true                            # as -E; excludes ns= in the same profile
shell=true                                # as -s/--shell
seed_creds=true                           # as --seed-creds (skipped in -s shell mode, with a warning)
seed_home=~/.config/csb/home              # as --seed-home; template copied into the launch HOME
tmpdir=/fast/tmp                          # as --tmpdir; the launch TMPDIR, -E HOME base and a
                                          # write root. Must exist. Overrides CSB_TMPDIR.
accent=magenta                            # as --accent; statusline tint (csb --help lists the colors)
args=bash --rcfile ~/.config/my.bashrc    # the ARGS after --: command in -s mode, extra agent
                                          # args otherwise. Whitespace-split, no quoting; a leading
                                          # ~/ or ${HOME} expands to the HOST home.
keep=COLORTERM DIRENV_LOG_FORMAT          # space-separated, appended to --keep
setenv=CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 # as --setenv; repeatable; injected post-scrub
deny_read=~/notes                         # as --deny-read: extra read deny (both modes); repeatable
allow_write=~/scratch                     # as --allow-write: extra write root (both modes); repeatable
allow_socket=/tmp/.s.PGSQL.5432           # as --allow-socket: reachable unix socket (macOS); repeatable
filter_egress=true                        # as --filter-egress: HTTPS only via csb-proxy, allowlisted
allow_host=api.anthropic.com              # as --allow-host: allowed under filtering; repeatable
allow_port=5432                           # as --allow-port: allowed localhost TCP port; repeatable
allow_loopback=true                       # as --allow-loopback: every localhost TCP port, for a test
                                          # runner whose helper picks its own; widens what --allow-port
                                          # names one at a time
paranoid_deny_read=/Volumes               # as --paranoid-deny-read: extra deny under --paranoid; repeatable
paranoid_allow_read=~/ref                 # as --paranoid-allow-read: re-expose read-only under --paranoid;
                                          # repeatable; rejected if it overlaps a deny
```

Note: bare `csb -p NAME` (no BRANCH) **launches** in the current dir --
`--here` is implied, unless the CLI or the profile says otherwise; plain `csb`
always lists. A failing or empty-output `token_cmd` aborts the launch before
any worktree/namespace side effects. In `-s` shell mode `token_cmd=` is skipped
and `seed_creds=` is ignored with a warning (a shell runs no agent).

**Host-specific overlay.** A profile `NAME` can have a sibling, gitignored
`NAME.local` layered on top after it is read: same syntax, but its
scalar values win and its list values (`keep=`, `setenv=`, `deny_read=`,
`allow_write=`, `allow_socket=`, `paranoid_deny_read=`, `paranoid_allow_read=`)
accumulate.
Commit portable profiles
to a dotfiles repo; keep host-specific values (a `token_cmd=` path, a
`seed_home=`) in the uncommitted `.local`. Precedence: base -> `.local`
-> explicit CLI flags.

**An empty value retracts a key** for every layer below it, which is how a
profile declines a repo default rather than replacing it: given
`token_cmd=op read ...` in a `~/.config/csb/config` section, a profile with
`token_cmd=` authenticates some other way, while a profile that never mentions
the key leaves it standing. Booleans are retracted by `false`, not by an empty
value; lists have no retraction and only ever union.

```
# ~/.config/csb/profiles/work.local   (gitignored, per-host)
token_cmd=pass work/claude/token-on-this-box
seed_home=~/dotfiles/csb-home
```

For a shorthand, alias the profile: `alias csbw='csb -p work'`.

## Seeding the sandbox HOME

Inside the sandbox, the agent runs with a redirected `HOME` and its real state
dir denied -- so your **user-level** files (for claude: `~/.claude/CLAUDE.md`,
`settings.json`, `rules/`) are invisible. To carry them in, put copies in a
template dir; csb seeds them into the launch HOME on **every** launch (so fresh
namespaces get them on first use), **non-overwriting** (existing files, including
ones the agent wrote, are kept; `--reseed` forces overwrite).

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
protects. The template is copied **before** the agent's own seed instructions,
so a template-provided file the agent also seeds (claude's
`.claude/.claude.json`) is merged rather than clobbered.

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
`--keep`) the eventual agent/`-s` launch gets -- so it has no more host access
than the agent's own sandboxed shell already would. It needs no git-tracking or
commit -- gitignore it, or bring in a personal copy via `.worktreeinclude`, if
it's specific to your machine. `up` failures abort the launch; `down` failures
only warn (`--delete` still completes). Local (network-reachable) services like Postgres/Redis stay
reachable from inside the sandbox exactly as they do for the agent itself --
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
inside the devShell, identically for the agent and `-s`:

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
csb              ~/.csb/agents  (the active namespace is re-allowed)
                 ~/.csb/claudes  (the pre-agent root, until it is migrated)
agents' HOST     ~/.claude  ~/.claude.json{,.backup}  ~/.codex  ~/.gemini
state            ~/.copilot  ~/.config/github-copilot  ~/.qwen  ~/.cursor
                 ~/.local/share/opencode  ~/.aider  ~/.aider.conf.yml
                 ~/.config/goose  ~/.local/share/goose  ~/.config/amp
cloud / infra    ~/.config/{gh,gcloud,doctl,fly,rclone,op,configstore}
                 ~/.config/containers/auth.json
                 ~/.kube  ~/.docker  ~/.pulumi/credentials.json
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
  an agent unsandboxed (hard error) -- and with it `--paranoid` and the
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

### `--paranoid`: whitelist reads under HOME

The default read policy is a blacklist. `--paranoid` flips it to a whitelist
**within the real HOME**: HOME is read-denied wholesale, and only the write-allow
roots (worktree, git dir, namespace HOME, tmp) are re-allowed for reading.

It is not a filesystem-wide whitelist. Everything outside HOME stays readable in
both modes -- `/nix` and `/etc` so the devShell works, but equally `/usr`,
`/opt`, `/Library` and `/Applications`, so a system-wide toolchain such as a
homebrew prefix remains readable and executable by absolute path. Fence those
with `deny_read=` (applies in both modes) or `paranoid_deny_read=` (paranoid
only).

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
namespace beneath the denied `~/.csb/agents`. Reaching it means traversing the
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

All five read/write/socket lists are set per launch, via CLI flags or profile vars
(no machine-wide config file) -- add-only, absolute or leading-`~/` paths:

| List | CLI flag | Profile var | Modes |
|---|---|---|---|
| extra read deny | `--deny-read` | `deny_read=` | both |
| extra write root | `--allow-write` | `allow_write=` | both |
| reachable unix socket (macOS) | `--allow-socket` | `allow_socket=` | both |
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

## Filtering egress (`--filter-egress`)

**Off by default.** Turn it on and the sandbox's only route out is `csb-proxy`,
a CONNECT proxy csb starts *outside* the sandbox that dials allowlisted hosts on
port 443 and nothing else. An unlisted host, an IP literal, a plain-HTTP
request, any other port: refused, and logged.

```sh
csb -s --here --filter-egress --allow-host api.anthropic.com
csb mybranch --filter-egress             # hosts from the config layers
```

Hosts union from `--allow-host` (repeatable), a config section's or profile's
`allow_host=`, and the user-global allowlist file under
`${XDG_CONFIG_HOME:-~/.config}/csb/` -- one host per line, `#` comments. csb
reads `allowed-hosts.<agent>` when that file exists and the unsuffixed
`allowed-hosts` otherwise, so one shared list serves every agent until one needs
its own. Copy `templates/allowed-hosts.claude` for a starting set covering Claude
Code's own endpoints. A leading `*.` matches subdomains only, so list a bare
parent separately when you want it too. `--filter-egress` with an
empty allowlist is an error rather than a silent blackhole.

`--allow-port PORT` (profile `allow_port=`) re-opens one **localhost** TCP port,
so a dev server or database on the host stays reachable while everything else
stays filtered.

### `--allow-loopback`, when the port cannot be named

Some toolchains talk to a helper process over loopback on a port the *kernel*
picks: `flutter test` binds `127.0.0.1:0` and has `flutter_tester` connect back,
and a dart VM service or a browser driver does the same. There is no port to pass
to `--allow-port`, so under filtering the connect is refused on macOS and dropped
on Linux -- which is a hang, not an error.

`--allow-loopback` (profile `allow_loopback=`) allows **every** loopback TCP port
instead. It replaces the per-port rules rather than adding to them, so there is
one loopback answer per platform: `(remote ip "localhost:*")` in the seatbelt
profile, `oif "lo" accept` in the nft ruleset. Off-host egress is untouched --
still the proxy and the allowlist, nothing else.

What it costs differs, because one platform can separate the sandbox's loopback
from the host's and the other cannot:

- **Linux** -- nothing beyond the sandbox itself. The namespace's loopback is
  private: pasta carries only the proxy port and any `--allow-port` out to the
  host, so widening what the sandbox may dial reaches its own processes and no
  one else's.
- **macOS** -- every service listening on the host's loopback becomes reachable
  again. There is one loopback, shared, and seatbelt cannot tell the sandbox's
  own peer from the host's. That includes every other live csb session's
  `csb-proxy`: a loopback-widened sandbox can CONNECT through a sibling
  session's proxy, so its effective egress allowlist is the union of every
  concurrent session's. Prefer `--allow-port` here whenever the port is known.

### It is enforced, not advisory

A direct dial that ignores `HTTPS_PROXY` fails *even to an allowed host* --
`curl --noproxy '*' https://api.anthropic.com/` gets nothing. The sandbox has no
independent egress capability, so the allowlist is applied at the only endpoint
it can reach, and a proxy-unaware or hostile client is not a bypass. Verified
end-to-end on both platforms.

The mechanisms differ, the guarantee does not:

- **macOS** -- the seatbelt profile's blanket IP-egress allow is *replaced* by
  the proxy's loopback port plus any `--allow-port` (or, under
  `--allow-loopback`, by loopback at large), so no rule ordering can let a
  wildcard win.
- **Linux** -- bwrap has no socket filter, so the whole launch runs inside a
  network namespace created by `pasta`, with an nftables default-drop ruleset
  loaded before anything in the sandbox runs. The namespace gets no address and
  no default route, so off-host traffic has nowhere to go. Its loopback is
  private: pasta is told to carry exactly the proxy port and any `--allow-port`
  out to the host's loopback and nothing else, so a host service the operator
  did not name has no presence inside the namespace at all -- and the ruleset
  then narrows what the sandbox may dial a second time, independently. The
  privacy runs both ways: a server the sandbox itself listens on is not
  published to the host either, so under `--filter-egress` a dev server started
  inside is not reachable from a host browser.

The Linux namespace also closes the abstract-unix-socket gap (X11 keystroke
injection) as a side effect -- abstract sockets are namespace-scoped. See
[Known gaps](#known-gaps).

`.worktreesetup.sh` is covered too. It runs before the proxy exists, so it gets
a sandbox with the `--allow-port` ports and **no** general egress -- never the
host's open network, which would hand a file the agent can write exactly the
capability the flag was bought to remove.

### What it costs, and what it does not buy

WebFetch and everything else stops working for hosts you didn't list. That is
the feature, and it is why the flag is off by default.

The proxy does not decrypt, so it controls **who** the sandbox talks to, not
**what** is said. Allowing `github.com` allows gists; there is no per-path or
per-method filtering, no body inspection, and the refusal log records
`host:port` rather than method and path. Treat the allowlist as bounding the
*destinations* of an exfiltration, not preventing one.

Its decisions land in `$CSB_PROXY_LOG` inside the launch HOME, readable from
in-sandbox, so a denied fetch is self-diagnosable rather than an opaque
transport error:

```
[csb-proxy] ALLOW api.anthropic.com:443
[csb-proxy] DENY host not allowed: example.com
```

Two things to expect. Under `--no-sandbox` egress is **not** filtered -- the
sandbox profile is the enforcement -- and csb says so rather than pretending.
And on Linux a blocked port is *dropped*, not refused, so a connection to one
hangs until the client's own timeout; macOS refuses immediately.

The proxy lives only as long as its session: one whose session is gone is an
orphan, killed (with its allowlist file removed) by the next launch's janitor
pass or by `csb --reap`. This matters beyond tidiness -- an orphan still
listens on the host's loopback with its old allowlist, and on macOS
`--allow-loopback` would let a later sandbox reach it.

## Choosing the nix target

By default csb runs in the repo's `devShells.<system>.default`. Point it at a
different closure -- a leaner `ci`, a `release` shell -- with `--nix-target NAME`
(profile `nix_target=`), which resolves `devShells.<system>.NAME` from the
repo's own flake.

The two launch modes can differ: `--nix-target-shell NAME` and
`--nix-target-agent NAME` (profile `nix_target_shell=` / `nix_target_agent=`)
each apply to one mode only and beat the shared `--nix-target` when that mode is
the one running. `--no-nix-target` clears all three. Whichever target wins also
applies to `.worktreesetup.sh`, which runs in the same devShell.

A *named* target never falls back: if the repo's flake has no such attribute the
launch fails, because csb's generic fallback devShell only ever provides
`default` and silently substituting it would run the wrong closure.

```sh
csb --nix-target ci feature/foo            # both modes in devShells.<system>.ci
csb --nix-target-shell dev --nix-target-agent ci feature/foo
```

Each flag is repeatable; profile vars accumulate across `NAME` + `NAME.local`.
The host tmp/scratch dir is the `CSB_TMPDIR` env var (see [Quickstart](#quickstart)).

## Inspecting the config and sandbox (dry-run)

Two read-only flags resolve a launch and print what it *would* use, then exit
before any launch, HOME seeding, credential seeding, or `token_cmd`. Both are
safe to run anywhere and never print a secret, so they double as the seam the
test suite (`docs/PLAN-005-tests.md`) drives.

- `--dump-config` -- print the resolved knobs as stable `KEY=VALUE` lines (all
  four layers, after all precedence), plus the `config_sections=` this repo
  selected. It looks up the main checkout root to select those sections and
  stops there -- no worktree lookup -- so the default (per-repo) namespace shows
  as an empty `namespace=` plus `branch=`, and outside a repository it still
  runs, selecting nothing. `token_cmd` is reported `present`/`absent` (never
  run), and `setenv` lists VAR names only (never their values).

  ```
  $ csb -p work --paranoid --dump-config
  mode=launch
  here=true
  agent=claude
  paranoid=true
  namespace=@work
  token_cmd=present
  token_env=CLAUDE_CODE_OAUTH_TOKEN
  seed=json_merge:.claude/.claude.json
  agent_args=--model|opus
  ...
  ```

  The `agent*`, `token_env`, `seed` and `cred_seed` lines are the resolved
  [agent adapter](#choosing-the-agent---agent): what csb will build, which
  variable carries the credential, and what it will seed where.

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

  **Running either dump from INSIDE a sandbox under-reports.** Both build the
  policy against paths as the *current* process sees them, and the builder skips
  a path it cannot `stat`. So a dump run inside a sandbox emits no rule for
  exactly the paths that sandbox already denies -- `--deny-read /opt/homebrew`
  prints nothing once `/opt/homebrew` is denied -- and `$HOME`-relative entries
  resolve against the namespace HOME rather than the real one, so the floor and
  the namespace rules come out a different shape than on the host. The dumps stay
  the right tool for flag/precedence questions; when the question is whether a
  specific path is reachable, probe it directly (`ls -d PATH`) or run the dump on
  the host.

## Threat model

**Read this first.** csb assumes a **trusted operator running trusted
instructions**. It is built to (a) prevent *accidental* damage and *accidental*
exposure of the obvious credentials, and (b) keep separate work (namespaces,
other repos) from bleeding into each other. It is **weaker** against *untrusted
instructions* -- prompt injection from a fetched page, a malicious dependency, a
poisoned issue/PR -- because the two capabilities csb leaves open by default
(broad filesystem *reads* and open *network egress*) are exactly the exfiltration
primitive: anything the agent can read, injected instructions can read, and
anything readable can be shipped off-box.
[`--filter-egress`](#filtering-egress---filter-egress) closes the second half by
destination, which narrows the exfiltration surface without eliminating it. csb
does not defend against a hostile agent.

Named trade-offs, accepted deliberately (see `docs/PLAN-002.md`):

- **Open network egress, by default.** Unrestricted outbound unless you ask for
  otherwise. This is the price of the agent reaching local services for real
  testing. Neither seatbelt nor bwrap filters by hostname, so host-based control
  needs a proxy: csb ships one, opt in per launch or per profile with
  [`--filter-egress`](#filtering-egress---filter-egress). Left off, anything
  readable is exfiltratable.
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
  devShell and with the same env scrub the eventual agent/`-s` launch gets
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
  for an agent and confined to `-s/--shell` precisely because it drops the one
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
| `task_for_pid` / debugger attach to host processes | macOS | would be code injection into a process outside the sandbox | **denied as a class** -- never demonstrated reachable (the OS already gates it), so this is belt-and-braces, not a closed hole |
| `sysctl kern.procargs2` reads other processes' argv + environment | macOS | discloses secrets from your other shells and dev servers -- disclosure, not execution | **open, unfixable** with seatbelt |
| Linux abstract unix sockets (e.g. X11) | Linux | keystroke injection into your session | **open by default; closed under `--filter-egress`**, which puts the launch in its own network namespace -- abstract sockets are namespace-scoped, so they go as a class |

The macOS fixes work by flipping whole seatbelt filter *classes* to
deny-by-default rather than by blacklisting service names -- a name blacklist
was measured ineffective. Two classes are denied: `mach-lookup` (mach and XPC
named services) and `network-outbound` with IP egress re-allowed (which is how
unix sockets are governed, so it cuts every host socket at once, the nix daemon
included).

Consequences worth knowing before you upgrade, on macOS: the keychain, the
browser login flow, `git`'s `osxkeychain` credential helper, and
system-configured HTTP proxies all become unreachable in-sandbox. Authenticate
with `--seed-creds` or `CLAUDE_CODE_OAUTH_TOKEN`.

Unix sockets need stating precisely, because the class deny is blunt: a socket
anywhere **outside** the sandbox's own trees is unreachable by default, whether or
not the thing listening is yours. A postgres or redis on a socket in `/tmp`, a
tmux server, `ssh-agent`, `docker.sock` -- all unreachable. TCP to localhost is
unaffected, which covers most local services. Sockets **inside** the sandbox's
own trees (the worktree, the git dir, the launch HOME) do work, so a Rails
`tmp/sockets/puma.sock`, `spring`, or an in-tree `pg_ctl -k` behaves normally:
those trees are created and owned by the sandbox, so a socket there is one the
sandbox itself made. `/tmp` and the per-user temp dir are writable but *shared
with the host*, so they stay denied -- re-allowing them wholesale was measured to
make a host-side socket reachable again, which is the nix-daemon hole reopening
under a different name.

Name the exceptions with `--allow-socket PATH` (repeatable) or a profile's
`allow_socket=`. A directory allows the sockets under it; a path that does not
exist yet is treated as one, so a socket the test suite creates on boot is
covered. This is the flag for a dev setup built on unix sockets rather than TCP
-- `allow_socket=/tmp/.s.PGSQL.5432` makes an in-sandbox `psql` with no `host:`
work, and the same profile line is a no-op on Linux, where such sockets are
already reachable. Two things it will not do, both refused with an error rather
than silently ignored: it cannot name a whole shared write root (`/tmp`, the
per-user temp dir), only a socket or a subdirectory under one; and it cannot name
a path csb closes -- the nix daemon socket by either spelling, `/run/user/<uid>`,
`/run/dbus`. `--allow-write` is refused for those same broker paths, since on
Linux a write bind would otherwise be layered back over the tmpfs that removes
them. Widening this is a real decision: naming `docker.sock`, `ssh-agent`, or a
tmux socket hands back a broker that can act as you, outside the sandbox. On
Linux a socket under a tree `--paranoid` blanks (the real HOME, a
`paranoid_deny_read` root) stays unreachable and this flag does not change that.

One gap is open and cannot be closed here. macOS exposes every same-uid
process's argv *and environment* via `sysctl kern.procargs2`, so a sandboxed
agent can read secrets out of your other shells and dev servers. No seatbelt
rule stops it: the read goes through a numeric MIB with no string name, so
`sysctl-name-prefix` has nothing to match -- `kern.procargs`, `kern.proc`, and
even a blanket `(deny sysctl-read)` were all measured still leaking, while the
blanket forms break `sysctl` and `uname`. Treat anything in another process's
environment as visible to the sandbox.

"Closed" means that specific route is closed and has a test
(`make test-escape`). It does **not** mean the class of brokered escapes is
exhausted: two independent escapes were found in a single afternoon by someone
not looking hard, and only two of seatbelt's filter classes are deny-by-default.

On Linux there is no socket filter at all -- the only lever is removing sockets
from the mount namespace, which is per-path and cannot be made complete. Both
platforms therefore keep a residual, and closing it would take a second boundary
rather than more profile work.

### Hardening for untrusted instructions

If you intend to run instructions you don't fully trust, the two real moves, in
order of leverage:

1. **A second boundary** -- a separate unprivileged OS user, a container, or a
   lightweight VM with a controllable network (the last being the documented
   successor to the deprecated `sandbox-exec`). **None of this is implemented,
   scheduled, or promised** -- it is the direction that would be needed, sketched
   in `docs/PLAN-003.md` and `docs/TODO.md`, and it may never be built. Assume it
   will not be.
2. **Restrict egress** -- [`--filter-egress`](#filtering-egress---filter-egress)
   with an allowlist as short as the task tolerates. It is enforced rather than
   advisory on both platforms, so it bounds where anything read can be shipped;
   it does not bound *what* is sent to an allowed host, since the proxy does not
   decrypt.

## What a repo needs

Nothing. If the repo has no `flake.nix` (or one without a `devShells.default`
for your system), csb falls back to a generic devShell from its own flake so the
sandbox still runs, logging a note on launch. nix ignores untracked files, so a
brand-new `flake.nix` counts as absent until you `git add` it -- csb falls back
in that case too.

The fallback aims to be genuinely comfortable for both the agent and an
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

**`~/bin` on PATH.** For both the agent and the shell, if `$HOME/bin` exists (in
whichever HOME the launch uses -- real under `--real-home`, otherwise the
namespace/ephemeral HOME) it is **prepended** to `PATH`, so your own scripts
(e.g. deploy wrappers) take precedence -- ahead of the devShell toolchain. This
happens inside the launched process only; host-side `nix` runs first with the
real PATH, so the trust model is unaffected.

For a project-specific toolchain, expose a standard `flake.nix` with
`devShells.default` (the repo's full toolchain); csb prefers it over the
fallback. Scaffold a minimal standalone dev flake with:

```sh
nix flake init -t "$CSB_SELF"
```

(the same command `csb` prints when a repo has no `devShells.default`; `CSB_SELF`
defaults to the private remote -- see [Environment](#quickstart))

csb dogfoods itself: its own `flake.nix` exposes a `devShells.default` (git +
shellcheck), so `csb --here` runs the agent on the csb repo like any other.

## Files

```
bin/csb                    the orchestrator (worktree + deny-list + launch)
ocaml/                     csb-config (config resolution, --help, --dump-config)
                           and csb-proxy (the --filter-egress CONNECT proxy)
LICENSE                    MIT
flake.nix                  packages {csb, csb-tools, one per agent, bwrap/pasta/nft (linux)} + apps
templates/repo/            scaffold: a standalone dev-shell flake for a consuming repo
templates/home/            starter seed-home skeleton (copy to ~/.config/csb/home)
templates/allowed-hosts.*  starter per-agent egress allowlist (copy to ~/.config/csb/)
Makefile                   install, lint, test, and build targets (make help)
test/                      bats test suite (make test); see docs/PLAN-005-tests.md
docs/PLAN-002.md           the implemented design (single mode, deny-list, profiles)
docs/PLAN-003.md           roadmap: VM second boundary (not implemented)
docs/PLAN-004.md           the pre-release audit: findings, fixes, scope decisions
docs/PLAN-005-tests.md     the test-suite plan (dump seams + bats tiers)
docs/PLAN-007-escape.md    the sandbox-escape investigation and what it closed
docs/PLAN-009-proxy.md     egress filtering, and the OCaml config layer
docs/PLAN-010-agents.md    the agent axis, and the plan for agents beyond claude
docs/TODO.md               current state and next steps
```

See `docs/` for design rationale and history (`PLAN-000` ... `PLAN-005`).

## License

MIT -- see [LICENSE](LICENSE). Do what you like with it.
