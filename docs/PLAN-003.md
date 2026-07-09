# plan 003

Not implemented (yet)!

## Run the sandbox in a lightweight VM for a real second boundary

An additive, opt-in `--vm` mode that runs claude (or the `-s` shell) inside a
lightweight Linux/NixOS guest instead of the in-process seatbelt/bwrap deny
wrapper. The existing deny-list mode stays the default and is untouched; `--vm`
is selected per run or per profile.

### Why (the driver)

Today's containment is a single privileged layer with two capabilities held
open by design: broad filesystem *reads* and open network *egress* (see the
README threat model and `docs/PLAN-002.md`). Under *trusted* instructions that
is defensible. Under *untrusted* instructions (prompt injection from a fetched
page, a poisoned dependency/issue) it is weak: anything the agent can read, an
injection can read, and anything readable can be shipped off-box. `docs/TODO.md`
names the two real fixes -- a second boundary and controllable egress -- and
notes that on macOS seatbelt this "cannot be a profile tweak" because seatbelt
has no process-isolation primitive and cannot filter egress by hostname. A VM is
the documented successor for exactly this.

A VM converts both open capabilities from blacklist to whitelist:

- **Reads become a whitelist by construction.** The guest sees only what csb
  mounts into it -- the worktree and the namespace HOME. The real HOME is simply
  never mounted. This replaces the deny-list floor (a blacklist that fails open;
  the standing risk in plan-002) with "nothing is visible unless shared."
- **Egress becomes enforceable by hostname.** seatbelt filters network by
  ip/port only (verified in plan-002: `host must be * or localhost`), which is
  why the `allowedDomains` proxy was removed. At the VM boundary a hostname
  allowlist is tractable again -- and this time it is enforced *below* the agent,
  not by a flag the agent's own process could relax.
- **Repo-controlled code moves off the host.** Today the repo's `flake.nix`
  shellHook and `.worktreesetup.sh` run unsandboxed on the host (the accepted
  "host-side trust" hole). In `--vm` mode `nix develop` and the setup script run
  *inside the guest*, closing that hole.

### Decisions (settled 2026-07-09)

1. **Additive, opt-in.** `--vm` (and profile `vm=true`) selects VM mode. The
   seatbelt/bwrap deny-list remains the default and the only mode when `--vm` is
   absent. No behavior change for existing invocations.
2. **Backend: Lima.** It is the only option that is genuinely one tool on both
   macOS and Linux, has a maintained NixOS-guest path, is in nixpkgs, and shares
   directories performantly on both hosts. Rationale and the rejected
   alternatives are below.
3. **Linux/NixOS guest on every host, including macOS.** One guest OS -> one
   code path and identical containment on mac and linux (no seatbelt-vs-bwrap
   divergence). Consequence, accepted: the repo's flake must expose a Linux
   `devShells.default` (e.g. `aarch64-linux`), and `nix develop` runs in the
   guest. Trade-offs in "The Linux-guest requirement" below.
4. **Whitelist mounts, not a deny-list.** Only the worktree and the active
   namespace HOME are shared (read-write) into the guest. The real HOME, other
   namespaces, other repos: never mounted. The `--paranoid` distinction
   disappears in VM mode -- VM reads are always a whitelist.
