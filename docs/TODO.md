# TODO

- [X] claude statusline script should include token use count
- [X] allow copy&paste from within a sandbox

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
- [x] publish to the public distribution home. DONE: the repo is pushed to
      `github.com/atongen/csb`, which is CSB_SELF's default (bin/csb, Makefile,
      flake template hint, README), so `make install` and `nix run
      github:atongen/csb` work out of the box for outside users. A CSB_SELF
      override (a local `path:` checkout) is now only needed for local
      development against a working tree.
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
    * lower-leverage companion: opt-in localhost-only egress mode (seatbelt
      `(deny network-outbound)` + `(allow ... (remote ip "localhost:*"))`,
      verified working; hostname allowlisting is NOT natively possible and
      would mean re-adding the removed proxy subsystem).
