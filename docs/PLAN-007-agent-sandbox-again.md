# plan 007-again -- csb's own egress control (allowed hosts + allowed ports)

Status: **DECIDED (2026-08-05) -- build it in csb, do not rebase on
agent-sandbox.nix.** The filename is historical: this started as a feasibility
study for rebasing csb on
[agent-sandbox.nix](https://github.com/archie-judd/agent-sandbox.nix) and ended
by rejecting it. That evaluation is retained as Appendix A because it is the
reason for the decision, and because it is the file `flake.nix`, `Makefile`, and
`ocaml/bin/csb_config_cli.ml` point at.

Verified against upstream `HEAD` and against `bin/csb` on 2026-08-05.

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

    1. built-in defaults
    2. global      ~/.config/csb/config   [global] section
    3. per-repo    ~/.config/csb/config   [<repo>] section
    4. profile     -p NAME (+ NAME.local), optional
    5. env         CSB_LATEST / CSB_VERBOSE / CSB_TMPDIR
    6. CLI flags

Union for lists is not new: the five list flags already accumulate across CLI and
profile today. The exact env-vs-profile ordering must be transcribed from the 36
precedence tests, not re-derived.

Operator's chosen shape: **one INI-style file, `~/.config/csb/config`**:

    [global]
    allowed_hosts = api.anthropic.com, *.githubusercontent.com
    allowed_ports = 5432

    [/Volumes/src/git.grandrew.com/atongen/csb]
    allowed_ports = 6379

A section header is either an absolute path (`~` expanded, resolved to the same
physical main-checkout root `repo_key` uses at `bin/csb:276`, so any path into a
repo matches its section) or a literal `repo-<key>`. Paths are readable;
`repo_key` survives a repo move. Accept both.

The value grammar is the one `~/.config/csb/profiles/NAME` already uses --
`KEY=VALUE`, `#` comments, blanks ignored -- so **one parser serves profiles and
this file**, differing only in section headers.

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

### When it lands

**Phase B of the csb-config work (section 9), not bash.** Phase A must first
reproduce today's behavior exactly -- the parity oracle only works while the spec
is frozen. Doing this in bash means writing tri-state plus union semantics twice
and rewriting the precedence tests twice.

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
- **P2 -- macOS wiring.** Pin line 8 to the proxy port, `allowed_ports` rules,
  proxy env, `--dump-sandbox` updates, snapshot regen.
- **P3 -- config surface.** Layers 2-3 with union semantics (section 5), which is
  Phase B of section 9.
- **P4 -- Linux netns.** `--unshare-net` + pasta + nftables, plus NixOS
  verification and an F4/abstract-socket re-measurement.

P1+P2 are the cheap, high-value half and are independently shippable. P4 is the
bulk and deserves its own verification pass. P3 can land before or after P2 --
it is orthogonal.

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
`bin/csb:1799-1844` is the whole spec -- **34 keys** in fixed order, booleans as
`true`/`false`, lists joined with `|`, `token_cmd` as `present`/`absent`,
`setenv` as VAR names only. `helpers.bash` confirms it "exits before repo
lookup".

Acceptance: `CSB=./csb-config` makes `lists.bats` (10) + `precedence.bats` (36)
plus the ~21 dump-config tests in `validation.bats` pass **unchanged** -- ~67
tests, none needing nix, a launch, or a repo. That tier runs *inside* a csb
sandbox (`make test` is 89/89 green in one), unlike Tiers 2-3.

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
contract stays at 34 keys; no goldens churn.

### Phases

- **A:** reproduce today exactly; ~67 tests pass unchanged.
- **B:** add config layers 2-3 with union-for-lists (section 5). Additive.
- **C:** revisit `-p` after real use.

Adoption is strangler-fig: `bin/csb` shells out to `csb-config` and reads the
resolved values back, keeping git/nix/exec in bash. Read `KEY=VALUE` with a
plain `while IFS='=' read -r k v` loop -- **do not `eval` the child's output** --
and use a NUL-delimited form for list-valued keys, since csb already handles
paths with spaces. `yojson` stays for that seam; nix never sees it.

---

## 10. Open questions, each with the command that answers it

1. **Proxy under real claude.** P1 proves the *tunnel* works -- curl completes a
   real TLS round-trip through it. What is NOT proven: that claude's Node client
   honors `HTTPS_PROXY` for its API calls and its own fetches, and that it copes
   with DNS being unavailable. Node does not read `HTTPS_PROXY` natively -- it
   depends on what the client library does -- so this is the one remaining
   behavior that could invalidate the approach. Run a real session with the proxy
   in front and an allow-nothing list, then read the refusal log (which also
   answers item 2).
2. **Which hosts does claude actually need?** Capture from the refusal log with
   an allow-nothing list, then build the default from evidence rather than
   guessing.
3. **Linux F4 re-measure.** `bats test/escape/escape.bats` on NixOS with
   `--unshare-net`, to see whether the abstract-socket residual closes.
4. **Does anything legitimate need plain HTTP?** Section 2 refuses non-CONNECT
   requests outright. Verify against a real session before committing to it.

Resolved: `-E` stays and error-on-both is approved (section 9).

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