5. **Egress is default-deny with a hostname allowlist** (phase 3). The default
   allowlist covers what claude and provisioning genuinely need (Anthropic API,
   nix substituters during provisioning, the flake's git remotes); users extend
   it via config. This is the `allowedDomains` idea from before, resurrected at
   the layer where it is actually enforceable.
6. **Unprivileged agent user in the guest** (phase 3). claude runs as a non-root
   guest user with no sudo; the egress firewall and mount policy are root-owned
   at boot, so the agent cannot relax them. This is the second boundary the
   single-layer model lacks.
7. **Mechanism isolated in one helper**, mirroring `build_deny_wrapper` today.
   A single `build_vm_launch` (and a guest-side entrypoint) is the only place
   that knows about Lima, so a future microvm.nix / vfkit backend is a swap, not
   a rewrite.

### Backend research and rejected alternatives

Verified 2026-07 against upstream docs (URLs below).

- **Firecracker -- rejected.** Linux/KVM only (no macOS) and, decisively,
  **block-device only**: no virtiofs, no 9p (a deliberate design choice,
  firecracker issue #1180). It therefore *cannot mount a live, editable git
  worktree* -- the core of csb's workflow. Wrong tool here regardless of host.
- **microvm.nix -- deferred as a future Linux/NixOS backend, not the primary.**
  Nix-native and declarative, NixOS-guest, excellent on Linux/KVM
  (qemu/cloud-hypervisor/crosvm/kvmtool all do virtiofs). But on macOS it works
  *only* via `vfkit` (Apple Virtualization.framework) and needs a Linux builder
  to build the guest -- less turnkey than Lima on the mac path. Attractive
  enough on NixOS hosts (fully declarative, no non-nix tool) that the launcher
  is kept backend-pluggable so a microvm.nix backend can be added later
  (decision 7).
- **Lima -- chosen.** Runs on macOS (Apple `vz` driver) and Linux (QEMU/KVM)
  from one tool and one config. NixOS guest via the `nixos-lima` template.
  Packaged in nixpkgs (`lima`). Shares directories via virtiofs (macOS `vz`;
  Linux via the Rust virtiofsd, with 9p/reverse-sshfs fallbacks). Host services
  are reachable from the guest as `host.lima.internal`. Per-instance disks
  persist, so a per-namespace instance amortizes the nix store across runs. It
  is a full VM (not a microVM), but `vz` boot on Apple Silicon is fast.
- **libkrun/krunvm -- noted, not chosen.** Genuinely cross-platform microVM
  (HVF on macOS, KVM on Linux), fast, virtiofs, in nixpkgs -- but oriented
  around OCI images, not booting a NixOS guest. A possible future backend if the
  sandbox is ever expressed as an OCI rootfs; not the NixOS-VM path this plan
  takes.

Sources: microvm-nix.github.io/microvm.nix/shares.html;
github.com/firecracker-microvm/firecracker/issues/1180;
lima-vm.io/docs/config/{vmtype,mount,network/user}; github.com/nixos-lima/nixos-lima;
github.com/crc-org/vfkit; github.com/libkrun/libkrun.

### Architecture

Host-side, csb keeps doing only git plumbing and now VM lifecycle; all
repo-controlled code executes in the guest.

```
host (csb)                              guest (Lima NixOS instance, per namespace)
----------                              -------------------------------------------
git worktree add (as today) ---------> [virtiofs rw]  /csb/worktree
resolve/seed namespace HOME ---------> [virtiofs rw]  /csb/home   (HOME + CLAUDE_CONFIG_DIR)
build_vm_launch: ensure instance,
  mounts, port-forwards, env       --> limactl shell <inst> -- csb-guest ...
                                            |
                                            +-- (unpriv. agent user, phase 3)
                                            +-- run .worktreesetup.sh (in guest now)
                                            +-- nix develop /csb/worktree
                                                  --command claude|bash
                                            +-- egress: default-deny + allowlist (phase 3)
host localhost db/redis  <--- host.lima.internal / curated port-forwards ---+
```

- **Instance identity.** One Lima instance per namespace:
  `csb-<repo-key>-<ns>` (reusing the existing repo-key + namespace scheme).
  Persistent by default so the guest nix store and devShell survive across runs;
  `csb -d` deletes the instance alongside the worktree/namespace. Ephemeral `-E`
  maps to a throwaway instance torn down on exit.
- **Shares (whitelist).** Two virtiofs mounts, both read-write: the worktree and
  the namespace HOME. Nothing else from the host is mounted -- that *is* the read
  boundary. `HOME` and `CLAUDE_CONFIG_DIR` inside the guest point at the mounted
  namespace HOME, so seeding, credentials, caches, and history persist exactly
  as they do today.
- **nix in the guest.** The guest is NixOS with nix + network. It runs
  `nix develop /csb/worktree --command ...` and gets the claude binary the same
  way csb does today, but for the guest system:
  `nix build $CSB_SELF#claude` (aarch64-linux). First run builds the linux
  devShell into the guest store; the persistent instance amortizes it.
- **Guest entrypoint.** A small `csb-guest` script (shipped in csb's flake, put
  on the guest via the share or the base image) does the in-guest half: run
  `.worktreesetup.sh`, apply `.worktreeenv`, `nix develop --command claude|bash`.
  Host `csb` passes it the scrubbed env overrides, `-s`/args, and `-y`. The
  worktree provisioning, `.worktreeinclude`, and credential/AWS seeding stay
  host-side (they touch host git and host secrets); the code-execution steps
  move into the guest.
- **Networking.**
  - *Local host services* (db/redis for testing) stay reachable, satisfying the
    same requirement as today. Two mechanisms: `host.lima.internal` (guest ->
    host gateway), or curated port-forwards so the repo's `localhost:5432`
    resolves to the host service unchanged. The forward list is itself part of
    egress control -- only declared ports cross.
  - *Egress* (phase 3): default-deny at the guest boundary with a hostname
    allowlist enforced by root (guest nftables + a small allowlisting proxy;
    `HTTPS_PROXY` pointed at it, direct egress dropped). Default allowlist:
    Anthropic API + nix substituters (provisioning) + the flake git remote.
    User-extensible via `${XDG_CONFIG_HOME:-~/.config}/csb/allowed-domains`
    (add-only, same parse discipline as `deny`/`allow-write`).
- **Two-phase network.** Provisioning (nix fetch/build of the devShell + claude)
  needs the substituters and git remotes; the locked-down run phase needs only
  the Anthropic API + forwarded services + the user allowlist. Provision with
  the wider set, then drop to the run allowlist before exec'ing claude, so an
  injection during the run cannot reach arbitrary hosts.

### The Linux-guest requirement (trade-offs)

Chosen (decision 3) because one guest OS gives one code path and identical
containment everywhere. The costs, stated plainly so the choice is revisitable:

Pros
- Identical behavior and containment on macOS and Linux; no per-OS sandbox
  divergence to maintain (seatbelt vs bwrap collapses to one guest).
- The guest is a NixOS csb fully controls -> the egress firewall, unprivileged
  user, and mounts are declarative and reproducible.
- Repo `flake.nix`/shellHook/`.worktreesetup.sh` execute in the guest, closing
  the host-side-trust hole (the whole point of the hardening driver).

Cons
- The repo must expose a Linux `devShells.default` (e.g. `aarch64-linux`). Repos
  that are macOS-only (darwin-specific toolchains) cannot use `--vm`. csb fails
  fast with guidance, exactly like the existing "no devShell for this system"
  guard.
- On macOS the guest runs `aarch64-linux`. Pure-nix devShells build natively in
  the guest (no host Linux builder needed if we ship/pull a prebuilt base image
  via nixos-lima and build the devShell in-guest). x86_64-only tooling needs
  Rosetta (vz supports it) or emulation.
- Heavier than a process wrapper: a persistent VM per namespace (disk + memory).
  Acceptable for the hardening use case; the default deny-list mode remains for
  the lightweight case.
- First-run latency: VM create + in-guest devShell build. Amortized by the
  persistent per-namespace instance.

A macOS-native alternative (keep the darwin devShell, isolate via a second OS
user or a macOS-native VM) was considered and set aside: it forks the codebase
per-OS and, for the darwin path, still lacks a clean egress-control story. If the
Linux-guest cost proves too high for common repos, this is the fallback to
revisit.

## Implementation phases

### phase 1: VM launch, open network (parity + read whitelist)

Goal: `csb --vm ...` boots a per-namespace Lima NixOS instance, shares the
worktree + namespace HOME, runs claude/`-s` shell in the guest devShell, with
open network. This alone delivers the read-whitelist second boundary.

- flake.nix: add a `lima` runtime input/package reference; add the `nixos-lima`
  guest template (pinned) and a `csb-guest` script package. Keep everything
  Linux+Darwin (Lima is in nixpkgs for both).
- bin/csb: add `--vm`/`--no-vm` flags and profile `vm=true`; add
  `build_vm_launch` (the single mechanism helper) and a VM branch at the two
  exec sites (`--shell` and claude), parallel to the current `deny_wrapper`
  branch. Reuse `setup_namespace`, `seed_home_template`, `seed_claude_config`,
  `seed_credentials`, `.worktreeinclude`, env-override assembly unchanged;
  route the *execution* through `limactl shell <inst> -- csb-guest`.
- Instance lifecycle: create-or-reuse `csb-<repo-key>-<ns>`; `-E` -> throwaway;
  `csb -d` also `limactl delete`s the instance; `csb -n` provisions the
  worktree + instance without launching.
- Guard: fail fast if the repo has no `devShells.<linux-system>.default`
  (extend the existing guard).

Acceptance (macOS + Linux):

    csb --vm -s -E --here -- cat /csb/worktree/flake.nix   # worktree visible
    csb --vm -s -E --here -- ls "$HOME"                     # only namespace HOME
    csb --vm -s -E --here -- cat ~/.ssh/config             # fails: never mounted
    csb --vm -s -E --here -- curl -s host.lima.internal:<svc>  # host svc reachable
    csb --vm -E --here                                     # claude launches, auths

### phase 2: worktree code moves into the guest; ergonomics

- Run `.worktreesetup.sh` and apply `.worktreeenv` inside the guest (they are
  repo-controlled -- the point is to keep them off the host in VM mode).
- Curated port-forwards: a config/profile way to map `localhost:PORT` in the
  guest to a host service, so repos that hardcode `localhost` work unmodified.
- Persist + reuse the guest nix store across runs (verify the persistent
  instance actually amortizes; document first-run cost).
- `--vm` composes with existing flags: `-p/--profile`, `--aws` (inject creds as
  guest env), `--seed-creds`, `--seed-home`, `-y`, `--ns`, `-L`.

Acceptance:

    csb --vm -p drip feature/foo         # profile + VM together
    csb --vm --aws role -s -E --here -- aws sts get-caller-identity  # role in guest
    <second run of same ns starts fast; no devShell rebuild>

### phase 3: the hardening payoff -- unprivileged user + egress allowlist

- Guest runs claude as a non-root user with no sudo; nftables default-deny
  egress + mount policy owned by root at boot.
- Allowlisting proxy in the guest; `HTTPS_PROXY`/`HTTP_PROXY` set for the agent;
  direct egress dropped except DNS + proxy + forwarded host ports.
- Default allowlist (Anthropic API, nix substituters for provisioning, flake git
  remote) + user `allowed-domains` file (add-only, parse-error-aborts, matching
  the `deny`/`allow-write` discipline).
- Two-phase network: provision wide, then drop to the run allowlist before exec.

Acceptance:

    csb --vm -s -E --here -- curl -s https://api.anthropic.com   # allowed
    csb --vm -s -E --here -- curl -s https://example.com         # blocked
    csb --vm -s -E --here -- sudo -n true                        # no sudo
    csb --vm -E --here                                           # claude still works

### phase 4: docs + cleanup

- README: a `--vm` section -- what it adds over the deny-list mode (read
  whitelist, hostname egress control, host-side-trust closed), the Linux-guest
  requirement and its trade-offs, port-forward/host-service story, the
  `allowed-domains` format, and a clear statement of what each mode is for
  (deny-list = trusted, lightweight; `--vm` = untrusted-instruction hardening).
- Update the README "Hardening for untrusted instructions" section to point at
  `--vm` as the implemented second boundary + egress control.
- docs/TODO.md: fold in / close the hardening item this plan implements.

## Risks / notes

- **Not a microVM.** Lima is a full VM; boot + first-run provisioning cost is
  real. Mitigation: persistent per-namespace instance; the default deny-list
  mode stays for the lightweight case.
- **Guest store size.** A nix store per namespace instance costs disk. Document;
  consider a shared store optimization later (out of scope).
- **Egress allowlist completeness (phase 3).** Too tight breaks tools that fetch
  at runtime; too loose weakens the point. The default set is the reviewed floor;
  users extend via `allowed-domains`. Revisit after real use, like the deny-list.
- **host.lima.internal / port binding.** Host services bound to `127.0.0.1` only
  are not reachable via the gateway; port-forwards or binding to a routable
  interface are needed. Document.
- **Cross-arch.** x86_64-only repo tooling on Apple Silicon needs Rosetta or
  emulation; pure-nix aarch64-linux devShells are the smooth path.
- **Lima is a non-nix tool dependency** (unlike seatbelt/bwrap which are OS/nix).
  It is in nixpkgs, so csb can pin it via its flake; keeping `build_vm_launch`
  the single integration point preserves the option to swap to a microvm.nix or
  libkrun backend without touching the rest of csb.

## Open questions (non-blocking)

- Guest base image: track `nixos-lima` upstream, or vendor a pinned csb guest
  NixOS config in this flake (more control over the phase-3 firewall/user, more
  to maintain)? Leaning vendored once phase 3 lands.
- Should `--vm` and the deny-list ever compose (VM *and* an in-guest bwrap), or
  is the VM boundary sufficient on its own? Default: VM alone; the unprivileged
  guest user is the in-guest boundary.
- Ephemeral `-E` in VM mode: throwaway instance per run (clean, slow) vs a
  shared scratch instance with a throwaway HOME (fast, weaker isolation).
  Default: throwaway instance, matching `-E` semantics.
