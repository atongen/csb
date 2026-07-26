#!/usr/bin/env bash
# Phase 1 verification harness (macOS). RUN FROM A NORMAL TERMINAL, NOT INSIDE csb
# -- nested sandbox-exec fails with "sandbox_apply: Operation not permitted".
#
# Drives sandbox-exec directly, NOT through csb, so it tests the seatbelt rules
# themselves without csb's path/namespace machinery in the way.
#
# Every candidate is measured against a positive control (profile P0, no denies).
# A "BLOCKED" result is only meaningful if P0 shows "ESCAPED" in the same run.
# See docs/PLAN-007-escape.md, Phase 1.
set -uo pipefail

WORK=$(mktemp -d /tmp/csb-ipc-probe.XXXXXX)
CANARY="$WORK/canary.txt"
APP="$WORK/CsbProbe.app"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CsbProbe</string>
<key>CFBundleIdentifier</key><string>local.csb.probe</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
EOF
cat > "$APP/Contents/MacOS/probe" <<EOF
#!/bin/sh
/usr/bin/id -un > "$CANARY" 2>&1
EOF
chmod +x "$APP/Contents/MacOS/probe"

# --- candidate profiles ------------------------------------------------------
# Order matters: (allow default) first, denies after, matching bin/csb:907.
profile() {
  echo '(version 1)'
  echo '(allow default)'
  case "$1" in
    P0) ;;                                   # positive control: no denies
    P1) echo '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))' ;;
    P2) echo '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))'
        echo '(deny mach-lookup (global-name "com.apple.lsd.mapdb"))'
        echo '(deny mach-lookup (global-name "com.apple.lsd.modifydb"))' ;;
    P3) echo '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))'
        echo '(deny mach-lookup (global-name "com.apple.lsd.mapdb"))'
        echo '(deny mach-lookup (global-name "com.apple.lsd.modifydb"))'
        echo '(deny mach-lookup (global-name "com.apple.lsd.open"))'
        echo '(deny mach-lookup (global-name "com.apple.pasteboard.1"))' ;;
    P4) echo '(deny mach-lookup)' ;;         # deny-all: the decision-4 shape
  esac
}

run_sb() {  # run_sb PROFILE_ID CMD... -> stdout+stderr, exit code preserved
  local id="$1"; shift
  profile "$id" > "$WORK/$id.sb"
  /usr/bin/sandbox-exec -f "$WORK/$id.sb" "$@" 2>&1
}

test_escape() {  # -> ESCAPED | blocked
  local id="$1" _
  rm -f "$CANARY"
  run_sb "$id" /usr/bin/open -g "$APP" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$CANARY" ] && { echo "ESCAPED (as $(cat "$CANARY"))"; return; }
    sleep 0.3
  done
  echo "blocked"
}

test_pbpaste() {
  local out; out=$(run_sb "$1" /usr/bin/pbpaste | wc -c | tr -d ' ')
  case "$out" in 0|"") echo "blocked" ;; *) echo "READ ${out}b" ;; esac
}

test_works() {  # does ordinary work still function under this profile?
  local id="$1" ok=""
  run_sb "$id" /bin/ls / >/dev/null 2>&1        && ok="${ok}ls "
  run_sb "$id" /usr/bin/git --version >/dev/null 2>&1 && ok="${ok}git "
  run_sb "$id" /usr/bin/dscacheutil -q host -a name localhost >/dev/null 2>&1 && ok="${ok}dns "
  command -v claude >/dev/null 2>&1 && \
    { run_sb "$id" "$(command -v claude)" --version >/dev/null 2>&1 && ok="${ok}claude "; }
  [ -n "$ok" ] && echo "$ok" || echo "(none)"
}

printf '%-4s %-24s %-12s %s\n' ID ESCAPE PBPASTE STILL-WORKS
printf '%-4s %-24s %-12s %s\n' ---- ------------------------ ------------ -----------
for id in P0 P1 P2 P3 P4; do
  printf '%-4s %-24s %-12s %s\n' "$id" "$(test_escape "$id")" "$(test_pbpaste "$id")" "$(test_works "$id")"
done

echo
echo "P0 MUST read ESCAPED. If it does not, this harness is broken and every"
echo "'blocked' below it is meaningless -- fix the control before believing anything."
echo
echo "Known limitation: this tests /usr/bin/open only. A compiled client calling"
echo "NSWorkspace/XPC directly might reach LaunchServices by another route, so a"
echo "clean 'blocked' here bounds the CLI vector, not the capability."
