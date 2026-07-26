#!/usr/bin/env bash
# Phase 1b: is a mach-lookup WHITELIST viable on macOS?
# RUN FROM A NORMAL TERMINAL, NOT INSIDE csb (nested sandbox-exec fails).
#
# Phase 1 established that no per-name blacklist blocks the `open` escape, and
# that blanket `(deny mach-lookup)` does. What it did NOT establish is whether
# real work survives that. This measures the COST, using real outcomes rather
# than exit codes -- the flaw in the Phase 1 STILL-WORKS column.
#
# Each row re-tests the escape, because re-allowing a service could hand
# LaunchServices another route back in. A whitelist row is only interesting if
# ESCAPE still reads "blocked".
#
# See docs/PLAN-007-escape.md, Phase 1b.
set -uo pipefail

WORK=$(mktemp -d /tmp/csb-wl-probe.XXXXXX)
CANARY="$WORK/canary.txt"
APP="$WORK/CsbProbe.app"
HOST=api.anthropic.com
CLAUDE_BIN=$(command -v claude || true)
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

# --- allow sets, cumulative --------------------------------------------------
# Plain level compares, not case fallthrough: `;;&' is bash 4+ and macOS ships
# bash 3.2 at /bin/bash.
allows() {
  local lvl=0
  case "$1" in A1) lvl=1 ;; A2) lvl=2 ;; A3) lvl=3 ;; A4) lvl=4 ;; KC) lvl=1 ;; PB) lvl=1 ;;
               A5) lvl=1 ;; PB5) lvl=1 ;; A6) lvl=1 ;; A7) lvl=1 ;; esac
  # PB5 is A5 (the shipped profile) plus the pasteboard, i.e. exactly what
  # `csb --pasteboard` emits. PB above is the same test against A1 only.
  if [ "$1" = "PB5" ]; then
    echo 'com.apple.pasteboard.1'
    echo 'com.apple.lsd.mapdb'
    echo 'com.apple.lsd.modifydb'
  fi
  # PB is the --pasteboard candidate (Phase 3b): A1 plus what pbcopy/pbpaste
  # need. Phase 1 showed the pasteboard breaking at P2, which named only the lsd
  # pair, so those are included. The point of this row is to confirm re-allowing
  # them does NOT hand LaunchServices a route back -- ESCAPE must stay blocked or
  # --pasteboard cannot be offered on macOS at all.
  if [ "$1" = "PB" ]; then
    echo 'com.apple.pasteboard.1'
    echo 'com.apple.lsd.mapdb'
    echo 'com.apple.lsd.modifydb'
  fi
  # KC is a DIAGNOSTIC row, not a candidate: A1 plus the keychain, to confirm
  # that a `Not logged in' failure is securityd being unreachable and nothing
  # else. csb does not need this allowed -- it seeds credentials as a file --
  # and the README treats the keychain failing closed as desirable.
  if [ "$1" = "KC" ]; then
    echo 'com.apple.SecurityServer'
    echo 'com.apple.securityd'
    echo 'com.apple.secd'
  fi
  if [ "$lvl" -ge 1 ]; then
    echo 'com.apple.dnssd.service'
    echo 'com.apple.mDNSResponder'
  fi
  if [ "$lvl" -ge 2 ]; then
    echo 'com.apple.trustd'
    echo 'com.apple.trustd.agent'
  fi
  if [ "$lvl" -ge 3 ]; then
    echo 'com.apple.system.opendirectoryd.api'
    echo 'com.apple.system.opendirectoryd.membership'
    echo 'com.apple.cfprefsd.daemon'
    echo 'com.apple.cfprefsd.agent'
  fi
  if [ "$lvl" -ge 4 ]; then
    echo 'com.apple.system.notification_center'
    echo 'com.apple.logd'
    echo 'com.apple.system.logger'
    echo 'com.apple.diagnosticd'
    echo 'com.apple.usymptomsd'
    echo 'com.apple.networkd'
    echo 'com.apple.symptomsd'
  fi
  return 0
}

