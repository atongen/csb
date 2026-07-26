#!/usr/bin/env bash
# Phase 1 verification harness (Linux/NixOS). Run from a normal terminal.
#
# Drives bwrap directly, NOT through csb, mirroring the argv csb builds at
# bin/csb:979-980, so it tests the mount policy itself.
#
# Every candidate is measured against a positive control (C0, csb's current
# argv). A "blocked" result is only meaningful if C0 shows "ESCAPED" in the
# same run. See docs/PLAN-007-escape.md, F4 and Phase 1.
set -uo pipefail

BWRAP=${CSB_BWRAP_BIN:-$(command -v bwrap)}
[ -x "$BWRAP" ] || { echo "no bwrap; set CSB_BWRAP_BIN"; exit 1; }
UID_N=$(id -u)
RUNDIR=/run/user/$UID_N
CANARY=/tmp/csb-linux-canary.$$
SDRUN=$(command -v systemd-run || echo /run/current-system/sw/bin/systemd-run)
DBSEND=$(command -v dbus-send || echo /run/current-system/sw/bin/dbus-send)
trap 'rm -f "$CANARY"; systemctl --user reset-failed csb-probe-$$ 2>/dev/null' EXIT

base=("$BWRAP" --ro-bind / / --dev-bind /dev /dev --proc /proc --unshare-pid --die-with-parent)

variant() {  # echo the extra args for a candidate
  case "$1" in
    C0) ;;                                        # positive control: csb today
    C1) echo "--tmpfs $RUNDIR" ;;                 # proposed fix
    C2) echo "--tmpfs $RUNDIR --tmpfs /run/dbus" ;;  # + system bus
  esac
}

test_escape() {
  local id="$1" extra; read -r -a extra <<< "$(variant "$id")"
  rm -f "$CANARY"
  "${base[@]}" ${extra[@]+"${extra[@]}"} -- \
    env XDG_RUNTIME_DIR="$RUNDIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNDIR/bus" \
    "$SDRUN" --user --wait --unit="csb-probe-$$" \
    /bin/sh -c "id -un > $CANARY 2>&1" >/dev/null 2>&1
  systemctl --user reset-failed "csb-probe-$$" 2>/dev/null
  if [ -f "$CANARY" ]; then echo "ESCAPED (as $(cat "$CANARY"))"; else echo "blocked"; fi
}

test_sysbus() {
  local id="$1" extra; read -r -a extra <<< "$(variant "$id")"
  if "${base[@]}" ${extra[@]+"${extra[@]}"} -- \
       "$DBSEND" --system --print-reply --dest=org.freedesktop.DBus \
       /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1
  then echo "REACHABLE"; else echo "blocked"; fi
}

test_works() {
  local id="$1" extra ok=""; read -r -a extra <<< "$(variant "$id")"
  "${base[@]}" ${extra[@]+"${extra[@]}"} -- /bin/sh -c 'ls / >/dev/null' 2>/dev/null && ok="${ok}ls "
  "${base[@]}" ${extra[@]+"${extra[@]}"} -- /bin/sh -c 'command -v git >/dev/null && git --version >/dev/null' 2>/dev/null && ok="${ok}git "
  "${base[@]}" ${extra[@]+"${extra[@]}"} -- /bin/sh -c 'getent hosts localhost >/dev/null' 2>/dev/null && ok="${ok}dns "
  [ -n "$ok" ] && echo "$ok" || echo "(none)"
}

printf '%-4s %-26s %-12s %s\n' ID ESCAPE SYSTEM-BUS STILL-WORKS
printf '%-4s %-26s %-12s %s\n' ---- -------------------------- ------------ -----------
for id in C0 C1 C2; do
  printf '%-4s %-26s %-12s %s\n' "$id" "$(test_escape "$id")" "$(test_sysbus "$id")" "$(test_works "$id")"
done

echo
echo "C0 MUST read ESCAPED, or the harness is broken."
echo
echo "Also worth running, separately, against real csb (one command, closes the"
echo "one gap in F4's characterization -- paranoid was never measured on Linux):"
echo
echo "  csb -s --here --paranoid -- env XDG_RUNTIME_DIR=$RUNDIR \\"
echo "      DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNDIR/bus \\"
echo "      $SDRUN --user --wait --unit=csb-f4p \\"
echo "      /bin/sh -c 'id -un > /tmp/csb-f4p.txt 2>&1; ls -la \$HOME/.ssh >> /tmp/csb-f4p.txt 2>&1'"
