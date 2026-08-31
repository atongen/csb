# TODO

- [X] debug the logout expirations (tied to session stop/start with credential seeding) and reduced model options set
    * renenable claude instrumentation and telemetry?
    * use oauth token instead of credential seeding? At one point I thought that using the oauth token was what lead to the reduces model options set - need to confirm, I could have been mistaken
    * platform differences? (macos vs [headless?] linux [nixos])
    * are these objectives in conflict?
    * honestly, the workflow with credential seeding is obnoxious, it would be great to remove it. Do we give up more powerful models here?
- [X] block access to homebrew on macos - ie. do not allow execution of `brew` within the sandbox. Confirm paranoid mode cannot even read from /opt/homebrew or /usr/local, etc.
      ANSWERED (2026-08-31). It needs config, not code -- and the paranoid
      assumption above is FALSE.
    * `--paranoid` does NOT fence it. Its read deny is scoped to the real HOME,
      so `/opt` and `/usr` stay readable in BOTH modes and
      `/opt/homebrew/bin/brew --prefix` runs fine under it. The README section
      is now "`--paranoid`: whitelist reads under HOME" so the lede stops
      implying a filesystem-wide whitelist.
    * `deny_read=/opt/homebrew` is the whole fix: it emits `(deny file* (subpath
      "/opt/homebrew"))` -- `file*`, so it stops exec as well as read, in both
      modes. Add `/usr/local` (the Intel prefix) and `/home/linuxbrew` for
      portability.
    * NOT a hardening gap. Writes to the prefix are already denied -- the
      profile is `(deny file-write*)` plus a five-entry allow-list (worktree,
      `/private/tmp`, `/dev`, namespace, `.git` minus hooks/config) -- so `brew
      install` cannot mutate it. That closes the interesting case, since the
      prefix is user-writable (`atongen:admin`) and a planted binary would run
      on the HOST later; same family as the `.worktreesetup.sh` / `flake.nix`
      host-exec residual in PLAN-004. `brew` is not on PATH either (nix owns
      PATH; the shim adds only `$HOME/bin` and `/usr/bin`, bin/csb:2230-2231).
      What remains is exec by ABSOLUTE path, so the goal here is a hermetic
      toolchain, not containment.
    * deliberately NOT in the built-in floor: that floor is a credential
      blacklist, and a toolchain path muddies what it means -- it would also
      break anyone whose devShell does not cover what they had been getting
      ambiently. Operator config plus a README recipe is the right shape.
    * bound: hygiene, not containment. An agent can still fetch a static binary
      into the writable worktree and run it -- the README's existing position on
      the blacklist generally.
- [X] customize devshell argument based on either shell mode or claude mode via config.
      DONE (2026-07-25): `--nix-target NAME` (profile `nix_target=`) selects
      `devShells.<system>.NAME`; `--nix-target-shell` / `--nix-target-claude`
      (`nix_target_shell=` / `nix_target_claude=`) override it for one mode and
      win when that mode runs; `--no-nix-target` clears all three. The winning
      target also applies to `.worktreesetup.sh`. A NAMED target never falls
      back to csb's generic devShell (which only provides `default`) -- a
      missing one is a hard error. See README "Choosing the nix target".
    * naming: `nix-target` is not nix's own vocabulary (nix says "installable"
      or "flake output attribute"), but it is the right call here precisely
      because it is looser than "devshell" -- `nix develop` resolves the name
      as `devShells.<system>.NAME` first and falls through to a package attr,
      so the flag is not strictly limited to devShells.
- [X] claude statusline script should include token use count
- [X] allow copy&paste from within a sandbox
    * REVISED (2026-07-25): the pasteboard is a mach service, so the IPC denies
      that close the LaunchServices escape remove it too. It is now the opt-in
      `--pasteboard` / `pasteboard=`, default OFF -- it is a read channel around
      the whole file deny-list. See docs/PLAN-007-escape.md phase 3b.
