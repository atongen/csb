# plan 008-loopback -- `--allow-loopback`, a private Linux loopback, and the proxy leak

Status: **`--allow-loopback` SHIPPED (981a949) and VERIFIED on BOTH platforms.
The leak fix (an ownership-stamp janitor, run at every launch and as `--reap` --
section 6) is SHIPPED and VERIFIED END-TO-END on both hosts. Every tier is green
on both: macOS 163/163 + 13/13, NixOS 163/163 + 119/119 + 13/13.**

**The NixOS pass (2026-08-12) closed every handoff step and found four defects
-- section 8 -- plus a fifth while fixing them. All five are LANDED and VERIFIED
on NixOS (section 9), and NONE is verified on macOS yet. They were: the PPID-1
discriminator defeated by `systemd --user` as a subreaper; `make test-escape`
unable to finish unattended on EITHER platform because the leaked proxy holds
bats' fd 3; orphaned allowlists never swept; `--tmpdir` relocating the ephemeral
HOME but nothing else; and the nft ruleset file leaking once per Linux launch.
None was a regression; all five pre-dated this plan.**

**"13/13" was operator-assisted for this plan's whole history** -- both
platforms needed a human to kill a proxy mid-run. Since 9.2 the Linux suite
finishes on its own in 20 seconds.

Two things came out of the flag work that were not the task: the Linux
`--filter-egress` namespace now has a private loopback, and `--filter-egress`
was found to leak one `csb-proxy` per launch, forever. Section 6 records the
cleanup design and what it deliberately does not do.

---

## Handoff (for a fresh context)

Read this section, then sections 6 and 8. Sections 1-5 are the record of what
shipped and why; read them when something questions a decision.

### Where the work stands

| piece | state |
|---|---|
| `--allow-loopback` / `allow_loopback=` (flag, profile key, both platforms) | **SHIPPED (981a949)**. Tier 1 green on both hosts |
| Linux private loopback (`pasta -t none -u none -U none -T <ports>`) | **SHIPPED (981a949)**. Flag semantics confirmed against pasta `2025_09_19.623dbf6`; runtime confirmed by the smoke test in section 4 and by Tier 3 arm 12 |
| Tier-2 golden `darwin/allow-loopback` | **GENERATED** (`make test-update` on the macOS host) |
| Tier-2 goldens `linux/allow-loopback`, `linux/filter-egress` | **GENERATED** (`make test-update` on the NixOS host, 2026-08-12). `filter-egress` gained the four pasta flags; `allow-loopback` shows the nft port set replaced by `oif "lo" accept` with pasta's `-T` list unchanged |
| Tier-3 `make test-escape` | **13/13 on BOTH hosts, both operator-assisted.** On Linux that is 4 real arms (6, 7, 8, 12) and 9 macOS skips -- **and on neither platform does the run terminate unattended; see section 8.2** |
| the leak fix: owner-stamped HOMEs + janitor (section 6) | **VERIFIED ON BOTH HOSTS** (section 6, "Measured"): launch-pass and `--reap` each exercised against a real exited session with a live bystander untouched |
| the PPID-1 discriminator | **MEASURED on both.** Correct for the ancestry csb is normally launched from; **defeated by `systemd --user` as a subreaper -- section 8.1** |
| per-session polling reaper | **DELETED** (rejected design; section 6 records why, so it is not rebuilt) |

### The expected numbers

**`make ci` runs all five and is the one to use** -- ordered cheapest first, and
it refuses to run inside csb rather than letting Tier 3's skips read as a pass.
On NixOS: 312 tests, exit 0, 77 seconds.

    make check          # shellcheck clean
    make test           # 169/169  (163 + 6 proxy-stamp tests from 9.1)
    make ocaml-test     # 119/119  (the config oracle: a subset re-run vs csb-config)
    make test-proxy     # 11/11    (real proxy + curl)
    make test-escape    # 13/13    (unattended since 9.2; it used to hang)

`make test` is NOT the whole suite -- bats does not recurse, so it runs
`test/*.bats` only. **This plan listed four of the five targets for its whole
history and omitted `test-proxy` entirely**, and a verification pass that
trusted the list ran 301 of 312 tests while reporting itself complete. That
omission is why `make ci` exists.

### What the NixOS pass verified (2026-08-12), in the order it ran

All five steps are DONE. Kept as the reproduction recipe, not as a to-do list.

1. `make check` clean; `make test` 161/163, failing only the two expected
   goldens, with `test/reap.bats` 6/6 green.
2. `make test-update` from the host (no D1 skip), then `make test` **163/163**.
3. **The janitor, live** -- every sub-step passed:
   - `csb -s -E --here --filter-egress --allow-host api.anthropic.com --
     bash -c ...` left proxy 494514 at PPID 1 and stamped HOME
     `csb-home.mjlwaI` (stamp 494387, dead). Deferred cleanup, as designed.
   - `csb --reap` then killed that proxy, removed `/tmp/csb-allow.8kHLb3`, and
     deleted the HOME. All three confirmed gone.
   - With a VERIFIABLY live session (`kill -0` on the stamp answered yes at the
     instant of the check), `csb --reap` reported `0` and `0` and left its
     proxy, HOME, and allowlist intact.
   - A real launch's quiet pass killed a dead orphan (639401), removed its
     allowlist, and deleted its HOME, while sparing that same live bystander.
   - Ground truth: a LIVE session's proxy 639046 showed PPID **638921**, which
     is the stamp pid AND the `passt.avx2` process -- `exec` carries the launch
     pid all the way to pasta. An exited session's proxy showed PPID 1 on every
     one of five observations.