profile() {
  echo '(version 1)'
  echo '(allow default)'
  [ "$1" = "CTL" ] && return          # positive control: stock csb profile
  echo '(deny mach-lookup)'
  local n
  while read -r n; do
    [ -n "$n" ] && printf '(allow mach-lookup (global-name "%s"))\n' "$n"
  done < <(allows "$1")
  # Rows beyond A1 add denies for the filter classes that SURVIVE
  # `(deny mach-lookup)` (PLAN-007 Phase 2). These are COST measurements: the
  # escape column is already known to read `blocked'.
  #
  # RESULT (run 4): A5 -- the network-outbound CLASS deny -- broke DNS and, via
  # DNS, HTTPS. Not a parse error: PB5 shows the pasteboard still working, so
  # the profile applied. A6/A7 split the cause; A6 is what csb ships today.
  case "$1" in
    A5|PB5)   # the class deny, MEASURED BROKEN -- kept as the reference point
      echo '(deny network-outbound)'
      echo '(allow network-outbound (remote ip "*:*"))'
      _class_denies ;;
    A6)       # WHAT csb SHIPS: no class deny, nix daemon socket by path only
      printf '(deny network-outbound (literal "%s"))\n' \
        "$(realpath /nix/var/nix/daemon-socket/socket 2>/dev/null || echo /private/var/run/nix-daemon.socket)"
      _class_denies ;;
    A7)       # can the class deny be rescued? one hypothesis: DNS also needs
              # the mDNSResponder UNIX socket, not just its mach service.
      echo '(deny network-outbound)'
      echo '(allow network-outbound (remote ip "*:*"))'
      echo '(allow network-outbound (literal "/private/var/run/mDNSResponder"))'
      echo '(allow network-outbound (literal "/var/run/mDNSResponder"))'
      _class_denies ;;
  esac
}

# The three non-socket class denies, shared by A5/PB5/A6/A7. If A6 regresses a
# column, drop the responsible line: `ps` is what would notice the sysctl one,
# and that is a disclosure fix rather than an escape fix, so it goes first.
_class_denies() {
  echo '(deny mach-priv-task-port)'
  echo '(deny iokit-open)'
  echo '(deny sysctl-read (sysctl-name-prefix "kern.proc"))'
}

run_sb() { local id="$1"; shift
  profile "$id" > "$WORK/$id.sb"
  /usr/bin/sandbox-exec -f "$WORK/$id.sb" "$@" 2>&1
}

test_escape() { local id="$1" _
  rm -f "$CANARY"
  run_sb "$id" /usr/bin/open -g "$APP" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$CANARY" ] && { echo "ESCAPED"; return; }
    sleep 0.3
  done
  echo "blocked"
}

# Real resolution, not an exit code: require an actual A record in the output.
test_dns() { local id="$1" out
  out=$(run_sb "$id" /usr/bin/dscacheutil -q host -a name "$HOST")
  case "$out" in *ip_address*) echo "resolves" ;; *) echo "FAILS" ;; esac
}

# DNS + TLS chain + network in one. Any HTTP status means the stack worked.
test_https() { local id="$1" out
  out=$(run_sb "$id" /usr/bin/curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 15 "https://$HOST/")
  case "$out" in
    ''|000|*curl*|*error*|*Operation*) echo "FAILS" ;;
    *) echo "http $out" ;;
  esac
}

# A real API round trip. Costs a few tokens.
# Native auth: claude finds its session credential in the macOS keychain, which
# is a mach service. This is NOT how csb runs claude -- see test_claude_token.
# NOTE: sandbox-exec inherits the environment, so CLAUDE_CODE_OAUTH_TOKEN must be
# explicitly unset here or it silently overrides the keychain and both columns end
# up testing the same credential. That bug invalidated the 2026-07-25 second run.
test_claude() { local id="$1" out
  [ -n "$CLAUDE_BIN" ] || { echo "(no claude)"; return; }
  [ "${SKIP_CLAUDE:-}" = "1" ] && { echo "(skipped)"; return; }
  profile "$id" > "$WORK/$id.sb"
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN /usr/bin/sandbox-exec -f "$WORK/$id.sb" \
        "$CLAUDE_BIN" -p 'reply with the single word: ok' 2>&1)
  case "$out" in
    *ok*|*OK*|*Ok*) echo "ROUND TRIP OK" ;;
    *) echo "FAILS: $(printf '%s' "$out" | head -1 | cut -c1-34)" ;;
  esac
}

