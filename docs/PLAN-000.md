# agent workflow

## overview

I've had a tmux workflow for many years and it is simple but has worked well for me.

Now I want to expand it to incorporate agent-driven development.

Relevant files:
* ~/bin/tm
* ~/bin/tm_expand
* cm function from ~/.zsh/functions.zsh
* .tmux-base.conf    .tmux-darwin.conf  .tmux-linux.conf   .tmux.conf
* TMPATH env var from ~/.zshenv
* ~/.zsh/completions/_tm ~/.zsh/completions/_cm
* possibly others?

My objective is to maintain the basic functionality from the tm executable, where I can quickly create and navigate tmux sessions, but also to integrate agent-driven development features.

tm usage:
$ tm SESSION_NAME [WINDOW_NAME]
where SESSION_NAME expands to the path from the TMPATH environment variable, and is the working directory of the session,
and WINDOW_NAME is an optional argument that specifies the name of the tmux window to create within the session.

The functionality I want to layer in includes:
* if the expanded TMPATH from the SESSION_NAME is a git repo, then WINDOW_NAME is treated as a branch name
* if the branch name does not exist, it is created from the current branch
* the tmux window is created with the branch name as the title
* a new git worktree is established for this branch
* the working directory is set to the root of the git repo
* the tmux window is split into two panes horizontally
* the top pane is a terminal rooted at the root of the git worktree
* the bottom pane immediately starts an interactive claude agent also running at the same worktree

The desired workflow is that I can seamlessly create new tmux sessions and
windows that map to git branches and running claude agents, each with their own
worktree, allowing me to easily manage multiple branches and agents in
parallel.

A "nice to have" feature would be to have visibility into the current sessions and windows that are running. Existing tmux commands that enable this are prefered.

## implementation plan

### decisions (from Q&A)