4. `make ocaml-build` clean, `make ocaml-test` 119/119, `make test-escape`
   13/13 (after clearing the hang -- section 8.2).
5. Sweep: **this host had no `csb-home` leftovers at all** and `--reap` never
   reported an unstamped dir. The ~30 orphans this plan once expected here are
   gone. A DIFFERENT leftover class is unswept instead -- section 8.3.

### Timing trap when driving this from an agent harness

The background-task output file is buffered until the task exits, so a wait
loop on it observes nothing until the session is already over -- which reads
exactly like "the live session died instantly" and makes the bystander test
silently vacuous. Two runs were lost to this before the session was made to
write its own marker file, which the foreground can poll honestly. Any repeat
of step 3 must confirm the session is live AT THE INSTANT of the `--reap`, with
`kill -0` on the stamp, and not infer it from elapsed time.

### Landmines

- **The Tier-3 loopback probe was vacuous once already.** It used a relative path
  to `csb-proxy` and `2>/dev/null`, so the listener never started, and the
  NEGATIVE case ("no 403") passed for the wrong reason. `listener=up` is now
  asserted in both runs specifically to stop that. Any rewrite must keep an
  assertion that the listener actually came up. The guard has since paid for
  itself twice: it caught the next vacuous run too (the symlink landmine below).
- **An absolute path through a symlinked ancestor under the real HOME is
  unreadable from inside the sandbox** (a common layout: `~/src ->
  /Volumes/src`). The HOME read deny covers the symlink itself, so the deny
  fires before the allowed target is ever resolved; interactive sessions never
  notice because the kernel cwd is a vnode and relative paths do not
  re-traverse the link. The Tier-3 harness therefore resolves `$REPO` with
  `pwd -P` (both setup functions). Run the suite from any path; hand the
  sandbox physical ones.
- **`make test-escape` hangs at the END of a green run, on BOTH platforms, and
  the cause is not PATH.** This was previously recorded here as a devShell
  problem -- a bare nix-store bats off a stray PATH "hung for 13 minutes
  producing nothing". That diagnosis was wrong; the cause is section 8.2, the
  last leaked proxy holding bats' fd 3. Every "13/13" in this plan's history
  was reached by a human killing that proxy. Treat any silent `test-escape` as
  8.2: `cat /proc/<bats>/wchan` (expect `anon_pipe_read`) and
  `ls -l /proc/<proxy>/fd` (expect fd 3 on the same pipe). Killing the orphan
  releases it immediately.
- **Goldens cannot be generated from inside csb.** The helper skips rather than
  producing a wrong one. That is deliberate (PLAN-007 addendum D1).
- **`-E=NAME` ephemeral HOMEs are shared across panes on purpose**
  (`bin/csb:1889`). Any cleanup that deletes them breaks the documented
  sibling-pane workflow. The janitor's glob matches only the random mktemp
  shape (`csb-home.XXXXXX`), never `csb-home-NAME`; keep it that way, and
  keep the test that pins it (`test/reap.bats`).
- **Do not reintroduce a PPID test.** A `csb-proxy` with PPID 1 looks like an
  orphan and usually is, and that was the discriminator until 9.1 -- but it is
  not universal on Linux: a subreaper above the launch collects orphans instead
  of pid 1, and `systemd --user` is one (measured, 8.1). The janitor reaps by
  the `csb-owner.*` stamp now. What `exec` still guarantees, and what the stamp
  rests on, is that the launch pid survives for the session's whole life.
- **An unstamped `csb-home` dir is never deleted.** The stamp is written in the
  same breath as `mktemp -d`, but a janitor in a concurrent launch can observe
  the gap between the two -- skipping unstamped dirs is what makes that race
  harmless. The same rule protects leftovers from launches that predate the
  stamp; they need one manual sweep (handoff step 5).
- **`test/reap.bats`'s proxy pass is live.** The dead-home tests are hermetic
  (the harness pins `CSB_TMPDIR`, and the scan is base-scoped), but `--reap`
  always scans the real process table -- a suite run on a host with genuine
  orphans reaps them. That is the tool doing its job, not a test leak.
- **`--dump-sandbox` also creates (and stamps) a throwaway HOME**; the next
  real launch removes it. Do not "fix" the dump path into deleting it inline --
  the dump seams launch nothing and reap nothing.
- **An allowlist file is removed only as a side effect of reaping its proxy.**
  A proxy that dies any other way strands its `csb-allow.*` forever, and
  nothing sweeps them. Section 8.3.
- **On the NixOS host `filter_egress=true` and `cfg_tmpdir=/scratch/tmp` are
  the resolved profile defaults**, so EVERY launch there starts a proxy (a
  launch with no `--filter-egress` on the command line still leaks one) and
  ephemeral HOMEs land outside `/tmp`. Read `--dump-config` before concluding a
  proxy appeared from nowhere, and before scanning the wrong tmp base.

