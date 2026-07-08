# TODO

- [ ] verify the Linux (bubblewrap) sandbox end-to-end on NixOS — the gating
      milestone from plan-002; run the phase-2 acceptance commands there, plus:
      write-policy probes (worktree/tmp writable, $HOME not), --unshare-pid
      (only own processes visible), and --ro-bind / not breaking the devShell
      (watch /run and XDG_RUNTIME_DIR).
- [ ] allow referencing a "template" directory for populating sandbox $HOME.
    * partially covered by plan-002 profiles (token_cmd/setenv/keep handle env
      and auth config); remaining scope is seeding FILES into a namespace HOME.
- [ ] revisit the deny-list defaults after the first month of use (blacklist
      completeness is the standing risk; see docs/PLAN-002.md risks).
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
