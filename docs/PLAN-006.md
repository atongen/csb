# plan 006

Implemented (csb 0.3.0).

## Per-repo default HOME + a flat namespace layout

Through PLAN-005 the default namespace was the **branch**: each branch got its
own isolated HOME at `~/.csb/claudes/<repo-key>/<branch>`, where `<repo-key>` was
`basename-pathhash` and branch names were percent-encoded. This document records
the switch to a **per-repo** default HOME, a flattened `~/.csb/claudes` layout,
and the simplifications that fell out of it.

### Why the change

Per-branch HOME fragmented everything a user reasonably expects to be
per-*project*: MCP/connector auth, command history, `~/.claude` memory,
onboarding/trust state, and custom settings. Every new branch started cold
(seeding papered over the file-based parts, but not live auth or history). In
practice the desirable unit of isolation is the repo, not the branch -- which is
also why the shared `@`-namespace (`--ns @drip`) had become the workaround.

### Decisions

1. **Default namespace = the repo.** One persistent HOME per repo, shared by all
   its branches and worktrees, at `~/.csb/claudes/repo-<key>`. The branch drops
   out of the namespace entirely (it survives only in the `.worktrees/<branch>`
   path, so `encode_branch` stays; `decode_branch` was removed as dead).

2. **Flat layout, two kinds.** Flattening the tree collapses the old
   "scoped-named" and "unscoped-named" kinds into one: a user-chosen name with no
   `<repo-key>/` parent to scope under is inherently global. So there are now two
   flat kinds under `~/.csb/claudes`:
   - `repo-<key>` -- the automatic per-repo default (`kind=repo`).
   - `@NAME` -- user-named, shared across repos (`kind=shared`).

3. **`-N NAME` and `-N @NAME` are the same.** A bare name auto-promotes to
   `@NAME`. The `@` prefix keeps user names in their own flat space, so none can
   ever collide with a `repo-<key>` default -- no separate reservation needed.

4. **`<repo-key>` keeps its `basename-pathhash` form.** The hash is `cksum` of
   the physical main-checkout path; it is the one thing that keeps two different
   repos sharing a basename (`acme/web` vs `personal/web`) from silently sharing
   a HOME. Kept as-is -- only flattened and prefixed with `repo-`.

5. **`-d` is worktree-only.** The per-repo default is shared across branches and
   an `@`-namespace is shared across repos, so neither is tied to the branch
   being deleted; `-d` no longer removes any config. Retire a namespace with
   `rm -rf`.

6. **`--prune-ns` removed; `--list-ns` demoted to a listing.** Orphan detection
   existed only because per-branch namespaces outlived their branches. With a
   permanent per-repo default and permanent `@` namespaces, nothing is ever an
   auto-removable orphan, so `--prune-ns` had no job left and was removed.
   `--list-ns` now just lists `repo-*` and `@*` and flags pre-0.3 leftover dirs.

7. **`--here` simplified.** It no longer derives a namespace from the current
   HEAD, so the detached-HEAD error path is gone -- the default is the repo
   regardless.

### Migration (option a: leave legacy, remove manually)

Existing `<repo-key>/<branch>` and `<repo-key>/NAME` dirs from the old nested
layout are simply never used or created again. No migration code runs.
`--list-ns` flags them as `LEGACY pre-0.3` with a manual `rm -rf` hint. This was
chosen over an auto-sweep or launch-time auto-migration: it is config, not data,
and fragile migration code was not worth its risk.

### Concurrency: parity with native

Two `csb` sessions on different branches of the same repo now share one HOME
(config, history, `.claude.json`) with **no locking**. This is deliberately
accepted: it is exactly the situation a user already gets running native
`claude` twice against one real `~/.claude`. The old per-branch default was
*more* isolated than native ever was; this change trades that csb-only bonus for
native-equivalent behavior. Adding locking would be csb solving a problem claude
itself does not solve, so it is documented rather than engineered. A user who
wants per-branch isolation back for a repo launches with an explicit name:
`csb --ns "$(git branch --show-current)" <branch>`.

### Clarified in the docs (README + --help)

`-N`, `-E`, and `--real-home` are now framed as three mutually-exclusive answers
to one question -- **which HOME the sandboxed process gets** -- rather than three
unrelated flags. Each one (potentially creates and) sets `$HOME` inside the
sandbox; they differ only in persistence and in whether that HOME is writable
inside the sandbox (`--real-home` alone is read-only, reads still obey the
deny-list). A summary table now leads both the `## Namespaces` README section and
the `HOME choice:` block in `--help`.