---

## 1. The trigger

A `flutter test` run inside a `--filter-egress` sandbox hangs. flutter_tools
binds `127.0.0.1:0` and has `flutter_tester` connect back on the port the kernel
picked. Under filtering, that connect is refused on macOS and dropped on Linux --
a hang rather than an error.

No configuration could express it. `allow_port` is validated as a single
`1..65535` int (`ocaml/lib/validate.ml`), and the port is not known in advance.

**A port-range flag was considered and rejected**: seatbelt's `remote ip` filter
takes `host:port` with `*` wildcards and has no range syntax, so a range would
mean tens of thousands of rules on macOS. It is not implementable there.

## 2. The flag

`--allow-loopback` / profile `allow_loopback=`, default off, in the EGRESS
section, negated by `--no-allow-loopback`.

It **replaces** the per-port rules rather than adding to them, so a reader sees
one loopback answer per platform:

- **macOS** -- `(allow network-outbound (remote ip "localhost:*"))`
- **Linux** -- `oif "lo" accept` in the nft ruleset

Off-host egress is untouched in both cases: still the proxy and the host
allowlist.

### The per-platform policy, and a correction

PLAN-007 Part 5 ("stop trying to sync the DEFAULTS, sync the predicate") governs
flags whose mechanism cannot be identical on both platforms: a flag promises
something about what it names, and the residual for what it does not name is
documented per platform.

**That policy was initially misapplied here** -- cited as a reason to ship the
blunt mechanism on Linux as well as macOS. It says nothing of the kind. It
constrains what a flag must guarantee, not which mechanism to pick, and PLAN-007's
own F4 shipped the asymmetry (Linux got the targeted fix, macOS the blunt one).
The real reason the Linux half was nearly dropped was that it could not be
measured from inside a sandbox, which is a scheduling constraint, not a design
one. Recorded because the same mistake is easy to repeat.

## 3. The Linux private loopback

pasta's default is `auto` in **both** directions. That meant every port bound on
the host's loopback existed inside the namespace, leaving the nft port set as the
only thing between the sandbox and every host service. csb now passes:

    pasta -f -t none -u none -U none -T <proxy_port>[,<allow_port>...] -- ...