1. **Worktree location:** `<repo>/.worktrees/<branch-flattened>`, where `<branch-flattened>` replaces `/` with `-` (e.g. `feature/foo` → `.worktrees/feature-foo`). The branch name in git and in the tmux window title keeps its slashes; only the directory is flattened.
2. **Default `main` window:** when `WINDOW_NAME` is omitted (defaults to `main`), open the original non-worktree checkout — same as today. Any *explicit* `WINDOW_NAME` triggers the worktree+agent flow in a git repo.
3. **No nested worktrees:** if the expanded workspace dir is itself already a worktree (its `.git` is a file pointing at a parent's `.git/worktrees/...`), refuse to create another one. Print an error and exit.
4. **Branch lifecycle:** if the branch exists (local or remote-tracking), reuse it. Otherwise create it from the main checkout's current `HEAD` via `git worktree add -b`.
5. **Existing worktree:** if a worktree for the branch already exists in `git worktree list`, reuse its path silently — just open/focus the window.
6. **Pane layout:** `split-window -v -c <worktree>`. Top pane = shell. Bottom pane = `claude` (started via `send-keys 'claude' Enter` so the pane survives `claude` exiting).
7. **Pane focus:** `select-pane` lands on the top (shell) pane after creation.
8. **Agent command:** literal `claude` from `$PATH`. No flags for now.
9. **Cleanup:** `tm -d <workspace> <branch>` kills the tmux window `<workspace>:<branch>` and removes the worktree at `<repo>/.worktrees/<branch-flattened>`. Branch is *not* deleted. Idempotent: missing window or missing worktree is silently OK; if both are missing, prints "nothing to do". Refuses `main`, refuses operating from inside a worktree, refuses non-TMPATH or non-git workspaces. On `git worktree remove` failure (uncommitted/untracked), prints the `--force` override command.
10. **Non-git fallback:** existing `tm` behavior preserved exactly, including `CMD` pass-through.
11. **Workspace resolution order:** (a) TMPATH match → use that dir; (b) literal filesystem path (abs or relative, exists as a directory) → use it; (c) otherwise fall back to a vanilla session rooted at `$HOME` (e.g. `tm home`, `tm quick`). The git/worktree branch fires for (a) and (b) but not (c), so the fallback can't accidentally trigger worktree creation if `$HOME` happens to be a git repo. `tm -d` accepts (a) or (b) but never falls back — it errors if `WORKSPACE` doesn't resolve to a real directory.

### feedback

- Keep this in `tm` rather than adding a new binary. The git-repo branch is cheap; the non-git path is untouched.
- Don't pollute `TMPATH`: putting worktrees inside `<repo>/.worktrees/` keeps them off `find -maxdepth 2`, so they won't appear as workspaces in `_tm`/`_cm` completion.
- Worktree creation must be idempotent. Always check `git worktree list --porcelain` first.
- Only run the pane-split + claude startup when the window is *newly created*. Re-attaching to an existing window must not stack panes or relaunch claude.
- `tmux ls` + `tmux list-windows -a -F '#S:#W #{pane_current_path}'` is enough for the "what's running" view — no new script needed. Mention it in the script header comment.
- Suggest (don't force) adding `.worktrees/` to a global gitignore (`~/.config/git/ignore`) so repos don't all need local entries.

### changes by file

**`~/bin/tm` no-args output** — improve the "visibility" view. Today `tm` with no args prints usage + `tmux ls`. Change it to also print a flat windows list across all sessions so you can see what's running at a glance:

```
USAGE: ...
<blank>
Sessions:
<tmux ls output>
<blank>
Windows:
<tmux list-windows -a -F '#S:#W  #{pane_current_path}' output>
```

Guard both tmux calls with `2>/dev/null || true` so `tm` with no args still works cleanly when no tmux server is running.

**`~/bin/tm`** — primary changes. New helpers + branch in the workspace-resolution path.

Add helpers (bash functions) near the top:

- `is_git_repo <dir>`: `git -C "$dir" rev-parse --git-dir >/dev/null 2>&1`. True for both main checkouts and worktrees.
- `is_worktree <dir>`: `[[ "$(git -C "$dir" rev-parse --git-common-dir)" != "$(git -C "$dir" rev-parse --git-dir)" ]]`. Distinguishes a linked worktree from the main checkout.
- `flatten_branch <branch>`: `echo "${branch//\//-}"`.
- `worktree_path <repo_root> <branch>`: `echo "$repo_root/.worktrees/$(flatten_branch "$branch")"`.
- `find_worktree <repo_root> <branch>`: parse `git -C "$repo_root" worktree list --porcelain` for a record matching `branch refs/heads/<branch>` and echo its `worktree` line. Empty if none.
- `branch_exists <repo_root> <branch>`: `git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"` OR `git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$branch"`.
- `ensure_worktree <repo_root> <branch>`:
  1. `existing=$(find_worktree "$repo_root" "$branch")`. If non-empty, echo it and return.
  2. Else compute `path=$(worktree_path "$repo_root" "$branch")`.
  3. If `branch_exists`, run `git -C "$repo_root" worktree add "$path" "$branch"`.
  4. Else run `git -C "$repo_root" worktree add -b "$branch" "$path"`.
  5. Echo `$path`.
- `process_worktreeinclude <repo_root> <wt_path>`: if `<repo_root>/.worktreeinclude` exists (same syntax as `.gitignore`), enumerate untracked files matching its patterns via `git ls-files --others -i --exclude-from=<file>`, filter through `git check-ignore -q` (so only files that are *also* gitignored are copied — tracked files never duplicated), then `cp -p` each match from `<repo_root>` to `<wt_path>`, creating parent dirs as needed. Runs on every worktree creation *and* every reuse, but never overwrites an existing path in the worktree — so the include file can be refined incrementally and only newly-listed files are materialized on the next `tm REPO branch` invocation.

Main flow changes after `workspace_dir=$(expand_workspace "$WORKSPACE")`:

```
# Default WINDOW_NAME='main' keeps the existing (non-worktree) behavior.
# An explicit WINDOW_NAME on a git workspace triggers worktree + agent.
agent_window=false
if [[ "$WINDOW_NAME" != "main" ]] && is_git_repo "$workspace_dir"; then
  if is_worktree "$workspace_dir"; then
    echo "tm: refusing to create a worktree inside an existing worktree: $workspace_dir" >&2
    exit 1
  fi
  repo_root=$(git -C "$workspace_dir" rev-parse --show-toplevel)
  workspace_dir=$(ensure_worktree "$repo_root" "$WINDOW_NAME")
  agent_window=true
fi
```

Then, on every code path that *creates* a new window (the four `new-window`/`new-session` invocations in the current script), capture whether the window was newly created, and if `agent_window=true && new_window=true`, run:

```
target="$SESSION_NAME:$WINDOW_NAME"
tmux split-window -v -c "$workspace_dir" -t "$target"
tmux send-keys -t "$target.1" 'claude' Enter
tmux select-pane -t "$target.0"
```

The simplest way to know "newly created" is to gate this on the same branches that currently call `new-window`/`new-session` for the missing case (lines 77, 87, 94, 105, 111 in the current script). On the "already exists, just select" paths, do nothing.

Header comment to add:

```
# Manual cleanup of a worktree window:
#   tmux kill-window -t <session>:<branch>
#   git -C <repo> worktree remove <repo>/.worktrees/<branch-flattened>
#   # then optionally:  git -C <repo> branch -d <branch>
#
# To see all running sessions/windows + their cwds:
#   tmux list-windows -a -F '#S:#W #{pane_current_path}'
```

**`~/bin/tm_expand`** — no change.

**`~/.zsh/functions.zsh` (`cm`)** — no change.

**`~/.zsh/functions.zsh`** — add an fzf branch picker bound to `^Xb`.

- Widget: `_tm-fzf-branch`. On a `tm REPO ...` (or `tm -d REPO ...`) command line, parses the buffer, resolves `REPO` via the same TMPATH-then-literal-path logic, lists branches via `git for-each-ref refs/heads/` + `refs/remotes/origin/` (strip `origin/`, filter `HEAD`, sort -u), and pipes them through fzf.
- Pre-seeds fzf's query with the trailing partial branch word so `tm drip feat^Xb` opens fzf already filtered to "feat".
- Insertion rules: trailing space → append; cursor right after the repo (no space) → insert ` BRANCH`; partial branch word at cursor → replace it.
- Falls back gracefully with `zle -M` messages if the buffer isn't a `tm` command, repo isn't found, or repo isn't a git repo.
- Complements (doesn't replace) the existing tab completion in `_tm`.

**`~/.zsh/completions/_tm`** — extend to complete branches as the second argument.

- Arg 1 (`tm <TAB>`): unchanged — `_path_files` against `$TMPATH`.
- Arg 2 (`tm REPO xxx<TAB>`): if the resolved `REPO` dir is a git repo, list branches via `git for-each-ref refs/heads/` + `refs/remotes/origin/` (strip `origin/`, filter `HEAD`, sort -u). Slashed branch names preserved. If the repo isn't found or isn't a git repo, no completions offered.
- Arg 3+: no completion (CMD pass-through is freeform).
- Worktrees live under `<repo>/.worktrees/` (depth ≥ 3 from `$HOME/src/`) so they won't appear in `TMPATH`'s `find -maxdepth 2` and won't pollute arg-1 completion.

`~/.zsh/completions/_cm` — no change (still completes only TMPATH workspaces).

**tmux configs** — no change.

### testing checklist

- `tm somerepo` → opens existing repo, `main` window, no worktree, no claude pane. (Regression check.)
- `tm somerepo feature/foo` on a fresh branch → creates `.worktrees/feature-foo`, new branch `feature/foo` off current HEAD, window `feature/foo` with shell on top + claude on bottom, focus on top.
- `tm somerepo feature/foo` a second time (window exists) → just focuses the existing window. No extra panes, no relaunch of claude.
- `tm somerepo feature/foo` after killing the window but worktree still on disk → reuses worktree path, recreates window with the two panes.
- `tm somerepo existing-remote-branch` (exists on origin but not locally) → `git worktree add` resolves the remote-tracking ref and sets up a local branch. Window created normally.
- `tm` invoked from inside `<repo>/.worktrees/feature-foo` (i.e. workspace_dir already a worktree) with a new WINDOW_NAME → errors out cleanly.
- `tm nongit-dir somewindow` → unchanged behavior (no worktree attempt, no agent pane).
- `tm nongit-dir somewindow some_command` → CMD still runs (regression check).
- `tmux list-windows -a -F '#S:#W #{pane_current_path}'` shows worktree paths for agent windows, repo root for `main`.

### out of scope (future work)

- `cm <session> <branch>` jumping into a worktree from outside tmux.
- Configurable agent command (env var like `TM_AGENT=claude`).
- `-df` or `--force` flag for `tm -d` to pass through to `git worktree remove --force`.