# csb's actual auth model: the credential arrives as a token in the environment
# (or, with --seed-creds, as a file in the namespace HOME). Neither path touches
# the keychain, so this is the column that reflects how csb really runs.
# Export CLAUDE_CODE_OAUTH_TOKEN before running, or `claude setup-token' first.
test_claude_token() { local id="$1" out
  [ -n "$CLAUDE_BIN" ] || { echo "(no claude)"; return; }
  [ "${SKIP_CLAUDE:-}" = "1" ] && { echo "(skipped)"; return; }
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { echo "(no token)"; return; }
  profile "$id" > "$WORK/$id.sb"
  out=$(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        /usr/bin/sandbox-exec -f "$WORK/$id.sb" \
        "$CLAUDE_BIN" -p 'reply with the single word: ok' 2>&1)
  case "$out" in
    *ok*|*OK*|*Ok*) echo "ROUND TRIP OK" ;;
    *) echo "FAILS: $(printf '%s' "$out" | head -1 | cut -c1-34)" ;;
  esac
}

echo "host baseline (unsandboxed), for comparison:"
printf '  dns=%s  https=%s\n' \
  "$(/usr/bin/dscacheutil -q host -a name "$HOST" | grep -q ip_address && echo resolves || echo FAILS)" \
  "$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOST/" 2>/dev/null)"

# PREFLIGHT: validate BOTH auth paths unsandboxed, before any profile is applied.
# A credential that is broken on the host fails identically in every row and
# makes the whole table unreadable -- that is exactly what happened on the
# 2026-07-25 second run, where a placeholder token was exported verbatim.
if [ -n "$CLAUDE_BIN" ] && [ "${SKIP_CLAUDE:-}" != "1" ]; then
  pf_kc=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_BIN" -p 'reply with the single word: ok' 2>&1 | head -1)
  case "$pf_kc" in *ok*|*OK*|*Ok*) pf_kc="OK" ;; *) pf_kc="BROKEN: $pf_kc" ;; esac
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    pf_tk=$("$CLAUDE_BIN" -p 'reply with the single word: ok' 2>&1 | head -1)
    case "$pf_tk" in *ok*|*OK*|*Ok*) pf_tk="OK" ;; *) pf_tk="BROKEN: $pf_tk" ;; esac
  else
    pf_tk="absent (deciding column will read '(no token)')"
  fi
  printf '  auth keychain=%s\n  auth token=%s\n' "$pf_kc" "$pf_tk"
  case "$pf_tk" in
    BROKEN*)
      echo
      echo "ABORT: CLAUDE_CODE_OAUTH_TOKEN is set but does not work UNSANDBOXED."
      echo "The token column would fail in every row for reasons unrelated to the"
      echo "sandbox. Fix or unset the token, then re-run. Current value starts:"
      printf '  %.8s...\n' "$CLAUDE_CODE_OAUTH_TOKEN"
      echo "(If that reads '...' you pasted the placeholder. Mint one with"
      echo " 'claude setup-token'.)"
      exit 1 ;;
  esac
fi
echo

test_pbpaste() {
  local out; out=$(run_sb "$1" /usr/bin/pbpaste | wc -c | tr -d ' ')
  case "$out" in 0|"") echo "blocked" ;; *) echo "works" ;; esac
}

printf '%-4s %-9s %-9s %-9s %-8s %-22s %s\n' \
  ID ESCAPE DNS HTTPS PBPASTE 'CLAUDE (keychain)' 'CLAUDE (token = csb)'
