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

## Handoff (written 2026-08-06, for a fresh context)

Read this, then section 0, then section 9. Sections 1-8 are the design; the
appendices are decision record and can be skipped until something questions the
decision itself.

### Where the work stands

| piece | state |
|---|---|
| P1 -- `csb-proxy` (CONNECT allowlist proxy, OCaml) | **DONE**, 11/11 in `make test-proxy` |
| P2 -- macOS wiring (`--filter-egress`) | **DONE**, verified end-to-end on aarch64-darwin; goldens on both platforms |
| `packages.csb-tools` flake output | **DONE**; an installed csb resolves csb-proxy with no PATH dependency |
| `csb-config` milestone 1 (default config parity) | **DONE**, byte-identical to bash |
| `csb-config` milestone 2 (the parser) | **NEXT. Not started.** |
| P3 -- layered INI config, union-for-lists | designed (section 5), not started |
| P4 -- Linux netns so `--filter-egress` enforces there | not started; the big one |

### The expected numbers -- run these first to detect drift

    make check          # shellcheck clean
    make test           # 99 ok   (Tier 1+2; snapshots SKIP inside csb, by design)
    make test-proxy     # 11 ok   (needs network for 2 of them; rest are offline)
    make ocaml-test     # 12 ok / 34 not ok  -- EXPECTED, this is the Phase A scoreboard
    diff <(./bin/csb --dump-config) <(./ocaml/_build/default/bin/csb_config_cli.exe)
                        # must be empty: 37 keys, byte-identical

If `make test` is not 99 or the parity diff is non-empty, something regressed --
fix that before starting anything new.

### The immediate next task

Write `csb-config`'s parser so `make ocaml-test` goes 12/46 -> 46/46. Everything
needed is decided and spiked; see section 9 for the evidence.

- **cmdliner 2.x** (`Cmd` API -- `Term.eval` is gone), plus a ~10-line argv
  pre-pass for the one flag with optional-value semantics (`-E` / `-E=NAME`),
  because `~vopt` steals the `BRANCH` positional. Six argv shapes are tabulated
  in section 9 with bash's exact answers -- match them.
- **`-X --no-X` in one invocation is an ERROR** (operator-approved), not
  last-wins. That is what makes cmdliner viable at all: it cannot see
  cross-option ordering.
- The 12 currently-passing tests are the ones whose expectation equals the
  default config. They are free; do not read them as progress.
- `validation.bats`'s ~21 dump-config tests join `make ocaml-test` once the
  parser can produce csb's die messages. **28 of 30 validation tests assert
  csb's exact error text** -- reproduce the strings, do not invent them.
- The three P2 keys (`filter_egress`, `allow_host`, `allow_port`) exist in the
  OCaml types but only as defaults; the parser must populate them, including
  list accumulation across config file + profile + CLI (bash order is
  CLI-first: see `--dump-config` with all three sources set).

This task is fully doable in-session: 46 black-box tests, no nix, no launch, no
operator handoff. That is unusual here -- prefer it over work that needs the host.

### What cannot be done from inside a csb sandbox

`CSB_SANDBOX=true` in the environment means all of this needs the operator:

- **`nix` is absent.** No flake builds, no `nix eval`.
- **Tier-2 snapshots skip** (`test/helpers.bash:195`, and D1 in
  `PLAN-007-escape.md` is why: goldens made in here are wrong AND compare equal).
  Regeneration is `make test-update` from a normal terminal, on both platforms.
- **No real launch** -- sandbox-exec cannot nest, so `make test-escape` and any
  end-to-end `--filter-egress` check are host-side.
- Network egress DOES work in here, which is why `make test-proxy` is meaningful.

### Landmines, all of which cost a round-trip this session

1. **Wrap an error only by ADDING context, never replacing it.** Cost three
   round-trips: `Socket is closed` masking a 403; the proxy log living outside
   the sandbox; and worst, my own handler swallowing nix's stderr, which hid
   `path '/Users/atongen/src' is a symlink` for a full turn.
2. **Do not wrap `run` around a bats helper that already calls `run`**
   (`dump_config`, `dump_sandbox` both do). It silently swallows exit status.
   Call them bare, like the rest of the suite.
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
sandbox (`make test` is 99/99 green in one), unlike Tiers 2-3.

**Baseline: `make ocaml-test` is 12/46 (2026-08-06.)** The target currently runs
`precedence.bats` + `lists.bats`; `validation.bats`'s dump-config subset joins it
once the parser exists to produce csb's die messages. The 12 passing are exactly
the cases whose expectation equals the default config, so they are what a stub
cannot get wrong -- not evidence of correctness. Driving 46/46 is Phase A, and
the number is the progress metric.

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
