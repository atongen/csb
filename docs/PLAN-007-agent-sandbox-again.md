# plan 007-again -- rebasing csb on agent-sandbox.nix (DISCOVERY)

Status: **discovery only.** No implementation, no decision. The deliverable is
feasibility, effort, and an itemized list of the concessions a rebase would
require.

Premise under test (2026-08-05): rewrite csb in place on top of
[agent-sandbox.nix](https://github.com/archie-judd/agent-sandbox.nix) instead of
maintaining our own seatbelt profile and bwrap argv -- now that upstream has
`allowedLocalPorts`, the thing whose absence got it removed in plan-002. Keep as
much of the csb surface (flags, profiles, worktrees, UX) as possible. Add
per-project allowed domains and per-project allowed local ports. Losing unix
domain sockets is acceptable. Other concessions are acceptable if named.

Everything below was verified against upstream `HEAD` on 2026-08-05 and against
`bin/csb` as committed at `fe30cf1`. Numbering note: this file shares the 007
prefix with `PLAN-007-escape.md` by request; renumber to 008 if that grates.

---

## 0. GATING FINDING -- the upstream license forbids this specific project

Not a footnote and not the same objection plan-001 waved through. The upstream
`LICENSE` is MIT plus:

> ADDITIONAL RESTRICTION: Notwithstanding any other provision of this license,
> the Software may not be accessed, used, copied, modified, merged, published,
> distributed, sublicensed, sold, or otherwise interacted with, in whole or in
> part, by any artificial intelligence (AI) system, machine learning model, or
> automated agent, including but not limited to accessing the Software for
> training, inference, code generation, data mining, or any other purpose. This
> prohibition applies to both direct and indirect use by AI systems. Only
> natural persons (humans) are granted the permissions above.
>
> Any violation of this restriction automatically terminates the permissions
> granted by this license.

    $ curl -sS https://raw.githubusercontent.com/archie-judd/agent-sandbox.nix/HEAD/LICENSE

Three places that bites, in increasing order of how hard it is to work around:

1. **The rebase itself.** csb is developed by claude, in csb. A rebase means an
   agent reading upstream source for "code generation" -- named in the clause.
   This has already happened: the analysis in this document was produced by an
   agent reading their `lib/`, `proxy/`, README, and LICENSE.
2. **csb's runtime use case.** csb exists to run an agent. Under the rebase the
   agent's own process is the thing exec'ing upstream's wrapper script inside
   upstream's profile -- an automated agent interacting with the Software, every
   launch, by design. This is not incidental; it is the product.
3. **Redistribution.** csb is MIT (`LICENSE`, "MIT License, Copyright (c) 2026
   Andrew Tongen"). A flake input does not vendor their code, but every csb user
   who launches an agent inherits reading 2. Publishing csb as a tool whose
   normal operation is an agent interacting with their Software is a
   redistribution question, not just a personal-use one.

plan-001 recorded this as "the upstream license carries a non-standard 'human
person' clause (worth a quick legal glance, not a blocker)". That assessment
predates both the agent-authored workflow and the runtime reading above. It
should be re-made, not inherited.

I am not a lawyer and this is not advice: the above is what the text says, and
whether the clause is enforceable, severable, or waivable is a call for you (a
natural person) to make. Concretely there are four routes:

- **Ask upstream** for a written exception or a clarification that sandboxing an
  agent, and agent-assisted contribution, are permitted. Open issues: 0, and the
  maintainer is responsive (see section 1) -- this is a cheap email.
- **Decide the clause does not bind this use** and proceed at your own risk, with
  the understanding that the agent-authored part of the work is the part most
  squarely inside the prohibition. If you take this route, say so explicitly in
  the plan, because I should not quietly assume it.
- **Take the mechanism, not the dependency** (section 9). The proxy-plus-
  deny-egress design is public knowledge, described in their README and now in
  our own docs; a clean-room csb implementation copies no code and touches no
  license.
- **Abandon** and keep the current architecture.

### DECIDED (2026-08-05): proceed, private use, no redistribution

Operator's call, recorded so it is not re-litigated: route 2 above. The clause is
accepted as a personal-use risk. csb stays on a private git server, is not
redistributed, and any licensing implications are deferred.

What that changes in practice:

- **`CSB_SELF` is already private, and already load-bearing.** The operator runs
  `CSB_SELF=git+ssh://git@git.grandrew.com/atongen/csb.git`; csb already fetches
  `#claude` (and `#bwrap` on Linux) through it every launch, so this is not
  something the rebase introduces -- the rebase only adds `mkCsbSandbox` as one
  more consumer of the same ref.
- **The in-repo default and the README's publication claims are now stale.**
  `bin/csb:29` and `Makefile:20` still default to `github:atongen/csb`, and
  `README.md:44-45,72` state csb is "Published at `github:atongen/csb`, which is
  `CSB_SELF`'s default, so `make install` and `nix run github:atongen/csb` work
  out of the box". Under section 0's decision that is no longer true. Separate,
  small cleanup: point the default at the private remote (or make an unset
  `CSB_SELF` a loud error) and drop the out-of-the-box claims. `docs/TODO.md:88`
  already tracks a related item.
- **The README's install instructions and the no-stability position** are scoped
  to a private tool. Anything in this plan that assumed public distribution
  should be read that way.

What it does not change: the finding stays in this document, because it is the
reason the decision had to be made, and because the calculus changes the day
redistribution is back on the table.

**Everything from here assumes that gate is cleared.** Section 9 remains a live
alternative on technical merit, not as a license fallback.

---

## 1. Reality check on the premise

The stated motivation is "a lot of eyeballs and users" instead of re-rolling our
own. Measured:

    $ curl -sS https://api.github.com/repos/archie-judd/agent-sandbox.nix
    stargazers 124   forks 15   watchers 2   open_issues 0
    created 2026-03-03   pushed 2026-08-02   license NOASSERTION
    $ curl -sS .../contributors
    6 total: archie-judd 262, github-actions[bot] 7, puffnfresh 2, +3 with 1 each

So: five months old, 124 stars, one maintainer with 262 of ~274 commits, and
`allowedLocalPorts` still absent from the CHANGELOG (last release 2.2.1,
2026-07-13) though present at HEAD since 2026-07-10.

That is more eyeballs than csb has (n=1) but it is not a widely-vetted
dependency. The honest framing is **not** "many eyeballs find the bugs" -- it is
**"we stop owning two kernel security policies."** That is still a real win, and
it is the strongest true version of the argument: the seatbelt profile and the
nftables/pasta plumbing are the parts of csb that are hardest to get right, most
expensive to verify (see the whole of `PLAN-007-escape.md`), and least
differentiated. Handing them to someone whose entire project is that policy is
defensible even at bus-factor 1. Just don't buy it as a robustness upgrade from
crowd review.

Positive signals worth recording: their profile independently reaches several
conclusions csb reached the hard way -- `kern.procargs2` denial, per-tty pty
pinning, refusing `/dev/tty`, `git` hooks/config write denial, excluding
`/System/Volumes` and `/private/var/folders`. Two implementations converging on
the same non-obvious rules is meaningful evidence both are thought through.

---

## 2. What we would be adopting -- the shape mismatch

| axis | csb today | agent-sandbox |
|---|---|---|
| macOS read posture | `(allow default)` + deny-list floor | `(deny default)` + explicit allows |
| exec posture | whatever the repo devShell puts on PATH | only the `allowedPackages` closure (store is readable, not exec-able) |
| HOME | redirected, persistent, writable; or real | always a fresh `mktemp -d /private/tmp/sandbox-home.XXXX`; binds symlinked in |
| env | `nix develop --ignore-environment` + `--keep` | `/usr/bin/env -i` with a baked PATH + declared `env` |
| egress | open (`remote ip "*:*"`) | open, or domain/method-filtered via a MITM proxy |
| host loopback | open (part of the `*:*` allow) | denied; per-port opt-in via `allowedLocalPorts` (TCP only) |
| host unix sockets | denied as a class, per-path opt-in (`--allow-socket`) | denied as a class, no opt-in, by deliberate design |
| Linux | bwrap, **no** netns (`--ro-bind / /`, no `--unshare-net`) | bwrap **inside a pasta netns** + nftables default-drop |
| when policy is decided | runtime, in bash, per launch | **nix eval / build time**, as function arguments |
| inspection seam | `--dump-sandbox` prints the exact artifact | a store `.sb`, then runtime-patched by the wrapper |

Rows 1-4 are an inversion, not a difference of degree. Rows 9-10 are where the
effort actually lives.

The single most important structural fact: **the sandbox is a wrapper derivation
around one binary, and every knob is a nix function argument.** The domain
allowlist is a `writeText` at eval time (`lib/shared.nix:34-48`); the `.sb`
profile is a `runCommand` output with per-store-path exec rules baked in
(`lib/darwin/default.nix:477`); only a handful of values (CWD, GIT_DIR, tty,
HOME, the proxy port) arrive at runtime via `sandbox-exec -D`. csb's entire
config model is the opposite: runtime flags and per-repo files resolved in bash.

---

## 3. The three load-bearing feasibility questions

### Q1 -- per-project domains and ports across the runtime/eval-time boundary

This is the feature you actually want, and it is the cheapest of the three.
`.csb/allowed-domains` and `.csb/allowed-ports` (plus `--allow-domain` /
`--allow-port` / profile keys) have to end up as nix arguments. Options:

- **(a) The repo flake exposes the sandbox package.** This is plan-001's original
  model, and the decoupling decision in plan-001's "DECIDED DIRECTION" section
  deliberately killed it: every consuming repo would again need csb-aware
  outputs, and a repo without them cannot be sandboxed. Regression. Reject.
- **(b) csb generates a nix expression per launch** and builds it:
  `nix build --impure --expr '...' --no-link --print-out-paths`, with
  agent-sandbox as an input of *csb's* flake. Repos stay standalone. csb keeps
  owning the config model, the files, the flags, the precedence, `--dump-config`.
  This is the same shape csb already uses for `#bwrap` and `#claude`, so it adds
  no new dependency class. **Recommended.**
- **(c) Fork upstream to read runtime config files.** Defeats the entire purpose
  of the exercise. Reject.

Under (b) the new csb code is a codegen layer: emit an attrset of
domains/ports/rwDirs/roDirs/env from the already-resolved config, then build.
Rough size: 100-150 lines, replacing `build_deny_wrapper`,
`build_socket_allows`, `build_ipc_brokers`, `refuse_ipc_brokers`, and the
profile/argv emitters -- so it is close to a wash on line count.

#### No flake is generated, and nothing needs to be git-tracked

The obvious objection to "generate nix at runtime" is that a flake inside a git
repo only sees *tracked* files, so a generated `flake.nix` would be invisible to
nix. That is a real rule, and it is why option (b) uses `--expr` rather than
writing a flake:

- **`nix build --impure --expr '<string>'` takes an expression on argv.** No
  flake, no `flake.nix`, no source tree copied to the store, nothing on disk,
  and no lock file written into anyone's repo. There is nothing for git to
  track or ignore.
- **What is generated is an argument attrset, not code.** The sandbox function
  itself lives in csb's own committed flake, fetched from `CSB_SELF` -- the same
  dependency shape csb already uses to resolve `#bwrap` and `#claude`:

      (builtins.getFlake "github:atongen/csb").lib.aarch64-darwin.mkCsbSandbox {
        binName           = "claude";
        allowedDomains    = { "api.anthropic.com" = "*"; };
        allowedLocalPorts = [ 5432 ];
        rwDirs            = [ "/Users/atongen/.csb/claudes/repo-<key>" ];
        env               = { CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN"; };
        allowedPackages   = [ /nix/store/... ];
      }

- **Where git tracking does still apply, and it is not new:** reading the
  *repo's* own `flake.nix` to harvest the devShell (Q2a). Any flake ref into a
  git repo resolves through the git tree, so an untracked `flake.nix` is
  invisible; tracked-but-modified is fine (nix warns "Git tree is dirty"). csb
  already inherits this today, because the current launch path is
  `nix develop "$worktree"` -- a flake ref into the repo. A repo whose
  `flake.nix` is not committed already does not work with csb. No new failure
  mode.
- **Escape hatch if a generated flake is ever wanted:** write it to a temp dir
  *outside* any git repo. A path flake in a non-git directory is copied to the
  store wholesale and tracking never enters into it.

Two build shapes, both worth pricing in the spike:

    # step 1 -- harvest, on the same code path as `nix develop` (same dirty/tracked
    # semantics, same error messages), so the generated expr stays repo-agnostic
    nix eval --json "$worktree#devShells.$system.$target" --apply '<extract buildInputs>'
    # step 2 -- build the wrapper
    nix build --impure --expr '<attrset above>' --no-link --print-out-paths

**Prefer a JSON handoff over emitting nix syntax.** csb's config values (domain
names, ports, absolute paths, env var names) come from files and flags, so
building a nix *expression* out of them in bash means owning nix quoting and
escaping -- a new injection surface in the security-relevant path. Instead have
csb write the resolved config as JSON and let the nix side parse it:

    nix build --impure --no-link --print-out-paths --expr \
      "(builtins.getFlake \"$CSB_SELF\").lib.$system.mkCsbSandboxFromJSON \
         (builtins.fromJSON (builtins.readFile \"$cfg_json\"))"

Only one interpolated value is then attacker-adjacent (a path csb itself chose),
the schema is checkable in nix with real error messages, and `--dump-config`'s
JSON form doubles as the snapshot artifact for tests (see section 5 and section
12).

`--impure` is required because the expr names absolute host paths and a mutable
flake ref. No posture change: csb already runs all nix host-side, unrestricted,
outside the sandbox.

Unverified, and worth proving rather than assuming: `writeClosure` needs the
harvested store paths *realised*, and step 1 only evaluates. `nix develop`
realises them today as a side effect, so either the build step stays or step 2's
derivation must pull them in.

Unmeasured, and it gates the UX: **eval+build latency for a distinct config.**
Every different domain set is a new derivation. They are all `writeText` /
`runCommand` (no compilation), so it should be seconds, but nothing here is
guessed for you:

    # measure cold and warm, with agent-sandbox in a local flake
    time nix build --impure --expr '<generated>' --no-link --print-out-paths

If a first-launch-per-config penalty lands above ~5s, that is a UX problem for a
tool whose current launch is already nix-bound.

### Q2 -- the devShell problem. THE risk item.

agent-sandbox bakes PATH from `allowedPackages` and permits `process-exec` only
for that closure. The store is readable but not executable
(`lib/darwin/seatbelt-profile.nix:167` allows `file-read*` on `/nix/store`; exec
rules are per-path). **So `nix develop <repo> --command <wrapper>` does not
work**: the repo's compilers and interpreters are visible and unrunnable. That
is csb's whole M2 capability story, and it is the current default.

Options, worst-to-best on isolation:

- **(c) `allowNix = true`.** Their own comment: "The `process-exec` grant covers
  the whole store." Cheapest possible fix, and it reopens F3 -- the nix daemon
  socket, which `PLAN-007-escape.md` closed *unconditionally on both platforms*
  because it is arbitrary host code execution as the operator. Their README says
  so too ("weakens the security posture ... `allowedPackages` no longer
  restricts what the agent can execute"). If used at all it must be an opt-in
  flag, default off, and it is a straight regression against a decision we
  already made with measurements.
- **(d) Accept M1.** Sandbox gets `commonTools` only; capability lives in
  `--no-sandbox`. Zero effort, and it walks back the M1->M2 progress the current
  tool represents.
- **(a) Harvest the repo devShell's inputs into `allowedPackages`** --
  `buildInputs ++ nativeBuildInputs ++ propagatedBuildInputs` off
  `devShells.<system>.<nix-target>` of the repo's own flake. Repos stay
  decoupled (no csb-specific outputs; we read what a standalone flake already
  has), `--nix-target*` survives as "which shell do we harvest", and exec stays
  closure-scoped. **Best fit.** Unverified: whether real devShells expose their
  inputs cleanly enough to harvest generically (`mkShell` does; `mkShellNoCC`,
  `inputsFrom`, and flake-parts shells need checking).
- **(b) (a) plus harvesting the devShell env** via `nix print-dev-env --json`,
  feeding vars into `env`. Needed because plan-001 already recorded that drip's
  native gems depend on shellHook-exported `DYLD_FALLBACK_LIBRARY_PATH` /
  `BUNDLE_PATH`, which `env -i` throws away. Two new problems: secret hygiene
  (`print-dev-env` dumps everything the hook exports, and `env` values are
  shell-expanded at launch), and the shellHook runs host-side to produce them --
  which is the same host-side-trust hole we already accept, so no worse.

Recommendation: build (a), measure per-repo whether (b) is required, treat (c)
as a documented flag only if a real repo forces it. **This is the item most
likely to blow any estimate.** It should be the Phase 0 spike, before anything
else is touched.

### Q3 -- HOME

`REAL_HOME="$HOME"; SANDBOX_HOME=$(mktemp -d /private/tmp/sandbox-home.XXXXXX)`
is unconditional (`lib/darwin/default.nix:532-533`). Consequences, all four
verified from source:

- **`-E/--ephemeral` becomes native and free.** Win.
- **The per-repo persistent HOME re-expresses** as `rwDirs = [ ns_dir ]` plus
  `env.CLAUDE_CONFIG_DIR = "<ns_dir>/.claude"`. This is upstream's own claude
  template pattern (`templates/claude/flake.nix:31,43`), and the symlink mapping
  makes `$HOME/.claude` resolve through. Works -- but HOME itself stops being
  persistent, so `~/.cache` and any other HOME-rooted tool cache no longer
  survives a run. Concession.
- **`--real-home` is not expressible.** No argument suppresses the redirect. It
  is a fork or a drop. Per `--help` this is the flag you pair with
  `--no-sandbox` for deployment shells -- and that combination still works,
  since `--no-sandbox` never enters the wrapper. So the loss is narrower than it
  first looks: `--real-home` survives for `--no-sandbox`, dies for sandboxed
  runs (where it is already the odd one out).
- **`-E=NAME`** (deterministic throwaway HOME so a sibling `-s -E=NAME` pane
  attaches to the same env) is not expressible -- HOME is always a fresh
  mktemp. Concession, and it is a workflow you use.

---

## 4. Flag-by-flag disposition

Unchanged, csb-side, the wrapper never sees them (~20 knobs): `BRANCH`,
`--here`, `-n/--no-launch`, `-d/--delete`, `--list-ns`, bare list, `-y/--yolo`,
`-p/--profile` + `.local` layering + every `--no-*` negation, `--dump-config`,
`-v/--verbose`, `-L/--latest`, `--accent`, `--seed-home`, `--reseed`,
`--seed-creds`, `-h`, `-V`, `.worktreeinclude`, `.worktreesetup.sh`.

| knob | disposition |
|---|---|
| `-k/--keep VAR`, profile `setenv=` | re-expressed as `env = { VAR = "$VAR"; }`; moves from runtime to the generated expr. `env -i` is already upstream's default so the scrub is belt-and-braces |
| `-s/--shell` | two wrappers (`binName = "bash"` / `"claude"`), or one bash wrapper. Upstream ships `debug/bash.shell.nix`. Fine |
| `--no-sandbox` | unaffected -- csb keeps its own unsandboxed path |
| `--allow-write PATH` | maps to `rwDirs`/`rwFiles` (csb already classifies dir vs file) |
| `--paranoid-allow-read PATH` | maps to `roDirs`/`roFiles` |
| `--nix-target*` | survives, re-purposed: which devShell to harvest (Q2a) |
| `--paranoid` | becomes the ONLY mode -- deny-default is what `--paranoid` approximates. Flag becomes a no-op or is removed |
| `--deny-read`, `--paranoid-deny-read` | **LOST, no target.** Nothing is readable to deny |
| `--allow-socket` | **LOST.** Upstream refuses unix-socket egress in both modes, deliberately ("The proxy speaks TCP, so nothing legitimate needs UNIX-socket egress"). Accepted by you. Takes the D9 broker-refusal logic and its tests with it |
| `--pasteboard` | **LOST** unless upstreamed -- the `mach-lookup` allowlist is hardcoded with no argument |
| `--real-home` | **LOST for sandboxed runs**, survives under `--no-sandbox` (Q3) |
| `-E=NAME` | **LOST** (Q3) |
| `--dump-sandbox` | **DEGRADED.** Redefined as "the store `.sb` plus the runtime patch lines", because the wrapper appends to a temp copy at launch (ancestor traversal, proxy port). No longer the exact artifact |
| NEW `--allow-domain` / `.csb/allowed-domains` | the point of the exercise |
| NEW `--allow-port` / `.csb/allowed-ports` | ditto; TCP only |

Tally: of ~33 user-visible knobs, ~25 survive untouched, 3 change meaning, 5 are
lost, 1 is degraded, 2 are added. Four flags collapse into one concept
(`--paranoid` family), which is a genuine simplification: the standing
"deny-list completeness" risk that plan-002 booked as its top residual is
deleted by construction, not managed.

---

## 5. Test suite leverage

    $ for f in test/*.bats test/escape/*.bats; do echo "$(grep -c '^@test' $f) $f"; done
    10 lists   36 precedence   30 validation   13 snapshots   8 escape   4 usable

- **lists / precedence / validation (76 tests): mostly portable.** They drive
  `--dump-config` and assert csb's own resolution -- profiles, `.local`
  layering, precedence, negations, list accumulation. That layer survives the
  rebase intact. The subset naming lost flags (`allow_socket`, `paranoid_*`,
  `real_home`) dies with them; new cases arrive for `allow_domain=` /
  `allow_port=`. Estimate 55-65 of 76 kept as-is.
- **snapshots (13 tests + 17 goldens): mostly dead.** The artifact changes shape
  and now embeds store hashes. This is the real test loss, and it is the seam
  `CLAUDE.md` tells us to prefer for in-session verification. A weaker
  replacement (assert the generated *expression*, which is deterministic and
  hash-free, instead of the profile) is probably the right substitute and is
  arguably a better seam for the new architecture -- it snapshots our decisions,
  not upstream's implementation.
- **escape / usable (12 tests): portable, and expected to improve.** They are
  black-box reachability assertions. Predicted outcomes, each needing a real run,
  not a guess:
  - F1 `open`/LaunchServices, F2 `pbpaste`: blocked -- `(deny default)` covers
    `mach-lookup` and only 7 `global-name`s are allowed.
  - F3 nix daemon: blocked while `allowNix = false`; **reopens if Q2c is taken.**
    That is the coupling to watch.
  - F4 Linux session dbus, and the abstract-socket residual (X11 keystroke
    injection) that `PLAN-007-escape.md` Part 10 declared "unchanged and
    unfixable here": **expected closed**, because upstream runs bwrap inside a
    pasta netns in *both* open and filtered modes, and abstract sockets are
    netns-scoped. If it measures out, the rebase fixes the one residual we wrote
    off as impossible.
- **test/manual probes: obsolete.** They measure csb's own filter classes.

---

## 6. What the rebase buys

1. Per-domain, per-method egress filtering on both platforms -- the thing that
   started this.
2. Host loopback closed by default with per-port opt-in, on both platforms. csb
   currently has no loopback control at all (it is inside `remote ip "*:*"`).
3. Read posture flips from deny-list to allowlist. plan-002's top residual gone.
4. Linux gets a network namespace, which is the only thing that closes the
   abstract-socket residual (section 5).
5. We stop maintaining a seatbelt profile and an nftables/pasta plumbing layer.
6. Platform parity becomes upstream's problem. `PLAN-007-escape.md` Parts 5-9
   are 500 lines about the "sync tax" of keeping two policies honest.

## 7. What it costs

1. The license gate (section 0). Unpriced and possibly fatal.
2. Q2: either M2 capability regresses, or we build the devShell harvest, or we
   reopen F3.
3. 5 flags lost, 3 changed, `--dump-sandbox` degraded, `-E=NAME` and
   `--real-home` workflows affected.
4. The snapshot suite and every manual probe rewritten.
5. The MITM proxy's own breakage: `gh` and Go tools fail TLS on macOS (upstream
   documents it), no WebSockets, DNS dead in-sandbox so ssh/remote-Postgres/
   `git@github.com:` are gone whenever domains are filtered. Note `--seed-creds`
   and token auth still work (HTTPS to Anthropic), but check whether claude's
   own transport tolerates the MITM CA -- it is a Node client, and
   `NODE_EXTRA_CA_CERTS` is set for exactly this reason.
6. A hard dependency on a five-month-old single-maintainer project for the
   security boundary, with our own `--dump-*` seams no longer showing the whole
   truth.
7. Upstream's release cadence becomes ours: `allowedLocalPorts` is unreleased at
   HEAD, so we would be pinning a rev, not a release.

## 8. Effort, honestly

Phased, in sessions rather than false precision:

- **Phase 0 -- spike, and it decides everything.** `csb --here` on this repo,
  generated expr, devShell harvest, no worktree, no profiles. Answers Q1 latency
  and Q2 feasibility. **1-2 sessions. Do not skip; do not proceed without it.**
- **Phase 1 -- core rebase.** Launch path, codegen layer, flag mapping,
  removals. 3-5 sessions.
- **Phase 2 -- tests and docs.** Port Tier 1, redefine the snapshot seam, rerun
  the escape suite on both platforms, rewrite the README threat model (which is
  substantially about a deny-list that no longer exists). 2-3 sessions.
- **Phase 3 -- Linux.** Verify the netns path, measure F4 and the abstract-socket
  residual. 1-2 sessions.

Call it 7-12 sessions with Q2 as the variance, plus a full README rewrite. This
is a rewrite, not a refactor: the launch path, the sandbox layer, the threat
model, and a third of the test suite all move. On whether to change
implementation language while doing it, see section 12.

## 9. The narrow alternative, for comparison

Worth pricing because it is genuinely cheap and it sidesteps section 0 entirely.
csb's macOS profile already emits the deny-default network class:

    $ ./bin/csb --here --dump-sandbox | grep -n network
    7:(deny network-outbound)
    8:(allow network-outbound (remote ip "*:*"))

Line 8 is the open internet. Replacing it with a proxy-port pin, adding
`--allow-port` for loopback, and running a **non-MITM CONNECT/SNI proxy** gets
domain filtering on macOS with: no license exposure (the design is public
knowledge and described in our own docs; no code is copied), no flags lost, no
tests lost, `--dump-sandbox` intact, and none of the `gh`/Go TLS breakage
upstream documents -- filtering the CONNECT hostname is sound for destination
control because the proxy dials the name it just checked. You give up HTTP-method
filtering and plaintext inspection, which we never asked for.

The catch is Linux: bwrap has no socket filter, so there is no cheap version --
it needs `--unshare-net` plus a userspace network, which `PLAN-007-escape.md`
Part 9 explicitly closed as "requires a new mechanism, do not reopen without a
new document." So this option is macOS-first and knowingly asymmetric, which is
exactly the drift Part 9 was written to stop.

**The trade in one line:** the rebase buys egress filtering, an allowlist read
posture, a Linux netns, and less code we own, at the price of a license question,
the M2 capability risk, and five flags. The narrow option buys egress filtering
on one platform only, at almost no price. Which is right depends entirely on
whether you want out of the business of owning kernel policy -- that, not the
domain filtering, is the actual decision.

## 10. Open questions, each with the command that answers it

1. **License.** Ask upstream. No command; it is an email or an issue.
2. **Q1 latency.** `time nix build --impure --expr '<generated>' --no-link
   --print-out-paths`, cold and warm, two distinct domain sets.
3. **Q2 harvest.** Does `devShells.<sys>.default` expose `buildInputs` cleanly
   for `mkShell`, `mkShellNoCC`, `inputsFrom`, and flake-parts shells?
   `nix eval --json '<repo>#devShells.<sys>.default.buildInputs' --apply 'map (p: p.outPath)'`
4. **Q2 env.** Does drip's suite run with harvested packages but no shellHook
   env? Run rubocop and a non-DB unit test in the wrapper.
5. **Claude through the MITM proxy.** Does an interactive claude session
   round-trip with `allowedDomains` set on macOS? Their README flags `gh`
   failing; claude is also a Node client.
6. **F4 / abstract sockets on Linux.** Run `test/escape/escape.bats` against a
   wrapper build on NixOS. This is the one that could turn an accepted permanent
   residual into a fixed bug.
7. **`--dump-sandbox` replacement.** Is snapshotting the generated expression an
   acceptable substitute for snapshotting the profile?

## 11. Recommendation

1. Resolve section 0 first. It is the only item that can make the other ten
   moot, and it costs one email.
2. If cleared, run **Phase 0 and nothing else**, then re-read this document.
   Q2's answer moves the recommendation more than anything else in here.
3. If not cleared, section 9 is the live path, and it is worth doing on its own
   merits regardless -- it is small, it is reversible, and it delivers the
   feature that prompted all of this.
4. **Language: OCaml, and it goes first, not last.** The port and the rebase do
   not overlap, so the config layer can be ported now against the strongest test
   oracle csb will ever have. Section 13 supersedes section 12's sequencing.

---

## 12. Implementation language -- should the rewrite leave bash?

Two separable questions: does bash cost us anything today, and does the rebase
change the answer.

### The rebase shrinks the part of csb where bash is worst

The gnarliest string-building in `bin/csb` -- seatbelt profile emission, bwrap
argv assembly, `build_socket_allows`, `build_ipc_brokers`, `refuse_ipc_brokers`,
dir-vs-file classification for every list -- **moves into nix**. That is also
the highest-knowledge-density code in the repo (four rounds of "which spelling
does the kernel see?" in `PLAN-007-escape.md` Part 11 alone). So the rebase
deletes bash's worst job rather than making it bigger. What remains in the
orchestrator is arg parsing, config precedence, git plumbing, nix invocation,
and exec -- work bash does adequately.

### Where a typed language would genuinely pay

1. **Config resolution is 76 of 89 tests** (lists 10, precedence 36, validation
   30). That ratio *is* the argument: the suite is that large because bash
   cannot represent "unset vs set-to-empty vs explicitly negated," so every
   `--no-*` flag, every profile/`.local` layer, and every accumulating list is a
   hand-rolled tri-state. A record of optionals plus one merge function replaces
   most of it, and it is exactly the CLAUDE.md rule about making invalid states
   unrepresentable.
2. **Mutually exclusive flag groups.** `--help` literally documents `-N`/`-E`/
   `--real-home` as "three MUTUALLY-EXCLUSIVE answers to one question", plus
   `--here` vs `BRANCH`. A sum type makes the bad combination unconstructible
   instead of caught by pairwise runtime checks. plan-002 phase 4 having to
   "re-check every pairwise interaction warning in the arg parser ... delete dead
   ones" is the symptom.
3. **Path canonicalization.** `canon_path` exists only because GNU
   `realpath -m` is not portable (`PLAN-007-escape.md` Part 11). Stdlib
   everywhere else; most of the GNU/BSD tax in CLAUDE.md's cross-platform rule
   evaporates.
4. **JSON.** `nix eval --json` parsing and the Q1 handoff. Today `jq` is
   optional-and-warned-about in `seed_claude_config`. Stdlib elsewhere.
5. **Style.** CLAUDE.md asks for pure functions, immutability, and composition.
   Bash is maximally hostile to all three. This is the honest strongest argument,
   and it is not a technical one.

### The enabling fact: the test suite is language-agnostic

`test/helpers.bash:4-5` -- "Every test runs the real bin/csb as a subprocess
against an ISOLATED HOME and XDG_CONFIG_HOME, via `--dump-config` (or
`--dump-sandbox` ...)". All 89 Tier-1 tests are black-box over the CLI; the
escape suite asserts path reachability. **Nothing tests bash internals.** So a
port keeps its full safety net as long as the CLI contract holds, which means a
language change can be *verified* rather than trusted. That makes the port much
less frightening than "2211 lines" implies.

### What we would lose

1. **Prior art -- but less than the line count suggests**, because the
   knowledge-dense emitters are deleted by the rebase either way. What ports is
   mostly mechanical.
2. **The install story.** `make install` copies one file into `~/bin`: no build,
   no deps, works when the flake does not. A compiled language means
   `nix build` / `nix profile install`. Counterweight: csb already requires nix
   at *runtime*, so this is a new build step, not a new dependency class.
3. **In-place debuggability.** Editing `~/bin/csb` mid-session, or handing
   someone one readable file. Real value for a single-maintainer tool.
4. **Risk concentration.** A language rewrite plus a containment-base rewrite at
   once means a regression is not bisectable to either. This is the decisive
   scheduling argument, independent of which language wins.

### Candidates

- **Go -- the recommendation if we move.** Single static binary,
  `buildGoModule` in the flake we already have, cross-compiles darwin/linux,
  stdlib `os/exec` + `encoding/json` + `path/filepath`, no runtime deps. Expect
  ~1.5-2x the line count. Weakness: no real sum types, so the
  unrepresentable-states win is partial.
- **Rust** -- fully delivers the type goal (real enums/`Option`), at the price of
  compile times and heavier nix packaging, for a program that mostly shells out.
  Justified only if item 5 above is the actual point rather than a preference.
- **Haskell** -- the best type-system fit for the *specific* problem csb has, and
  the worst fit for the rest of the program. Worth stating precisely because the
  split is unusually clean:
  - **The config layer is literally a monoid.** Layering
    defaults < env < profile < `profile.local` < CLI is `mconcat` over a record
    of `Last a` fields; `deriving (Generic, Semigroup, Monoid)` writes the merge
    that plan-002 phase 4 hand-audited and that 36 precedence tests pin down.
    Higher-kinded data (`Config Maybe` -> validate -> `Config Identity`) makes
    "a partially specified config" a type rather than a convention. No other
    candidate gets this for free -- Rust gives `Option` but not the monoid, Go
    gives neither.
  - **The flag groups are ADTs.** `data HomeChoice = PerRepo | Shared NsName |
    Ephemeral EphKind | RealHome` plus `-Wincomplete-patterns` delivers the
    CLAUDE.md unrepresentable-states rule outright, same as Rust.
  - `optparse-applicative` is the best CLI parser in any of these languages for
    this shape. Caveat: csb's `--help` is hand-written prose with a deliberate
    layout (the HOME-choice explainer), and it would fight that -- the help text
    is documentation here, not generated output.
  - **But ~2/3 of csb is IO orchestration** -- shell out to git, nix,
    sandbox-exec, exec the wrapper. That is all `IO`, so the purity win is
    confined to exactly the 1/3 already identified as the win, while
    `String`/`Text`/`ByteString` and exception-vs-`ExceptT` friction is spread
    over all of it.
  - **Build and install are the real blocker.** Multi-GB GHC closure, builds in
    minutes not seconds, and static linking on darwin is not a supported thing --
    the binary stays dynamically linked against `/nix/store`, so it is not
    relocatable the way `make install`'s one-file copy is. Cross-building the
    other platform is far worse than `GOOS=darwin go build`.
  - **One consideration specific to this repo:** csb is developed *by* claude
    (`CLAUDE.md`). Models write reliable bash and Go; Haskell leaning on
    `generic-lens`, higher-kinded data, and `DerivingVia` is where that
    assistance gets least reliable. For a single-maintainer tool that is a real
    input, not a stylistic one.
- **Nix as the config language** (the tempting astronaut move, since the Q1 JSON
  handoff already puts the schema in nix): precedence layering is pure and `//`
  is exactly attrset override, so `defaults // env // profile // local // cli`
  would express it in a language already required. **Reject**, for one decisive
  practical reason: it makes `--dump-config` require a nix eval. That seam is
  currently nix-free, instant, and drives all 89 tests -- 89 nix evals is a
  suite nobody runs. Also no sum types and poor error messages, so the type win
  is illusory.

**The astronaut trap, named so it can be avoided.** csb's job is to parse config
and exec subprocesses. Any of these languages tempts a beautiful effect-system
DSL for "run a subprocess", which buys nothing and violates the CLAUDE.md rule
about unexpected complexity and scope creep. The type-system win here is real but
*local*: it lives in config resolution and flag validity, nowhere else.
- **Python** -- no build step, but a runtime dependency (macOS
  `/usr/bin/python3` needs the CLT and drifts) and no type leverage without
  effort. Worst of both. Reject.
- **TypeScript/Deno** -- a single shebang file is attractive; a whole JS runtime
  for a program whose job is `exec` is not.
- **More nix** -- the *policy* already moves there, correctly. Do not push
  imperative git/worktree/exec logic into nix; that direction is a trap.

### Verdict -- SUPERSEDED by section 13

The reasoning above stands; the *sequencing* conclusion it originally carried
("rebase in bash first, decide language later on a trigger") was wrong, and
section 13 replaces it. The error: it assumed the two rewrites would collide.
Measurement says they do not overlap at all. One point from it survives intact
and still governs -- **bash emitting JSON is fine; bash emitting nix syntax is
not** (Q1) -- and one still governs the *pairing*: do not do both rewrites
simultaneously.

---

## 13. DECIDED (2026-08-05): OCaml first, and the first step

Language chosen: **OCaml.** Rationale is section 12's candidate entry plus the
build/install profile -- ADTs with exhaustiveness checking, native compile in
seconds, small stdlib, `cmdliner` for the CLI, and `opam`/`dune` as prior art for
exactly this shape of program (parse layered config, orchestrate subprocesses).

### The sequencing correction

`bin/csb` splits almost exactly into thirds along its own section comments:

    $ grep -n '^# --- ' bin/csb
    630-1315   deny-list / write policy      686 lines (31%)  <- the REBASE deletes
    usage 177 + profiles 223 + argparse 317 = 717 (32%)       <- the OCaml win
    latest 28 + git/worktree 375 + modes 356 = 759 (34%)      <- survives both

The two projects **do not overlap**. The 686 lines the rebase deletes
(`build_deny_wrapper` 319, `build_deny_paths` 131, `build_write_roots` 62,
`build_socket_allows` 42, `refuse_ipc_brokers` 27, `emit_ancestor_metadata` 21,
`build_ipc_brokers` 20) are policy emission that moves into nix. The 717 lines
OCaml wins are config resolution, which the rebase never touches. So section 12's
"one rewrite at a time, rebase first" was avoiding a collision that does not
exist, and had the order backwards on two counts:

1. **The license question blocked the rebase and never touched the port.** They
   are independent projects. (Now moot per section 0, but the independence is
   the durable point.)
2. **The test oracle is strongest now.** Porting against today's known-good
   behavior means a fixed spec with 89 black-box tests as judge. Porting after
   the rebase means porting against a target that just lost 5 flags, had its
   snapshots regenerated, and had its threat model rewritten.

### The first step: `csb-config`

A standalone OCaml binary implementing **exactly `--dump-config`, nothing else.**
Not a port of csb -- one pure function: `(argv, profile files, env) -> KEY=VALUE`.
No git, no nix, no exec, no writes. `bin/csb:1799-1844` is the whole contract:
**34 keys** in fixed order, booleans as `true`/`false`, lists joined with `|`,
`token_cmd` as `present`/`absent`, `setenv` as VAR names only. `helpers.bash`
confirms `--dump-config` "exits before repo lookup", so it does not even need a
repo.

Started 2026-08-05. `ocaml/` holds `dune-project`, `lib/types.ml` (the ADTs),
`lib/dump.ml` (the wire format), `bin/csb_config_cli.ml`; `make ocaml-build` /
`make ocaml-test` drive it.

**Milestone 1 VERIFIED (2026-08-05).** Compiles, and its output is byte-identical
to bash for the no-args case:

    $ make ocaml-build && diff -u <(./bin/csb --dump-config) \
        <(./ocaml/_build/default/bin/csb_config_cli.exe) && echo IDENTICAL
    IDENTICAL   # 34 lines

Toolchain as resolved in the devShell: **ocaml 5.4.1, dune 3.21.1, cmdliner
2.1.1, yojson 3.0.0.** Note cmdliner is **2.x** -- most examples in circulation
target 1.x, whose `Term.eval` API is gone; target the `Cmd` API.

**One environment finding, fixed.** `OCAMLPATH` arrives unset in a csb-launched
devShell, so `dune` could not resolve `cmdliner` ("Library "cmdliner" not
found") even though both packages were in the shell. The flake now sets
`OCAMLPATH` explicitly via `lib.makeSearchPath`; verified by exporting the same
value by hand and linking a scratch executable against both libraries. Follow-up:
when `csb-config` grows a `buildDunePackage` output for the install story, switch
the devShell to `inputsFrom` that package and drop the explicit `OCAMLPATH`.

Two things the type modeling surfaced immediately, both worth recording because
they are exactly the payoff being tested:

- **"Neither BRANCH nor --here" is a real third state** -- the worktree listing.
  bash represents it as two coincidentally-empty variables, so it is invisible in
  the source; as a variant (`List_worktrees | Here | Branch of string`) it has to
  be named and handled.
- **`--ns NAME` stores its value verbatim.** The `@` normalization happens later,
  in `setup_namespace`, not at parse time -- so the dump prints the raw string.
  Transcribed from the parser rather than inferred from `--help`, which describes
  the normalized form and would have produced a wrong type.

Acceptance criterion, pre-existing and precise:

    $ for f in test/lists.bats test/precedence.bats test/validation.bats; do ...
    test/lists.bats        dump_config=10  dump_sandbox=0
    test/precedence.bats   dump_config=38  dump_sandbox=0
    test/validation.bats   dump_config=22  dump_sandbox=9

`CSB=./csb-config` must make all of `lists.bats` + `precedence.bats` plus the
dump-config tests in `validation.bats` pass **unchanged** -- ~67 tests, none
needing nix, a launch, or a repo. That tier runs *inside* a csb sandbox
(`make test` is 89/89 green in one), which is the constraint that forced
`PLAN-007-escape.md`'s Tier 2/3 verification out to a host terminal. This slice
does not have that problem.

What it de-risks in one or two sessions: whether `cmdliner` can reproduce csb's
actual flag surface -- every `--no-*` negation, `-E[=NAME]`'s optional argument,
repeatable list flags, and four-layer precedence with `.local` on top. Cheap
failure, early.

### Adoption: strangler fig, not big bang

`bin/csb` shells out to `csb-config`, reads the resolved values back, and keeps
doing the git/nix/exec work. OCaml owns the algebra; bash owns the orchestration.
Ships the moment the ~67 tests pass with both implementations agreeing, then
migrates outward one section at a time behind the same bats oracle. The 686 lines
of emitters are never ported, because the rebase deletes them.

Design points to settle at the seam:

- **Do not `eval` the child's output back into bash** -- read `KEY=VALUE` with a
  plain `while IFS='=' read -r k v` loop, and pick a NUL-delimited form for the
  list-valued keys, since csb already handles paths containing spaces.
- **Have `csb-config` emit the Q1 JSON.** One artifact then serves the debug
  seam, the bash handoff, *and* the nix input -- so this project and the rebase
  meet at a typed interface instead of colliding. OCaml owns "what the config
  means"; nix owns "what the policy is". That is a cleaner split than csb has
  today.

### Setup and caveats

- devShell gains `ocaml`, `dune_3`, `ocamlPackages.cmdliner`,
  `ocamlPackages.yojson` (+ `ocaml-lsp` / `ocamlformat` for comfort, `qcheck`
  later when the merge laws become property tests instead of 36 examples).
- `buildDunePackage` output in the flake we already have.
- **Keep bats as the oracle.** Do not rewrite the tests into an OCaml test
  framework; their entire value is being implementation-independent.
- Correction to section 12's build pitch: **OCaml cross-compilation is weak**
  compared to Go or Zig. Irrelevant here -- nix builds per-platform on each host.
- **`make install`'s one-file-copy property is lost** for the binary. Tolerable
  while it is just `csb-config` beside a bash `csb`; decide the install story
  before the port grows past the config layer, not after.