- [X] close the IPC sandbox escapes (docs/PLAN-007-escape.md). DONE (2026-07-25),
      reviewed and corrected 2026-07-26 (see that plan's ADDENDUM).
      F1/F2/F3/F4 closed. macOS denies two whole seatbelt filter classes
      (mach-lookup, network-outbound-minus-IP), which closes AF_UNIX brokering
      as a class; Linux is per-path tmpfs and cannot be complete.
    * the closeout review found the darwin snapshot goldens had been regenerated
      from INSIDE a sandbox (where `getconf DARWIN_USER_TEMP_DIR` falls back to
      $TMPDIR), so `make test` was red on the host; Tier 2 now refuses to run in
      there at all. The claude API round trip under the shipped profile is
      confirmed. `sysctl kern.procargs2` was measured UNFIXABLE with seatbelt --
      no name-prefix rule can match a numeric-MIB read -- so that trail is
      closed, not deferred.
    * VERIFIED on NixOS: `make test` green, `make test-update` an empty diff (the
      Linux goldens are host-independent now, not a hand-patched guess), and F4
      ran as a test for the first time. That run also caught the positive control
      asserting on `/bin/echo`, absent on NixOS -- fixed, and F3/F4 hardened so a
      missing binary can no longer read as containment.
    * the macOS mach-lookup whitelist is THREE names: two for DNS and
      `com.apple.system.opendirectoryd.libinfo` for getpwuid. The third was
      missing at first, so `id -un` printed the raw uid and psql refused to
      connect over any transport. New `test/escape/usable.bats` holds one
      assertion per re-allowed name -- add a name, add its assertion.
    * host services over a unix socket stay unreachable by design (postgres on
      /tmp/.s.PGSQL.5432 included; use `-h localhost`/`PGHOST`). Sockets in the
      sandbox's own trees work.
    * REMAINING: the interactive TUI under the shipped profile is hand-verified
      only, the one item never covered by automation.

- [X] State as of the last session
    - csb's own `flake.nix` now exposes `devShells.default` (git + shellcheck), so
      `csb --here` / `csb <branch>` can launch claude inside csb itself.
    - A pre-launch guard (bin/csb, just before `setup_namespace`) fails fast when a
      repo's `flake.nix` has no devShell for this system, instead of nix develop's
      cryptic "does not provide attribute" error.
    - Read deny-list floor expanded (cloud/infra/db creds + REPL/shell histories;
      see README "The read deny list").
    - New `--paranoid` flag (and profile key): flips reads to deny-real-HOME-minus-
      allowlist. Verified end-to-end on macOS/seatbelt AND Linux/bwrap (NixOS):
      claude logs in, real-home and sibling-namespace reads denied, active-namespace
      reads allowed; under bwrap the real HOME is tmpfs'd and the worktree/namespace
      remain readable.
      * Fixed a seatbelt alias-precedence bug that logged claude out under paranoid:
        a later `(allow file* ns)` does NOT override an earlier `(deny file-read*
        real_home)`, so the namespace needed its own `file-read*` re-allow. See
        docs/PARANOID.md.

- [X] first live dogfood run: from the csb main checkout, `csb --here -s -- shellcheck bin/csb`
      (shell mode, no claude needed) should enter the devShell and pass; then
      `csb --here` to confirm claude launches. nix ignores UNTRACKED files, so
      `git add flake.nix` before the run if not yet staged.
- [x] verify `--paranoid` on Linux/bwrap: confirmed the real HOME is tmpfs'd and
      the worktree/namespace remain readable.

- [x] verify the Linux (bubblewrap) sandbox end-to-end on NixOS — the gating
      milestone from plan-002. DONE: phase-2 acceptance commands pass, plus
      write-policy probes (worktree/tmp writable, $HOME not), --unshare-pid (only
      own processes visible), and --ro-bind / not breaking the devShell.
- [x] allow referencing a "template" directory for populating sandbox $HOME.
    * DONE: `--seed-home DIR` / profile `seed_home=` (default ~/.config/csb/home)
      copies the template's files into the launch HOME every launch,
      non-overwriting (`--reseed` to overwrite). Seeds before the onboarding
      .claude.json so a template-provided one is merged. See README "Seeding the
      sandbox HOME". (env/auth config was already covered by profiles.)
- [x] publish to the public distribution home. DONE, then REVERSED (2026-08-05):
      csb is not published. CSB_SELF's default (bin/csb, Makefile, README, flake
      template hint) is the private remote
      `git+ssh://git@git.grandrew.com/atongen/csb.git`, so a launch needs ssh
      access to it; a `path:` override remains the way to run against a local
      working tree. Reason: operator choice -- csb stays private and
      unredistributed for now, and licensing implications are deferred (the
      agent-sandbox rebase that raised the question was since rejected on
      technical grounds). See docs/PLAN-009-proxy.md appendix A.1.
