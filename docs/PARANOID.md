# --paranoid logged claude out: root cause and fix (RESOLVED)

## Symptom

`csb --paranoid` launched claude in a logged-out state ("Not logged in ·
Please run /login"). Without `--paranoid` (same namespace, everything else
equal) claude was logged in normally. macOS/seatbelt only; Linux/bwrap was
never affected.

## Root cause: seatbelt is not simply last-match-wins across filter aliases

`--paranoid` inserts, ahead of the namespace re-allow (bin/csb Darwin branch):

    (deny file* (subpath ".../.csb/claudes"))   # deny-list floor (both modes)
    (deny file-read* (subpath "<real-home>"))   # paranoid adds this
    (allow file-read* (subpath "<write-root>")) # paranoid re-allows write roots
    ...
    (allow file* (subpath "<namespace>"))       # namespace re-allow, LAST

The namespace re-allow is the LAST matching rule for reads under the namespace,
so under a pure "last-match-wins" model it should win -- which is what an earlier
analysis assumed. It does not. Seatbelt does NOT treat a later `file*` allow as
overriding an earlier `file-read*` deny; the two are different filter-alias
classes and the read deny survives.

Empirically (minimal profiles, `sandbox-exec -f`):

    deny file-read* PARENT ; allow file*      CHILD (last)  -> DENIED
    deny file*      PARENT ; allow file*      CHILD (last)  -> ALLOWED
    deny file-read* PARENT ; allow file-read* CHILD (last)  -> ALLOWED

So a later allow only overrides an earlier deny when it uses the SAME alias
class. The paranoid write-root re-allows already use `file-read*` (matching the
`file-read*` deny), so repo/tmp reads worked. The namespace, re-allowed
separately with `file*`, was the only read root left uncovered -- so every read
under the namespace, including `.credentials.json` and `.claude.json`, was
denied and claude fell back to logged-out.

## The fix

In the paranoid block (bin/csb Darwin branch), after re-allowing the write
roots, emit a matching-class read re-allow for the namespace:

    [[ -n "$ns_real" ]] && printf '(allow file-read* (subpath "%s"))\n' "$ns_real"

This sits alongside the existing `(allow file* <namespace>)`; the two together
match the ALLOWED case above. The fix is macOS-only. Linux/bwrap binds the
namespace back last over the tmpfs'd real HOME, so it has no alias-precedence
issue.

## Verification (macOS, from a normal terminal, outside csb)

- `csb --paranoid ... -- -p "..."` (print mode): claude answers, exit 0 (before
  the fix: "Not logged in", exit 1).
- Isolation probe via `csb --paranoid ... -s -- bash -c '...'`:
  - real-home paths (`~/.ssh`, `~/.claude`, `~/.zshrc`, `~/.gitconfig`) DENIED;
  - active namespace `.credentials.json` / `.claude.json` READABLE;
  - sibling namespace (`@personal`) DENIED.
- `make check` (shellcheck) clean.

## Why it could not be finished inside the sandbox

- `sandbox-exec` will not nest -> the paranoid profile could not be built or
  tested from within a running csb session.
- `log`, `security`, `python3`, `jq`, `node` were not on the in-sandbox PATH,
  so the seatbelt violation log could not be read from inside.

The denied path had to be observed from a normal terminal, which is where the
namespace-read deny (contradicting the last-match-wins assumption) surfaced.

## Key line references

- Paranoid sandbox rules + the fix: bin/csb Darwin branch (paranoid block),
  Linux branch (`--tmpfs <real-home>` + namespace `--bind` last).
- Namespace re-allow: `(allow file* <namespace>)` immediately after the paranoid
  block (Darwin).
- Write roots (the paranoid read allowlist): `build_write_roots`.
- Deny-list floor: `build_deny_paths`.
