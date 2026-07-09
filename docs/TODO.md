# TODO

## Resume here (dogfooding csb-on-csb)

State as of the last session (all UNCOMMITTED in the working tree):
- csb's own `flake.nix` now exposes `devShells.default` (git + shellcheck), so
  `csb --here` / `csb <branch>` can launch claude inside csb itself.
- A pre-launch guard (bin/csb, just before `setup_namespace`) fails fast when a
  repo's `flake.nix` has no devShell for this system, instead of nix develop's
  cryptic "does not provide attribute" error.
- Read deny-list floor expanded (cloud/infra/db creds + REPL/shell histories;
  see README "The read deny list").
- New `--paranoid` flag (and profile key): flips reads to deny-real-HOME-minus-
  allowlist. Verified end-to-end on macOS/seatbelt: claude logs in, real-home
  and sibling-namespace reads denied, active-namespace reads allowed. NOT yet
  verified on Linux/bwrap.
  * Fixed a seatbelt alias-precedence bug that logged claude out under paranoid:
    a later `(allow file* ns)` does NOT override an earlier `(deny file-read*
    real_home)`, so the namespace needed its own `file-read*` re-allow. See
    docs/PARANOID.md.

Next steps:
- [ ] first live dogfood run: from the csb main checkout, `csb --here -s -- shellcheck bin/csb`
      (shell mode, no claude needed) should enter the devShell and pass; then
      `csb --here` to confirm claude launches. nix ignores UNTRACKED files, so
      `git add flake.nix` before the run if not yet staged.
- [ ] verify `--paranoid` on Linux/bwrap (see the bwrap item below): confirm the
      real HOME is tmpfs'd and the worktree/namespace remain readable.

- [ ] verify the Linux (bubblewrap) sandbox end-to-end on NixOS — the gating
      milestone from plan-002; run the phase-2 acceptance commands there, plus:
      write-policy probes (worktree/tmp writable, $HOME not), --unshare-pid
      (only own processes visible), and --ro-bind / not breaking the devShell
      (watch /run and XDG_RUNTIME_DIR).
- [x] allow referencing a "template" directory for populating sandbox $HOME.
    * DONE: `--seed-home DIR` / profile `seed_home=` (default ~/.config/csb/home)
      copies the template's files into the launch HOME every launch,
      non-overwriting (`--reseed` to overwrite). Seeds before the onboarding
      .claude.json so a template-provided one is merged. See README "Seeding the
      sandbox HOME". (env/auth config was already covered by profiles.)
- [ ] revisit the deny-list defaults after the first month of use (blacklist
      completeness is the standing risk; see docs/PLAN-002.md risks). Floor was
      expanded once already; `--paranoid` (whitelist reads) is the escape hatch
      when the blacklist feels insufficient.
- [ ] future --aws upgrade path (out of scope for plan-002): host-side
      credential broker + AWS_CONTAINER_CREDENTIALS_FULL_URI, viable because
      sandbox networking is open — would fix the no-refresh-in-session caveat.
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
