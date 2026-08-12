#!/usr/bin/env bash
# Tier 3 helper, run INSIDE the sandbox by test/escape/usable.bats: does a
# process here reach another process here over loopback, on a port nothing
# named? $1 is csb-proxy, used only as a listener that binds 127.0.0.1:0,
# announces its port, and answers a CONNECT for an unlisted host with 403
# without dialling anything.
#
# Every step reports, and no step hides a failure: a probe that dies quietly
# makes the negative case ("no 403") pass for the wrong reason.
#
# One marker per line on stdout, for the caller to assert on:
#   probe=...     the probe could not run; the rest did not happen
#   listener=up   csb-proxy is listening (asserted in BOTH runs)
#   reply=...     a complete loopback round trip
#   dial=refused  connect() was refused -- macOS under filtering
#   dial=timeout  connect() went unanswered -- Linux under filtering, dropped
set -u

proxy="${1:-}"
[[ -n "$proxy" ]] || { echo "probe=no-proxy-argument"; exit 0; }
[[ -x "$proxy" ]] || { echo "probe=proxy-not-executable: $proxy"; exit 0; }
[[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]] || { echo "probe=no-tmpdir"; exit 0; }

# A private dir, removed on every exit path: fixed names in a shared TMPDIR
# outlive the run and collide between concurrent ones.
work="$(mktemp -d "$TMPDIR/csb-loopback.XXXXXX")" \
  || { echo "probe=cannot-write-tmpdir"; exit 0; }
listener=""
trap 'kill "${listener:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

allow="$work/allow"
port_out="$work/port"
proxy_err="$work/stderr"
result="$work/result"

printf 'allowed.invalid\n' >"$allow" \
  || { echo "probe=cannot-write-tmpdir"; exit 0; }

"$proxy" "$allow" >"$port_out" 2>"$proxy_err" &
listener=$!

# csb-proxy flushes the port as it binds, so this waits on the bind rather than
# on a fixed sleep. Integer seconds only: fractional sleep is not portable.
port=""
tries=0
while (( tries < 15 )); do
  port="$(head -1 "$port_out" 2>/dev/null || true)"
  [[ -n "$port" ]] && break
  sleep 1
  (( tries += 1 ))
done

if [[ -z "$port" ]]; then
  echo "probe=no-listener"
  sed 's/^/probe-stderr: /' "$proxy_err" 2>/dev/null || true
  exit 0
fi
echo "listener=up"

# The dial runs in a child writing to a file, and is killed if it never answers:
# under filtering Linux DROPS the SYN, and bash's /dev/tcp has no timeout of its
# own, so waiting on it directly would hang the whole launch.
(
  if ! exec 3<>"/dev/tcp/127.0.0.1/$port"; then
    echo "dial=refused" >"$result"
    exit 0
  fi
  printf 'CONNECT denied.invalid:443 HTTP/1.1\r\n\r\n' >&3
  line=""
  read -r -t 5 line <&3 || true
  echo "reply=${line%$'\r'}" >"$result"
) 2>/dev/null &
dialer=$!

tries=0
while (( tries < 10 )); do
  [[ -s "$result" ]] && break
  sleep 1
  (( tries += 1 ))
done
kill "$dialer" 2>/dev/null || true

if [[ -s "$result" ]]; then
  cat "$result"
else
  echo "dial=timeout"
fi

# Leave nothing listening: the namespace outlives this script only as long as
# something in it is alive, and a stray proxy holds the whole launch open. The
# EXIT trap kills it; this waits so the exit does not race the teardown.
kill "$listener" 2>/dev/null || true
wait "$listener" 2>/dev/null || true
exit 0