`-T/--tcp-ns` is the namespace-to-host direction, which is the one csb needs (the
sandbox dials `127.0.0.1:<proxy_port>` and must reach the host's proxy). `none`
and comma-lists are valid for all four options. Confirmed against pasta
`2025_09_19.623dbf6`.

Two narrowings now exist and neither rests on the other: **pasta decides what is
there to dial, nft decides what may be dialled.** That is what makes
`--allow-loopback` affordable on Linux -- it widens the second over a loopback
that reaches nothing it was not given.

`join_by` renders one port list two ways (`a, b` for nft's set, `a,b` for pasta's
spec) so the two cannot drift apart.

### An unintended finding

`-t auto` -- the other direction, also default before this change -- forwards
"all ports currently bound in namespace". A dev server started **inside** a
filtered sandbox was therefore published on the host's loopback without anything
asking for it. `-t none` closes that. It is a user-visible behaviour change and
is documented in the README: under `--filter-egress` a dev server inside the
sandbox is no longer reachable from a host browser.

### What the flag costs

- **Linux** -- nothing beyond the sandbox's own processes.
- **macOS** -- every service on the host's loopback. One loopback, shared, and
  seatbelt cannot distinguish the sandbox's own peer from the host's. Prefer
  `--allow-port` there when the port is known.

## 4. What was measured, and what was not

| claim | how |
|---|---|
| `remote ip "localhost:*"` is valid seatbelt syntax | Apple ships that literal in `/usr/share/sandbox/com.apple.CommCenter.sb`. **NOT compile-tested** -- nested `sandbox-exec` is impossible in-session |
| the private-loopback namespace still reaches the proxy | `csb -s --here --filter-egress --allow-host api.anthropic.com -- curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/` returned **404** on NixOS. A dead proxy path gives `000` or a hang, so this confirms the `-T` direction at runtime |
| the negative case is real on macOS | `TMPDIR=/tmp bash test/escape/loopback-probe.sh <proxy>` from inside a filtered sandbox: `listener=up`, `dial=refused` |
| the positive case's asserted string is right | the same dial logic against that sandbox's own allowed proxy port returned `HTTP/1.1 403 Forbidden` |
| `--reap`'s discriminator | 37 orphans killed on the macOS host; the 4 survivors each had a live `claude` parent |
| the discriminator's LIVE half, on NixOS | a live session's proxy 639046 showed PPID 638921 = the stamp pid = the `passt.avx2` process. Its DEAD half: PPID 1 on five separate observations |
| the discriminator's LIMIT | measured, and it is real: `systemd --user` collects orphans instead of pid 1 (section 8.1) |
| **`make test-escape` passes** | **13/13 on macOS AND NixOS -- both needing a manual kill to terminate** (section 8.2) |
| **the Tier-2 goldens** | **GENERATED on both platforms** |
| the janitor end to end on NixOS | handoff step 3: every sub-step, against real sessions with a live bystander |

### The probe bug, recorded because it nearly shipped green

The first Tier-3 probe was inline in `usable.bats`, used a **relative** path to
`csb_proxy_cli.exe` (cwd inside `csb -s -E` is not the worktree) and sent the
proxy's stderr to `/dev/null`. The listener never started, `$port` was empty, and
bash dialled `/dev/tcp/127.0.0.1/` -- which reads as "connection refused" and made
the negative assertion pass while proving nothing. It also left the proxy running,
which held the launch open and hung the terminal.

It is now `test/escape/loopback-probe.sh`: absolute path, every step reports, the
proxy's stderr is echoed as `probe-stderr:` lines, the dial is bounded by a killed
child rather than `timeout` (absent on macOS), and the listener is killed on exit.

### The file-descriptor probe (a dead end, kept so it is not retried)

For the leak fix in section 5, a "lifeline fd" design was probed:

    mac:                       FD9-SURVIVED
    linux, --filter-egress:    FD9-GONE
    linux, --no-filter-egress: FD9-SURVIVED

So **pasta closes inherited descriptors**; bwrap does not. Note the probe tested
the wrong proposition -- it asked whether the *innermost* process could write to
fd 9, when what the design needs is whether *any* ancestor holds it for the
session's life. That was never resolved, because the design was dropped for
simpler reasons.

Section 8.2 is the same question answered from the other side, and the answer
does not contradict this: **the proxy is started on the HOST, before pasta**,
so pasta closing descriptors never applies to it and it keeps whatever the
launching shell held -- fd 3 under bats. "pasta closes inherited descriptors"
is a fact about the sandbox payload only.

## 5. The proxy leak

`bin/csb` ends in `exec nix develop ...`, which replaces the shell, so the EXIT
trap never runs on the normal path. The trap comment says as much -- it is "a
failure-path net, not the normal-path cleanup" -- and that is correct for the
seatbelt profile, which `sandbox-exec` reads after csb is gone. But the proxy kill
was bundled into the same trap, so **nothing** reaped it. One `csb-proxy` leaked
per `--filter-egress` launch: ~30 on the NixOS host, 37 on the macOS one.

This is not only untidy. An orphan is still listening on the host's loopback and
will still tunnel CONNECT to its own allowlist. It interacts badly with the flag
in section 2: on macOS, `--allow-loopback` lets a sandbox dial any loopback port,
so it can reach every leaked proxy from every past session and inherit the union
of their allowlists.

The same shape applies to the ephemeral HOME. It lives under `$TMPDIR` and
`bin/csb:1794` delegates to "the OS reaps it" -- which is three-days-untouched on
macOS and boot-time on Linux. With `--seed-creds` that directory holds a live
session credential.

`--reap` (a mode, dispatched before the repo is located) kills proxies whose PPID
is 1 and removes the allowlist file each was reading. Section 6 grew it a
dead-home half and a quiet twin that runs at every real launch.

The union hazard has a LIVE form too, and no cleanup can touch it: on macOS a
`--allow-loopback` sandbox can CONNECT through any CONCURRENT session's proxy,
so its effective allowlist is the union of every live session's. One shared
loopback, no mechanism to narrow it -- documented in the README's cost bullet,
per PLAN-007 Part 5. On Linux the private loopback means a sibling session's
proxy has no presence inside the namespace at all.

## 6. DECIDED: the next session cleans up, via an ownership stamp

Candidate 1 below shipped (working tree), chosen over 2/3 so nothing new
enters the launch path's process tree: no daemon, no polling, no job-control
question, and it survives `SIGKILL` of everything. The accepted cost is that a
leak lives until the next launch or an explicit `csb --reap`.

What runs, in `bin/csb`:

- `reap_orphan_proxies` -- kills the proxy each dead session's `csb-owner.*`
  stamp names, and removes that stamp's allowlist. Superseded 9.1: this pass
  read PPID 1 off the process table until a subreaper was shown to defeat it
  (8.1). It still rests on `exec` preserving the launch pid, but as the stamp's
  OWNER field rather than as a parent link.
- `report_unowned_proxy_artifacts` -- counts, and never touches, proxies and
  allowlists no surviving stamp claims. Runs after the pass above, so anything
  it sees is genuinely unowned.
- `reap_dead_homes` -- deletes `csb-home.XXXXXX` dirs whose `.csb-owner` stamp
  names a pid that no longer answers `kill -0`. The stamp is written at
  `mktemp -d` time and holds `$$`, which `exec` preserves for the session's
  life. Dirs with a missing or malformed stamp are counted and reported by
  `--reap`, never deleted. Only the tmp base the CURRENT config resolves
  (`cfg_tmpdir`, else `TMPDIR`, else `/tmp`) is scanned -- symmetric with
  where creation happens and hermetic under the test harness; homes created
  under some other tmpdir config are found by running `--reap` under that
  config.
- Both run quietly at every real launch (the dump seams and the listing modes
  skip them) and verbosely as `csb --reap`.

The passes stay independent, and the proxy one still reaps orphans from EVERY
kind of session -- namespace, named ephemeral, --real-home -- because a proxy is
stamped whatever the HOME arrangement. Only the HOME pass is restricted to the
random ephemeral shape.

### Measured (macOS host, unsandboxed)

The full acceptance sequence, run against real sessions with 3 unrelated live
`--filter-egress` sessions as bystanders:

- A session launched by the stamped csb wrote `.csb-owner` = the session pid;
  the exec'd `-s` bash carried that pid and parented the proxy.
- **The launch pass**: relaunching after a session exit killed the prior
  session's PPID-1 proxy and removed its allowlist file, quietly, at a real
  launch. Bystanders untouched.
- **`--reap`**: after the stamped session exited, reaped its proxy (verified
  PPID 1 first), removed its `csb-allow.*` file, and deleted its stamped HOME.
  Reported 27 unstamped pre-stamp dirs and deleted none of them (several
  belonged to the live bystanders -- the conservative rule is what kept them
  safe, since pre-stamp dirs are indistinguishable from live ones).
- **The base residual bit once**: a shell with no `TMPDIR` scanned `/tmp` and
  found nothing. Run `--reap` from a login shell, or set `TMPDIR` explicitly
  (`getconf DARWIN_USER_TEMP_DIR` on macOS).

### Measured (NixOS host, unsandboxed, 2026-08-12)

The same acceptance sequence, and it passed in full -- pids and artifacts in
handoff step 3. Three things the macOS run did not show:

- **The base residual did NOT bite here, for a reason worth knowing**: the
  profile sets `cfg_tmpdir=/scratch/tmp`, so `reap_dead_homes` scanned
  `/scratch/tmp` and creation happened there too. The two agree because both
  read the resolved config, which is the property section 6 claims. `/tmp` held
  no `csb-home` at all -- scanning it would have found nothing and proved
  nothing.
- **The launch pass and `--reap` were exercised against the SAME live
  bystander**, which is stronger than the macOS run: one live session survived
  a `--reap`, a foreign real launch, and its own suite's launches.
- **Tier 3 exercises the janitor incidentally.** `usable.bats` arm 12 makes two
  filtered launches; only ONE orphan is ever left behind, because launch 2's
  own quiet pass reaps launch 1's. That is the janitor working unprompted, and
  it is why the fd-3 hang in 8.2 strands exactly one proxy rather than four.

Safety properties, argued once here:

- Pid reuse can delay cleanup, never cause it: `kill -0` on a reused pid
  reports alive, so the dir is kept. A live session's pid is the user's own
  and always answers, so there is no path to deleting a live session's HOME.
- The stamp lives inside the sandbox-writable HOME, so the agent can delete or
  corrupt it. That only exempts the agent's own HOME from cleanup (the
  unstamped rule) -- the very leak the janitor exists to fix, and nothing
  worse.