- [ ] revisit the deny-list defaults after the first month of use (blacklist
      completeness is the standing risk; see docs/PLAN-002.md risks). Floor was
      expanded once already; `--paranoid` (whitelist reads) is the escape hatch
      when the blacklist feels insufficient.
- [x] ~~designed-but-deferred: per-profile / per-run deny and allow-write
      additions, so one app's extra write root doesn't have to be granted
      machine-wide.~~ DONE (2026-07-21): the four read/write lists are now
      profile vars (`deny_read=`, `allow_write=`, `paranoid_deny_read=`,
      `paranoid_allow_read=`) and repeatable CLI flags (`--deny-read`,
      `--allow-write`, `--paranoid-deny-read`, `--paranoid-allow-read`),
      accumulating like keep=/setenv= across base + .local, add-only over the
      built-in floor. The change went further than the sketch: the machine-wide
      config (deny/allow-write/config files) was removed entirely — the tmp dir
      moved to `CSB_TMPDIR`, and `paranoid_deny=` became `paranoid_deny_read=`.
      `paranoid_allow_read` is new (re-expose a read under --paranoid WITHOUT
      write; rejected at build time if it overlaps a deny). Load-bearing
      constraints held: values come ONLY from operator-authored sources
      (profiles under ~/.config/csb, outside every write root, + CLI flags),
      never from repo/worktree files; and allow_write widens --paranoid READS
      too (write roots are read-re-allowed there).
- [x] ~~future --aws upgrade path (out of scope for plan-002): host-side
      credential broker + AWS_CONTAINER_CREDENTIALS_FULL_URI, viable because
      sandbox networking is open — would fix the no-refresh-in-session caveat.~~
      DROPPED (2026-07-14): the whole `--aws`/`aws_profile=` credential-injection
      feature was removed from bin/csb and the README (no ongoing need). See the
      removal note in docs/PLAN-002.md phase 3. `~/.aws` stays in the deny-list.
- [ ] hardening for the untrusted-instruction threat model (single layer +
      open egress is the exposure; see README "Hardening"). Highest leverage:
      a second boundary — separate unprivileged OS user, or a lightweight VM
      (Tart/UTM/Lima) with a controllable network, which is also sandbox-exec's
      documented successor. macOS seatbelt has no process-isolation primitive,
      so this cannot be a profile tweak.
    * companion, now SHIPPED: `--filter-egress` (PLAN-008, complete 2026-08-08)
      is opt-in per-host egress control on both platforms -- a CONNECT allowlist
      proxy outside the sandbox, enforced by the seatbelt profile on macOS and
      by a pasta netns + nftables default-drop on Linux. It bounds the
      destinations of an exfiltration, not its content: the proxy does not
      decrypt, so there is no per-path or per-method filtering. The second
      boundary above remains the higher-leverage move.
- [ ] VERIFY ON NIXOS: the Linux `--filter-egress` namespace now has a PRIVATE
      loopback -- pasta runs with `-t none -u none -U none` and an explicit
      `-T <proxy_port>[,<allow_port>...]` instead of the default `auto`
      forwarding, which had mapped every host-bound loopback port into the
      namespace and left the nft port set as the only thing narrowing it. Two
      payoffs: the isolation stops depending on one rule, and `--allow-loopback`
      costs nothing on Linux (intra-sandbox loopback free, host loopback still
      shut) rather than what it costs on macOS, where one shared loopback makes
      the same split impossible. A third payoff was not the goal: `-t auto` had
      also published ports the SANDBOX bound onto the host's loopback, since
      that direction's `auto` forwards "all ports currently bound in namespace"
      -- a dev server started inside a filtered sandbox was reachable from the
      host without anything asking for it. `-t none` closes it.
      Flag semantics confirmed against pasta 2025_09_19.623dbf6 (`-T/--tcp-ns`
      is the namespace->host direction, `none` and comma-lists valid for all
      four). RUNTIME still unmeasured: `make test-escape` plus a `curl` through
      the proxy is what settles it, and the proxy path is what breaks if the
      forwarding is wrong.
