# plan 007 -- sandbox escapes: IPC brokering and the nix daemon

IMPLEMENTED (2026-07-25), reviewed and corrected 2026-07-26. All open decisions
are resolved; see "Resolution and scope" for what shipped, what is deliberately
not fixed, and why.

Landed in bin/csb: the macOS filter-class denies and the two-name DNS whitelist
(`build_deny_wrapper`, Darwin branch), plus the sandbox-owned unix-socket
re-allow; the Linux `--tmpfs` mounts over `/run/user/<uid>`, `/run/dbus` and
`/nix/var/nix/daemon-socket` (Linux branch); `--pasteboard` / `pasteboard=`.
Plus Phase 0's README pass, regenerated darwin snapshots, and
`test/escape/escape.bats` + `make test-escape`.

Every macOS line is now measured, including the `network-outbound` CLASS deny,
which took two attempts: run 4 measured it breaking DNS, run 5 found the cause
(the mDNSResponder UNIX socket, needed in addition to its mach service) and
came back clean. See "Phase 1c RESULTS". AF_UNIX brokering is therefore closed
as a class on macOS -- nix daemon, tmux, editor IPC, docker, ssh-agent -- not
merely per path.

READ THE ADDENDUM AT THE BOTTOM OF THIS FILE FIRST if you are resuming cold. It
is the 2026-07-26 closeout review, run from an unsandboxed session, and it
corrects several conclusions reached above -- including one rule this file
recommends that was later measured to do nothing.

STILL OPEN:

1. **The interactive TUI is confirmed by hand only, never by automation.** The
   API half of this item is CLOSED: a real `claude -p` round trip under the
   shipped profile works (addendum Part 1), which was the deciding column runs 3
   and 5 could only infer from an `http 404`. A pty session remains a manual
   check. The measured fallback if it ever regresses is still row A6.
2. **The Linux snapshot goldens are unverified on NixOS.** They were hand-patched,
   not regenerated. The host-dependence that made that risky is now removed --
   the goldens collapse the conditional tmpfs block to an `<IPC-TMPFS>` marker
   and a separate assertion covers which paths are really mounted (addendum D2)
   -- so `make test-update` on NixOS should produce an EMPTY diff. Any diff is a
   real finding.

The `trusted-users` guard was dropped as redundant -- see Phase 3.

## Why this document exists

An agent running in a `csb --paranoid` sandbox on another project noticed it
could execute the host's `nix`. Investigating that led to a second, much larger
finding: on macOS the seatbelt profile can be escaped outright, to the operator's
own uid, with full real-HOME access, in about fifteen lines and in BOTH normal
and `--paranoid` modes.

This file records the findings, the verbatim evidence, the bounds, and the
remediation plan, in enough detail to resume cold after a context clear.

## Summary

| ID | Finding | Platform | Severity | Status |
|---|---|---|---|---|
| F1 | `open` -> LaunchServices -> launchd spawns a process outside seatbelt as the operator's uid | macOS | CRITICAL, both modes | VERIFIED; FIX VERIFIED (`(deny mach-lookup)` + 2 DNS allows; Phase 1b run 3, TUI confirmed) |
| F2 | `pbpaste` reads the live host clipboard, bypassing the whole file deny-list | macOS | moderate | VERIFIED; same capability as a shipped feature, so exposed as a flag (Phase 3b) rather than simply removed |
| F3 | nix daemon socket reachable -> builder executes outside the sandbox as `_nixbld1` | both | low on this host after `nix sandbox = true`; medium on any host with the darwin default `sandbox = false` | VERIFIED (both configs) |
| F4 | session dbus -> `systemd-run --user` spawns a unit outside the bwrap namespace as the operator's uid | Linux | CRITICAL, both modes | VERIFIED (baseline read + paranoid spawn); FIX VERIFIED |
| F5 | README overstates the `--paranoid` guarantee and the threat model | docs | -- | VERIFIED |

Root cause, shared by all four and identical on both platforms: csb's sandbox
constrains FILE operations and nothing else, so it silently assumes no service
will act on the sandboxed process's behalf. That assumption is false on both
macOS and Linux.

- macOS: the profile begins with `(allow default)` (bin/csb:907) and adds only
  file rules, leaving every mach service and unix socket reachable.
- Linux: `--ro-bind / /` (bin/csb:979) carries every host socket into the
  namespace, and a read-only bind mount does NOT block `connect()`. The only
  namespace unshared is PID.

On both, a reachable broker converts into execution outside the boundary as the
operator's own uid. Neither PATH nor the env scrub is a boundary: exec is
unrestricted and a sandboxed process sets its own environment.

## Resolution and scope (2026-07-25)

DECIDED. Every open decision at the end of this file is now resolved, and the
scope is deliberately bounded.

**Governing context.** A container or VM boundary is the most likely next
direction, but it is an idea, not a commitment -- it may never be built, and
nothing in this plan depends on it. What is certain is that the current
implementation has live use cases and stays in service. This plan is therefore
about making it *honest and defensible as it stands*, not about turning a
profile into a boundary against a hostile agent. Whatever answers the residual,
nothing below does.

**Rule applied to every item:** ship it if it is one line or one flag AND either
measured or measurable with one harness row. Document it as an accepted gap
otherwise. Nothing here is allowed to grow into a research project.

**No-stability position, stated in the README as part of Phase 0.** csb is
single maintainer, MIT, no warranty, and carries no stability or security
guarantee: flags, defaults, profile keys, the sandbox policy and the containment
approach itself can change at any time -- a change of containment mechanism
would be exactly that kind of change. Use at your own risk, pin a rev if that
matters, re-read the threat
model after upgrading. This is not a disclaimer bolted on to excuse the findings
above; it is what lets this plan ship a tightened policy that breaks the
keychain, the browser login flow, `osxkeychain` git credentials and unix-socket
dev services without treating any of them as a compatibility obligation.

### The architectural position, stated once

`(deny mach-lookup)` is not "another name-based mitigation that happened to
work". It flips an entire seatbelt *filter class* from allow-default to
deny-default, which is why the unidentified LaunchServices route stopped
mattering when five guessed names did not. That is the right move, and it
generalizes: csb's macOS profile is `(allow default)` plus file rules, so every
other filter class is in the same pre-F1 state that F1 exploited --
`network-outbound` (which is how AF_UNIX sockets are governed, and is exactly
the F3 mechanism), `mach-priv-task-port` (task_for_pid; macOS has no PID
namespace, so every host process is visible and addressable), `iokit-open`,
`sysctl-*`.

So Phase 2 closes the classes where the deny is one line, and csb's claim
becomes a testable property -- "these seatbelt classes are deny-by-default" --
rather than a list of holes someone happened to find. It is still not a
boundary against a hostile agent, and the docs must not say it is.

Linux does not get this. bwrap has no socket filter, so the only lever is
mounts, and mounts cannot reach abstract unix sockets (they are scoped to the
network namespace). See the out-of-scope list.

### In scope -- ships

| Item | Platform | Cost | Status |
|---|---|---|---|
| `(deny mach-lookup)` + the two DNS allows (A1) | macOS | 3 lines | VERIFIED (Phase 1b run 3 + hand-run TUI) |
| `(deny network-outbound)` + re-allow IP egress + 2 mDNSResponder socket allows | macOS | 4 lines | VERIFIED (row A7, run 5; the mDNS allows are load-bearing -- see run 4) |
| `(deny mach-priv-task-port)`, `(deny iokit-open)` | macOS | 2 lines | SHIPPED, measured free (rows A6/A7). Neither was ever demonstrated reachable -- see addendum Part 3 |
| ~~`(deny sysctl-read (sysctl-name-prefix "kern.proc"))`~~ | macOS | -- | DROPPED, and later measured INEFFECTIVE anyway: no name-prefix rule can match the numeric-MIB read. See addendum D3 |
| unix-socket re-allow scoped to the sandbox's own write roots | macOS | 4 lines | SHIPPED later, measured (addendum D4 + Tier C) |
| `--pasteboard` / `--no-pasteboard`, default off | macOS | one flag | DECIDED; prerequisite cleared by row PB |
| `--tmpfs /run/user/<uid>` and `--tmpfs /run/dbus` | Linux | 4 argv tokens | VERIFIED (C1/C2) |
| `--tmpfs /nix/var/nix/daemon-socket`, unconditional | Linux | 2 argv tokens | mechanical |
| ~~nix `trusted-users` hard-error guard~~ | both | -- | DROPPED as redundant once the socket is closed unconditionally; see Phase 3 |
| README honesty pass (Phase 0 + Phase 4, merged) | -- | docs | highest priority item in this plan |
| snapshot regen + a tight `make test-escape` | both | tests | Phase 5 |

The macOS `network-outbound` class deny is the highest-leverage line in the
table after A1: one rule closes AF_UNIX brokering as a *class*, covering the nix
daemon (F3) and also tmux, editor IPC sockets, docker and ssh-agent -- none
individually probed, all surviving A1, any of them execution outside the sandbox
as the operator. It also makes the darwin half of the old Phase 3 dead code.

### Out of scope -- documented, not fixed

- **`--nix` / `--no-nix` flag. CUT.** Eight touch points for the finding this
  plan itself downgraded to low. The socket denies above close in-sandbox nix
  unconditionally on both platforms, and `nix develop` is the OUTER layer so
  csb's own operation never needs it. If someone needs `nix build` inside a
  sandbox, that is `--no-sandbox`, or a future flag when a real user asks. The
  `trusted-users` guard was ALSO dropped, as redundant once the socket is closed
  unconditionally -- see Phase 3 for the reasoning and for what would make it a
  prerequisite again.
- **Linux abstract unix sockets. ACCEPTED, UNFIXABLE HERE.** Abstract sockets
  are scoped to the network namespace, not the mount namespace, so no `--tmpfs`
  can remove them and only `--unshare-net` closes them -- which contradicts the
  open-egress requirement. X11 (`@/tmp/.X11-unix/X0`) is the practical instance:
  keystroke injection into a host session is execution as the operator. This is
  the cleanest single reason mounts are a patch on Linux rather than a boundary.
- **Linux sockets beyond the two named. ACCEPTED.** `/tmp/tmux-<uid>/default`,
  `/run/docker.sock`, `/run/podman`, and whatever else the host runs are carried
  in by `--ro-bind / /`. A per-path tmpfs list is whack-a-mole with no endpoint.
  Operators who care can enumerate their own exposure with
  `find /run /tmp /var/run -maxdepth 3 -type s`. Document, do not chase.