What was built first and rejected, kept so it is not rebuilt: a detached
per-session bash reaper that polled its own PPID every 5s (`exec` preserves
the pid, so reparenting marks session end) and then killed the proxy, deleted
the random ephemeral HOME, and removed the temp files. Andrew rejected it on
reading the code, and the rejection holds in the terms CLAUDE.md already sets
out:

- Three of its comments were paragraph-long justifications of a workaround (why
  polling rather than a descriptor, why 5s, why the pid is re-identified before
  the kill). By the repo's own rule, that means the code is wrong.
- It was a polling daemon **per session**, and this operator runs many
  concurrently. Each forks a `ps` forever.
- It was bash-inside-bash as a string, with a `shellcheck disable`, untestable
  by any tier that exists.
- The pid-reuse defence existed only because the design has a race window at
  all.

The unchosen candidates, for contrast: **2. Don't exec** (keep csb alive and
`wait`; cleanup becomes ordinary trap code, but Ctrl-Z job control becomes a
question) and **3. Both** (2 for the normal path, 1 as backstop). If deferred
cleanup ever proves too slow in practice, 2 is the upgrade path and composes
with the stamp rather than replacing it.

## 7. Still open

Section 9 is landed and verified on NixOS. What is left is macOS confirmation
and the one-time sweeps.

- **None of section 9 is verified on macOS.** 9.1 is the one that matters: the
  stamp should make the discriminator platform-independent, which is most of its
  point, but that claim is measured on Linux only. 9.2's `3>&-` should end the
  macOS hang too (same bats, same leak) -- also unmeasured.
- **Regenerate the macOS Tier-2 goldens**: 9.5 changed the netns shim text. That
  is Linux-only, so darwin may well be byte-identical -- confirm rather than
  assume, the way 9.4's unchanged goldens had to be.
- **Run `make ci` on macOS.** It is new (this session) and has only ever run on
  NixOS. `make test-proxy` in particular has no recorded macOS result at all.
- One manual sweep per host, now of four things rather than one: unstamped
  `csb-home` dirs, and (NixOS) 34 `/tmp/csb-allow.*`, 41 `/tmp/csb-nft.*`, 4
  `/scratch/tmp/csb-loopback-*`. All predate their fixes; `--reap` reports the
  allowlists and refuses to delete them, by the unstamped rule.
