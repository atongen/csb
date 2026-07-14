#!/usr/bin/env bash
#
# csb statusline: claude runtime (model, context+tokens, cost, rate limits) on one row,
# csb sandbox state (repo, worktree/here, namespace, yolo, paranoid) on another.
# Seeded into the sandbox HOME as ~/.claude/statusline.sh by csb's seed_home
# template; wired via ~/.claude/settings.json (statusLine.command).
#
# Reads claude's session JSON on stdin and csb's CSB_* env (injected by bin/csb).
# ASCII only. Degrades to a minimal line when jq is unavailable. Independent of
# claude's theme setting, which it neither reads nor overrides.
set -u

input=$(cat)

# --- csb launch state (injected into the sandbox env by bin/csb) --------------
csb_mode="${CSB_MODE:-}"
csb_ns="${CSB_NS:-}"
csb_ephemeral="${CSB_EPHEMERAL:-false}"
csb_yolo="${CSB_YOLO:-false}"
csb_paranoid="${CSB_PARANOID:-false}"

# --- colors (ANSI escapes are ascii bytes; kept legible on light and dark) ----
RESET='\033[0m'; BOLD='\033[1m'
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'

# threshold color for an integer percentage 0-100
pct_color() {
  if   [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# humanize an integer token count: 68234 -> 68k, 1500000 -> 1.5M
humanize_tokens() {
  local n="$1"
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n / 1000000)) $(((n % 1000000) / 100000))
  elif [ "$n" -ge 1000 ];    then printf '%dk' $((n / 1000))
  else printf '%d' "$n"; fi
}

# --- accent (CSB_ACCENT: a per-profile tint so personal/work are tellable) ----
# Map a color NAME or raw ANSI SGR params to an SGR code; unknown -> no tint.
# bin/csb validates the value; this degrades silently for anything it doesn't
# know so a hand-set CSB_ACCENT never garbles the line.
accent_code() {
  case "$1" in
    black) echo 30 ;; red) echo 31 ;; green) echo 32 ;; yellow) echo 33 ;;
    blue) echo 34 ;; magenta) echo 35 ;; cyan) echo 36 ;; white) echo 37 ;;
    gray|grey) echo 90 ;;
    bright-red) echo 91 ;; bright-green) echo 92 ;; bright-yellow) echo 93 ;;
    bright-blue) echo 94 ;; bright-magenta) echo 95 ;; bright-cyan) echo 96 ;;
    bright-white) echo 97 ;;
    *) case "$1" in *[!0-9\;]*) return 1 ;; *) echo "$1" ;; esac ;;
  esac
}
ACCENT=""
if [ -n "${CSB_ACCENT:-}" ] && acode=$(accent_code "$CSB_ACCENT"); then
  ACCENT="\033[${acode}m"
fi

# Reverse encode_branch (bin/csb): show feature/foo, not feature%2Ffoo. Undo the
# / encoding before the % encoding, mirroring the encode order.
decode_branch() {
  local s="$1"
  s="${s//%2F//}"
  s="${s//%25/%}"
  printf '%s' "$s"
}

# --- session fields from stdin ------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  # Join on the unit separator (0x1f), not a tab: `read` treats tab as IFS
  # whitespace and collapses runs of it, which would drop empty fields (absent
  # rate limits) and shift every field after them.
  IFS=$'\037' read -r MODEL CTX COST RL5 RL7 REPO WT TOKIN TOKMAX <<EOF