- **Second unprivileged OS user. NOT NOW.** It was the cheapest real second
  boundary on macOS, but it is a different piece of work from this plan and
  would likely be thrown away if a container/VM boundary is ever built.
- **The macOS keychain root cause.** Row KC did not behave as predicted and the
  service it depends on is unidentified. Moot -- csb authenticates by token or
  seeded file -- and it stays unidentified.
- **Identifying what `open` really talks to. NOT A GATE.** Under a class-level
  deny the name does not need to be known, which is the whole point. If it is
  ever wanted it is one command, and its output doubles as a complete inventory
  of the mach services real claude touches:

      printf '(version 1)\n(allow default)\n(trace "/tmp/open-trace.sb")\n' > /tmp/tr.sb
      /usr/bin/sandbox-exec -f /tmp/tr.sb /usr/bin/open -g -a Calculator
      grep global-name /tmp/open-trace.sb

### Phase 1c -- one more harness row, before Phase 2 lands on macOS

Add row **A5** to `test/manual/ipc-probe-darwin-whitelist.sh`: A1 plus the four
class denies above. It gates only the four new lines, not A1, and it is a cost
measurement -- the escape column is already known to read `blocked`.

- must still show `DNS=resolves`, `HTTPS=http 404`, `CLAUDE (token)=ROUND TRIP OK`
- `sandbox-exec` fails loudly on an unparseable profile, so the row also
  settles the syntax. Try `(allow network-outbound (remote ip "*:*"))` first;
  fall back to `(allow network-outbound (remote ip))`.
- known accepted cost: local dev services reached over a **unix socket** (a
  postgres `.s.PGSQL.5432`, say) stop working in-sandbox. TCP to localhost is
  unaffected, which is the common case.
- drop any individual line that breaks something real. `sysctl-read
  kern.proc` is the most likely to (it backs `ps`), and it is a disclosure fix
  rather than an escape fix, so it is the first to go. Do not spend a second
  afternoon on it.

### Phase 1c RESULTS (2026-07-25, probe runs 4 and 5)

Run 4 measured the `network-outbound` class deny breaking DNS. Run 5 found the
cause and fixed it, so the class deny SHIPS. Both runs are kept below, because
the sequence is the point: the first result looked like "this approach is too
blunt to work" and was actually "one missing allow".

#### Run 5 -- the class deny works (FINAL)

    ID   ESCAPE    DNS       HTTPS     PBPASTE
    CTL  ESCAPED   resolves  http 404  works      <- control, valid
    A1   blocked   resolves  http 404  blocked
    A6   blocked   resolves  http 404  blocked    <- class deny dropped, nix socket by path
    A7   blocked   resolves  http 404  blocked    <- class deny + mDNSResponder socket

Run with `SKIP_CLAUDE=1`, so the claude columns are absent by design -- the
question was DNS, and the `http 404` to api.anthropic.com exercises the same
TCP+TLS path the API uses.

**A7 SHIPS.** DNS needed the mDNSResponder UNIX socket in addition to its mach
service; with two literal allows, the whole `network-outbound` class can be
denied while IP egress, DNS and HTTPS all match the unsandboxed host. That
closes AF_UNIX brokering as a CLASS on macOS -- the nix daemon (F3), and also
tmux, editor IPC sockets, docker, ssh-agent, none of which were individually
probed and all of which are the same shape as F3.

**A6 also came back clean**, which is the useful secondary result: it isolates
`mach-priv-task-port`, `iokit-open` and `sysctl-read kern.proc` as costing
nothing, and it is the measured fallback if A7 ever has to be reverted. Read
"costing nothing" narrowly -- these rows measured DNS, HTTPS and `pbpaste` only,
which is why the `ps` breakage surfaced later and only in a live sandbox.

Accepted cost of A7, now real: services reached over a **unix socket** are
unreachable in-sandbox -- a postgres `.s.PGSQL.5432`, say. TCP to localhost is
unaffected, which is the common case. NOTE, added later: this also covered the
sandbox's OWN sockets, which was not intended and is now fixed for the
sandbox-owned write roots only. See addendum D4.

Unmeasured under A7: the deciding CLAUDE column and the interactive TUI. See the
header of this file.

#### Live in-sandbox verification (2026-07-26)

The shipped profile was then exercised from INSIDE a real `csb --paranoid
--here` session -- the first time any of this was checked against a live sandbox
rather than a hand-built profile. All as intended:

    pbpaste                     0 bytes                             (F2 closed)
    open -g -a Calculator       "Unable to find application"        (F1 closed)
    nix store info              cannot connect to socket ...        (F3 closed)
                                'Operation not permitted'
    dscacheutil / curl          resolves / http 404                 (matches host)
    git, rg, jq, curl, date, id, sw_vers, df, vm_stat, uname, sysctl hw.ncpu,
    sysctl kern.boottime        all working

Note the F1 symptom: `open` fails at the LaunchServices *database* lookup, which
is the mechanism, not a coincidence of Calculator's path.

**One line was dropped as a result.** `(deny sysctl-read (sysctl-name-prefix
"kern.proc"))` breaks `ps` outright:

    $ ps aux
    ps: %mem: requires entitlement
    Failure calling sysctl: Operation not permitted

