# plan 008 -- csb's own egress control (allowed hosts + allowed ports)

Status: **DECIDED (2026-08-05) -- build it in csb, do not rebase on
agent-sandbox.nix.** This started as a feasibility study for rebasing csb on
[agent-sandbox.nix](https://github.com/archie-judd/agent-sandbox.nix) and ended
by rejecting it. That evaluation is retained as Appendix A because it is the
reason for the decision.

Verified against upstream `HEAD` and against `bin/csb` on 2026-08-05.

---

## Handoff (updated 2026-08-07, for a fresh context)

Read this, then section 0, then section 9. Sections 1-8 are the design; the
appendices are decision record and can be skipped until something questions the
decision itself.

### Where the work stands

| piece | state |
|---|---|
| P1 -- `csb-proxy` (CONNECT allowlist proxy, OCaml) | **DONE**, 11/11 in `make test-proxy` |
| P2 -- macOS wiring (`--filter-egress`) | **DONE**, verified end-to-end on aarch64-darwin; goldens on both platforms |
| `packages.csb-tools` flake output | **DONE**; `nix build .#csb-tools` green on aarch64-darwin 2026-08-06, with cmdliner |
| `csb-config` milestone 1 (default config parity) | **DONE**, byte-identical to bash |
| `csb-config` milestone 2 (the parser) | **DONE (2026-08-06)**, 73/73 in `make ocaml-test` |
| **adoption -- `bin/csb` delegates resolution to `csb-config`** | **DONE (2026-08-06)**, 99/99 in `make test`; see below. NOT yet exercised by a real launch |
| parity tier (`make test-parity`) | **DELETED** with the bash resolution path, as planned -- it compared csb-config to itself |
| P3 -- layered INI config, union-for-lists | **DONE (2026-08-07)**, 122/122 in `make test`; see below. NOT yet exercised by a real launch |
| P3b -- one layer type, clearing across layers, flag parity | **DONE (2026-08-08)**, 143/143 `make test` and 115/115 `make ocaml-test`; section 5. NOT yet exercised by a real launch, and `ocaml/lib/layer.ml` needs `git add` before `nix build` |
| P4 -- Linux netns so `--filter-egress` enforces there | not started; the big one |

### The expected numbers -- run these first to detect drift

    make check          # shellcheck clean
    make test           # 143 ok  (Tier 1+2. bats reports a skip as `ok N # skip`,
                        #          so 143 is the total on every platform and what
                        #          varies is how many are skips: 14 inside csb --
                        #          12 Tier-2 goldens plus 2 Linux-only cases --
                        #          and fewer on a host, where the goldens run.)
    make test-proxy     # 11 ok   (needs network for 2 of them; rest are offline)
    make ocaml-test     # 115 ok  (csb-config alone, without the bash wrapper)
    ( export CSB_MAIN_ROOT="$(pwd -P)"
      diff <(./bin/csb --dump-config) <(./ocaml/_build/default/bin/csb_config_cli.exe) )
                        # must be empty: 38 keys, byte-identical

If any of those four moves, something regressed -- fix that before starting
anything new. The guard exports `CSB_MAIN_ROOT` because that is what `bin/csb`
derives and passes down (P3, below), and a bare `VAR=x diff <(a) <(b)` would not
reach either substitution -- landmine 13's shape, one construct over.

### Adoption, as built

`bin/csb` no longer parses a flag. It runs `csb-config` over its own argv and
reads the resolution back; git, nix, the sandbox profile and exec stay in bash.
That deleted about 620 lines from `bin/csb` -- `usage()`, the argparse loop,
`load_profile` and friends, the six validators, the dump block -- against about
165 added, and it is the reason the two implementations can no longer drift:
there is only one.

**The contract, which is the part to understand before changing either side:**

- `bin/csb` sets `CSB_EMIT_TO=<tempfile>` and runs the child under
  `exec -a "$PROG"`, so argv[0] -- and therefore every diagnostic prefix, the
  usage line and the version string -- names the program the operator typed.
- **Exit 0**: the file holds the resolution. **Exit 2**: csb-config answered the
  operator itself (`--help`, `--version`, `--dump-config`) and resolved nothing,
  so `bin/csb` exits 0 without launching. **Anything else**: it already said why
  on stderr, and `bin/csb` propagates the status (cmdliner's parse errors are
  124, a `die` is 1).
- The wire format is NUL-terminated `KEY=VALUE` records, a list key repeating
  once per element. NUL because it is the one byte a path, a claude argument or
  a `setenv` value cannot contain. **Parsed, never `eval`ed.**
- The emit file carries `token_cmd` unredacted -- that is the whole reason it is
  a private file rather than stdout -- and is unlinked as soon as it is read.
- `--dump-config` stays redacted and byte-identical: it is answered by
  csb-config, not by the emit path.

**Two guards, because a silent no-op is this repo's recurring failure mode.** An
unrecognized key is fatal, which catches a rename or an addition on one side
only. A *missing* scalar key would not be caught by that, and `paranoid` or
`filter_egress` quietly reverting to its default is a weaker sandbox that looks
normal -- so `csb_config_scalars` in `bin/csb` lists all 25 and requires each to
arrive. List keys are absent when empty, so only scalars can be required.

**The emit key set is exactly what `bin/csb` consumes** -- 25 scalars plus 10
list keys. Note it is not the dump's 37: the three raw `nix_target*` keys are
gone, because `effective_nix_target` was the only consumer and csb-config now
computes it as `nix_target_effective`; and `dump` was added, carrying
`sandbox` for the seam bash still has to serve.

**Verified on the host (2026-08-07).** `make test` (99) and the dump seams cover
everything up to the launch, and no further -- landmine 8's blind spot, which
adoption widened, because `claude_args`, `keep`, `setenv` and `token_cmd` now
cross the emit seam and no dump reaches any of them. So these were driven by
hand on aarch64-darwin, running the branch checkout directly rather than
installing it:

- `nix build .#csb` succeeds with the split install and `csb-tools` in
  `runtimeInputs`.
- `csb --here -s` launches and gives a working shell.
- **`token_cmd` round-trips through a real claude launch.** The control matters
  and is easy to get wrong: `CLAUDE_CODE_OAUTH_TOKEN` is in `keep_vars`, so a
  host-set token sails through the scrub and authenticates the session whether
  or not `token_cmd` ever fires. Run with it unset --
  `( unset CLAUDE_CODE_OAUTH_TOKEN; csb --here -p <profile> )` -- and a session
  that authenticates can only have got its token across the seam. It did.
- **`keep` and `setenv` arrive in the launched environment**, from both a
  profile and `-k`, with an unkept variable absent as the control. The
  load-bearing case was a `setenv` value carrying spaces *and* an interior `=`
  (`CSB_TEST_B=has spaces and=an equals sign`), which arrived whole: the seam
  splits each record at the FIRST `=` only, so a value may contain as many more
  as it likes.

So every key that crosses the emit seam has now been observed on the far side of
a real launch, which is the only place any of them is observable.

Still unconfirmed: `make install` on a real HOME rather than the fake one used
in-session.

A note for whoever trials a branch build side by side with an installed csb: the
working-tree fallback is relative to `$0`'s directory, so a **symlink** shim in a
bin dir resolves to the wrong place and dies. Use an `exec` wrapper or an
absolute path. Also, `main` knows none of the P2 profile keys
(`filter_egress`, `allow_host`, `allow_port`), and both versions read the same
`~/.config/csb/profiles` -- so one of those keys in a shared profile takes the
OLD csb down with `unknown key`.

### `--help` is cmdliner's now

`usage()` is gone; the 177 lines of hand-maintained prose live in csb-config as
option `~doc` strings and a `~man` block, grouped into HOME SELECTION, SANDBOX
POLICY, EGRESS FILTERING, SEEDING THE LAUNCH HOME, READ-ONLY SEAMS and
NEGATIONS, plus a PROFILES section for the key list. This is what section 9
decided; the HOME-choice explainer survived as prose, as promised.

One wrinkle worth knowing, and it is landmine 10's sibling: cmdliner picks its
help *renderer* from `TERM`, not from whether anyone is watching, so a piped
`--help` came out overstruck for a pager that was not there. The driver rewrites
a bare `-h`/`--help` to `--help=plain` when stdout is not a tty.

`CSB_VERSION` moved out of `bin/csb` into `ocaml/lib/version.ml`, so there is one
copy. `csb --version` still prints `csb 0.3.1`.

### How `csb-config` is found, and why not the way `csb-proxy` is

`CSB_CONFIG_BIN` verbatim, else a `csb-config` beside `$0`, else this repo's own
`ocaml/_build/.../csb_config_cli.exe`, else `$CSB_TOOLS_DIR` (`~/.csb/bin`),
else `PATH`, else a die naming `make install`.

The working-tree entry is why `./bin/csb --here --dump-config` still just works
after `make ocaml-build` -- `CLAUDE.md` names that seam as the in-session
verification path, so needing an env var for it would have taxed every future
session. It comes before the installed copies on purpose: running the tree tests
the tree, even on a host with csb installed.

**`csb-config` does NOT go in the bin dir** (operator, 2026-08-07). The first cut
installed both there and was wrong for a reason the Makefile had already written
down: that dir "may itself be under version control, so it must hold real,
portable content", and a per-platform native binary is portable content's
opposite. So `make install` splits -- `BIN_DIR` (`~/bin`) takes the script,
`TOOLS_DIR` (`~/.csb/bin`) takes the binary. Two things fall out of it:

- **`~/.csb/bin` is outside every sandbox write root, and that is a requirement,
  not a coincidence.** csb-config decides policy and runs *unsandboxed*, so a
  writable one is a persistence vector of exactly the `.git/hooks` class that
  section 5 rules on. The write roots are the worktree, the git dir,
  `/private/tmp`, `/dev` and the launch HOME -- so the launch HOMEs under
  `~/.csb/claudes/<ns>` are writable and this sibling is not. **Never cache or
  install it under the temp dir**, which is a write root.
- An overridden `TOOLS_DIR` that is neither the default nor on `PATH` produces a
  csb that dies on every invocation, so `make install` warns at install time
  rather than leaving it to first use.

**Deliberately no `nix build` fallback**, which is how
`csb-proxy` resolves: that runs only under `--filter-egress`, whereas this runs
on every invocation, and a nix eval in front of `csb --help` is not a trade
worth making. It also keeps section 6 item 5 true -- no nix on the policy path.

The cost is that the two must be installed together, which `make install` does
in one step, and `packages.csb` gained `csb-tools` in `runtimeInputs` so
`nix run` keeps working. The split install is verified against a fake HOME
(`make install HOME=$T BIN_DIR=$T/bin TOOLS_DIR=$T/.csb/bin`, then the installed
csb resolving with an empty PATH and no env). **The flake half is not: nix is
absent in here.** `nix build .#csb` is an operator check.

### P3, as built (2026-08-07)

Section 5's design landed as specified. Four layers now fold into one
`Profile.t` before `Resolve` ever runs: `Profile.builtin`, the matched sections
of `config` then `config.local` (`lib/config_file.ml`), the `-p` profile, and
the CLI on top. `Resolve` barely changed -- it took `profile : Profile.t option`
and now takes `layers : Profile.t`, so every existing precedence rule kept
working unedited. That is what "additive" meant, and it held.

**The one design question section 5 left open was where repo identity comes
from**, because a selector is matched against the physical main checkout root
and `csb-config` has no git. **`bin/csb` derives it and passes it down as
`CSB_MAIN_ROOT`**, beside `CSB_EMIT_TO` on the same `exec -a` line. Git stays on
the bash side of the seam, so there is exactly one derivation of repo identity
-- `main_checkout_root()` in `bin/csb`, which `repo_key` now calls too, so the
namespace HOME and the config sections cannot disagree about which repo this
is. The alternative, teaching csb-config to shell out to git, would have put an
exec on the policy path and a second implementation of `--git-common-dir`
semantics in the tree.

An inherited `CSB_MAIN_ROOT` is honoured verbatim, an **inherited empty one
included** (`${CSB_MAIN_ROOT-...}`, not `:-`). That is what makes the layering
testable without a repository: `test/config.bats` is 21 hermetic tests that set
the root directly, and it runs in both tiers -- it is in `OCAML_ORACLE`, so
`make ocaml-test` covers it too (landmine 12: the oracle names its files).

Five decisions the implementation forced, none of them in section 5:

1. **The grammar trims whitespace around `=`,** in profiles as well. Section 5's
   own example writes `paranoid = true`, which the profile parser rejected. One
   grammar for all the layers means the profile parser had to learn it; the
   price is that a value cannot carry a leading or trailing space.
2. **A non-matching section is still parsed and validated.** Only the matching
   ones apply, but a typo'd key or a bad port in another repo's section is fatal
   now rather than lying in wait until that repo is the one launching. Same
   reasoning as the allowed-hosts file's eager validation.
3. **A `KEY=VALUE` before any section header is an error.** The alternative --
   treating the preamble as an implicit `[*]` -- makes a global setting look
   local to whatever section follows it.
4. **`setenv` is deduplicated by variable name, keeping the highest layer.**
   The launch exports these in order and a later `env` argument wins, so a
   surviving duplicate would decide precedence silently, off the end of a list
   nobody reads. One VAR, one entry, and the dump shows it.
5. **The two multi-key axes move as a unit across layers.** A layer naming any
   of `ns=`/`ephemeral=`/`real_home=` replaces all three below it, and the same
   for the three `nix_target*` keys -- the rule the CLI already applied to the
   profile, now applied between every pair of layers. Without it a config `ns=`
   and a profile `ephemeral=true` would both survive into resolution and be
   ranked by an accident of evaluation order.

**The prerequisite deny is in**: a linked worktree's own `.git` FILE is
write-denied (`wt_gitfile_deny`, in the same literal-deny loop as
`.git/config`), with a test on each platform plus the main-checkout control --
there `.git` is the writable common dir and denying it would break every commit.
No golden churn: `--dump-sandbox` is driven with `--here`, and every existing
snapshot is a main checkout.

`--dump-config` gained a 38th key, `config_sections`, listing what matched as
`config[*]|config.local[*work*]` in application order. It is **dump-only** -- the
emit seam does not carry it, because `bin/csb` consumes nothing from it and an
unrecognized key there is fatal by design.

`Types.default` was deleted rather than updated. It had no callers, and a
second, unused statement of the defaults sitting beside a real layer 1 is a
drift trap.

Not verified: a real launch. The dump seams cover resolution and the profile,
and `config_sections` makes the selection visible, but landmine 8 still holds --
`setenv` reaching the launch environment is only observable by launching.

### The immediate next task

- **P4 (section 4), on a NixOS host.** `--unshare-net` + pasta + nftables so
  `--filter-egress` enforces on Linux instead of disabling itself. Cannot be
  done from inside a csb sandbox at all.

Before P4, the operator checks what adoption, P3 and P3b left open: a real
launch, `nix build .#csb`, and `make install`. For P3 specifically, the launch
worth running is one with a real `~/.config/csb/config` -- `csb --here
--dump-config` first, to see `config_sections=` name the sections it should,
then a launch and `env | grep DISABLE_AUTOUPDATER` inside it.

**P3b adds three to that list, and the first is a hard prerequisite:**

- **`git add ocaml/lib/layer.ml`.** It is a new file, so landmine 11 applies and
  `nix build` cannot see it until it is staged -- the failure is the confusing
  one, "Unbound module Layer" for a file sitting right there on disk.
- **The Tier-2 goldens have not been re-run since P3b.** They skip inside csb, so
  the 143 above does not cover them. P3b touched resolution and not the profile
  generator, so no golden should move; a host `make test` on each platform is
  what confirms it. If one does move, that is a finding, not churn.
- **A launch with `--per-repo`** against a config section or profile that sets
  `ns=`, since HOME selection is what decides the directory the launch actually
  runs in, and that path lives in `bin/csb` past both dump seams.

Also open, and not P3's to fix: the README documented no egress surface at all
until this pass (its profile key list had been missing `filter_egress`,
`allow_host`, `allow_port`, `pasteboard` and the three `nix_target*` keys since
P2). Those keys are listed now, but P2's `--filter-egress` workflow still has no
section of its own.

### No decisions left open

`-V` was dropped from `bin/csb` (operator, 2026-08-06) rather than restored in
csb-config: cmdliner owns `--version` and offers no short form, so removal is
what makes the two agree.

### What cannot be done from inside a csb sandbox

`CSB_SANDBOX=true` in the environment means all of this needs the operator:

- **`nix` is absent.** No flake builds, no `nix eval`.
- **Tier-2 snapshots skip** (`test/helpers.bash:195`, and D1 in
  `PLAN-007-escape.md` is why: goldens made in here are wrong AND compare equal).
  Regeneration is `make test-update` from a normal terminal, on both platforms.
- **No real launch** -- sandbox-exec cannot nest, so `make test-escape` and any
  end-to-end `--filter-egress` check are host-side.
- Network egress DOES work in here, which is why `make test-proxy` is meaningful.

### Landmines, each of which cost a round-trip

1. **Wrap an error only by ADDING context, never replacing it.** Cost three
   round-trips: `Socket is closed` masking a 403; the proxy log living outside
   the sandbox; and worst, my own handler swallowing nix's stderr, which hid
   `path '/Users/atongen/src' is a symlink` for a full turn.
2. **Do not wrap `run` around a bats helper that already calls `run`**
   (`dump_config`, `dump_sandbox` both do). It silently swallows exit status.
   Call them bare, like the rest of the suite. The related trap, one tier over:
   **a bats test body runs under `errexit`**, so `out="$(thing_that_dies)"`
   aborts the test at that line rather than recording the status. Every die
   path in `parity.bats` needed `&& rc=0 || rc=$?`. The tell is a failure with
   no diagnostic output -- the code that would have printed it never ran.
3. **Scope `--dump-sandbox` assertions by platform.** Linux emits bwrap argv with
   no seatbelt syntax at all; three tests failed on NixOS for this.
4. **A `path:` flake ref must be physical.** nix refuses a symlinked ancestor.
   `bin/csb` now canonicalizes it; `repo_key` had already learned this.
5. **A bare git `CSB_SELF` resolves the remote's DEFAULT branch.** A new flake
   output on a feature branch is simply absent. Use `?ref=<branch>` or `path:`.
6. **The proxy's stdout carries ONLY the port.** Build/status chatter belongs on
   stderr; `make ocaml-build` violated this and broke `make proxy-run`.
7. **`TMPDIR` may or may not end in a slash.** Normalize.
8. **No seam covers the launch environment.** `--dump-config` covers resolved
   config, `--dump-sandbox` covers the profile, and `env_overrides` between them
   is invisible to both -- an ordering bug there produced a silently isolated
   sandbox. A `die` guards that specific case now. If the class recurs, a third
   dump seam is the answer; once is not enough evidence.
9. **Silent no-ops are this repo's recurring failure mode.** Prefer a loud error,
   and when a flag is a deliberate no-op on a platform, assert that it says so
   (see the Linux `--filter-egress` test).
10. **cmdliner decides its own diagnostic styling at module-initialization
    time**, from `NO_COLOR`/`TERM`, which is before any `main` can correct the
    environment. Its `unknown option` error therefore arrives with SGR escapes
    *inside* the phrase, and `assert_output --partial "unknown option"` fails on
    bytes nobody can see. `Cli.eval` renders cmdliner's errors into a buffer and
    unstyles them when stderr is not a tty. Anything else that greps a child's
    stderr will meet this again.
11. **A flake builds from the git tree, so a NEW source file is invisible to
    `nix build` until it is `git add`ed.** Edits to tracked files are picked up
    from the working tree, which makes the failure mode specific and confusing:
    the new *contents* of a tracked file compile against the *absent* new
    modules beside it, and nix reports "Unbound module Cli" for a file sitting
    right there on disk. `git add` is enough; no commit is needed. Third entry
    in this file's flake-ref family, after 4 and 5.
12. **A test the port cannot answer must be excluded by a tag, not by a copy.**
    `make ocaml-test` runs `--filter-tags '!dump-sandbox'`, so a new
    `--dump-config` test joins the oracle automatically and a new
    `--dump-sandbox` test breaks it loudly until tagged. Duplicating the file
    would have let the two drift.
13. **An assignment prefix on `exec` does not reach the exec'd program.**
    `VAR=x exec -a name cmd` sets `VAR` in the *shell* -- `exec` is a special
    builtin, so the prefix persists rather than being exported for one command.
    The adoption seam passes `CSB_EMIT_TO` that way and would have handed
    csb-config an unset variable, which is the quiet kind of wrong: csb-config
    would have printed the dump and exited 0, and `bin/csb` would have launched
    with an empty resolution. Write `( export VAR=x; exec -a name cmd )`.
14. **cmdliner picks its help RENDERER from `TERM` too**, not only its
    diagnostic styling (landmine 10), and not from whether stdout is a tty. With
    a real `TERM` and no pager on `PATH` a piped `--help` arrives overstruck
    (`N^HNA^HAM^HME^HE`), so `csb --help | grep` misses. Rewriting a bare
    `-h`/`--help` to `--help=plain` when stdout is not a tty is the fix, and it
    is the same shape as `Cli.eval`'s unstyling. Expect a third member of this
    family before trusting any cmdliner output to a pipe.
15. **shellcheck SC2094 fires on `rm -f "$f"` inside `while ... done <"$f"`** --
    read and write of one file in the same construct. The fix is also the better
    code: record the fault, `break`, and unlink once after the loop, so the
    temp file is removed on every path rather than only on the fatal one.
16. **An assignment prefix does not reach a process substitution either.**
    `VAR=x diff <(a) <(b)` runs `a` and `b` in children of the SHELL, set up
    before `diff` is executed, so neither sees `VAR` -- landmine 13's rule in a
    second construct. The drift guard at the top of this file is exactly that
    shape, which is why it exports first, in a subshell.

### Conventions that are not obvious from the code

- **The operator does all git.** Do not commit, branch, or push.
- **ASCII only** in every file.
- `make check` AND `make test` before calling anything done.
- Prefer the read-only seams (`--dump-config`, `--dump-sandbox`) over reasoning
  about the launch path; they are why Tier 1 is trustworthy.
- Code comments describe the present only -- no history, no "was", no dates.
  Narrative belongs in docs like this one.
- `--filter-egress` is **OFF by default** and should stay that way until the
  WebFetch cost (section 7 item 4) is judged acceptable; it is not a bug.

### Open questions with no answer yet

Section 10 is the live list. The two that matter most: whether removing the
`mDNSResponder` allows under filtering breaks anything (DNS is unused there, the
proxy resolves), and whether `platform.claude.com` is truly required -- it is
listed on documentation grounds but has never been observed in a refusal log,
and would only surface at token expiry.

---

## 0. The decision

Give csb per-host egress filtering by writing the missing pieces ourselves,
rather than adopting agent-sandbox as the containment base.

**The reason is not the proxy -- the proxy is the cheap part. It is that a rebase
costs csb its capability story and its config model, and building does not.**
Two findings drove it, both measured against upstream source:

- **The exec-closure problem (Appendix A, Q2).** agent-sandbox permits
  `process-exec` only for the closure of its declared `allowedPackages`; the nix
  store is readable but not executable. So `nix develop <repo> --command
  <wrapper>` yields a toolchain that is *visible and unrunnable* -- and running
  the agent inside the repo's own devShell is csb's entire M2 capability story.
  Every fix was bad: harvest the devShell's `buildInputs` (unverified, and it
  loses the shellHook env that drip's native gems need), or `allowNix = true`,
  which reopens F3 -- a boundary closed on measured evidence in
  `PLAN-007-escape.md`. **Building our own makes this problem disappear:**
  `nix develop` stays the outer layer, the toolchain just works, and nix runs
  host-side so nothing inside ever needs the daemon socket.
- **The eval-time config problem (Appendix A, Q1).** Every agent-sandbox knob is
  a nix function argument; the profile is a `runCommand` output. Per-project
  domains and ports would therefore need a generated nix expression and a
  `nix build` per launch. **Building our own deletes that whole layer** -- csb
  already generates its policy at runtime, so there is no nix codegen, no
  `--impure`, no per-launch eval latency, and no flake fetch on the policy path.

Everything else follows: no license question, no 5 lost flags, no degraded
`--dump-sandbox`, no rewritten snapshot suite, no dependency on an unreleased
upstream rev.

---

## 1. What csb already is

The framing that settled this: **csb is already its own agent-sandbox.** It owns
the seatbelt profile generator, the bwrap argv, the IPC broker denies,
`--paranoid`, `--allow-socket`, `--pasteboard`, and the write allow-list. That is
686 lines of policy (`bin/csb:630-1315`) that a rebase would have *replaced*, not
supplied -- and in several places it is stricter than upstream's by decisions
made deliberately with probe evidence behind them.

Exactly two things are missing:

1. **An egress-filtering proxy** (section 2), and the profile/env wiring to force
   traffic through it (section 3).
2. **On Linux, a network namespace** so the proxy cannot simply be bypassed
   (section 4).

That is the whole scope. Not a rewrite.

---

## 2. The egress proxy

**Non-MITM, CONNECT-only, in OCaml, in the dune project we already have.**

What it does: listen on `127.0.0.1:0`; print the chosen port on stdout so the
launcher can pin the profile to it; read `CONNECT host:port HTTP/1.1`; match
`host` against the allowlist (exact, plus `*.suffix` wildcards); on allow, dial,
reply `200`, and splice bytes bidirectionally until either side closes; on deny,
reply `403` and log the refusal. Plain (non-CONNECT) HTTP is refused rather than
proxied -- everything csb needs is HTTPS, and refusing it removes a parser.

**BUILT AND VERIFIED (2026-08-05).** `ocaml/lib/allowlist.ml` (host matching),
`ocaml/lib/proxy.ml` (the server), `ocaml/bin/csb_proxy_cli.ml` (CLI). 8/8 tests
green via `make test-proxy` (`test/proxy/proxy.bats`), driving real curl through
a real proxy:

    ok 1 allowed exact host tunnels a real TLS request
    ok 2 allowed wildcard *.github.com matches a subdomain
    ok 3 an unlisted host is refused
    ok 4 an IP literal is refused even though it needs no name lookup
    ok 5 a port other than 443 is refused on an allowed host
    ok 6 a non-CONNECT (plain http) request is refused
    ok 7 the wildcard does not match the bare parent domain
    ok 8 a comment line in the allowlist is not a host

Actual size: ~250 lines across the three files, **zero new nix dependencies**
(`unix` + `threads.posix` ship with the compiler). Deliberately its own test
tier, not part of `make test`, which stays dump-only and hermetic -- though only
tests 1-2 need a network (a refused CONNECT never dials upstream), so the rest
run offline and the two skip without connectivity.

The port handshake is a FIFO: the proxy prints its bound port on stdout and the
launcher blocks on `head -1` before emitting the profile. Same shape upstream
uses, and it needs no polling.

One non-obvious implementation requirement, learned the hard way in every proxy
ever written: **`SIGPIPE` must be ignored** (`Sys.set_signal Sys.sigpipe
Signal_ignore`), or the first client that hangs up mid-transfer kills the
process.

Dropping MITM is what makes it small, and it drops the expensive parts with it:
no CA generation, no cert minting, no TLS library, no
`SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS` injection, and none of the "`gh` and other
Go tools fail HTTPS with a certificate error" breakage upstream documents. For
comparison, their Go proxy is 563 lines including the cert machinery.

#### What MITM would buy, and what we therefore give up

The distinction that matters: **MITM is not needed for destination control, only
for content control.** Without decrypting, the proxy still fully decides *who*
the sandbox can talk to -- it dials the hostname it just checked, so a client
that lies in `CONNECT` reaches only a host that was already allowed. What it
cannot do is see or constrain *what* is said. Specifically:

1. **Per-domain HTTP method filtering.** Upstream's
   `"api.github.com" = [ "GET" "HEAD" ]` requires reading the request line, which
   requires decrypting. Ours is allow/deny per host, all methods.
2. **Path and URL filtering.** Cannot allow `github.com/myorg/*` while denying
   the rest. This is the real granularity loss, and it is the mechanism behind
   section 7's caveat: allowing `github.com` allows gists, which is an exfil
   channel an allowlist cannot close.
3. **Body inspection.** No outbound secret scanning, size caps, or content-type
   limits. Nobody asked for these; they are the theoretical ceiling MITM buys.
4. **Audit detail.** Refusal logs record `host:port`, not method and path.
   Coarser forensics after the fact.
5. **Header rewriting -- the most interesting one.** An MITM proxy can *hold* a
   credential and inject it, so the sandbox never possesses the secret at all.
   csb currently forwards `CLAUDE_CODE_OAUTH_TOKEN` into the launch env, where a
   compromised agent simply reads it. A terminating proxy could keep it out of
   reach entirely. That is a genuine capability we are declining, and it is worth
   revisiting on its own merits later -- as a credential broker, not as a
   filtering mechanism.

Against all that, MITM costs: a TLS library and CA/cert-minting machinery (new
dependencies, and the bulk of upstream's 563 lines); `SSL_CERT_FILE` /
`NODE_EXTRA_CA_CERTS` / `REQUESTS_CA_BUNDLE` injection; breakage of every client
with pinned certs or its own trust store (upstream documents `gh` and other Go
tools failing HTTPS on macOS); and it turns the proxy into a component that sees
plaintext credentials, making its own logs sensitive. For a first version whose
requirement is "allowed hosts", that trade is clearly wrong.

One place non-MITM is *more* permissive: upstream states WebSocket connections
are not permitted when their proxy is active. A `CONNECT` tunnel carries `wss://`
transparently, so ours would allow websockets to allowed hosts.

#### Two implementation requirements that follow

- **Refuse IP-literal `CONNECT` targets** (`CONNECT 1.2.3.4:443`) unless the
  literal itself is allowlisted. Otherwise the host allowlist is bypassed by
  simply not using a hostname -- the allowlist would be decorative.
- **Refuse `CONNECT` to ports other than 443** by default, so the tunnel cannot
  be repurposed to reach an arbitrary service on an allowed host.

**Write it from the HTTP spec, not from their Go.** Appendix A's license clause
prohibits AI-system interaction with that source, and this project is
agent-authored. Clean-room is both the correct engineering hygiene and the
cleanest answer to the clause.

Side benefit: with the proxy resolving names, the sandbox needs no DNS at all.
The `mDNSResponder` socket allows currently in the profile can go, which is
tighter than today.

---

## 3. macOS integration -- nearly free

csb already emits the deny-default network class. The whole change is line 8:

    $ ./bin/csb --here --dump-sandbox | grep -n network
    7:(deny network-outbound)
    8:(allow network-outbound (remote ip "*:*"))      <- becomes localhost:<proxy port>

Plus: per-port `(allow network-outbound (remote ip "localhost:<p>"))` rules for
`allowed_ports`, `HTTP_PROXY`/`HTTPS_PROXY` in the launch env, and the
port-pinning handshake (start proxy, read its port, then emit the profile).

The hard part -- flipping `network-outbound` from allow-default to deny-default
as a *class* -- `PLAN-007-escape.md` already did and measured (row A7). This
builds directly on it.

---

## 4. Linux -- the real bill, stated honestly

bwrap has no socket filter, so on Linux `HTTP_PROXY` is advisory: a process can
dial out directly and ignore it. Making the proxy unbypassable requires
`--unshare-net` plus a userspace network plus a firewall -- the shape upstream
uses (`pasta -4 --config-net`, gateway `10.0.2.2`, nftables OUTPUT default-drop
with a single `accept` for `tcp dport <proxy port>`).

This is the part where agent-sandbox's value was real, and it cannot be
shortcut. It is also exactly what `PLAN-007-escape.md` Part 9 closed as
"requires a new mechanism ... do not reopen without a new document" -- so this
document is that reopening, deliberately.

Rough shape: 2-4x the macOS effort, plus a NixOS verification pass.

**It pays twice.** `--unshare-net` is the only thing that closes the Linux
abstract-unix-socket residual -- X11 keystroke injection via
`@/tmp/.X11-unix/X0` -- which Part 10 wrote off as "unchanged and unfixable
here". If it measures out, this work retires a permanent residual as a side
effect.

---

## 5. Config surface: global + per-project that combine

Requirement (operator, 2026-08-05): global `allowed_ports=5432` plus project A
`allowed_ports=6379` yields `5432,6379` in the sandbox. Same for allowed hosts.

**Precedence chain**, lowest to highest, with one rule doing the work --
**lists union across layers; scalars and booleans override**:

    1. built-in defaults        (including the privacy setenv= entries, below)
    2. matched sections   ~/.config/csb/config, then config.local
    3. profile            -p NAME (+ NAME.local), optional
    4. env                CSB_LATEST / CSB_VERBOSE / CSB_TMPDIR
    5. CLI flags

Union for lists is not new: the five list flags already accumulate across CLI and
profile today. The exact env-vs-profile ordering must be transcribed from the 36
precedence tests, not re-derived.

### DECIDED (2026-08-07): selectors, and document order

The requirement, in the operator's words: aggregate configuration for *sets* of
repositories -- a global set, repos matching a pattern, and specific repos --
added lowest to highest with lists unioning and scalars overwriting. Plus
machine-local overlays, because the same `~/.config/csb` is shared between a
macOS and a NixOS box.

**Three selector kinds. Section headers are matched against the physical main
checkout root** (`~` expanded; the same path `repo_key` derives, so running from
a linked worktree selects the repo's sections, not the worktree's):

| kind | example | matches |
|---|---|---|
| everything | `[*]` | every repo |
| glob | `[*work*]`, `[*/work/*]`, `[*/csb]`, `[/Volumes/src/*/client-a]` | by pattern |
| exact path | `[/Volumes/src/git.grandrew.com/atongen/csb]` | one repo |

**`*` matches any character INCLUDING `/`.** That one rule is what lets the glob
kind absorb the two the operator also asked for: `*work*` is a substring match,
and `*/csb` is a match-by-name. Offering `substring` and `name` as separate
syntaxes would be two more ways to say the same thing, and would immediately
raise the question of how they rank against a glob.

**`repo-<key>` is NOT a selector.** Section 5 originally offered it on the
grounds that it "survives a repo move". Measured 2026-08-07: it does not.
`repo_key` is `basename-<cksum>` of the *physical main checkout path*
(`bin/csb`), so a move changes the key. As a selector it is exactly as fragile as
the path and unreadable besides.

**Ordering is DOCUMENT ORDER, not specificity**: `config` in full, then
`config.local` in full, and within each, top to bottom. Every matching section
applies; the last one to set a scalar wins, and lists union across all of them
regardless of order.

This is a deliberate rejection of the operator's first framing (rank by
specificity, least to most). Two reasons, the second decisive:

- **Specificity is not a total order.** Is `*work*` more specific than
  `*/client-a/*`? There is no true answer, so any answer is a rule to memorize,
  and a wrong guess is silent.
- **Specificity fights the machine-local overlay.** Given a shared
  `config` with `[/Volumes/src/work/api] nix_target=release` and a gitignored
  `config.local` with `[*] nix_target=ci`, specificity ranking makes the exact
  path win and the machine-local override is *ignored* -- backwards, and the
  operator would have to restate every specific selector in `.local` to
  override anything.

Document order costs nothing here because **the operator's model IS document
order**, given the file is written the way it was described: `*` first, then
groups, then specifics. And getting the order wrong has a small blast radius,
since lists union regardless and only scalars care.

    # ~/.config/csb/config          (shared, committed)
    [*]
    paranoid = true
    [*work*]
    allow_host = api.internal.corp
    [/Volumes/src/work/api]
    nix_target = release

    # ~/.config/csb/config.local    (gitignored, this machine only)
    [*]
    nix_target = ci                 # wins: last to set the scalar

**`--dump-config` must report which sections matched, in application order.** A
typo'd selector matches nothing and is otherwise invisible, which is this repo's
recurring failure mode; this makes the whole layering debuggable.

The value grammar is the one `~/.config/csb/profiles/NAME` already uses --
`KEY=VALUE`, `#` comments, blanks ignored -- so **one parser serves profiles and
this file**, differing only in section headers.

### Prerequisite: deny the linked worktree's own `.git` file -- DONE (2026-08-07)

Config sections grant capability (`allow_write`, `allow_host`, `sandbox=false`,
`paranoid=false`), and they are selected by a path derived from git. A linked
worktree's `.git` is a FILE at the worktree root, inside write root 22, and it
is what `--git-common-dir` reads to produce `main_root`. Measured 2026-08-07:

    (allow file-write* (subpath ".../wtprobe/wt"))            <- holds wt/.git
    (deny  file-write* (literal ".../main/.git/config"))
    (deny  file-write* (literal ".../main/.git/worktrees/wt/config.worktree"))
    # no deny for ".../wt/.git"

So a sandboxed agent can `git init` somewhere writable, repoint that file, and
make the next launch resolve a `main_root` of its choosing -- selecting whichever
config section it likes. Today that buys little; under this section it selects
policy, which is the `.git/hooks` persistence class that `PLAN-007-escape.md`
closed. **The deny landed before the layering.** It is safe: csb writes that file at
worktree creation, outside the sandbox, and git does not rewrite it in normal
operation (`git worktree repair` would, and is a host-side command).

### Shipped defaults for layer 1 -- DECIDED (2026-08-07)

Section 9a established that the allowlist and its companion environment are one
unit. Two of the three go into the built-in defaults as `setenv=` entries,
because they cost nothing:

- `DISABLE_AUTOUPDATER=1` -- no loss whatever: csb pins claude via nix, so a
  successful update would target a read-only store path. It *removes* the false
  "Auto-update failed - Run claude doctor" banner that section 9a measured.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` -- Anthropic receives no telemetry
  or crash reports. No functional loss known. Open question: whether
  feature-flag delivery rides along, which would gate newer features.

`ENABLE_CLAUDEAI_MCP_SERVERS=false` is **deliberately NOT a default**, though
section 9a lists it as droppable. The operator has a live claude.ai-hosted MCP
connector (Drip), and defaulting it off would silently remove that tool surface
from every launch. It stays a per-section opt-in, which is precisely what the
layering makes cheap.

Note this does not turn `--filter-egress` on; it stays off by default (section 8,
and section 7 item 4 for why). These two variables are free, and the allowlist is
the part with a real usability price.

### Per-project config CANNOT live in the repo. Measured.

The obvious design is an in-repo `.csb/config`. The dump seam rules it out:

    $ ./bin/csb --here --dump-sandbox | grep -n 'file-write'
    21:(deny file-write*)
    22:(allow file-write* (subpath "<repo/worktree>"))
    23:(allow file-write* (subpath "<repo>/.git"))
    24,26:(allow file-write* (subpath "/private/tmp")) ... (launch HOME)
    27:(deny file-write* (subpath "<repo>/.git/hooks"))
    28:(deny file-write* (literal "<repo>/.git/config"))

An in-repo `.csb/config` sits inside write root 22, so **the agent could edit the
policy its own next launch runs under** -- add a host, a port, an `allow_write`.
Both plausible mitigations fail on write root 23:

- *Read only the committed file:* the agent can commit and move refs.
- *Read the main checkout, not the worktree:* the shared `.git` is writable from
  any worktree.

So anything csb reads out of the repo or its git dir is agent-influenceable.
Decisive framing: lines 27-28 exist precisely because `.git/hooks` and
`.git/config` are "the persistence vectors a sandboxed process could use to fire
arbitrary code the next time" (`PLAN-007-escape.md`). An in-repo `.csb/config`
would be a newly-added vector of that exact class. csb does not get to deny one
and ship the other.

`~/.config/csb/` is readable but outside every write root -- verified above. That
is where layers 2-3 live. Cost: config no longer travels with the repo. Under a
private single-operator tool that cost is approximately zero.

### Does this retire profiles? Partly. Do not couple the removal.

- **Per-repo defaults: subsumed** by layer 3 -- most of what profiles do now that
  HOME is per-repo by default.
- **`token_cmd`: subsumed** -- belongs in layer 2 or 3.
- **Named variants: NOT subsumed.** Two configs for one repo, chosen per
  invocation (work vs personal token on one checkout; a yolo variant) has no
  expression in a chain keyed by repo identity. That residual is exactly `-p`.

So profiles shrink to "optional named overlay". Ship layers 2-3, then look at
what is left in `~/.config/csb/profiles/` after a month. Bundling the removal in
turns one reversible change into two irreversible ones.

### P3b -- one flag surface, and clearing across layers -- DONE (2026-08-08)

P3 shipped the layering but left the three surfaces saying different things. Two
gaps, and they turn out to be one root: **a layer can add but cannot retract.**

#### The requirement (operator, 2026-08-08)

Config carries the repo's default -- `seed_creds=true`, or `token_cmd=CMD` --
and a named profile reverses it, so that `-p work` takes effect over the repo
default. Booleans already do this; `token_cmd` cannot, and it is the sharp case.

Measured 2026-08-08, with `[*] token_cmd = op read op://global/...` in config:

    profile work: token_cmd=op read op://work/...  ->  op read op://work/...
    profile clear: token_cmd=                      ->  op read op://global/...

The second is the bug. `token_cmd` has **no CLI flag at all** (`ocaml/lib/cli.ml`
names it only in `--doc` strings), so a profile is the only place that could
retract it, and a profile cannot. A repo that defaults to a work credential has
no expression for "this variant authenticates some other way".

#### The rule: an empty value clears every layer below

`Profile.overlay` reads `None` as "this layer did not say", so an empty value is
inert across layers -- it resets the key within its own file and nothing more.
It becomes an explicit **cleared** state that beats the layers below.

**The blast radius is five keys.** Empty is already a hard error for every
validated key, measured across the whole grammar:

    paranoid=     rc=1  paranoid needs true or false: ''
    allow_host=   rc=1  allow_host: not a hostname or *.suffix pattern: ''
    allow_write=  rc=1  allow_write: not an absolute or ~/ path: ''
    setenv=       rc=1  setenv needs VAR=value: ''
    allow_port=   rc=1  allow_port: not a port from 1 to 65535: ''
    nix_target=   rc=1  nix_target: invalid nix target ''
    ns=           rc=0  accepted, inert
    accent=       rc=0  accepted, inert
    keep=         rc=0  accepted, inert (split_ws "" = [])

So only `ns`, `token_cmd`, `seed_home`, `accent` and `args` change meaning, and
each changes it from a silent no-op into something `--dump-config` reports.
Within one layer the observable result is unchanged, so no existing file shifts
under its author.

**This is not a new semantic -- it is an existing one reaching one more
boundary.** `resolve.ml:120-121` is already exactly this rule at the CLI edge:

    | Cli.Cleared -> None
    | Cli.Untouched -> pf (fun p -> p.seed_home)

`--no-seed-home` already retracts the layer below. `Cli.t` already carries the
tri-state that requires (`type 'a setting = Untouched | Cleared | Set of 'a`),
and `Profile.t` carries a plain `'a option`. Two spellings of one idea, which is
why the rule reaches one boundary and not the other.

#### The type, which is where the work actually is

One type serves every layer, and the merge is its monoid:

    type 'a layer = Unset | Cleared | Set of 'a
    let over hi lo = match hi with Unset -> lo | Cleared | Set _ -> hi

`over` is associative with `Unset` as its identity, so the four-layer stack stops
being nested `overlay` calls and becomes a fold, and resolution is one final
`Set v -> v | Unset | Cleared -> default`. `Cli.t` and `Profile.t` become the
same type rather than two shapes with a translation between them, which is what
deletes the `Cli.Cleared`/`Cli.Untouched` special-cases in `resolve.ml` (44,
120-127): they are the general rule, written out per key.

**Booleans keep `bool option`, deliberately.** `bool layer` has four states and
`Cleared` is indistinguishable from `Set false` -- an invalid state made
representable, which is the one thing the house rule forbids. For a bool,
clearing *is* `Some false`. `Cli.t` already splits exactly this way (`pair ~pos
~neg` for bools, `'a setting` for strings), and it is why `seed_creds=false` in a
profile already beats `seed_creds=true` in config; verified 2026-08-08. The
operator's first scenario is satisfied today and this subsection does not touch
it.

**The multi-key axes collapse into single fields, and this is the prize.**
`Profile.t` carries `ns`, `ephemeral` and `real_home` as three independent fields
and then reconstructs the invariant by hand:

    let home_over = over.ns <> None || over.ephemeral <> None || over.real_home <> None
    let axis on hi lo = if on then hi else lo

That is P3's decision 5 implemented as derived state -- the invalid case, two
layers both answering "which HOME", is representable and prevented by code. Make
it one field over a sum type (`home : home_sel layer`, with
`home_sel = Ns of string | Ephemeral of throwaway | Real_home`) and `home_over`
and `axis` both disappear: the axis rule becomes ordinary `over`. `Cli.t` already
found this shape for the nix targets (`nix_targets = Nt_untouched | Nt_cleared |
Nt_set of Types.nix_targets`, one field), and `Types.t` already has the resolved
`home` sum type. `Profile.t` is the layer that never caught up.

**What the collapse must preserve, measured 2026-08-08 rather than assumed.** The
three keys are independent *within* a layer and an axis only *between* layers,
and two rules already distinguish the cases:

    profile: ns=foo + ephemeral=false      -> namespace=foo   (coexist)
    profile: ns=foo + ephemeral=true       -> dies, "mutually exclusive"
    config ns=bar / profile ephemeral=false -> namespace=      (axis reset)
    config ns=bar / profile real_home=false -> namespace=

So `ephemeral = Some true` is what makes a layer's selector *positive*
(`profile.ml:150-157`, the exclusivity check), while `ephemeral <> None` is what
makes the layer *claim the axis* (`overlay`'s `home_over`). A plain
last-line-wins single field would break both: it would silently accept the second
line and drop `ns=foo` on the first.

The fold is therefore per layer, not per line. The three keys parse into a
scratch triple, the existing exclusivity check runs on it unchanged, and the
layer's single field is derived once:

    ns = Some n            -> Set (Ns n)
    ephemeral = Some true  -> Set (Ephemeral ...)
    real_home = Some true  -> Set Real_home
    any of the three named -> Cleared      (this is `ephemeral=false` today)
    otherwise              -> Unset

All four measured rows fall out of that with no special case, and the last line
is the point: **`ephemeral=false` is already a working cross-layer retraction**,
undocumented and un-named. The `Cleared` constructor is not new behavior here --
it is the name for behavior that already shipped.

**This is why clearing cannot be sequenced before the refactor.** A cleared `ns=`
has to decide whether it triggers `home_over` -- a rule that has to be specified,
tested, and got right, and that exists only because the axis is three fields.
Do the refactor first and there is no rule to write.

**Lists are deliberately excluded.** An empty `deny_read=` would have to mean
"discard what the layers below accumulated", which is a different operation from
the scalar case and a policy-weakening primitive: today list union is monotonic,
so no layer can drop a restriction another layer added. That invariant is worth
keeping on purpose rather than losing as a side effect of a syntax. If a list
ever needs retraction it should arrive as an explicit `clear_deny_read` key,
where it is visible, and not before something needs it.

**The emit seam does not change.** `Dump.opt` encodes an absent scalar as an
empty value, and `token_cmd=` on the wire already means absent -- confirmed
against a live emit. `token_cmd` and `seed_creds` are both in `bin/csb`'s
required-scalar list and stay there; clearing produces the encoding that list
already expects. So nothing on the bash side of the seam moves.

**The objection, recorded because it is this repo's failure mode.** An empty
value is the least visible possible spelling of a verb, and a truncated line
becomes a policy action. Two things answer it: today that same truncated line is
silently ignored, which is strictly worse, and after the change `--dump-config`
shows the outcome next to `config_sections`, which makes it the debuggable kind
of wrong.

#### Three steps, one effort -- and step 1 changes no behavior

The type work is not a follow-on to the clearing rule; it is its prerequisite, so
this is one effort rather than two. But it stages into three steps, and the order
matters for one specific reason: **only step 1 is behavior-preserving, and that
is a verification gate worth buying.**

1. **Unify the layer types.** `'a layer` for scalars, `bool option` for booleans,
   the two axes collapsed to single sum-typed fields, `overlay` and the CLI
   special-cases replaced by a fold over `over`. **No behavior change.** The gate
   is that `make test` (122) and `make ocaml-test` (94) stay green with *no test
   edited and no golden regenerated*, which is the strongest evidence available
   in here that the refactor was faithful. Every test drives the real binary
   through `--dump-config`/`--dump-sandbox` (`test/helpers.bash:4-5`), so nothing
   asserts internals and the whole suite survives the reshaping intact.
2. **Make `Cleared` reachable from a file.** An empty value parses to `Cleared`
   for the five plain-string scalars instead of `None`. This is where behavior
   changes and where new tests are written.
3. **Close the flag gaps.** `--token-cmd`, `--setenv`, and the `tmpdir`
   key/flag. Independent of 1 and 2; it could equally be its own piece.

Sequencing steps 1 and 2 the other way would mean writing the `home_over`
interaction rule, testing it, and then deleting it -- so the merged effort is
also the smaller one.

#### The flag surface: what is accidental and what is not

Measured by diffing `ocaml/lib/cli.ml` against `Profile.known_keys` against
`Types.t`:

| gap | keys | verdict |
|---|---|---|
| CLI-only: modes and seams | `--dump-config`, `--dump-sandbox`, `--no-launch`, `-d`, `--list-ns`, BRANCH, `-E=NAME` | **Stays CLI-only.** These answer "what am I doing right now", not "how is this configured". A file saying `dump=config` makes every launch print and exit. |
| CLI-only: the selector | `-p/--profile` | **Stays CLI-only.** A profile naming a profile recurses. |
| CLI-only: per-run action | `--reseed` | **Stays CLI-only.** Overwriting on seed is a one-shot repair; sticky in a file it silently overwrites a launch HOME on every run. |
| CLI-only: negation | the 18 `--no-*` flags | **Closed by the clearing rule above** for scalars; booleans need no negation, lists keep none by decision. |
| config/profile-only | `token_cmd`, `setenv` | **Accidental. Add `--token-cmd CMD` and `--setenv VAR=value`.** |
| config/profile-only, naming only | `args` | **Not a gap.** The CLI spells it `-- ...`. Leave both spellings. |
| env-only | `CSB_TMPDIR` (`cfg_tmpdir`) | **Accidental. Add a `tmpdir` key and `--tmpdir DIR`,** so the one env-only setting stops being a special case. |

One caveat on `--token-cmd`: a CLI flag puts the command in shell history and in
`ps` argv. It is the command and not the secret, and the emit seam already
carries it unredacted through a private file, so this is a note for the man page
rather than a reason to withhold the flag.

**Explicitly not in scope: a `profile=` key in config.** `[*/work/*] profile=work`
is coherent and probably useful, but it is a layer-2 value selecting layer 3 --
an ordering inversion, and a new feature rather than a symmetry fix. It wants its
own decision.

#### As built -- DONE (2026-08-08)

All three steps landed in one pass. `make check` clean, **143/143 `make test`**
(was 122), **115/115 `make ocaml-test`** (was 94), and the emit-seam drift guard
still byte-identical.

**Step 1 met its gate**: `lib/layer.ml` plus the reshaping of `Profile.t`,
`Cli.t` and `Resolve` ran green at 122/94 with **no test edited and no golden
regenerated**. The 15 axis probes above were re-run afterwards and match the
pre-refactor recordings row for row, which matters because the suite does not
cover every one of those combinations.

Three things the implementation forced, none of them foreseen:

1. **The CLI retracted per KEY where the file layers retract per AXIS** --
   `--no-ns` cancelled a profile's `ns=` but left its `real_home=true` standing,
   while `ephemeral=false` in a file layer wiped the whole axis. The first cut
   preserved that. **Step 4 removed it instead (operator, 2026-08-08):** no test
   pinned the cross-selector case -- both existing tests were same-key -- so the
   granularity was an accident of three interdependent boolean expressions, not
   a decision. See "Step 4" below.
2. **A layer's HOME answer is derived per LAYER, not per line**, exactly as the
   corrected section above specifies -- `Profile.draft` collects the six raw keys
   and `Profile.seal` folds them once, so the existing exclusivity error survives
   unchanged rather than degrading into last-line-wins.
3. **`Env.resolve_tmpdir` had to become `Env.checked_tmpdir ~where`**, since
   CSB_TMPDIR, a `tmpdir=` key and `--tmpdir` now all reach the same validator
   and only the label differs.

**Step 2 was the one-line change the refactor was for**: `Profile.scalar`
returning `Layer.Cleared` instead of `Layer.Unset` for an empty value. Ten tests
cover it, including the operator's scenario end to end and the three controls
(a boolean is retracted by `false`, an empty boolean is still a bad value, an
empty list value does not clear the list).

**Step 3** added `--token-cmd`/`--no-token-cmd`, `--setenv`, and `--tmpdir`/
`--no-tmpdir` with a matching `tmpdir` key. `--setenv` sits at the top of the
setenv stack and dedupes by name like every other layer. Seven tests. The emit
seam and `bin/csb` are untouched: every new surface resolves into a key that
already existed, so the 25 required scalars and 10 list keys are unchanged.

`--help`'s CONFIGURATION section and the README's key list both gained `tmpdir`
and a paragraph on retraction.

Not verified: a real launch, and `nix build` -- **`ocaml/lib/layer.ml` is a new
file, so landmine 11 applies and it must be `git add`ed before the flake can see
it.**

#### Step 4: the CLI collapses onto the same axis -- DONE (2026-08-08)

`--no-ns`, `--no-ephemeral` and `--no-real-home` are **gone**, replaced by one
`--per-repo`, and `Cli.t`'s four HOME fields (`ns`, `ephemeral`,
`ephemeral_name`, `real_home`) are one `home : Types.home_sel Layer.t`. Every
layer now answers the HOME question the same way, which is what step 1 was for
and did not finish.

What it cost, in full: a negation naming a different selector than the layer
below used no longer leaves that selection standing. Nothing became
inexpressible -- the layers below hold at most one selector, so every outcome is
still reachable by naming a positive selector or none -- and no test covered it.
What it removed was three flags that were synonyms in every case except the one
where the difference was a surprise.

What it bought:

- `Resolve`'s HOME block: **35 lines to 7**. `cli_home`, `cancels` and the
  `-E=NAME` re-naming special case are all gone; it is now `Layer.over` and a
  fold to `Per_repo`.
- `Cli.check_exclusive`: **4 dies to 1**. The three HOME exclusivity checks moved
  into `Cli.home_of`, which states the same "two positives is unresolvable" rule
  `Profile.seal` applies to a file layer -- one rule, not two copies.
- `--per-repo` maps to `Layer.Cleared`, so the CLI spells retraction exactly as a
  file layer's empty value does.

Backward compatibility was explicitly waived (operator): csb has one user.
**Anything with `--no-ns`, `--no-ephemeral` or `--no-real-home` in it now fails
with a usage error** -- worth grepping shell aliases for. Positive selectors are
untouched, so an alias like
`csb -p drip --shell --here --no-sandbox --real-home -- script/release` behaves
exactly as before; verified.

Totals after step 4: **143/143 `make test`, 115/115 `make ocaml-test`.**

#### Why before P4

It is pure OCaml plus tests, needs no nix and no launch, and is doable entirely
inside a csb sandbox -- the same properties that let P3 land in one pass. P4
needs a NixOS host and the operator. Doing the cheap one first also means the
config surface is settled before the Linux work starts adding keys to it.

### When it landed -- DONE (2026-08-07)

**Phase B of the csb-config work (section 9), not bash.** Phase A had to
reproduce today's behavior exactly first -- the parity oracle only worked while
the spec was frozen -- and adoption then made `csb-config` the only
implementation. So this was purely additive OCaml: a layer between the built-in
defaults and the profile, plus the section-header parse. It reached the launch
for free, needed no nix and no launch to verify, and was done entirely inside a
csb sandbox. What it cost, and the five decisions it forced, are in the handoff
at the top of this file.

---

## 6. What this keeps that a rebase would have cost

1. **M2 capability** -- the agent runs in the repo's own devShell with its full
   toolchain. This was the rebase's fatal flaw.
2. **The whole flag surface.** A rebase lost `--allow-socket`, `--pasteboard`,
   `--deny-read`, `--paranoid-deny-read`, `--real-home` (sandboxed), `-E=NAME`,
   and changed the meaning of `--paranoid`.
3. **`--dump-sandbox` as an exact-artifact seam.** A rebase degraded it to a
   store `.sb` that the wrapper patches at runtime -- and `CLAUDE.md` points at
   that seam for in-session verification.
4. **The snapshot suite.** 13 tests and 17 goldens survive instead of being
   rewritten against hash-bearing store paths.
5. **No nix on the policy path.** No generated expressions, no `--impure`, no
   per-launch eval, no flake fetch to build a profile.
6. **No license question**, no unreleased-rev pin, no upstream release cadence.
7. **The IPC work.** `--allow-socket`, the broker refusals, and the D9 shared-root
   check are csb-specific and have no upstream equivalent (upstream refuses
   unix-socket egress outright).

---

## 7. What we give up, and the residual risks

1. **The original motivation.** "Stop owning kernel security policy" was the
   whole point of rebasing, and this keeps us owning it -- plus a proxy, plus a
   netns, with no second pair of eyes. Weaker than it sounds: csb already owns
   both policies, has for months, with a measured escape investigation behind
   them. The *marginal* new ownership is the proxy and the Linux netns.
2. **No HTTP-method filtering** and no plaintext inspection (non-MITM).
3. **Domain allowlists are coarse.** Allowing `github.com` allows gists and raw.
   An allowlist raises exfiltration cost; it does not close the channel.
4. **WebFetch is largely amputated, and this is the biggest usability cost.**
   The tool fetches operator- and agent-chosen URLs, which by definition are not
   on a fixed allowlist -- so under egress filtering it works only for listed
   domains. For a research-heavy workflow that is most of its value. The same
   applies to any agent-initiated fetch of documentation, changelogs, or package
   metadata. This was missed in the first several drafts of this plan: the cost
   was framed as lost method/path granularity, when the sharper cost is losing a
   tool in daily use. Mitigations, none free:
   - Per-project `allowed_hosts` (section 5) covers *known* domains, not
     exploratory reading.
   - A wildcard entry (`*`) for a read-only escape hatch defeats the point.
   - Accept it: the agent asks the operator to add a host, which is a real
     workflow tax measured in interruptions.
   **Failure mode MEASURED (2026-08-06).** A denied WebFetch does not report a
   policy denial. curl sees `CONNECT tunnel failed, response 403`; claude's
   client surfaces only `Error: Socket is closed` -- indistinguishable from a
   network fault. Observed sequence: WebFetch fails, the agent retries, fails
   again, shells out to curl to diagnose its own sandbox, then interrupts the
   operator to ask for an allowlist entry. **One fetch cost about four
   exchanges.** Not a blocker; considerably worse than a papercut, because the
   error misattributes policy as flakiness.

   Mitigated, and **the mitigation is measured, not assumed (2026-08-06)**: the
   decision log lives on the launcher's stderr, *outside* the sandbox, so the
   agent cannot read the one artifact that explains its failure.
   `csb-proxy --log-file PATH` adds a second sink (stderr keeps streaming for the
   operator), and a sandboxed agent asked to read that path after a denied fetch
   successfully diagnosed its own denial. **P2 wired it and it is confirmed in the
   real topology:** the log lands in the launch HOME, `CSB_PROXY_LOG` names it in
   the sandbox env, and `cat "$CSB_PROXY_LOG"` from inside shows the ALLOW/DENY
   lines. So the four-exchange sequence above collapses to one step, given the
   one remaining piece:

   - a line in the repo's `CLAUDE.md`: "a transport error on a fetch may be an
     egress denial; check `$CSB_PROXY_LOG`".

   The policy is not secret, so exposing it costs nothing. Note the underlying
   error string is unfixable here -- `Socket is closed` comes from claude's own
   client -- so making the *explanation* reachable is the whole of the available
   remedy.
4. **Linux asymmetry for a while.** macOS gets egress control first. Part 9 warns
   about exactly this drift; the alternative is blocking a cheap win on the
   expensive half.
5. **Still not a boundary against a hostile agent.** Nothing here narrows the
   residuals in `PLAN-007-escape.md` Part 10 except, possibly, the Linux abstract
   sockets (section 4).
6. **Proxy correctness is now ours.** A bug in `CONNECT` parsing or host matching
   is an egress hole. This wants adversarial tests, not just happy-path ones.

---

## 8. Effort and sequencing

- **P1 -- proxy. DONE (2026-08-05).** OCaml CONNECT proxy + allowlist matching +
  port handshake + refusal log; 8/8 in `make test-proxy`. Verified with curl, not
  with claude -- see section 10 item 1.
- **P2 -- macOS wiring. IMPLEMENTED (2026-08-06), one handoff outstanding.**
  `--filter-egress` / `--no-filter-egress` (profile `filter_egress=`),
  `--allow-host HOST` (profile `allow_host=`, plus an add-only
  `$XDG_CONFIG_HOME/csb/allowed-hosts`), `--allow-port PORT` (profile
  `allow_port=`). `start_egress_proxy` runs csb-proxy **outside** the sandbox,
  reads its port off stdout through a FIFO, and the profile's single IP-egress
  rule becomes that port plus any `--allow-port`. Proxy env
  (`HTTPS_PROXY`/`HTTP_PROXY` + lowercase, `NO_PROXY=localhost,127.0.0.1`,
  `CSB_PROXY_LOG`) is injected post-scrub; the decision log lands in the launch
  HOME so the agent can read it; the EXIT trap reaps the proxy and its temp
  allowlist.

  **OFF by default.** Turning it on amputates WebFetch for unlisted hosts
  (section 7 item 4), so it is opted into per run or per profile. Consequence
  worth keeping: the unfiltered profile is byte-identical to before, so the 17
  existing goldens stay valid.

  Fails closed in three places: `--filter-egress` with an empty allowlist is an
  error rather than a total blackhole; a missing csb-proxy is an error naming
  `make ocaml-build`; `--no-sandbox` warns that egress is NOT filtered, because
  the profile is the enforcement and without it `HTTPS_PROXY` is advisory.
  Linux warns and disables itself rather than emitting a loopback-only rule that
  would *look* like filtering while enforcing nothing (P4).

  `--dump-sandbox` emits `localhost:<PROXY_PORT>` -- a placeholder, so the seam
  starts no proxy and stays hermetic and snapshot-able.

  **VERIFIED END-TO-END on aarch64-darwin (2026-08-06)**, from
  `csb -v --shell --here --filter-egress` with the host list in
  `~/.config/csb/allowed-hosts`:

      $ env | grep -i proxy
      HTTPS_PROXY=http://127.0.0.1:57066        (+ lowercase, HTTP_PROXY)
      NO_PROXY=localhost,127.0.0.1              (+ lowercase)
      CSB_PROXY_LOG=~/.csb/claudes/repo-<key>/csb-proxy.log
      $ curl https://api.anthropic.com/                     -> 404
      $ curl https://example.com/                           -> 403 CONNECT tunnel failed
      $ curl --noproxy '*' https://api.anthropic.com/        -> Couldn't connect to server
      $ cat "$CSB_PROXY_LOG"
      [csb-proxy] ALLOW api.anthropic.com:443
      [csb-proxy] DENY host not allowed: example.com

  Four claims, all discharged. The third is the one that matters: **the ALLOWED
  host also fails on a direct dial.** That is the difference between advisory and
  enforced -- the sandbox has no independent egress capability at all, so the
  allowlist is applied at the only reachable endpoint rather than depending on a
  client choosing to honor `HTTPS_PROXY`. A proxy-unaware or hostile client
  reaches nothing. The fourth: the decision log is readable from *inside* the
  sandbox in the real topology, so section 7 item 4's mitigation works where it
  is meant to.

  **One bug this found, worth keeping as a shape.** The env-injection block sat
  above `start_egress_proxy`, so `proxy_port` was empty, the block silently
  skipped, and the result was a *correctly enforced* sandbox with no way to reach
  the proxy and nothing explaining why. A silently isolated sandbox is the same
  failure class `PLAN-007-escape.md` keeps rediscovering: a no-op that reads as
  working code. Fixed by ordering, plus a `die` if the condition ever recurs.
  Note why the suite could not catch it: `--dump-config` covers resolved config
  and `--dump-sandbox` covers the profile, but the `env_overrides` array between
  them is invisible to both. Launch-path ordering is only testable by launching.
  If that class recurs, a third dump seam for the launch environment is the
  answer; once is not enough evidence to add one.

  **Tier-2 goldens: DONE (2026-08-06), generated on both hosts.**
  `darwin/filter-egress` is `darwin/baseline` with line 8 replaced by exactly two
  rules (`localhost:<PROXY_PORT>` and `localhost:5432`) -- the blanket allow is
  *replaced*, not supplemented, so no ordering can let the wildcard win.
  `linux/filter-egress` is byte-identical to `linux/baseline`, and that identity
  is the Linux assertion. The commit was `+72 / -0`: every pre-existing golden
  verified unchanged on both platforms, which is the load-bearing result -- the
  flag adds nothing to any profile when unused.

  **csb-proxy resolution: DONE.** `ocaml/dune-project` defines a `csb-tools`
  package whose `public_names` install as `csb-proxy` and `csb-config`;
  `packages.csb-tools` (`ocamlPackages.buildDunePackage`) exposes it, and csb
  resolves `"$CSB_SELF#csb-tools"` at launch exactly as it resolves `#bwrap` on
  Linux. `CSB_PROXY_BIN` remains the verbatim override for tests and
  working-tree builds, mirroring `CSB_BWRAP_BIN`. In-tree artifact names are
  unchanged, so the Makefile paths still hold, and `--dump-sandbox` still
  resolves nothing (the placeholder keeps that seam nix-free).
- **P3 -- config surface. DONE (2026-08-07).** Layers 2-3 with union semantics
  (section 5), which is Phase B of section 9; see the handoff for what it cost.
- **P3b -- one flag surface, and clearing across layers. DONE (2026-08-08).**
  Four steps:
  unify `Cli.t` and `Profile.t` on one `'a layer` type with the two multi-key
  axes collapsed to single sum-typed fields (behavior-preserving); then an empty
  value clears the layers below (five scalars; booleans and lists unaffected);
  then `--token-cmd`, `--setenv`, and a `tmpdir` key/flag; then the CLI's HOME
  axis collapses onto the same one field, trading three `--no-*` flags for one
  `--per-repo`. Section 5 has the
  decision and the measurements. OCaml and tests only -- no nix, no launch, no
  host.
- **P4 -- Linux netns.** `--unshare-net` + pasta + nftables, plus NixOS
  verification and an F4/abstract-socket re-measurement.

P1+P2 are the cheap, high-value half and are independently shippable. P4 is the
bulk and deserves its own verification pass. P3 can land before or after P2 --
it is orthogonal. P3b landed before P4 because it was sandbox-doable and P4 is
not, and because settling the config surface before the Linux work adds keys to
it was cheaper than the reverse.

---

## 9. The OCaml layer (`csb-config`) -- in progress

Language: **OCaml** (survey in Appendix B). ADTs with exhaustiveness checking,
native compile in seconds, small stdlib, `opam`/`dune` as prior art for exactly
this shape of program. It also gives the proxy a home with no new dependencies.

### Why the config layer goes first

`bin/csb` splits almost exactly into thirds along its own section comments:

    630-1315   deny-list / write policy      686 lines (31%)   <- gains the proxy wiring
    usage 177 + profiles 223 + argparse 317 = 717 (32%)        <- the OCaml win
    latest 28 + git/worktree 375 + modes 356 = 759 (34%)       <- mechanical

The config third is where the type win lives: 76 of 89 tests exist because bash
cannot represent "unset vs set-empty vs explicitly negated". The test oracle is
strongest *now*, against known-good behavior.

### The contract

`csb-config` implements exactly `--dump-config`: a pure function
`(argv, config files, env) -> KEY=VALUE`. No git, no nix, no exec, no writes.
`bin/csb`'s dump block is the whole spec -- **37 keys** in fixed order, booleans
as `true`/`false`, lists joined with `|`, `token_cmd` as `present`/`absent`,
`setenv` as VAR names only. `helpers.bash` confirms it "exits before repo
lookup".

(That reads as of the spec being frozen. Since adoption there is no dump block
in `bin/csb` to be the spec: `csb-config` owns `--dump-config`, and `bin/csb`
passes the flag through. The 37 keys and their order are unchanged; P3 appended
a 38th, `config_sections`.)

Acceptance: `CSB=./csb-config` makes `lists.bats` (10) + `precedence.bats` (36)
plus the 27 dump-config tests in `validation.bats` pass **unchanged** -- 73
tests, none needing nix, a launch, or a repo. That tier runs *inside* a csb
sandbox (`make test` is 99/99 green in one), unlike Tiers 2-3.

**`make ocaml-test` is 73/73 (2026-08-06).** The target selects the oracle by
tag (`--filter-tags '!dump-sandbox'`) across all three files rather than naming
tests, so the 12 `validation.bats` cases that need the sandbox-profile
generator -- which lives in `bin/csb`, not here -- are the only ones excluded.

### Milestone 1 -- VERIFIED (2026-08-05)

Compiles, and byte-identical to bash for the no-args case:

    $ make ocaml-build && diff -u <(./bin/csb --dump-config) \
        <(./ocaml/_build/default/bin/csb_config_cli.exe) && echo IDENTICAL
    IDENTICAL   # 34 lines

`ocaml/` holds `dune-project`, `lib/types.ml` (the ADTs), `lib/dump.ml` (the wire
format), `bin/csb_config_cli.ml`. Driven by `make ocaml-build` / `make
ocaml-test`.

Toolchain as resolved: **ocaml 5.4.1, dune 3.21.1, cmdliner 2.1.1, yojson
3.0.0.** cmdliner is **2.x** -- most examples target 1.x, whose `Term.eval` is
gone; target the `Cmd` API.

**Environment finding, fixed.** `OCAMLPATH` arrives unset in a csb-launched
devShell, so dune could not resolve `cmdliner` ("Library "cmdliner" not found").
The flake now sets it via `lib.makeSearchPath`; confirmed working after relaunch.
Follow-up: when `csb-config` grows a `buildDunePackage` output for the install
story, switch the devShell to `inputsFrom` and drop the explicit path.

Two things the type modeling surfaced immediately:

- **"Neither BRANCH nor --here" is a real third state** (the worktree listing).
  bash spells it as two coincidentally-empty variables; as
  `List_worktrees | Here | Branch of string` it must be named.
- **`--ns NAME` stores its value verbatim** -- `@` normalization happens later in
  `setup_namespace`. Transcribed from `bin/csb:1623`, not inferred from `--help`,
  which describes the normalized form and would have produced a wrong type.

### Milestone 2 -- the parser. cmdliner spike results

Four measured findings against csb's real argv:

| shape | cmdliner 2.1.1 | bash csb | verdict |
|---|---|---|---|
| `-E` bare | `<anon>` via `~vopt` | ephemeral, no name | ok |
| `--ephemeral=work` | `work` | `work` | ok |
| `-E=work` | `=work` | `work` | broken: `=` not stripped for short opts |
| `-E feature/foo` | eph name = `feature/foo`, no branch | eph + `branch=feature/foo` | **breaks a real invocation** |
| `feature/foo -- --model opus` | `rest=[--model,opus]` | same | ok |
| `--deny-read /a --deny-read /b` | accumulates in order | same | ok |

Plus two structural questions, both then measured:

- **Error text: NOT a problem.** `~vopt:(Some "")` makes a bare `--ns` yield
  `Some ""`, so csb's own validation fires with its exact wording; `--ns work`,
  `--ns=work`, `-N work` all parse correctly. cmdliner only generates
  diagnostics for unknown-option and type errors, which csb never asserts on.
  (28 of 30 `validation.bats` tests assert csb's text -- they survive.)
- **Flag-pair ordering: confirmed fatal.** bash is last-wins
  (`--paranoid --no-paranoid` -> `false`, reversed -> `true`). Even `flag_all`
  gives no interleaved order across two options -- both orderings returned
  `paranoid=1 no_paranoid=1`. cmdliner structurally cannot see this.

### DECIDED (2026-08-05): cmdliner, `-E` stays, error-on-both

Both blockers are resolved, and neither costs a feature.

**Ordering: `-X --no-X` in one invocation becomes an error** (operator approved),
joining csb's existing "mutually exclusive" family. That removes the ordering
requirement rather than working around it. The 36 precedence tests are
unaffected -- they assert "CLI `--no-X` beats profile `X=true`", where only one of
the pair is ever on the command line.

**`-E` stays.** Rows 3-4 above are not a cmdliner limitation so much as a
`~vopt` one, and `~vopt` is avoidable. A ~10-line argv pre-pass rewrites the one
flag that has optional-value semantics into two unambiguous internal options --
bare `-E`/`--ephemeral` to a flag, the `=NAME` forms to a distinct valued
option -- so no option ever steals the `BRANCH` positional. Verified against
bash on all six shapes:

| argv | bash | ocaml + pre-pass |
|---|---|---|
| `-E` | `eph=true name= branch=` | identical |
| `-E=work` | `eph=true name=work branch=` | identical |
| `-E feature/foo` | `eph=true name= branch=feature/foo` | identical |
| `--ephemeral` | `eph=true name= branch=` | identical |
| `--ephemeral=work` | `eph=true name=work branch=` | identical |
| `--ephemeral work` | `eph=true name= branch=work` | identical |

Note the last row: bash's `--ephemeral` takes no separate argument, so
`--ephemeral work` means ephemeral plus `branch=work`. A `~vopt` option would
have swallowed `work` as the name. The pre-pass is what preserves this, and it is
the only place csb's grammar needs one.

So cmdliner is taken, for generated `--help` (replacing 177 lines of drift-prone
hand-maintained usage prose -- plan-002 phase 4 already had to re-audit it),
shell completion (csb has none today), and man pages. The hand-written
HOME-choice explainer survives as a `~man` `S_DESCRIPTION` block. The dump
contract stays at 37 keys; no goldens churn.

### Milestone 2 -- BUILT (2026-08-06). 73/73.

`lib/{err,env,lines,validate,profile,cli,resolve}.ml`, ~700 lines, driving
`make ocaml-test` from 12/46 to 73/73 with **no test file's assertions
touched** (the only edit to `test/` was a `# bats test_tags=dump-sandbox`
line above the 12 tests that need the profile generator).

The layering that came out of it, and it is the part worth keeping: three
partial layers -- `Env.t`, `Profile.t`, `Cli.t` -- fold into the one
`Types.t`. Only `Types.t` makes invalid states unrepresentable; the layers
above it are deliberately full of `option`, because "the operator did not
say" is the distinction the whole precedence chain is made of. `Cli.t` spells
it as `'a option` for a flag pair and `Untouched | Cleared | Set of 'a` for a
valued option with a `--no-` reset -- which is exactly bash's `$x` plus
`$x_cli`, minus the chance of reading one without the other.

Four decisions the tests forced, none of them anticipated by the spike:

1. **The argv pre-pass got a second job.** Splitting at `--` cannot be left to
   cmdliner (it folds the tail into the `BRANCH` positional and forgets where
   the separator was), so the pre-pass owns both that and `-E=NAME`. Splitting
   naively at the first `--` breaks `--accent --`, which bash accepts as a
   value; the pre-pass therefore skips the token after a value-taking option,
   the same way bash's `shift 2` does.
2. **Optional values are modelled, not sentinelled.** `Arg.opt ~vopt:(Some
   None) (some (some string))` gives `string option option`: `None` absent,
   `Some None` named with no value, `Some (Some v)` valued. That third state is
   what lets csb's own "`--nix-target` requires a NAME" fire instead of
   cmdliner's phrasing, with no magic string standing in for "missing".
3. **cmdliner's own diagnostics needed unstyling** -- landmine 10.
4. **Two more `mutually exclusive` cases**, both extending the operator-approved
   error-on-both rule to pairs the spike did not enumerate: `--nix-target` with
   `--no-nix-target`, and `-d/--delete` with `--list-ns` (bash is last-wins on
   both, which cmdliner cannot see).

**Checked by differential sweep, not by inspection.** 41 argv/profile/env
shapes were run through both binaries against one isolated HOME and diffed,
including all six `-E` rows above, three-source list accumulation, and eleven
die paths. Every output matched but for `basename $0` in the message prefix --
and one case the bats suite does not reach, which is how it was found.

Three known divergences from bash, all supersets or dead corners, none covered
by a test:

- **A value that looks like an option.** `--accent --` sets the accent to `--`
  in bash; cmdliner applies its own end-of-options rule first and reports
  "`--accent` requires a COLOR". The same shape covers `--deny-read --foo` and
  friends. Both implementations exit 1 naming the same flag in every such case,
  which is why the pre-pass does not canonicalize short options to
  `--opt=value` to close it: no *valid* csb value begins with `-`, so the only
  reachable difference is the wording of an error.
- `--opt=value` is accepted for every valued option; bash accepts it only for
  `-E=`/`--ephemeral=` and calls the rest an unknown option.
- `allow_port` is an `int`, so a leading-zero port dumps normalized (`0080` ->
  `80`) where bash echoes it back verbatim.

(`-V` was a fourth until it was dropped from `bin/csb`; the two now agree on
`--version` alone.)

### Phases

- **A: DONE (2026-08-06).** Reproduce today exactly; 73 tests pass unchanged.
- **Adoption: DONE (2026-08-06).** `bin/csb` delegates; the bash resolution path
  and the parity tier are deleted. The contract is in the handoff at the top of
  this file -- read that, not this paragraph, before touching either side.
- **B: DONE (2026-08-07).** Config layers 2-3 with union-for-lists (section 5),
  additive as predicted: `Resolve` took a stacked `Profile.t` in place of an
  optional one and no precedence rule changed.
- **C:** revisit `-p` after real use.

Adoption was strangler-fig and came out close to the sketch: `bin/csb` runs
`csb-config` over its own argv and reads `KEY=VALUE` back, parsed and never
`eval`ed, keeping git/nix/exec in bash. Two things the sketch got wrong.
NUL-termination turned out to be right for *every* key rather than only the
list-valued ones -- one framing for the whole stream is simpler than two, and it
costs nothing. And `yojson` was never needed: repeating a list key once per
element is enough structure for a flat record set, so the dependency went unused
and the seam has no parser on either side.

---

## 9a. Approach validation (2026-08-06) -- the blocking questions are answered

Before P2, the two questions that could have invalidated the whole approach were
"does claude use an HTTP proxy at all" and "which hosts does it need". Both are
now settled from Anthropic's own documentation
(<https://code.claude.com/docs/en/network-config>), plus empirical proxy runs.

### Claude Code supports exactly this proxy shape

> "Claude Code respects standard proxy environment variables."
> "Lowercase variants also work, and Claude Code uses the first one that's set in
> the order `https_proxy`, `HTTPS_PROXY`, `http_proxy`, `HTTP_PROXY`."
> "Claude Code does not support SOCKS proxies."

An `HTTP_PROXY`-style CONNECT proxy is the supported configuration; SOCKS -- which
we were never going to build -- is the unsupported one. The proxy URL is also
**validated at startup**: an unparseable value stops launch naming the variable,
so a misconfiguration fails loudly rather than silently going direct.

Verification path for a real session, straight from the docs: `/status` shows a
**Proxy** row with the active URL (and marks an unparseable one as ignored), and
`claude --debug` writes to `~/.claude/debug/<session-id>.txt`.

### The MITM decision is further confirmed

The docs describe a whole configuration surface that exists only to make TLS
interception work: `NODE_EXTRA_CA_CERTS`, `CLAUDE_CODE_CERT_STORE`
(`bundled,system` by default), and mTLS client cert/key/passphrase variables.
Non-MITM means csb touches **none** of it. Enterprise TLS-inspection proxies are
documented as needing their root CA in the OS trust store; we avoid that entirely.

### Empirically validated against the real endpoints

All eight relevant documented hosts tunnel, with every status coming from the
host rather than the proxy, and zero DENY entries:

    api.anthropic.com 404   claude.ai 403      claude.com 200
    platform.claude.com 200 downloads.claude.ai 403
    storage.googleapis.com 400  raw.githubusercontent.com 301  code.claude.com 302

    POST https://api.anthropic.com/v1/messages -> 401   # full TLS+HTTP round trip

Byte integrity and concurrency are now regression tests (10/10 in
`make test-proxy`): a 334 KB transfer through the tunnel is `cmp`-identical to a
direct fetch and completes in ~0.1s, and 8 simultaneous tunnels all succeed.

### An evidence-based default allowlist

Derived from the docs' "Network access requirements" table rather than guessed:

| host | why | needed by csb? |
|---|---|---|
| `api.anthropic.com` | API requests, WebFetch safety check, feature flags | **required** |
| `platform.claude.com` | OAuth token exchange/refresh/revocation | **required** -- see below |
| `claude.ai` | claude.ai account auth | required with `--seed-creds` |
| `code.claude.com` | doc lookups (claude-code-guide, pre-approved WebFetch) | recommended |
| `claude.com` | sign-in redirect; pre-approved doc lookups | recommended |
| `raw.githubusercontent.com` | `/release-notes` changelog | optional |
| `storage.googleapis.com` | plugin metadata, artifact upload | optional |
| `downloads.claude.ai` | native installer/auto-updater | **droppable** -- csb pins claude via nix |
| `mcp-proxy.anthropic.com` | claude.ai MCP connectors | droppable via `ENABLE_CLAUDEAI_MCP_SERVERS=false` |
| `*.datadoghq.com` (2 hosts) | optional telemetry / error reports | droppable via `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` |
| `formulae.brew.sh`, `registry.npmjs.org` | homebrew / npm installs | not applicable (nix install) |
| `bridge.claudeusercontent.com` | Claude in Chrome | not applicable |

**The non-obvious one:** `platform.claude.com` is required *even for claude.ai
sign-ins*, because OAuth token exchange and refresh go there. csb authenticates
with `CLAUDE_CODE_OAUTH_TOKEN`, which needs refresh -- so omitting this host
would produce a session that works until the token expires and then fails in a
confusing way. Exactly the class of bug an evidence-based list prevents.

Minimum viable pair: `api.anthropic.com` + `platform.claude.com`.

### Two design consequences

- **`NO_PROXY` must exempt loopback.** With `HTTPS_PROXY` set, an HTTP client
  reaching an `allowed_ports` service (a dev server on `localhost:3000`) would be
  routed to the proxy and refused. Set
  `NO_PROXY=localhost,127.0.0.1` so loopback bypasses it; seatbelt still governs
  which ports are reachable, so this loosens nothing. Non-HTTP clients (postgres,
  redis) never read the variable and are unaffected.
- **The proxy must not buffer.** Claude runs a byte-level streaming watchdog that
  aborts a response after 180s of no bytes on the direct API, counting SSE
  keep-alive pings. The current unbuffered 64 KB read/write pump satisfies this;
  any future change that adds a buffering layer would break long, quiet streams.

The list ships as `templates/allowed-hosts` and is what `make proxy-run` serves.
Transitional: it becomes the built-in default (config layer 1) once csb-config
owns config resolution.

**Invariant worth stating, because violating it is silent:** the proxy's stdout
carries *only* the port. Anything else a launcher reads as the port and then
fails with a nonsense proxy URL -- which is exactly what happened when
`make ocaml-build`'s progress echoes went to stdout and `make proxy-run`
inherited them. Build and status output belongs on stderr; stdout is the
handshake channel.

### Real-session result (2026-08-06) -- CONFIRMED

An interactive claude session was run with `HTTPS_PROXY` pointed at
`make proxy-run`. The proxy log shows fourteen `ALLOW api.anthropic.com:443`
entries: **claude's client honors `HTTPS_PROXY` and its real API traffic,
streaming included, goes through the tunnel.** The blocking question is closed.

Four hosts were attempted and denied, all of them ones this plan had predicted
droppable:

| denied host | predicted? | outcome |
|---|---|---|
| `http-intake.logs.us5.datadoghq.com` | yes, telemetry | harmless |
| `mcp.us5.datadoghq.com` | **no -- undocumented** | harmless |
| `downloads.claude.ai` | yes, updater | **user-visible error banner** |
| `mcp-proxy.anthropic.com` | yes, MCP connectors | breaks claude.ai connectors |

Three findings worth keeping:

1. **`mcp.us5.datadoghq.com` is absent from Anthropic's documented host table.**
   The docs list two datadoghq hosts; this is a third. The documented list is
   therefore necessary but not sufficient, which is the retroactive justification
   for running this empirically instead of trusting the table.
2. **A denied host can surface as a user-facing error.** Denying
   `downloads.claude.ai` produces a persistent
   `"Auto-update failed - Run claude doctor"` banner. Functionally harmless -- csb
   pins claude via nix, so a successful update would target a read-only store
   path -- but a false alarm that teaches the operator to ignore real errors.
   **The fix is to stop claude attempting it, not to allow the host:**
   `DISABLE_AUTOUPDATER=1`. Confirmed live in the installed binary
   (`grep -ac DISABLE_AUTOUPDATER` on `.claude-unwrapped` -> 11), alongside the
   `autoUpdates` settings key.
3. **The allowlist and its companion env are one unit.** A tight list without
   `DISABLE_AUTOUPDATER` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` /
   `ENABLE_CLAUDEAI_MCP_SERVERS=false` produces exactly the noise above. These
   belong in the shipped defaults as `setenv=` entries when config layers land
   (section 5), not as operator folklore.

`mcp-proxy.anthropic.com` is an operator decision, not a technical one:
claude.ai-hosted connectors (`mcp__claude_ai_*` tools) route through it, so
denying it disables them. Left commented in `templates/allowed-hosts`.

Two things this run did NOT establish:

- **`platform.claude.com` was never contacted**, so its "required" status is
  untested -- the token did not need refreshing. Not disproven; it would surface
  at expiry as a session that works and then stops. Keep it listed.
- **Enforcement.** Traffic used the proxy because `HTTPS_PROXY` was set, not
  because anything forced it. That is P2.

### The remaining gap: enforcement

The docs say claude honors the proxy and the run above confirms it, but nothing
yet *compels* it.

One run, two terminals, no csb changes needed:

    # terminal 1 -- port is the first stdout line, decisions stream on stderr
    make proxy-run

    # terminal 2, with the port from above
    export HTTPS_PROXY="http://127.0.0.1:$PORT" NO_PROXY=localhost,127.0.0.1
    curl -sS -x "$HTTPS_PROXY" -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/  # 404 = healthy
    curl -sS -x "$HTTPS_PROXY" https://example.com/                                          # 403 = enforcing
    claude --debug

In the session: `/status` must show the **Proxy** row with that URL -- if it is
absent or marked invalid, claude is not using the proxy and nothing else matters.
Then exercise the network (any prompt hits `api.anthropic.com`; a WebFetch and
`/release-notes` reach the optional hosts) and watch terminal 1. **Every `DENY`
line names a host the allowlist is missing** -- that is the run doing its job, not
failing. Add it and restart (the file is read once, at startup).

Run it unsandboxed first: it isolates "does claude honor the proxy" from every
csb variable. The integration check afterwards is one line, since csb scrubs the
environment:

    HTTPS_PROXY="http://127.0.0.1:$PORT" NO_PROXY=localhost,127.0.0.1 \
      csb --here -k HTTPS_PROXY -k NO_PROXY

That works today, before P2, because the current profile still permits all egress
including loopback. What it does **not** prove is enforcement -- nothing stops
claude going direct if it chose to. Enforcement is what P2 adds by pinning the
profile to the proxy port, and the post-P2 check is that
`curl https://example.com` from inside the sandbox fails at the *network* layer
rather than returning the proxy's 403.

If claude hangs instead of erroring, read terminal 1 first: a refused CONNECT
surfaces as a client-side error some libraries retry quietly, so the proxy log is
the source of truth. `claude --debug` writes the client's own view to
`~/.claude/debug/<session-id>.txt`.

---

## 10. Open questions, each with the command that answers it

1. **Proxy under real claude -- LARGELY ANSWERED, see section 9a.** Claude Code
   documents support for `HTTPS_PROXY`-style CONNECT proxies, and all the
   documented hosts tunnel correctly. Residual: one confirmation run showing the
   `/status` Proxy row populated and an empty refusal log.
2. **Which hosts does claude need -- ANSWERED.** Documented, not guessed; the
   evidence-based default allowlist is in section 9a.
3. **Does DNS actually need to be denied, or merely unused?** The proxy resolves,
   so the sandbox needs no DNS. Whether removing the `mDNSResponder` allows breaks
   anything unrelated (git, tooling) is unmeasured -- keep them until P2 is
   working, then remove and re-run `make test-proxy` plus a real session.
4. **Linux F4 re-measure.** `bats test/escape/escape.bats` on NixOS with
   `--unshare-net`, to see whether the abstract-socket residual closes.
5. **Does anything legitimate need plain HTTP?** Section 2 refuses non-CONNECT
   requests outright. Verify against a real session before committing to it.

Resolved: `-E` stays and error-on-both is approved (section 9); proxy support and
the host list are settled (section 9a).

---

## Appendix A -- the agent-sandbox evaluation (decision record)

Compressed; the full evaluation is in this file's git history. Retained because
these are the findings that produced section 0.

### A.1 The license clause

Upstream `LICENSE` is MIT plus: the Software "may not be accessed, used, copied,
modified ... or otherwise interacted with, in whole or in part, by any artificial
intelligence (AI) system, machine learning model, or automated agent, including
... code generation", and violation "automatically terminates the permissions
granted".

    $ curl -sS https://raw.githubusercontent.com/archie-judd/agent-sandbox.nix/HEAD/LICENSE

It lands three times: the rebase would be agent-authored; csb's *product* is an
agent exec'ing that wrapper every launch; and csb is MIT, so users would inherit
the second reading. `PLAN-001.md` logged it as "worth a quick legal glance, not a
blocker", which predates both the agent-authored workflow and the runtime
reading.

**Operator decision (2026-08-05): accepted as a personal-use risk; csb stays
private and unredistributed; implications deferred.** Consequence recorded in
`docs/TODO.md`: `CSB_SELF` now defaults to the private remote and the README's
publication claims were removed. The clause no longer gates anything, but it is
why section 2 says write the proxy from the spec rather than from their Go.

### A.2 Upstream, measured

124 stars, 15 forks, 6 contributors of whom one holds 262 of ~274 commits,
created 2026-03-03. `allowedLocalPorts` landed 2026-07-10 (PR #68) and is still
absent from the CHANGELOG (last release 2.2.1, 2026-07-13). More eyeballs than
csb has; not a widely-vetted dependency. The honest argument for adopting was
never crowd review -- it was "stop owning kernel policy".

Worth recording: their profile independently reaches several conclusions csb
reached the hard way -- `kern.procargs2` denial, per-tty pty pinning, refusing
`/dev/tty`, git hooks/config write denial, excluding `/System/Volumes` and
`/private/var/folders`. Two implementations converging on the same non-obvious
rules is evidence for both.

### A.3 Why it was removed in the first place (plan-002), and what changed

plan-002 decision 5 made open network a requirement (local db/redis) and killed
`allowedDomains` with it. That was correct then: csb's locked rev was `48ba13c`
(2026-06-16), whose README states host loopback is "blocked unconditionally on
both platforms ... If you have a use case that requires reaching a specific
host-local service, please open an issue". `allowedLocalPorts` landed 2026-07-10
-- **two days after csb removed the dependency** (2026-07-08). So the specific
blocker was real and has since been fixed upstream. The broader "too restrictive"
objections (Q2, Q3) were not.

### A.4 How its filtering actually works

Not a kernel hostname filter -- a userspace proxy plus total egress denial:

- **macOS:** no `(allow network*)`. One runtime-patched rule,
  `(allow network-outbound (remote ip "localhost:$_PROXY_PORT"))`. The proxy
  starts before `sandbox-exec` (that branch drops `exec` so the wrapper survives
  to `kill $_PROXY_PID`). DNS is dead inside -- the `mDNSResponder` re-allow that
  open mode needs is deliberately absent in filtered mode.
- **Linux:** `pasta -4 --config-net` provides a netns-local network; nftables
  OUTPUT default-drop with one `accept` for `tcp dport $SANDBOX_PROXY_PORT` to
  gateway `10.0.2.2`.

This is the design section 2-4 adopts. Nothing about it was ever unavailable to
csb -- `PLAN-003.md` concluded a hostname allowlist needed a VM because "seatbelt
filters network by ip/port only", which is a non-sequitur: ip/port is sufficient
when the only reachable port is your own proxy.

### A.5 Q1 -- eval-time config

Every knob is a nix function argument; the allowlist is a `writeText`
(`lib/shared.nix:34-48`); the `.sb` is a `runCommand`
(`lib/darwin/default.nix:477`). Only CWD, GIT_DIR, tty, HOME and the proxy port
arrive at runtime via `sandbox-exec -D`. Per-project config therefore required
generating a nix expression per launch (`nix build --impure --expr`, no flake, so
no git-tracking problem) with a JSON handoff to avoid owning nix quoting.
**Moot under section 0** -- csb generates policy at runtime.

### A.6 Q2 -- the exec closure (the decisive finding)

    lib/darwin/default.nix:327   closurePathsFile = pkgs.writeClosure (allowedPackages ++ ...)
    lib/darwin/default.nix:492     echo "(allow process-exec (subpath \"$storePath\"))"
    lib/darwin/seatbelt-profile.nix:167   (allow file-read* (subpath "/nix/store"))   # read, not exec

Nesting inside a devShell yields `EPERM` on exec for every tool not in the
declared closure. Not fixable by binding paths -- the block is on `process-exec`
of a store path. And `allowNix` bundles the whole-store exec grant *and* the nix
daemon socket into one argument (`lib/darwin/default.nix:435-443`), so the cheap
fix reopens F3. See section 0.

### A.7 Q3 -- the HOME model

`REAL_HOME="$HOME"; SANDBOX_HOME=$(mktemp -d /private/tmp/sandbox-home.XXXXXX)`
is unconditional (`:532`), with `rm -rf` in the exit trap. Binds under the real
HOME are symlinked into `SANDBOX_HOME` at the same *relative* path
(`mkSymlinkHomeMappingStr`), so `$HOME`-relative lookups resolve through.
Consequences:

- `-E` is its default and only mode -- so dropping `-E` would have cost the
  rebase nothing.
- Per-repo and `@NAME` homes both port as **one `rwDirs` entry plus
  `CLAUDE_CONFIG_DIR`**, differing only in path. Named homes were never the
  problem.
- **The casualty is HOME as the persistence boundary.** Today everything written
  to HOME survives; there, only declared binds do, so `~/.cache`,
  `~/.local/state`, and every tool cache evaporate unless enumerated. Cold caches
  every launch until the list is built.
- Binds **fail closed** (`assertBindsExistBashStr`: "declared as rwDir but does
  not exist", exit 1; deliberately no `mkdir`).
- `--real-home` is unexpressible, but survives where it is used -- paired with
  `--no-sandbox`, which never enters the wrapper.
- Cross-namespace scoping is **parity, not a win**: csb already denies the
  `~/.csb/claudes` parent and re-allows only the active namespace.

Caveat on reading dumps: `--dump-sandbox` run from *inside* csb shows doubled
paths (`.../repo-<key>/.csb/claudes/repo-<key>`) because `$HOME` is already
redirected. Artifact of nesting. `PLAN-001.md`'s note about a "fixed
`~/.csb/claudes` parent bind" is stale for the same reason -- it described the
agent-sandbox-era design.

### A.8 What a rebase would have cost the flag surface

Of ~33 user-visible knobs: ~25 survive untouched; `--paranoid` becomes the only
mode (collapsing `--deny-read` and `--paranoid-deny-read`, which have no target
under deny-default); `--allow-socket` is lost (upstream refuses unix-socket
egress by design); `--pasteboard` is lost (hardcoded `mach-lookup` list);
`--real-home` and `-E=NAME` are lost for sandboxed runs; `--dump-sandbox` is
degraded. Test impact: ~55-65 of the 76 Tier-1 config tests port; the 13
snapshots and 17 goldens mostly die; the 12 escape/usable tests port and would
have improved.

The one genuine security improvement a rebase offered, beyond egress: reads flip
from deny-list to allowlist, deleting plan-002's standing "blacklist
completeness" residual. `--paranoid` already approximates this.

---

## Appendix B -- implementation language survey (decision record)

Chosen: **OCaml** (section 9). The survey, retained for the reasoning.

**Where a typed language pays, and it is one place:** config resolution is 76 of
89 tests, because bash cannot represent "unset vs set-empty vs explicitly
negated" -- every `--no-*` flag, profile layer and accumulating list is
hand-rolled tri-state. Mutually exclusive groups (`--help` calls `-N`/`-E`/
`--real-home` "three MUTUALLY-EXCLUSIVE answers to one question") become
unconstructible as a sum type. `canon_path` exists only because GNU
`realpath -m` is not portable. And `CLAUDE.md` asks for pure functions and
immutability, which bash is maximally hostile to.

**The enabling fact:** `test/helpers.bash:4-5` -- every test runs the real
`bin/csb` as a subprocess via `--dump-config`/`--dump-sandbox`. Nothing tests
internals, so a port keeps its full safety net and can be *verified* rather than
trusted.

**Candidates.**

- **OCaml -- chosen.** ADTs with exhaustiveness checking, native compile in
  seconds, small stdlib, direct `Unix` module (which the proxy needs), trivial
  nix packaging via dune, and `opam`/`dune` as prior art for parse-config-and-
  orchestrate-subprocesses. Weak at cross-compilation, which does not matter --
  nix builds per-platform on each host.
- **Go** -- static binary, best-in-class cross-compile, stdlib exec/JSON, no
  runtime deps; but no real sum types, so the unrepresentable-states win is
  partial.
- **Rust** -- fully delivers the type goal; compile times and heavier packaging
  for a program that mostly shells out.
- **Haskell** -- the best *type* fit and the worst *program* fit. The config
  layer is literally a monoid (`mconcat` over `Last` fields; HKD makes
  `Config Maybe -> Config Identity` a type), but ~2/3 of csb is IO
  orchestration, the GHC closure is multi-GB, static linking on darwin is not
  supported, and advanced-extension Haskell is where agent assistance is least
  reliable -- relevant for a repo whose implementer is claude.
- **Python** -- runtime dep, no type leverage. Reject.
- **Nickel** -- purpose-built merge-with-priority semantics, which is exactly the
  section 5 problem; worth revisiting for the config *file* if the hand-rolled
  layering gets unwieldy.
- **Nix as the config language** -- rejected: it makes `--dump-config` require a
  nix eval, and 89 nix evals is a suite nobody runs.

**The astronaut trap, named so it can be avoided.** csb parses config and execs
subprocesses. Any of these languages tempts an effect-system DSL for "run a
subprocess", which buys nothing and violates `CLAUDE.md` on unexpected
complexity. The type win is real but *local*: config resolution and flag
validity, nowhere else.

**One claim retired:** section 9's spike showed the arg *parser* was never the
OCaml selling point. The ADTs and the merge monoid are.