printf '%-4s %-9s %-9s %-9s %-8s %-22s %s\n' \
  ---- --------- --------- --------- -------- ---------------------- --------------------
# ROWS overrides which rows run; CTL is the positive control, always keep it.
for id in ${ROWS:-CTL A1 A6 A7 A5 PB5 KC PB A2 A3 A4}; do
  printf '%-4s %-9s %-9s %-9s %-8s %-22s %s\n' \
    "$id" "$(test_escape "$id")" "$(test_dns "$id")" "$(test_https "$id")" \
    "$(test_pbpaste "$id")" "$(test_claude "$id")" "$(test_claude_token "$id")"
done

cat <<'NOTES'

Rows: CTL = stock csb profile (control: MUST show ESCAPED and everything working).
A1 = deny-all + DNS. A2 = +TLS/trustd. A3 = +directory/prefs. A4 = +logging.
A1..A4 are cumulative. KC = A1 + keychain, a DIAGNOSTIC row, not a candidate.
PB = A1 + pasteboard, the --pasteboard flag candidate (Phase 3b): it is only
offerable if PB shows PBPASTE=works AND ESCAPE=blocked. If PB escapes, the flag
cannot exist on macOS.

A6 IS THE ROW THAT MATTERS: it is what csb emits today. A1 plus the nix daemon
socket denied BY PATH, plus mach-priv-task-port (task_for_pid), iokit-open, and
sysctl kern.proc (kern.procargs2 leaks other processes' argv and environment).
A6 must match A1 on every column; anything worse is a cost these lines added.

A5 kept the whole network-outbound CLASS denied, which would have cut AF_UNIX
brokering wholesale (tmux, editor IPC, docker, ssh-agent -- not just nix). Run 4
measured it BREAKING DNS, and HTTPS with it. PB5 (same denies + pasteboard)
still showed PBPASTE=works, which rules out a parse failure: the profile applied
and the network stack was genuinely broken. A7 tests the one cheap hypothesis --
that DNS also needs the mDNSResponder UNIX socket, not only its mach service.
If A7 comes back clean on every column it is strictly better than A6 and should
replace it in bin/csb. If it does not, stop: A6 ships and macOS keeps
non-nix unix-socket brokering as a documented open gap.

Which column matters: "CLAUDE (token)". csb never authenticates claude through
the macOS keychain -- --seed-creds writes the credential into the namespace HOME
as a file, and the token path uses an environment variable. The keychain column
is there only to explain failures, not to gate the decision.

Reading it:
  - Any row with ESCAPE=ESCAPED means that allow set handed LaunchServices a way
    back in. Note WHICH name did it -- that is a finding in itself.
  - Lowest row with ESCAPE=blocked and CLAUDE (token)=ROUND TRIP OK is the
    candidate whitelist, and option (b) is viable.
  - If the keychain column fails everywhere but KC succeeds, that confirms a
    `Not logged in' failure is just securityd being unreachable -- expected, and
    irrelevant to csb.
  - Only if the TOKEN column fails on every blocked row does claude genuinely
    not work under a whitelist, promoting decision 4 to option (c).

Export CLAUDE_CODE_OAUTH_TOKEN first, or the deciding column reads "(no token)".
Set SKIP_CLAUDE=1 to omit the API round trips entirely, and ROWS to run a
subset -- e.g. `SKIP_CLAUDE=1 ROWS='CTL A1 A6 A7' ./ipc-probe-darwin-whitelist.sh`
answers the A7 question (a DNS/HTTPS question) in seconds and for free.

NOT covered: the interactive TUI. If a row looks viable, confirm by hand with a
real session under that profile before trusting it. The profiles are left in the
work dir only while the script runs, so regenerate one:
  printf '(version 1)\n(allow default)\n(deny mach-lookup)\n%s\n' \
    '(allow mach-lookup (global-name "com.apple.dnssd.service"))' > /tmp/a1.sb
  /usr/bin/sandbox-exec -f /tmp/a1.sb claude
NOTES