- One manual sweep per host of pre-stamp `csb-home` leftovers (reported by
  `--reap`, deliberately not deleted). macOS has 27; several belong to live
  sessions, so sweep when quiesced (or `lsof +D` each first). The macOS host
  also carries one hand-started probe proxy (`csb_proxy_cli.exe` with a
  relative allowlist path, deliberately outside `--reap`'s matcher) to kill
  by hand. **NixOS has none** -- it never accumulated any.
- Whether to tighten `--allow-loopback` on macOS at all. There is no mechanism to
  do so; the residual is documented instead, per PLAN-007 Part 5 -- and it now
  includes the live cross-session proxy union (section 5).

## 8. Found by the NixOS pass (2026-08-12)

Three defects the macOS pass could not have seen. None is a regression; all
three predate this plan. 8.1 and 8.2 need a decision before they are fixed --
each has a cheap wrong answer that CLAUDE.md's own rules argue against.

### 8.1 The PPID-1 discriminator is defeated by a subreaper, and this host has one

`bin/csb:906` tests `[[ "$ppid" == "1" ]]`. On Linux an orphan does not
necessarily reach pid 1: it is collected by the nearest ancestor marked
`PR_SET_CHILD_SUBREAPER`, and `systemd --user` marks itself. Measured on the
NixOS host (user manager = pid 1630), with one script forking a child and
exiting, run two ways:

    from tmux (the tmux server is itself PPID 1)   -> orphan PPID 1
    systemd-run --user -p KillMode=process ...     -> orphan PPID 1630

So csb launched from tmux or ssh leaks a REAPABLE proxy, and csb launched from
a desktop terminal that the session manager started as a user unit or scope
leaks one the janitor will never match -- silently, forever, with no error. The
whole NixOS verification ran from tmux, which is why every other measurement
here is clean.

The macOS host cannot show this: `launchd` reparents to pid 1.

Not fixed, because the shape of the fix is a real choice: accept "PPID is 1 OR
the user manager", or invert the test to "the parent is not a live csb launch",
or stop using PPID at all and have the stamp cover proxies too. The first is
the smallest and the least principled -- it hardcodes one process manager.

### 8.2 A leaked proxy holds bats' fd 3, so `make test-escape` never terminates

`make test-escape` on NixOS produced ZERO bytes for 14m29s. The evidence:

    cat /proc/<bats>/wchan        -> anon_pipe_read
    ls -l /proc/<bats>/fd         -> 0 => pipe:[5959477]
    ls -l /proc/<proxy>/fd        -> 3 => pipe:[5959477]   <-- the WRITE end

bats uses fd 3 as its output channel. `bin/csb:881` backgrounds the proxy with
stdout and stderr redirected but says nothing about inherited descriptors, so
the proxy keeps fd 3; it then outlives the suite by design (section 6's
deferred cleanup), and bats waits for an EOF that never comes. Killing the
orphan released it instantly and the suite finished **13/13, exit 0** -- the
results are genuine, the hang is in teardown after the last assertion.

The stranded proxy is always arm 12's second launch, since each launch's quiet
pass reaps the previous one's.

Two candidate fixes, and the obvious one is the wrong one:

- **Harness**: close fd 3 on the csb invocations in `test/escape/usable.bats`
  (`3>&-`). Standard bats practice, localized to the tests, no production
  change. Preferred.
- **csb**: start the proxy with fd 3 closed. This is a bats-specific constant
  in production code, and justifying it would take exactly the paragraph-long
  comment CLAUDE.md forbids. The principled version -- a detached daemon should
  inherit no descriptors at all -- is not expressible in bash without listing
  fds by hand, which is the same workaround wearing a hat.

**This is not Linux-specific.** The macOS run hung too; the operator caught it
by hand and the agent did not record it, which is why this plan claimed an
unattended 13/13 there. Both "13/13 green" results were operator-assisted. The
13-minute hang the Landmines once blamed on a stray-PATH bats was almost
certainly this same fd, three sessions earlier.

The lesson is bigger than the bug: **a suite that only terminates because a
human intervened must say so in the same breath as its pass count**, or the
next reader plans around a green that does not exist.

### 8.3 Orphaned allowlist files are never swept

`reap_orphan_proxies` removes an allowlist ONLY as a side effect of reaping the
proxy that named it (`bin/csb:911-913`). A proxy that dies any other way -- the
EXIT trap on an abnormal path, a manual kill, OOM, a nix-shell teardown --
strands its `csb-allow.*` permanently. Nothing else looks for them.

The NixOS host carries **34** `/tmp/csb-allow.*`, oldest 2026-08-08, on a box
with five weeks of uptime (so `/tmp` has had no boot clean to hide them). Plus
4 fixed-name `/scratch/tmp/csb-loopback-*` files that
`test/escape/loopback-probe.sh` writes and never removes -- fixed names in a
shared tmp are also a collision between concurrent runs.

Contents are hostnames, not credentials, so this is unbounded growth rather
than an exposure. It is the same shape as the ephemeral HOME leak in section 5
and would fit `--reap` as a third pass, with the same conservative rule:
delete only what no live proxy names in its argv.

### 8.4 csb honours `cfg_tmpdir` for the HOME and for nothing else

Found by asking why 8.3's files were in `/tmp` when this host's HOMEs are in
`/scratch/tmp`. They are two different bases, from the same launch:

| site | base used | correct? |
|---|---|---|
| `bin/csb:1895,1901` ephemeral HOME | `${cfg_tmpdir:-${TMPDIR:-/tmp}}` | yes |
| `bin/csb:930` the janitor's scan | `${cfg_tmpdir:-${TMPDIR:-/tmp}}` | yes, symmetric with creation |
| `bin/csb:1919` the SANDBOX's `TMPDIR` | `cfg_tmpdir` | yes |
| `bin/csb:869` proxy allowlist | `${TMPDIR:-/tmp}` | **no** |
| `bin/csb:875` proxy port fifo | `${TMPDIR:-/tmp}` | **no** |
| `bin/csb:1074` deny profile | `${TMPDIR:-/tmp}` | **no** |
| `bin/csb:1402` nft rules | `${TMPDIR:-/tmp}` | **no** |
| `bin/csb:1526` `resolve_config`'s emit file | `${TMPDIR:-/tmp}` | unavoidable |

`--tmpdir` / `CSB_TMPDIR` / `tmpdir=` therefore relocates the ephemeral HOME and
the sandbox's own temp dir, while every other file the launch writes stays in
the host's `$TMPDIR`. An operator who set it to keep csb's litter on one
filesystem got neither the isolation nor the cleanup.

The four wrong sites are all reachable only from the launch path, which runs
after `resolve_config "$@"` (`bin/csb:1648`), so `cfg_tmpdir` is populated by
the time they execute -- verified: `build_deny_wrapper` is defined at
`bin/csb:985` and called from below. The one exception is genuine and should be
commented as such: `resolve_config` creates its emit file in order to LEARN
`cfg_tmpdir`, so it cannot use it.

This is a prerequisite for 8.3, not a tidy-up alongside it: a third `--reap`
pass scoped to `cfg_tmpdir` would scan `/scratch/tmp` and never see the 34
files sitting in `/tmp`.

Out of scope but noticed: `bin/csb:350` uses a bare `mktemp` and then `mv`s
onto `$cfg`. If `$TMPDIR` and `$cfg` are on different filesystems that rename
is a copy, so the write is not atomic. Unrelated to tmpdir policy; recorded so
it is not lost.

## 9. LANDED: the four fixes (2026-08-13)

Andrew's decisions, all IMPLEMENTED and VERIFIED on the NixOS host in the forced
order 9.4, 9.1, 9.3, 9.2 -- 8.4 first, because 8.3's pass needs to know where to
look. A fifth leak of the same class turned up while verifying and is 9.5.

Where it stands after landing:

    make check          # shellcheck clean
    make test           # 169/169 (163 + 6 new proxy-stamp tests)
    make test-escape    # 13/13, exit 0, UNATTENDED, 20 seconds
                        # (it hung 14m29s before 9.2)

A full escape run now leaves exactly the last launch's allowlist, HOME and
stamp -- the deferred-cleanup design -- and `--reap` clears all three. No
`csb-nft.*` and no `csb-loopback-*` survive at all.

### 9.1 Ownership stamps replace PPID entirely (was 8.1)

**Decided: stop using PPID at all; the stamp covers proxies too.** This is the
right call and it is strictly more robust -- it is one mechanism instead of two,
it is identical on launchd and systemd, and it states ownership instead of
inferring it from a process-tree accident.

It needs one guard that PPID did not, and the guard is load-bearing:

- **PPID could never kill the wrong process.** It matched on live process shape,
  so the worst case was missing an orphan. A RECORDED pid inverts that risk: pid
  reuse means the number in the stamp may name an innocent process by the time
  the janitor reads it.
- So a stamped proxy is killed only when **both** hold: its owner pid is dead,
  AND the recorded proxy pid's argv still matches `csb-proxy` with that exact
  allowlist path. Allowlist paths are `mktemp`-random, so a false positive needs
  a reused pid that is also a csb-proxy reading the same random path.
- Note this is NOT the same safety argument as the HOME pass. There, pid reuse
  can only DELAY cleanup (section 6). Here it could cause a wrong kill, which is
  why the argv re-check is a requirement and not a belt-and-braces extra.
- Keep the conservative twin: **a `csb-proxy` with no stamp is reported, never
  killed** -- mirroring unstamped HOMEs. This is also what covers proxies left
  by csb versions from before the change, which by definition have no stamp.

The stamp cannot live in the ephemeral HOME: section 6 requires the proxy pass
to reap orphans from EVERY kind of session, including `--real-home` and
namespace ones that have no ephemeral HOME. It gets its own record under the
resolved tmp base, naming owner pid, proxy pid, and allowlist path -- which is
what makes 9.3 mostly fall out of this pass rather than duplicate it.

**As built.** `start_egress_proxy` writes `csb-owner.XXXXXX` (three lines: owner
pid, proxy pid, allowlist) once the proxy has answered with its port.
`reap_orphan_proxies` iterates those stamps instead of the process table;
`report_unowned_proxy_artifacts` runs after it and reports what no surviving
stamp claims. Two things worth keeping:

- **The stamp is NOT named `csb-proxy.XXXXXX`.** That glob also matches
  `csb-proxy.log`, which lands in the tmp base whenever there is no ephemeral
  HOME, and the janitor would have parsed the log as a stamp. The name parallels
  the HOME's `.csb-owner` instead.
- **The proxy pass became hermetic**, which it never was before: it now reaps
  only stamps under the resolved tmp base, and the harness pins that per test.
  `test/reap.bats` asserts real reap COUNTS for the first time (6 new tests,
  including the pid-reuse guard: a stamp whose pid is now a plain `sleep` must
  not be killed, while the dead owner's litter still goes). Only the report pass
  still reaches the real process table, so its process count is asserted without
  a number.

### 9.2 Fix the harness, not csb (was 8.2)

**Decided: the harness.** Confirming the mapping, since the plan's wording
inverted the usual instinct: the OBVIOUS fix is to patch `bin/csb`, and that is
the WRONG one; the harness fix is the non-obvious one and the right one. Close
fd 3 on the csb invocations in `test/escape/usable.bats` (`3>&-`).

`bin/csb` must not learn a constant that exists because of bats, for the same
reason section 6 rejected the polling reaper: it would need a paragraph of
comment to justify, and by this repo's rule that means the code is wrong.

**As built.** One change, made at all eight launch sites in `escape.bats` and
`usable.bats` by extending the wrapper they already share: `exec "$@"` became
`exec "$@" 3>&-`. Applying it to the exec'd command rather than to `run` leaves
bats' own fd handling untouched. Result: 13/13 in 20 seconds, exit 0, no human.

**The same bug bit the new Tier-1 tests, twice, which is the argument for 9.2 in
miniature.** `test/reap.bats` needs a live stand-in proxy, and the first version
leaked two descriptors into it: bats' fd 3 (so the suite hung at the end, exactly
as 8.2 describes) and the stdout pipe of the `$(fake_proxy ...)` command
substitution that started it -- the latter blocking each caller for the full 300s
sleep, which read as a hang but was really three tests running to completion very
slowly. Both are fixed by `>/dev/null 2>&1 3>&-` on the background start. Any
long-lived process a bats test starts needs this; it is a property of leaving a
process running, not of csb.

### 9.3 A third `--reap` pass for allowlists (was 8.3), with one split

**Decided: reap them** -- with a distinction the finding lumped together:

- **`csb-allow.*` is csb's own litter and belongs in `--reap`.** After 9.1 the
  stamp already names the allowlist path, so a dead owner's file is removed
  exactly, by name. Files with no stamp -- the 34 legacy ones -- are reported
  and not deleted, the same rule as unstamped HOMEs, and swept by hand once.
- **`csb-loopback-*` is a TEST artifact and does not belong in `--reap`.**
  Teaching the production janitor the filenames of a probe script is the same
  category error as 9.2's rejected fix. `test/escape/loopback-probe.sh` already
  has an exit trap for its listener; its files go in that trap. Their fixed
  names are also a collision between concurrent runs, which the trap does not
  fix -- give them `mktemp` names while they are being touched.

**As built.** The allowlist half fell out of 9.1 exactly as predicted: a dead
owner's file is removed by name from its stamp, and unclaimed ones are counted
and reported. The probe now makes one `csb-loopback.XXXXXX` dir and removes it
in an EXIT trap that also kills its listener, so every exit path cleans up --
verified, a full escape run leaves none.

### 9.4 Honour `cfg_tmpdir` everywhere it can be honoured (was 8.4)

**Decided: yes, and it lands first.** The four sites in 8.4's table move to
`${cfg_tmpdir:-${TMPDIR:-/tmp}}`. `resolve_config`'s emit file stays on
`$TMPDIR` with a one-line comment saying why, since it runs to discover the
value it would otherwise use.

**As built, and one prediction was wrong.** This plan expected Tier 2 to move
("the goldens carry temp paths"). It did not: the relocated paths never appear
in a dump, so the Linux goldens were byte-identical after the change. Do not
read an unchanged golden here as the fix having failed. The single-source
`tmp_base()` is what the janitor's scan and every creation site now share, so
the two cannot drift the way they had.

Two sites beyond the table's four also moved, found by grep rather than by the
table: `csb-proxy.log`'s fallback when there is no ephemeral HOME, and the
`csb-home-NAME` path for `-E=NAME`.

### 9.5 The nft ruleset file leaked too, and 9.4 is what made it visible

Not in the original findings. After 9.4 moved `csb-nft.XXXXXX` out of `/tmp` and
into the resolved base, an escape run left five of them in plain sight -- one per
Linux `--filter-egress` launch, by the same mechanism as every other leak here:
the launch `exec`s, so the EXIT trap that would have removed it never runs.
`/tmp` on the NixOS host held **41** from before the move, so this is old, not a
regression 9.4 introduced.

The fix does not involve the janitor at all, and should not: the netns shim
loads the ruleset and never needs the file again, so it deletes it there --

    "$nft_bin" -f "$rules" || exit 1
    rm -f "$rules"
    exec "$@"

Deleting a temp file at the instant it becomes useless beats recording ownership
so something else can delete it later. This is the only one of the five leaks
with that option, because it is the only file with a definite last reader. It
does change the Linux Tier-2 goldens, which carry the shim verbatim.