$(printf '%s' "$input" | jq -r '[
    (.model.display_name // "?"),
    ((.context_window.used_percentage // 0) | floor | tostring),
    ((.cost.total_cost_usd // 0) | tostring),
    ((.rate_limits.five_hour.used_percentage // "") | tostring),
    ((.rate_limits.seven_day.used_percentage // "") | tostring),
    (.workspace.repo.name // ""),
    (.workspace.git_worktree // ""),
    ((.context_window.total_input_tokens // 0) | tostring),
    ((.context_window.context_window_size // 0) | tostring)
  ] | join("")')
EOF
else
  MODEL=$(printf '%s' "$input" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)
  CTX=""; COST=""; RL5=""; RL7=""; REPO=""; WT=""; TOKIN=""; TOKMAX=""
fi
[ -n "$REPO" ] || REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
BRANCH=$(git branch --show-current 2>/dev/null || true)

# --- left: csb identity -------------------------------------------------------
# repo name (accent-tinted per profile), then one mode:branch token, then the
# namespace only when it says something the branch does not.
left="${ACCENT}${BOLD}${REPO}${RESET}"

# branch label: the real branch is the source of truth (and already decoded);
# fall back to the decoded worktree dir name, then to a detached-HEAD marker.
if [ -n "$BRANCH" ]; then
  blabel="$BRANCH"
elif [ -n "$WT" ]; then
  blabel=$(decode_branch "$WT")
else
  blabel="detached"
fi

# mode prefix from csb's own notion (worktree vs --here), not git-worktree-ness:
# here positively flags that edits land in the current checkout, not an isolated
# worktree. Empty CSB_MODE (run outside csb) -> bare label.
case "$csb_mode" in
  worktree) left="$left ${CYAN}wt:${blabel}${RESET}" ;;
  here)     left="$left ${CYAN}here:${blabel}${RESET}" ;;
  *)        left="$left ${CYAN}${blabel}${RESET}" ;;
esac

# namespace: ephemeral and @-shared always carry info; a bare name only when it
# differs from the branch (the default ns IS the encoded branch -> redundant).
ns_disp=""
if [ "$csb_ephemeral" = "true" ]; then
  ns_disp="ephemeral"
elif [ -n "$csb_ns" ]; then
  case "$csb_ns" in
    @*) ns_disp="$csb_ns" ;;
    *)  ns_dec=$(decode_branch "$csb_ns"); [ "$ns_dec" != "$blabel" ] && ns_disp="ns:$ns_dec" ;;
  esac
fi
[ -n "$ns_disp" ] && left="$left ${YELLOW}${ns_disp}${RESET}"

[ "$csb_yolo" = "true" ]     && left="$left ${RED}${BOLD}[YOLO]${RESET}"
[ "$csb_paranoid" = "true" ] && left="$left ${BLUE}[PARANOID]${RESET}"

# --- right: claude runtime ----------------------------------------------------
right="${CYAN}${MODEL:-?}${RESET}"
if [ -n "$CTX" ]; then
  right="$right $(pct_color "$CTX")ctx:${CTX}%${RESET}"
  # token count next to the pct: current context / window size, both humanized.
  # 0 or missing (older claude lacks the field) -> pct alone.
  case "${TOKIN:-}" in
    ''|0|*[!0-9]*) ;;
    *) tok=$(humanize_tokens "$TOKIN")
       case "${TOKMAX:-}" in ''|0|*[!0-9]*) ;; *) tok="$tok/$(humanize_tokens "$TOKMAX")" ;; esac
       right="$right $tok" ;;
  esac
fi
[ -n "$COST" ] && right="$right $(printf '$%.2f' "$COST" 2>/dev/null || printf '$?.??')"
rl=""
if [ -n "$RL5" ]; then i=$(printf '%.0f' "$RL5"); rl="$(pct_color "$i")5h:${i}%${RESET}"; fi
if [ -n "$RL7" ]; then i=$(printf '%.0f' "$RL7"); rl="${rl:+$rl }$(pct_color "$i")7d:${i}%${RESET}"; fi
[ -n "$rl" ] && right="$right $rl"

# --- one row: identity, then runtime, joined by a pipe ------------------------
# Space-delimits fields within each group; a pipe separates the two groups. No
# right-alignment: the only width signal available to a statusline subprocess is
# COLUMNS, and when it overstates the pane (stale on first render, and never
# corrected in API-OAuth-token sessions) a right-aligned runtime block is padded
# past the true edge and truncated to a fragment. A fixed join stays fully
# visible regardless of what COLUMNS reports.
printf '%b\n' "${left} | ${right}"