That is exactly the outcome Phase 1c pre-committed to dropping first -- a
disclosure fix, not an escape fix, costing a tool agents use routinely. The
kern.procargs2 leak (other processes' argv AND environment) is now a documented
open gap in the README. The likely better rule is a narrower `kern.procargs`
prefix, which should miss `kern.proc.all` and leave `ps` working; it is
UNMEASURED and deliberately not shipped on a guess, having just been burned
twice by exactly that.

`iokit-open` and `mach-priv-task-port` cost nothing observable.

#### Run 4 -- why the class deny first looked dead

    ID   ESCAPE    DNS       HTTPS     PBPASTE  CLAUDE(keychain)
    CTL  ESCAPED   resolves  http 404  works    ROUND TRIP OK      <- control, valid
    A1   blocked   resolves  http 404  blocked  FAILS: Not logged in
    A5   blocked   FAILS     FAILS     blocked  FAILS: Not logged in   <- the class deny
    PB5  blocked   FAILS     FAILS     works    FAILS: Not logged in
    KC   blocked   resolves  http 404  blocked  FAILS: Not logged in
    PB   blocked   resolves  http 404  works    FAILS: Not logged in
    A2/A3/A4       resolves  http 404  blocked  FAILS: Not logged in

(No token was exported on this run, so the deciding CLAUDE column read
`(no token)` throughout. It does not matter here: A1 and A2-A4 are unchanged
from run 3, where the token column passed, and the question this run answered
was whether A5 costs anything -- which the DNS column answers on its own.)

**A5 broke DNS, and HTTPS with it.** Note what rules that out: PB5 is A5 plus
the pasteboard allows and shows `PBPASTE=works`, so the profile parsed and
applied and the processes ran. This was the network stack genuinely failing,
not `sandbox-exec` refusing the profile. The HTTPS failure is very likely just
downstream of DNS (the probe resolves api.anthropic.com), so this is probably
one root cause, not two.

The decision at this point was to drop the line per the rule this plan set for
itself, replacing it with a path deny on the nix daemon socket, and to spend
exactly one more row (A7) on the cheap rescue hypothesis. Run 5 vindicated the
rescue, so the drop was reverted and A7 is what ships. The lesson worth keeping:
"one more targeted row" was the right amount of further effort -- both stopping
at run 4 and open-ended debugging would have been worse.

## Environment where everything below was verified

Verified from INSIDE a live `csb --paranoid` session (`--dump-config` reported
`paranoid=true sandbox=true here=true`), aarch64-darwin, Darwin 24.5.0.

    $ id
    uid=1000(atongen) gid=1000(atongen) groups=1000(atongen),...,20(staff),80(admin),...

    $ ls /Users/atongen
    ls: cannot open directory '/Users/atongen': Operation not permitted

The sandbox was working as designed when every probe below succeeded.

Relevant host facts (each with the command that produced it):

    $ ls -ld /Users/atongen
    drwxr-x---+ 139 atongen staff ...            # group staff can read

    $ ls -ld /Volumes/src
    drwxr-xr-x 11 atongen staff ...              # world-readable; code tree lives here

    $ ls -l /private/var/run/nix-daemon.socket
    srw-rw-rw- 1 root daemon 0 ...               # 0666

    $ nix --version
    nix (Determinate Nix 3.13.2) 2.32.4

    $ nix store info
    Store URL: daemon
    Trusted: 0                                   # the operator is NOT a nix trusted-user

    $ nix config show sandbox            # false          (Determinate darwin default)
    $ nix config show sandbox-fallback   # true
    $ nix config show trusted-users      # root

UPDATE, same session: the operator then set `sandbox = true` and
`sandbox-fallback = false` in `/etc/nix/nix.custom.conf`. Verified live:

    $ nix config show sandbox           # true
    $ nix config show sandbox-fallback  # false

This materially shrinks F3 on this host. See "F3 after nix sandbox = true"
below. The F1/F2 findings are unaffected -- they do not involve nix.

Nested `sandbox-exec` does not work, so NO seatbelt rule proposed in this
document has been empirically tested:

    $ printf '(version 1)(allow default)' > /tmp/t.sb
    $ /usr/bin/sandbox-exec -f /tmp/t.sb /usr/bin/true
    sandbox-exec: sandbox_apply: Operation not permitted

This matches the warning in CLAUDE.md and in docs/PARANOID.md. Any verification
of a proposed fix MUST run from a normal terminal, outside csb.

## F1 -- `open` / LaunchServices is a complete macOS sandbox escape

CRITICAL. Applies to normal mode and `--paranoid` equally. Requires no
misconfiguration, no daemon, no credentials.

`/usr/bin/open` asks LaunchServices to launch an application. launchd, not the
sandboxed process, spawns it. The result is not a descendant of the sandboxed
process and therefore inherits no seatbelt profile.

Step 1, the mechanism (this alone proves LaunchServices is reachable):

    $ /usr/bin/open -g -a Calculator ; echo "exit=$?"
    exit=0
    $ ps aux | grep -c '[C]alculator.app'
    1

Step 2, arbitrary code. A minimal `.app` bundle written to `/tmp` (a write root
by design), launched with `open -g`. Locally created files carry no quarantine
xattr, so Gatekeeper does not intervene. The bundle's executable was a `/bin/sh`
script writing its findings to `/tmp/csb-esc.txt`:

    user: atongen uid=1000
    real-HOME listable: YES == ESCAPED
    ~/.ssh/config readable: YES
    ~/.claude/.credentials.json readable: no

That is the operator's own uid, outside the sandbox, with the real HOME readable
-- every path the deny floor exists to protect (`~/.ssh`, `~/.aws`, `~/.gnupg`,
the real `~/.claude`). The escaped process is also in group `admin`.

The `.credentials.json` line is almost certainly just "that file does not exist
on macOS" (claude stores the session credential in the keychain there). Do NOT
read it as evidence of any protection.

`(allow default)` is line 2 of every profile csb generates:

    $ grep -c 'allow default' test/snapshots/darwin/*
    ...:1 for all eight except no-sandbox:0

`--paranoid` is not a mitigation. The escape above was run from inside one.

## F2 -- `pbpaste` reads the host clipboard

Moderate. A read channel that bypasses the entire filesystem deny-list, because
the pasteboard is a mach service and the profile denies only file operations.

    $ /usr/bin/pbpaste | wc -c
    9

Nine bytes of the operator's live clipboard, read from inside a `--paranoid`
sandbox. The clipboard is shared with every host app. If a secret is copied out
of a password manager while an agent is running, the agent can read it.

## F3 -- the nix daemon socket

Medium on macOS, low on Linux. This is the finding that started the
investigation.

`nix develop` is the OUTER layer and the sandbox wraps only the innermost
command (bin/csb:1871, bin/csb:1877). The launched process therefore never needs
`nix` for csb's own operation -- cutting the socket costs csb nothing
structurally.

But the socket is reachable, so in-sandbox `nix` is a client to a root daemon
living outside the sandbox. Builds are performed by the daemon, not by the
sandboxed process:

- macOS: connecting to a unix socket is `network-outbound` in seatbelt, which
  `(allow default)` permits. `(deny file-write*)` does not cover it.
- Linux: `--ro-bind / /` (bin/csb:979) puts the socket in the namespace, and a
  read-only bind mount does NOT block `connect()`.

Probe 1, where the builder lands. A `derivation` with `builder = "/bin/sh"`,
built with `nix build --impure -f`:

    builder-user: _nixbld1 (uid 351)
    can-opendir /Users/atongen: NO
    can-read ~/.zshrc: NO
    can-write /Users/atongen/csb-probe-canary: NO

Probe 2, what it can reach:

    builder-user: _nixbld1
    read /Volumes/src sibling repo README: 59663 bytes
    list /Volumes/src/git.grandrew.com/atongen: 62 entries

Consequences:

1. Arbitrary code execution outside the sandbox, as `_nixbld1`, with host
   network.
2. Reads of anything other-readable. `/Users/atongen` is `drwxr-x---` and
   `_nixbld1` is not in `staff`, so the real HOME is safe HERE -- but by unix
   file mode, not by the seatbelt profile. That is a downgrade from a structural
   guarantee to an incidental one, and it silently breaks on any host whose home
   is 0755.
3. `--deny-read` and `--paranoid-deny-read` are UNENFORCEABLE for any
   other-readable path. The README recommends `paranoid_deny_read=/Volumes`
   for exactly this operator's layout (README:486) to fence sibling repos. That
   recommendation does not hold: a `nix build` reads them freely.
4. Therefore the `--paranoid` guarantee at README:510 is currently true only by
   accident of file modes.

What F3 does NOT grant:

- No escalation to the operator's uid. `nix develop` / `nix run` execute
  in-sandbox as the same user; only daemon-performed builds escape, as `_nixbld1`.
- No new egress. Network is already open by design, so the builder's network is
  not an additional capability.
- No write outside `/nix/store`. `--out-link` and `--add-root` create their
  symlink client-side, so seatbelt still governs them.
- No eval-time read bypass. `builtins.readFile "/Users/atongen/.ssh/..."`
  evaluates in the client, in-sandbox, and is correctly denied.
- No poisoning of the next csb launch. The store is content-addressed; nix
  profiles live under the namespace HOME.

On Linux nix's build sandbox defaults to `true`, so the builder gets a chroot
containing only the store and points 2 and 3 largely collapse. F3 is a
macOS-severity issue, the same asymmetry pattern as the `--paranoid` ancestor
leak already documented at README:525.

### F3 after nix sandbox = true

The probes above ran with the Determinate darwin default `sandbox = false`. After
the operator set `sandbox = true` / `sandbox-fallback = false`, the same probe
shape was rebuilt and the builder is fully contained:

    builder-user: sh: line 1: /usr/bin/id: Operation not permitted
    read /Volumes sibling repo: DENIED
    list /Volumes/src/git.grandrew.com/atongen:  entries
    list /Users:  entries
    read /etc/passwd: DENIED

So on THIS host, F3 consequences 2 and 3 above -- the other-readable file
disclosure and the `paranoid_deny_read` defeat, which was the sharpest part of
F3 -- are CLOSED. `sandbox-fallback = false` also means a sandbox setup failure
now fails the build instead of silently retrying unsandboxed.

What remains of F3, and why the Phase 3 work is still worth doing:

- It is closed by HOST config, not by csb. Any other host -- a fresh Determinate
  install on darwin, a colleague's box, CI -- gets `sandbox = false` again and
  the full finding returns. csb cannot assume this setting.
- The trusted-users cliff below is UNCHANGED and is the severe case.
- Builders still execute outside csb's seatbelt profile, now inside nix's own
  sandbox. Narrow, but it is still a boundary csb does not control.
- Store writes and unbounded build resource use are unchanged. Minor.

Net effect on priority: F3 drops from medium to low ON THIS HOST. Phase 3 is now
mostly about portability, defense in depth, and the trusted-users guard, rather
than about closing a live hole here. F1 was already the priority; this widens
that gap.

### The F3 configuration cliff -- trusted-users

`Trusted: 0` is why F3 is rated medium rather than total. If the launching user
is ever a nix trusted-user (NixOS hosts that add `@wheel`, CI boxes, some
installer paths, a reinstall), then restricted settings become settable from
inside the sandbox: `--option post-build-hook`, `--builders`, `--store`,
`--option sandbox false`. Nix trusted-user is root-equivalent by design, so in
that configuration in-sandbox nix is **root RCE on the host** and a total escape.

Check with `nix store info` and look for `Trusted: 1`.

## F4 -- session dbus is a complete Linux sandbox escape

CRITICAL, VERIFIED on NixOS (jupiter) in BASELINE mode. The Linux analogue of
F1, and the same severity.

Mode coverage, stated precisely because the two platforms differ:

- Every macOS probe in this document ran under `--paranoid`. Paranoid only ADDS
  read denies on top of baseline, so an escape under paranoid implies an escape
  under baseline. F1/F2's "both modes" claim is sound.
- Every Linux probe ran under BASELINE. Paranoid adds `--tmpfs "$real_home"`
  (bin/csb:983), so the implication does NOT run in this direction. F4 under
  `--paranoid` is INFERRED, not measured.

The inference is that paranoid changes nothing for F4, because the escape rides
`/run/user/<uid>/bus` and paranoid only tmpfs's the real HOME and any
`paranoid_deny_read` roots -- neither touches `/run`. The escaped unit lives
outside the namespace either way, so the canary should read the real `~/.ssh`
while the in-sandbox control shows an empty tmpfs, exactly as in baseline.

Confirm with one command before treating F4 as characterized:

    csb -s --here --paranoid -- env XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        /run/current-system/sw/bin/systemd-run --user --wait --unit=csb-f4p \
        /bin/sh -c 'id -un > /tmp/csb-f4p.txt 2>&1;
                    ls -la /home/atongen/.ssh >> /tmp/csb-f4p.txt 2>&1'

Clean up with `systemctl --user reset-failed csb-f4p; rm -f /tmp/csb-f4p.txt`.

bwrap is invoked with `--unshare-pid` only (bin/csb:979-980). `--ro-bind / /`
leaves the session dbus socket at `/run/user/<uid>/bus` reachable, and
`systemd-run --user` over that bus asks the systemd user manager -- which lives
outside the namespace -- to spawn a transient unit.

Control, showing the bwrap tmpfs working as designed:

    $ csb -s --here -- ls -la /home/atongen/.ssh
    total 0
    drwxr-xr-x 2 atongen atongen   40 ... .
    drwx------ 1 atongen atongen 1086 ... ..

The bus is reachable from inside the sandbox once the scrubbed env vars are set
by the sandboxed process itself:

    $ csb -s --here -- env XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        /run/current-system/sw/bin/dbus-send --session --print-reply \
        --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.ListNames
    array [
       string "org.freedesktop.DBus"
       ...
       string "org.freedesktop.systemd1"        <- the user manager
    ]

And the escape, same invocation shape plus `systemd-run --user --wait`:

    Running as unit: csb-f4.service
    Finished with result: success

    $ cat /tmp/csb-f4.txt
    atongen
    total 12
    drwx------ 1 atongen atongen   80 ... .
    drwx------ 1 atongen atongen 1086 ... ..
    -rw------- 1 atongen atongen  100 ... id_ed25519.pub
    -rw------- 1 atongen atongen 1754 ... known_hosts
    -rw------- 1 atongen atongen  932 ... known_hosts.old

Real `~/.ssh` contents, as `atongen`, where the sandbox itself sees an empty
tmpfs. That is a full escape to the operator's uid, exactly like F1.

(No private key appears in that listing on this host. Irrelevant to the finding
-- the escaped unit runs as the operator and can read anything they can.)

Linux is therefore NOT the stronger platform here, contrary to what the README
implies by highlighting its PID namespace. Both platforms are escapable to the
operator's own uid; only the broker differs.

Supporting detail, from the earlier probe:
world-writable inside the sandbox, and the systemd user manager's sockets are
visible:

    $ csb -s --here -- ls -l /run/user/1000/bus
    srw-rw-rw- 1 atongen atongen 0 ... /run/user/1000/bus

Three earlier probe attempts were INCONCLUSIVE, all for non-containment reasons
(this is what motivated the positive-control requirement in Phase 1):
`systemd-run` not on the scrubbed PATH, then `dbus-send` and `systemd-run` both
failing because the env scrub had removed `DBUS_SESSION_BUS_ADDRESS` /
`XDG_RUNTIME_DIR`. Do not read any of those as evidence of containment; setting
the vars inside the sandbox made the escape work immediately.

### F4 mitigation -- note the correction

An earlier draft of this plan proposed `--unshare-ipc` plus a tmpfs over
`/run/user/<uid>`. **`--unshare-ipc` is close to irrelevant here**: it unshares
the SysV IPC / POSIX message queue namespace, which has nothing to do with
AF_UNIX sockets. dbus is a socket in the filesystem, so the load-bearing fix is
purely a mount one -- remove the socket from the namespace:

    --tmpfs /run/user/<uid>

Open questions for Phase 1 on the Linux side:

- confirm F4 under `--paranoid` (command above). Expected to behave identically;
  unmeasured.
- does a tmpfs at `/run/user/<uid>` break anything in the devShell? The env
  scrub already drops `XDG_RUNTIME_DIR`, so probably not, but verify.
- the SYSTEM bus at `/run/dbus/system_bus_socket` is also carried in by
  `--ro-bind / /`. It is polkit-gated for most privileged actions, but it needs
  the same positive-control probe rather than an assumption.
- enumerate what else under `/run` brokers execution before settling on a
  per-path tmpfs list versus something broader.

## F5 -- documentation is wrong

Three specific places:

- README:508-523, "paranoid guarantee (and its bound)". Claims `--paranoid`
  "cannot read file *contents* outside the allow-list". False under F1 (total),
  and under F3 for any other-readable path.
- README:624, "Host-side trust (flake.nix/shellHook **only**)". The word "only"
  is wrong. F3 adds the nix daemon; F1 adds LaunchServices.
- README:639, "Single layer. The seatbelt/bwrap profile *is* the containment."
  Accurate but now reads differently: that layer is filesystem-only and porous
  to IPC. Needs to say so.

## What is NOT affected

Recorded so the response stays proportionate.

- `--no-sandbox` is unchanged and unaffected. It already documents itself as
  having no containment.
- The write allow-list holds. No probe wrote outside an allowed root except via
  the daemon into `/nix/store`.
- The env scrub holds.
- Namespace HOME redirection holds.
- Linux gets a PID namespace; macOS does not, so `ps aux` shows all 560 host
  processes from inside the sandbox. Known, minor, unchanged.
- These blocked cleanly and are NOT vectors:

      $ /bin/launchctl submit -l probe -- /tmp/probe.sh   # exit=1
      $ /bin/launchctl bootstrap gui/1000 /tmp/probe.plist
      Bootstrap failed: 5: Input/output error
      $ /usr/bin/osascript -e 'tell application "Finder" to get name of home'
      execution error: Finder got an error: A privilege violation occurred. (-10004)
      $ (exec 3<>/dev/tcp/127.0.0.1/22)                   # closed, sshd not listening

  `osascript -e 'do shell script "..."'` runs in-process and stays sandboxed
  (it reported `home-denied`).

- `launchctl print gui/1000` DOES work and enumerates 408 services. Information
  disclosure, not execution.

## Plan

### Phase 0 -- honest docs first, no code (DONE 2026-07-25)

The single most important item in this plan, and the only one that protects
anyone using the current release. The README promised something false; the fixes
are days away but the wrong promise was already shipped.

Landed:

- the intro now opens with a threat-model callout instead of burying the pointer
- README "paranoid guarantee" rewritten: it is a FILESYSTEM guarantee, and the
  filesystem is not the only way out
- "Host-side trust (flake.nix/shellHook only)" -- "only" dropped, nix daemon and
  IPC brokering named
- "Single layer" -- says the layer is filesystem-only and porous to IPC
- new "Known gaps" subsection under `## Threat model`, naming F1-F4 with status
- this file lands as the design record

The recipes in this file publish alongside the corrections rather than waiting
for Phase 2. F1 is trivially rediscoverable, the repo is public and single
maintainer, and an operator relying on a false guarantee is the larger harm.

Phase 4 tightens the same passages once Phase 2 lands.

### Phase 1 -- verification harness, must run OUTSIDE csb

Nothing in Phase 2 starts until this reports, because no proposed seatbelt rule
has been tested (nested `sandbox-exec` is impossible; see above).

HARD REQUIREMENT, learned the hard way: every negative result MUST be paired
with a positive control. During this investigation four probes reported failures
that looked like containment and were not:

- `nix` "absent" -- actually just not on the scrubbed PATH; worked via
  `/nix/var/nix/profiles/default/bin/nix`
- `systemd-run: not found` -- not on PATH; NixOS has it at
  `/run/current-system/sw/bin/systemd-run`
- `dbus-send`: "Unable to autolaunch a dbus-daemon without a $DISPLAY" -- the
  env scrub removed `DBUS_SESSION_BUS_ADDRESS`; the socket was reachable the
  whole time
- `systemd-run --user`: "$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not
  defined" -- same cause

None of these were policy denials. Neither PATH nor the env scrub is a boundary:
exec is unrestricted, absolute paths always work, and a process inside the
sandbox can set any environment variable it likes.

So a "blocked" cell in the matrix is only valid if the SAME command, with the
SAME absolute paths and the SAME explicitly-set environment, is shown to succeed
without the deny rule applied. A harness that skips this will manufacture false
"verified fixed" results and Phase 2 will encode them.

Deliverable: `test/manual/ipc-probe.sh`, driving `sandbox-exec` DIRECTLY (not
through csb), sweeping candidate deny sets and printing a matrix of:

- escape blocked? (`open -g` a `/tmp` app bundle; check the canary file)
- `pbpaste` blocked?
- still-works: `claude --version`, tty and `less`, `git`, DNS, the devShell

Candidate mach service names to sweep:

    com.apple.coreservices.launchservicesd
    com.apple.lsd.mapdb
    com.apple.lsd.modifydb
    com.apple.lsd.open
    com.apple.pasteboard.1

Plus, for comparison, a `(deny mach-lookup)`-with-allowlist variant (see
decision 4).

Separately, on the NixOS box, resolve F4 with the `systemd-run --user` probe
above plus a `dbus-send` probe.

Output: a minimal VERIFIED deny set, which is the input to Phase 2.

### Phase 1 RESULTS (2026-07-25)

Both harnesses were run. The `.sh` harnesses are tracked in `test/manual/`
(`ipc-probe-darwin.sh`, `ipc-probe-linux.sh`, `ipc-probe-darwin-whitelist.sh`);
their `.out` captures are gitignored as host-specific, so **the matrices
transcribed into this file are the record** -- re-run a harness to regenerate
one. Positive controls passed in both, so the negative results are meaningful.

macOS -- the proposed name blacklist DOES NOT WORK:

    ID   ESCAPE                   PBPASTE      STILL-WORKS
    P0   ESCAPED (as atongen)     READ 2964b   ls git dns claude     <- control
    P1   ESCAPED (as atongen)     READ 2964b   ls git dns claude     <- launchservicesd
    P2   ESCAPED (as atongen)     blocked      ls git dns claude     <- +lsd.mapdb/modifydb
    P3   ESCAPED (as atongen)     blocked      ls git dns claude     <- +lsd.open/pasteboard
    P4   blocked                  blocked      ls git dns claude     <- (deny mach-lookup)

None of the five guessed service names blocks `open`. It reaches LaunchServices
by a route not identified. Only blanket `(deny mach-lookup)` stopped it.

Two consequences. First, decision-4 option (a), a per-name blacklist, is dead on
macOS -- not merely unproven but measured as ineffective. Second, this is a
positive argument for deny-by-default: under a whitelist the unknown name does
not need to be known, which is exactly what defeated P1-P3.

Incidental: `pbpaste` broke at P2, which does NOT include `pasteboard.1`. The
pasteboard depends on `lsd.mapdb`/`lsd.modifydb` (likely UTI resolution), so F2
falls out of the same change.

Linux -- the proposed mount fix DOES work:

    ID   ESCAPE                     SYSTEM-BUS   STILL-WORKS
    C0   ESCAPED (as atongen)       REACHABLE    ls git dns          <- control (csb today)
    C1   blocked                    REACHABLE    ls git dns          <- --tmpfs /run/user/UID
    C2   blocked                    blocked      ls git dns          <- + --tmpfs /run/dbus

F4 is also CONFIRMED under `--paranoid` against real csb: the transient unit
started and exited 0 (`Running as unit: csb-f4p.service ... success`). The
canary file contents were not captured, so strictly the SPAWN is measured under
paranoid and the READ is inferred -- the unit runs outside the namespace by
construction and baseline already demonstrated the read.

**The platforms have diverged.** Linux has a cheap, targeted, verified fix.
macOS has only a blunt one whose cost is unmeasured. That asymmetry, not the
original finding list, is now the central fact of this plan.

### Phase 1b -- REQUIRED before Phase 2 on macOS

The `STILL-WORKS` column above is NOT trustworthy for P4 and must not be cited
as evidence that deny-all is cheap. It checks exit codes only:

- `dscacheutil` can exit 0 without resolving anything. On macOS `getaddrinfo`
  reaches mDNSResponder over mach, so a blanket `(deny mach-lookup)` should
  break real DNS; this test would not notice.
- `claude --version` prints a string and exits -- no network, no TLS, no
  keychain, no TUI.

So P4 is verified to BLOCK THE ESCAPE and unverified on COST. The whole
feasibility of a whitelist turns on that gap.

Phase 1b harness: `test/manual/ipc-probe-darwin-whitelist.sh`. It starts from
`(deny mach-lookup)` and adds `(allow mach-lookup (global-name ...))` back in
four cumulative tiers until real work functions, measuring real outcomes --
`dig`/`host` output compared against the host, an actual HTTPS request to
api.anthropic.com, and a real `claude -p` round trip -- not exit codes. Likely
candidates to re-allow, in rough order: `com.apple.dnssd.service` /
`com.apple.mDNSResponder` (DNS), `com.apple.trustd` (TLS chain validation),
`com.apple.system.opendirectoryd.api` (getpwuid), `com.apple.cfprefsd.*`,
`com.apple.system.notification_center`, `com.apple.logd`.

Deliberately NOT re-allowed: `com.apple.SecurityServer` / `securityd`. The
README already treats the keychain failing closed as desirable.

The output of Phase 1b is either a working whitelist (option b is viable) or a
demonstration that claude cannot function under one (which promotes option c).

#### Phase 1b RESULTS, first run (2026-07-25)

    host baseline (unsandboxed): dns=resolves  https=404

    ID   ESCAPE    DNS        HTTPS      CLAUDE -p
    CTL  ESCAPED   resolves   http 404   ROUND TRIP OK            <- control, valid
    A1   blocked   resolves   http 404   FAILS: Not logged in
    A2   blocked   resolves   http 404   FAILS: Not logged in
    A3   blocked   resolves   http 404   FAILS: Not logged in
    A4   blocked   resolves   http 404   FAILS: Not logged in

This is a MUCH better result than the claude column suggests.

Under A1 -- blanket `(deny mach-lookup)` plus two DNS names, the smallest
candidate -- the escape is blocked while DNS resolution and HTTPS both match the
unsandboxed host baseline exactly. The network stack is intact. A2 through A4
(trustd, opendirectoryd, cfprefsd, notification_center, logd, and the rest)
changed nothing, so none of them are needed. In particular TLS worked WITHOUT
`trustd`, consistent with claude and curl using bundled CA stores rather than
Security.framework chain validation.

The sole failure is authentication, and it has two causes stacked, neither of
which is "a whitelist cannot work":

1. A HARNESS ARTIFACT. The probe ran `claude` against the operator's REAL HOME,
   so it took the native macOS path and looked for its session credential in the
   keychain, which is a mach service (`securityd`). csb never does this:
   `--seed-creds` copies the credential host-side into a FILE in the namespace
   HOME, and the token path uses an environment variable. Neither touches the
   keychain, so the probe measured a code path csb does not use.
2. A DELIBERATE EXCLUSION. `com.apple.SecurityServer` was left out of the
   whitelist on purpose, because the README already treats the keychain failing
   closed as desirable (see its keychain caveat). The probe then measured that
   choice as a failure.

Note the symptom is identical to the one in docs/PARANOID.md ("Not logged in,
Please run /login") but the cause is different -- that one was seatbelt alias
precedence, this one is an unreachable keychain. Do not conflate them.

Provisional conclusion, PENDING the second run: A1 is a viable whitelist and it
is remarkably small -- two DNS service names. That would make decision-4 option
(b) not merely feasible but cheap, and is the opposite of what the raw table
appears to say.

#### Phase 1b RESULTS, second run -- DECISIVE (2026-07-25)

A second run was attempted and INVALIDATED (see the note at the end of this
section). The third, corrected run is authoritative and is transcribed here in
full, since the `.out` captures are not tracked:

    host baseline: dns=resolves  https=404  auth keychain=OK  auth token=OK

    ID   ESCAPE    DNS       HTTPS     PBPASTE  CLAUDE(keychain)  CLAUDE(token=csb)
    CTL  ESCAPED   resolves  http 404  works    ROUND TRIP OK     ROUND TRIP OK
    A1   blocked   resolves  http 404  blocked  FAILS: Not logged ROUND TRIP OK
    KC   blocked   resolves  http 404  blocked  FAILS: Not logged ROUND TRIP OK
    PB   blocked   resolves  http 404  works    FAILS: Not logged ROUND TRIP OK
    A2   blocked   resolves  http 404  blocked  FAILS: Not logged ROUND TRIP OK
    A3   blocked   resolves  http 404  blocked  FAILS: Not logged ROUND TRIP OK
    A4   blocked   resolves  http 404  blocked  FAILS: Not logged ROUND TRIP OK

Preflight validated both auth paths unsandboxed, and CTL passed everything, so
the control is sound.

**OPTION (b) IS VIABLE.** Row A1 -- blanket `(deny mach-lookup)` plus exactly two
DNS service names -- blocks the escape while DNS, HTTPS, and a real claude API
round trip all work. A2/A3/A4 add trustd, opendirectoryd, cfprefsd and logging
and change nothing, so none are needed. Two names is the entire whitelist.

INTERACTIVE CONFIRMED. The operator ran a real TUI session under the A1 profile
in the same shell: renders, accepts input, gets real model responses, survives a
window resize, terminal paste works, exits cleanly.

**`--pasteboard` IS OFFERABLE.** Row PB (A1 + `pasteboard.1` + `lsd.mapdb` +
`lsd.modifydb`) shows `PBPASTE=works` with `ESCAPE=blocked`, clearing the
blocking prerequisite in Phase 3b -- re-allowing the pasteboard does not hand
LaunchServices a route back.

UNRESOLVED RESIDUAL, recorded rather than papered over: the KC diagnostic did
NOT behave as predicted. Adding `SecurityServer`/`securityd`/`secd` did not
restore keychain auth, so the keychain depends on some service name not
identified here. This is moot for csb -- csb never authenticates via the
keychain, and the token column passes -- but the earlier hypothesis that
`securityd` alone explains the `Not logged in` failure is NOT confirmed. Do not
cite it as established.

SCOPE OF WHAT `(deny mach-lookup)` COVERS. Worth stating because an earlier
draft of this plan understated it: XPC named services are reached via
`xpc_connection_create_mach_service`, which seatbelt governs through
`mach-lookup`. So this single deny closes mach AND XPC-named-service brokering,
which is the bulk of macOS IPC -- not merely the LaunchServices instance. What
remains outside it: `iokit-open`, `sysctl-*`, and filesystem sockets such as the
nix daemon (Phase 3). Smaller than feared, but not nothing.

INVALID RUN, kept for the lesson: the second run should be ignored entirely
(its capture is not tracked). A placeholder token was exported, which failed unsandboxed
AND -- through a harness bug, since `sandbox-exec` inherits the environment --
overrode the keychain column too, so every row failed for reasons unrelated to
the sandbox. The control row caught it. The harness now runs the keychain column
under `env -u CLAUDE_CODE_OAUTH_TOKEN` and preflights both auth paths before
applying any profile.

### Phase 2 -- IPC containment (fixes F1, F2, F3 and F4)

Ships together with Phase 3b -- `(deny mach-lookup)` removes `pbcopy`/`pbpaste`,
which docs/TODO.md:4 records as a delivered feature, so landing Phase 2 alone is
a silent regression. One change, not two.

Linux, verified and ready to implement: extend the bwrap argv (bin/csb:979-980)
with `--tmpfs /run/user/<uid>` and `--tmpfs /run/dbus`, plus
`--tmpfs /nix/var/nix/daemon-socket` for F3. Note the earlier correction:
`--unshare-ipc` is NOT the fix and is close to irrelevant here.

macOS. Emitted after `echo "(allow default)"` (bin/csb:907):

    (deny mach-lookup)
    (allow mach-lookup (global-name "com.apple.dnssd.service"))
    (allow mach-lookup (global-name "com.apple.mDNSResponder"))
    (deny network-outbound)
    (allow network-outbound (remote ip "*:*"))
    (allow network-outbound (literal "/private/var/run/mDNSResponder"))
    (allow network-outbound (literal "/var/run/mDNSResponder"))
    (allow network-outbound (subpath "<each sandbox-owned write root>"))
    (deny mach-priv-task-port)
    (deny iokit-open)

WHAT SHIPPED, as of the addendum: exactly the above. Two later corrections are
folded in -- the `(deny sysctl-read (sysctl-name-prefix "kern.proc"))` line this
section originally listed is GONE (dropped as breaking `ps`, then measured
ineffective regardless: addendum D3), and the sandbox-owned `subpath` re-allows
were ADDED so the class deny stops cutting the sandbox's own unix sockets
(addendum D4).

The first three lines are the A1 set, VERIFIED by Phase 1b run 3: escape
blocked, DNS and HTTPS identical to the unsandboxed host, real claude API round
trip working, interactive TUI confirmed by hand. Do NOT add
trustd/opendirectoryd/cfprefsd/logd -- A2-A4 measured as unnecessary, and every
added name is surface.

The remaining lines are the class denies from "Resolution and scope", VERIFIED by
Phase 1c run 5 (row A7). The two mDNSResponder literals are load-bearing, not
defensive: without them DNS fails even though the mach service is allowed -- that
is what run 4 measured. They close, in order: AF_UNIX brokering as a class (the
nix daemon of F3, plus tmux, editor IPC sockets, docker, ssh-agent -- all
unprobed, all surviving A1), debugger attach to host processes (macOS has no PID
namespace), and IOKit. The `kern.procargs2` disclosure is NOT closed and cannot
be -- see addendum D3.

Known fallout to document in Phase 4, beyond the browser login flow:

- `git` with `credential.helper=osxkeychain` cannot reach the keychain, so HTTPS
  push/pull breaks in-sandbox. SSH remotes are unaffected.
- System-configured HTTP proxies / PAC are read via a mach service, so a
  corporate proxy setup breaks. `com.apple.SystemConfiguration.configd` is the
  name to add IF that is ever reported -- not preemptively.
- HOST services reached over a unix socket stop working; TCP is unaffected. The
  sandbox's own in-tree sockets keep working (addendum D4).

Note the keychain stays unreachable under this profile, which is consistent with
the README's existing position that the keychain failing closed is desirable. It
does mean native keychain login is unavailable in-sandbox, so `--seed-creds` or
a token becomes REQUIRED rather than merely recommended. That is a real
behavioural change and belongs in the Phase 4 docs.

#### The pasteboard is a shipped feature, not just a leak (DECIDED: make it a flag)

F2 (`pbpaste` reading the host clipboard) and in-sandbox copy/paste are the SAME
capability. `docs/TODO.md:4` records `[X] allow copy&paste from within a sandbox`
as deliberately delivered, and bin/csb:1856 appends `/usr/bin` to PATH partly so
`pbcopy`/`pbpaste` resolve by name. Blanket `(deny mach-lookup)` removes it.

So option (b) is NOT zero-cost: it trades a shipped feature for the escape fix.
Phase 1 measured the collateral -- `pbpaste` broke at P2, which did not even name
`pasteboard.1`, so the pasteboard depends on `lsd.mapdb`/`lsd.modifydb`.

Decision (operator, 2026-07-25): expose it as a flag rather than choosing for the
user. See Phase 3b.

Design call, DECIDED: the IPC denies are ALWAYS-ON, with no `--allow-ipc` hatch.
Sandbox escapability is not a usability axis anyone wants to tune, and
`--no-sandbox` already exists as the deliberate full escape hatch. The rule that
settles future cases: **expose named capabilities, never expose the boundary.**
`--pasteboard` is on the right side of that line; `--allow-ipc` is not.

Known fallout: claude's "open this URL to log in" browser flow breaks. With
`--seed-creds` or a token that flow is never used. Document it.

Every generated profile changes, so all snapshots regenerate on BOTH platforms
(`make test-update` on macOS and on NixOS).

### Phase 3b -- the pasteboard axis (macOS; addresses F2)

New boolean `--pasteboard` / `--no-pasteboard` plus profile key `pasteboard=`,
mirroring `paranoid` at the same touch points listed for `--nix` in Phase 3
(help text bin/csb:56-145 and the `--no-*` list at :145; default and `_cli` var
at :1245; arg parse at :1287-1288; `profile_bool` at :1077; unknown-key list at
:1099; precedence at :1168; `--dump-config` emit at :1487).

Semantics: under Phase 2's `(deny mach-lookup)` whitelist, `--pasteboard` adds
the allows that make `pbcopy`/`pbpaste` work again. From Phase 1, that is at
least `com.apple.pasteboard.1` plus `com.apple.lsd.mapdb` and
`com.apple.lsd.modifydb`, since the pasteboard broke at P2 which named only the
lsd pair. The exact minimal set must be measured, not assumed.

DEFAULT: off. The capability is an un-deniable read channel around the entire
file deny-list -- if a secret is copied out of a password manager while an agent
is running, the agent can read it -- so the safe value is the default and the
operator opts in per run or per profile.

PREREQUISITE: CLEARED. The concern was that re-allowing `lsd.mapdb`/
`lsd.modifydb` might hand LaunchServices a route back and reopen F1. Row PB of
Phase 1b run 3 measures exactly this set and reports `PBPASTE=works` with
`ESCAPE=blocked`, so the flag can be offered. Keep the PB row in the harness as
a regression guard -- if a future macOS changes this, the flag has to go.

Linux: no equivalent. The clipboard there is an X11/Wayland concern, unaffected
by the `/run/user/<uid>` tmpfs.

No-op when `--no-sandbox` is in effect, like the other sandbox flags.

### Phase 3 -- the nix axis (addresses F3) -- FLAG CUT, guard kept

The `--nix` / `--no-nix` flag is **CUT**. It was eight touch points (help text
bin/csb:56-145; default and `_cli` var at :1245; arg parse at :1287-1288;
`profile_bool` at :1077; unknown-key list at :1099; precedence at :1168;
`--dump-config` emit at :1487; emission at :823) for the finding this plan
downgraded to low once the host set `sandbox = true`. Phase 2's class denies
close the daemon socket on both platforms with no flag, `nix develop` is the
OUTER layer so csb never needs in-sandbox nix for its own operation, and
`--no-sandbox` covers anyone who genuinely wants to `nix build` in there.
Revisit only if a real user asks.

Chokepoint, recorded because it constrains any future revisit: denying the `nix`
BINARY by path is worthless -- `/tmp` is a write root and exec is unrestricted,
so `cp /nix/store/.../nix /tmp/nix` defeats it. The socket is the only real
chokepoint, and Phase 2 closes it:

- Darwin: subsumed by `(deny network-outbound)` -- the daemon socket is AF_UNIX.
  No nix-specific rule is emitted.
- Linux: `--tmpfs /nix/var/nix/daemon-socket`, unconditional.

**The trusted-users guard: DROPPED at implementation time, as redundant.** The
plan kept it on the reasoning that the cliff (a nix trusted-user makes
in-sandbox nix root-equivalent via `--option post-build-hook`) is undetectable
after the fact. But that cliff needs an in-sandbox nix CLIENT, and Phase 2 now
makes the daemon socket unreachable on both platforms with no opt-in -- so there
is no client to escalate. Guarding it would have added a `nix store info` daemon
round trip to every launch to defend a path that is already cut.

It becomes a PREREQUISITE again the moment either of these changes:

- a `--nix` flag is added, re-opening the socket by choice
- the macOS `(deny network-outbound)` block is ever dropped (the row A6
  fallback). In that case macOS also needs the old targeted rule back:
  `(deny network-outbound (literal "<realpath of the daemon socket>"))`, from a
  host-side `realpath /nix/var/nix/daemon-socket/socket`, skipped if absent.

### Phase 4 -- documentation

README:

- reframe `## Filesystem sandbox` (README:361). It is not only a filesystem
  boundary.
- new subsection on process brokering and IPC: what `open` did, what is now
  denied, and explicitly that a mach-name blacklist CANNOT be proven complete.
- new subsection on nix inside the sandbox: `_nixbld1`, outside seatbelt, the
  `trusted-users` cliff (documented only -- the guard was dropped, see Phase 3),
  that in-sandbox nix is now off
  with no flag, and the recommended host config (`sandbox = true`,
  `sandbox-fallback = false` in `/etc/nix/nix.custom.conf`).
- tighten the passages Phase 0 corrected: the "Known gaps" list moves from
  "verified, unfixed" to "closed in vN, with these accepted residuals", and the
  Phase 2 fallout list (osxkeychain git credentials, system proxy/PAC, unix
  socket dev services) gets documented.
- state in the threat model that F3's blast radius on any given host is bounded
  by file modes, not by the profile.

This file: update the status line from Proposed to Implemented, record what
Phase 1 actually found, and split closed vs. accepted.

docs/TODO.md: the open "hardening for the untrusted-instruction threat model"
bullet gains weight. F1 is direct evidence that the in-profile approach cannot
yield a guarantee on macOS, which strengthens the existing VM / second-boundary
item (docs/PLAN-003.md).

### Phase 5 -- tests

The suite today is DUMP-ONLY: Tier 1 config/validation via `--dump-config`,
Tier 2 snapshots via `--dump-sandbox`. Nothing launches
(test/helpers.bash:60-91). That is precisely why F1 was invisible to it.

- Tier 2: regenerate all snapshots on both platforms; add `pasteboard-on` cases.
  No `nix-*` cases -- the flag is cut.
- Tier 1: `--pasteboard` / `--no-pasteboard` precedence and profile-key tests,
  mirroring the existing paranoid cases in test/precedence.bats.
- NEW Tier 3, KEPT (decision 5, resolved yes): `test/escape/escape.bats` plus a
  `make test-escape` target. Real launches asserting the escapes are closed:

      csb -s -E --here -- /usr/bin/open -g -a Calculator   # must fail
      csb -s -E --here -- /usr/bin/pbpaste                 # must fail
      csb -s -E --here --pasteboard -- /usr/bin/pbpaste    # must WORK (PB regression guard)
      csb -s -E --here -- nix store info                   # must fail

  Must skip itself when already inside csb (sandbox-exec cannot nest) and when
  the devShell is unavailable. Not part of default `make test`; a pre-release
  gate. Keep it to a handful of assertions -- this is the only tier that would
  have caught F1, and the only reason to grow it is a new verified escape.

## Resolved decisions

All five open decisions were resolved on 2026-07-25. Nothing here is blocking.

- **Pasteboard.** F2 and in-sandbox copy/paste are one capability, and the
  latter is a shipped feature (docs/TODO.md:4). Rather than silently dropping it
  or silently keeping the leak, expose `--pasteboard` / `--no-pasteboard` +
  `pasteboard=`, default OFF. See Phase 3b; its blocking prerequisite was
  cleared by row PB of Phase 1b run 3.

1. **nix default. MOOT -- the flag is cut.** In-sandbox nix is closed
   unconditionally on both platforms by the Phase 2 socket denies, which is also
   why the `trusted-users` hard-error guard was dropped rather than shipped:
   there is no in-sandbox client left to escalate. See Phase 3.
2. **IPC denies always-on, no `--allow-ipc`.** Rule: expose named capabilities,
   never expose the boundary. `--no-sandbox` is the one hatch and it announces
   itself.
3. **Phase 0 timing: immediately.** Done, alongside this file. An operator
   relying on a false guarantee is the larger harm, and the repo is public.
4. **Blacklist vs. whitelist: option (b), extended.** (a) is measured dead
   (P1-P3 all escaped). (b) is measured viable and cheap on macOS (two DNS
   names, escape blocked, TUI confirmed), and Linux has its own verified fix
   (C1/C2). Extended, because (b) as originally scoped closes ONE seatbelt
   filter class and leaves four others in exactly the pre-F1 state F1
   exploited -- so Phase 2 also denies `network-outbound`, `mach-priv-task-port`,
   `iokit-open` and `sysctl-read kern.proc`, each one line.
   **The answer to "is b sufficient, or b-then-c" is: neither.** Extended (b)
   makes csb's claim a testable property rather than a list of patched holes,
   and it is what the current implementation gets. It is still not a boundary
   against a hostile agent and the docs now say so. Something like (c) would be
   needed for that claim; it is not scheduled, not promised, and not a gate on
   this work. Until and unless it exists, the answer to the residual is "don't
   run untrusted instructions under csb", stated plainly in the README.
5. **Tier 3 escape tests: yes, tightly scoped.** A handful of assertions and an
   opt-in `make test-escape`. It is the only tier that would have caught F1.

### What would reopen this

Recorded so a future reader knows what evidence matters:

- the A5 row shows a class deny breaking real work -- then that line is dropped
  and the corresponding gap moves to the accepted list
- a broker turns up that survives extended (b) -- then the profile approach is
  finished on macOS and the only remaining moves are a different mechanism or a
  narrower claim
- an operator needs csb to contain untrusted instructions -- extended (b) does
  not do that and never will, and today the only honest answer is "don't"

## Reproduction recipes

All must be run from inside a csb sandbox, EXCEPT the seatbelt-rule
verification, which must be run outside one.

F1, the escape. Write `/tmp/X.app/Contents/Info.plist` (CFBundleExecutable
`probe`, CFBundleIdentifier `local.csb.probe`, LSBackgroundOnly true) and
`/tmp/X.app/Contents/MacOS/probe` (a `chmod +x` `/bin/sh` script writing
`id -un` and `ls /Users/<you>` results to `/tmp/out`). Then
`/usr/bin/open -g /tmp/X.app` and read `/tmp/out`.

F2: `/usr/bin/pbpaste | wc -c`

F3: build a `derivation { builder = "/bin/sh"; args = [ "-c" "... > $out" ]; }`
with `nix build --impure --no-link --print-out-paths -f probe.nix`, then `cat`
the out path. Reach `nix` via
`PATH=/nix/var/nix/profiles/default/bin:$PATH` or
`PATH=/run/current-system/sw/bin:$PATH`.

F3 cliff check: `nix store info` and look at the `Trusted:` line.

F4 (NixOS): `csb -s --here -- systemd-run --user --pty /usr/bin/id`

## Probe artifacts created and removed

Recorded for audit. All were cleaned up; verified absent at the end of the
session.

- `/tmp/csb-probe.nix`, `/tmp/csb-probe2.nix`, `/tmp/t.sb` -- removed
- `/tmp/csb-probe.sh`, `/tmp/csb-probe.plist`, `/tmp/csb-esc.txt` -- removed
- `/tmp/CsbProbe.app` -- removed
- `/tmp/lcl`, `/tmp/lcerr` -- removed
- Two `nix build` outputs under `/nix/store` (`csb-escape-probe`,
  `csb-escape-probe2`), built with `--no-link`, so ungarbage-collected only
  until the next `nix store gc`
- One `Calculator` process launched and killed; one `CsbProbe` background app
  that self-exited. Verified none remaining:
  `ps aux | grep -i 'csbprobe\|calculator' | grep -v grep` returned nothing
- `launchctl remove csb-ipc-probe` and
  `launchctl bootout gui/1000/csb-ipc-probe2` were run; both submissions had
  already failed, and `launchctl print gui/1000/csb-ipc-probe2` confirmed no
  such service

---

# ADDENDUM -- closeout review (2026-07-26, from an UNSANDBOXED session)

Everything above was written from inside a csb sandbox, where `sandbox-exec`
cannot nest and the shipped artifact cannot be exercised. This addendum was
produced from a normal terminal, so the things the plan had to leave as
inference are now measured. Every claim below carries its command.

Nothing in the code, the README or the goldens was changed while writing this.
It was a proposal.

**STATUS: the proposal in Part 4 was accepted and implemented the same day.**
Tiers A, B and C all shipped, including the optional item 9. `make check` is
clean, and `make test` (81) plus `make test-escape` (8, two of them new) pass on
aarch64-darwin.

**NixOS run, same day -- header item 2 is CLOSED.** `make test` passes there and
`make test-update` produces an EMPTY diff, which is the pass criterion D2's
marker was introduced to create: the Linux goldens are now host-independent
rather than a hand-patched guess. F4 also executed as a test for the first time
and passed.

That run found one bug, and it is the same bug this document has now made four
times: **the positive control asserted on `/bin/echo`, which does not exist on
NixOS**, so the only test whose job is to prove the harness works was itself
broken on the platform where it mattered. Fixed to `/bin/sh -c 'echo ok'`. Two
assertions were hardened in the same pass, because `assert_failure` alone is
satisfied by a missing binary just as well as by containment -- exactly the trap
Phase 1's hard requirement exists to stop:

- F4 now also asserts `refute_output --partial "Running as unit"`. It had been
  invoking `/bin/true`, which is likewise absent on NixOS, so its pass was
  unfalsifiable.
- F3 now also asserts `refute_output --partial "Trusted:"` -- a field the daemon
  supplies, so its absence is the round trip failing. Note `Store URL:` CANNOT
  serve here: nix prints it from config before connecting, so it appears in the
  blocked output too. Measured, not assumed.

**A third name was then added to the mach-lookup whitelist, because the profile
shipped with uid->name resolution broken.** Asking a plain usability question --
can the sandbox still reach a host postgres? -- turned it up immediately:

    $ csb -s -E --here -- psql -h localhost ...
    psql: error: local user with ID 1000 does not exist
    $ csb -s -E --here -- id -un
    id: cannot find name for user ID 1000          # whoami prints "1000"

`getpwuid` goes through a mach service, so `(deny mach-lookup)` broke it, and
libpq treats a missing username as fatal over EVERY transport -- TCP included,
which is why this is not a socket-policy story. Isolated by bisecting names
against a bare `(allow default)` control: the fix is
`com.apple.system.opendirectoryd.libinfo`. Note the trap -- Phase 1b's A2-A4 rows
tested `com.apple.system.opendirectoryd.api`, cleared the directory services as
"unnecessary", and were measuring a DIFFERENT service; `.api` does not fix it.
The three probes those rows ran (curl, dscacheutil, claude) never call
`getpwuid`. Verified the re-allow costs nothing: `open -g -a Calculator` still
fails with "Unable to find application" and `pbpaste` still fails.

That is the second whitelist name established only by someone stumbling into the
breakage (the first was the mDNSResponder socket literal, run 4). Both are
invisible to Tier 1/2, which validate the profile TEXT rather than what it
permits. So Tier 3 now has a second file, `test/escape/usable.bats`: one
assertion per re-allowed name -- uid resolves, DNS resolves, TCP+TLS to the API
works. **Adding a name to the whitelist means adding the assertion that
justifies it.** `escape.bats` stays what its header says it is.

Answering the original question, measured against a live Homebrew postgres:
in-sandbox `psql -h localhost` works; `psql` with no host fails, because libpq
falls back to `/tmp/.s.PGSQL.5432` and `/tmp` is shared with the host, so it is
denied by design. The practical trap is that the socket is libpq's DEFAULT -- a
Rails `database.yml` with no `host:`, or `DATABASE_URL=postgres:///db`, breaks
in-sandbox until it names a host.

The interactive TUI under the shipped profile remains a manual check -- the only
item in this plan never verified by automation.

## Part 1 -- what holds up

**The Tier 3 gate passes, and this was its first ever run.**

    $ make test-escape
    ok 1 escape: open(1) cannot reach LaunchServices (F1)
    ok 2 escape: pbpaste cannot read the host clipboard (F2)
    ok 3 escape: --pasteboard re-allows pbpaste WITHOUT reopening F1 (row PB)
    ok 4 escape: the nix daemon socket is unreachable (F3)
    ok 5 escape: systemd-run --user ... (F4) # skip Linux only
    ok 6 escape: a real launch still works (positive control)

**Header item 1 is CLOSED for the API path.** A real claude round trip under the
SHIPPED profile -- not a hand-built harness row -- works:

    $ ./bin/csb -E --here --seed-creds -- -p 'reply with exactly: ok'
    ok

That is the deciding column the plan could only infer from `http 404`. The
interactive TUI remains unmeasured by automation; it is the same profile plus a
pty, and the operator already ran a TUI under A1 by hand.

**`--pasteboard` genuinely works**, which no test asserts (see D6):

    $ /usr/bin/pbpaste | wc -c                                        # 18
    $ ./bin/csb -s -E --here --pasteboard -- bash -c '/usr/bin/pbpaste | wc -c'
    18

`make check` is clean. The Linux goldens are internally consistent with the
bwrap argv order the code emits (the three IPC tmpfs pairs land after
`--die-with-parent` and before `--tmpfs $real_home`), so the hand-patch was done
correctly as far as ordering goes -- it still needs `make test-update` on NixOS
for the existence question, which is header item 2 and D2 below.

## Part 2 -- defects

### D1. The darwin snapshot goldens are wrong: `make test` fails 9/9 snapshots

    $ nix develop --command bats test/          # from a normal terminal
    not ok 46..54   (every snapshot test)
    +(allow file-write* (subpath "/private/tmp"))

ROOT CAUSE, measured: the goldens were regenerated from INSIDE a csb sandbox,
where the confstr lookup behind `getconf` is denied and libc falls back to
`$TMPDIR`:

    $ csb -s -E --here -- bash -c 'getconf DARWIN_USER_TEMP_DIR'
    /tmp/nix-shell.SinoZu                     # dirname(realpath) = /private/tmp
    $ getconf DARWIN_USER_TEMP_DIR            # host, and inside plain nix develop
    /var/folders/9y/5_l9m.../T/

`normalize_sandbox` derives its `<VARTMP>` placeholder the same way
`build_write_roots` does, so inside a sandbox that placeholder silently stood for
`/private/tmp` -- which absorbed the real `/private/tmp` write root and made it
look like the `/var/folders` one. Confirmation from both directions:

    $ csb -s -E --here -- bash -c 'bats test/snapshots.bats'   # all 10 ok
    $ nix develop --command bats test/snapshots.bats           # 9 of 10 fail

The CODE is fine. `build_write_roots`' `case` guard rejects the non-`/var/folders`
parent and warns instead of write-allowing it, so nothing over-broad was ever
emitted -- the guard did exactly its job. But the comment at bin/csb:810-812
("Derived via getconf, NEVER from $TMPDIR") states the wrong reason: `getconf`
itself falls back to `$TMPDIR`. The guard, not the choice of `getconf`, is what
holds.

Fix: `make test-update` from a normal terminal (it adds one write line to all
nine, plus the matching `file-read*` line in the four paranoid goldens), and add
a guard so this cannot recur -- `CSB_SANDBOX=true` is exported at bin/csb:1951,
so the Tier 2 helper can refuse to compare or refresh when it is set. Snapshot
goldens are a host-fingerprint artifact; they must be generated from one known
context and that context is "a normal terminal".

### D2. CI will go red on the next push to GitHub, on both runners

`github/main` is still at 445ba42, so this has not run yet.

- macos-latest: D1's missing line.
- ubuntu-latest: the Linux goldens hardcode all three `--tmpfs` paths, but
  bin/csb emits each only `[[ -d "$p" ]]`. On a GH runner `/run/user/<uid>` is
  usually absent (no login session) and `/nix/var/nix/daemon-socket` exists only
  after the installer step. A conditional argv cannot have an unconditional
  golden -- structurally the same defect as D1, and it will also bite any
  contributor whose Linux box differs from the NixOS one.

Fix, in the test tier rather than the code (the conditional emission is correct
behaviour -- bwrap cannot mkdir a mountpoint under the ro root): collapse the
IPC tmpfs block to a single stable marker in `normalize_sandbox`, and assert the
real thing separately -- "for each of the three broker paths that exists on this
host, a `--tmpfs` is emitted". That is host-independent and keeps the review
value the goldens exist for.

### D3. The kern.procargs2 gap is NOT closeable by seatbelt. The trail is dead.

The README and this plan both leave the door open: "a narrower `kern.procargs`
prefix would likely do better and has not been measured." It is now measured,
with a compiled probe reading the numeric MIB directly and a canary process
holding `CSB_SECRET_CANARY=hunter2`:

    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };  sysctl(mib, 3, ...)

    profile                                                    result
    host, unsandboxed (control)                                7324 bytes, LEAKED
    (allow default) alone                                      7324 bytes, LEAKED
    the shipped IPC rules                                      7324 bytes, LEAKED
    + (deny sysctl-read (sysctl-name-prefix "kern.procargs"))  7324 bytes, LEAKED
    + (deny sysctl-read (sysctl-name-prefix "kern.proc"))      7324 bytes, LEAKED
    + (deny sysctl-read)            <- blanket                 7332 bytes, LEAKED
    + (deny sysctl*)                <- blanket                 7332 bytes, LEAKED

Not even a blanket deny stops it, because `sysctl-name-prefix` matches the STRING
name and `KERN_PROCARGS2` is reached by numeric MIB, which has no name to match.
Meanwhile the blanket denies do break real tools:

    ncpu=sysctl: sysctl fmt -1 1024 1: Operation not permitted
    uname=uname: sysctl: Operation not p...

So the line that was dropped never would have worked, and the narrower
replacement it suggested does not work either. Two corrections follow:

1. This gap belongs in the same category as Linux abstract sockets -- **open,
   UNFIXABLE with this mechanism** -- not "open, accepted because denying it
   broke `ps`". The README currently invites a reader to spend an afternoon on a
   rule that cannot work.
2. The recorded cost is also not reproducible. `/bin/ps` is setuid root, and
   seatbelt refuses to exec a setuid binary under ANY profile -- including a bare
   `(allow default)`:

       $ sandbox-exec -f <(printf '(version 1)\n(allow default)\n') \
           /bin/bash -c 'ps aux | wc -l'
       1                                  # /bin/ps: Operation not permitted
       $ csb -s -E --here -- /bin/ps aux
       /bin/ps: Operation not permitted

   `ps` does not work inside csb today, with or without the sysctl deny. The
   `ps aux` transcript in "Live in-sandbox verification" cannot have come from
   inside the sandbox. That is the plan's own positive-control rule catching the
   plan -- and it is the third time in this investigation a symptom was
   attributed to the wrong cause.

### D4. In-sandbox unix sockets are cut too, and the docs imply otherwise

The README says "local dev services reached over a **unix socket** stop working",
which reads as host services. Two processes inside the SAME sandbox also cannot
talk over one, with a positive control:

    $ csb -s -E --here --no-sandbox -- <nc -lU + nc -U probe>   received=[hello]
    $ csb -s -E --here            -- <same probe>               client-rc=1

That breaks a Rails worktree's `tmp/sockets/puma.sock`, `spring`, `pg_ctl -k
$PWD/tmp`, an in-tree `ssh -S` ControlPath, and any test suite that boots a
service on a socket in the repo. It is the largest unadvertised cost of the
`network-outbound` class deny.

A scoped re-allow fixes it, measured (note the realpath form is the one that
matches, which is why the mDNSResponder pair needs both spellings):

    (allow network-outbound (subpath "<realpath'd write root>"))   -> works

But it must NOT be applied to the shared write roots. Measured: with
`/private/tmp` re-allowed, a HOST-side socket in that tree is reachable again
(`rc=0`), which is F3's shape returning. So the defensible form is repo-scoped
only -- worktree, git common dir, namespace/ephemeral HOME -- and explicitly not
`/private/tmp`, `/private/var/folders` or `/dev`. Those trees are created and
owned by the sandbox, so a socket in them is one the sandbox itself made.

### D5. This file contradicts itself in six places

- line 134: the three class denies are still marked "needs the A5 row below";
  they were measured (A6/A7) and one of them was dropped.
- lines 150-156: "The `trusted-users` guard still ships" -- Phase 3 (line 1060)
  and the ships-table (line 138) both say DROPPED.
- line 228: A6 "isolates ... `sysctl-read kern.proc` as costing nothing" --
  contradicted 30 lines later, and A6 only measured DNS/HTTPS/pbpaste.
- lines 940-951: the Phase 2 profile block still lists the dropped sysctl line
  and calls the remainder "seven lines"; six shipped.
- line 1085: Phase 4 tells the README to document "the `trusted-users` cliff and
  its hard-error guard" -- a guard that does not exist.
- line 1113 and bin/csb:990: `test/escape.bats`; the file is
  `test/escape/escape.bats`.

Also the header says IMPLEMENTED (2026-07-25) while the live verification and
the commit are 2026-07-26.

### D6. The PB regression guard only asserts half of what it was specified to

Phase 5 called for two assertions: `--pasteboard` restores `pbpaste`, AND it does
not reopen F1. `test/escape/escape.bats:49` implements only the second -- it runs
`open -g -a Calculator` with the flag and asserts failure. So the flag can rot
to a no-op silently. Part 1 shows the positive half passes today, so the
assertion is free to add.

### D7. Two doc overclaims

- bin/csb:51-55 (help): "host IPC does NOT [stay reachable] (mach/XPC on macOS,
  the session bus on Linux, unix sockets on both)". On Linux only three paths are
  removed; unix sockets are emphatically NOT closed as a class there. The README
  is honest about this; the help text is not.
- README Known-gaps table lists `task_for_pid` as an escape "**closed**". It was
  never demonstrated reachable -- see Part 3.

### D8. README duplication and a dangling colon

Lines 766-767 and 782-783 say the same thing about Linux having no socket filter.
Worse, the paragraph at 782-785 ends "...which is not implemented and not
promised:" and the colon runs straight into the `### Hardening for untrusted
instructions` heading. Somewhere a list was lost in editing.

## Part 3 -- implemented but of no measured value

- **`(deny mach-priv-task-port)` and `(deny iokit-open)`.** Zero cost, zero
  demonstrated vector. `task_for_pid` against another process already requires
  root or a debugger entitlement on modern macOS, so this line is belt-and-braces
  over an OS restriction rather than a fix for anything probed. KEEP both -- they
  are free and they are what makes "these classes are deny-by-default" a true
  statement -- but stop describing task_for_pid as a closed escape (D7).
- **`test/manual/ipc-probe-darwin.sh`.** Its question -- is a mach-name blacklist
  viable -- is settled, measured dead, and transcribed. It has no remaining use
  beyond being the reproduction. Keep it or delete it; the whitelist harness
  supersedes it. This is the only artifact in the change I would call dead weight.
- **`test/snapshots/linux/pasteboard`.** Byte-identical to `linux/baseline`. That
  identity IS the assertion (the flag is a documented no-op on Linux). Keep.
- The dropped `sysctl` line and the dropped `trusted-users` guard were both
  correctly dropped. Only their stale references remain (D5).

An unasked-for dividend worth recording: `(deny network-outbound)` +
`(allow network-outbound (remote ip "*:*"))` now ships, so docs/TODO.md's
localhost-only egress mode is a one-token change to that allow line
(`"localhost:*"`) rather than new machinery. Not a task -- a door that opened.

## Part 4 -- proposal

Same rule the plan set for itself: ship it if it is one line or one flag AND
measured. Everything below is measured.

**Tier A -- required, the tree is not green without it.**

1. `make test-update` from a normal terminal; commit the nine darwin goldens.
2. Guard Tier 2 against `CSB_SANDBOX` (bin/csb:1951) so a golden can never again
   be generated or validated from inside a sandbox. ~2 lines in
   `test/helpers.bash`.
3. Make the Linux IPC tmpfs block host-independent (D2): marker in the
   normalizer, plus one existence-driven assertion. Then `make test-update` on
   NixOS closes header item 2.
4. Fix D8 (the duplicate paragraph and the dangling colon).

**Tier B -- docs coherence, no code.**

5. Rewrite the `kern.procargs2` paragraph and table row per D3: **open,
   unfixable with seatbelt**, with the four-variant measurement as the reason,
   and delete the "a narrower prefix would likely do better" invitation.
6. Correct the six internal contradictions in this file (D5) and the two
   overclaims (D7). Fix bin/csb:990's stale test path and the comment at
   bin/csb:810-812.
7. Document D4's real scope: unix sockets are cut for the sandbox's own processes
   too, not only host services -- with the Rails `tmp/sockets` case named,
   because that is how it will actually be met.

**Tier C -- optional, recommended, measured.**

8. Add the missing PB positive assertion (D6). One line.
9. Re-allow `network-outbound` on the REPO-SCOPED write roots only (D4). Three
   lines inside the existing write-roots loop, gated to exclude the shared roots.
   It restores in-tree unix sockets with no new host exposure, and the `nc`
   probe from D4 belongs in `escape.bats` as its guard. Do this only if an
   in-tree socket is something you actually want back; the honest alternative is
   Tier B item 7 alone.

**Explicitly closed, do not reopen.**

- the `kern.procargs`/`kern.proc` sysctl rule, in every form (D3)
- identifying what `open` really talks to -- already out of scope, and now moot
  twice over
- a per-path Linux socket list beyond the three that ship

**Left open, honestly.** The interactive TUI under the shipped profile is still
hand-verified only. The residual the plan names -- this is not a boundary against
a hostile agent -- is unchanged, and D3 makes it slightly larger than the README
currently admits: any process's environment is readable from inside the sandbox
and there is no seatbelt rule that changes that.

## Probe artifacts created and removed (this session)

- 14 ephemeral `$TMPDIR/csb-home.*` dirs from the real launches above, REMOVED.
  One of them held a live `.claude/.credentials.json` copied in by the
  `--seed-creds` round trip; verified zero remaining. The 26 older ones are
  pre-existing and were not touched -- `-E` homes are not reaped on exit, which
  is worth its own look someday.
- `/tmp/csbuds/` and `/tmp/csb-uds-*` unix-socket probes, REMOVED. AF_UNIX paths
  are capped at 104 bytes, which invalidated the first run of that probe until
  the socket was moved out of the scratch dir -- another false negative caught
  only by its control.
- one `env CSB_SECRET_CANARY=hunter2 sleep 300` canary and two `nc -lU`
  listeners, killed; verified none remaining.
- `.sb` profiles, the `procargs2` C probe and its binary, and a scratch clone of
  the repo used for the golden regen: all under this session's scratchpad, none
  in the repo, none in `/tmp`.
- one nested `claude -p` API round trip (Part 1) -- it answered `ok` and exited.
