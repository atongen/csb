# csb (claude sandbox)

We are going to build a tool that automates sandboxing claude on linux.
You can review the prior art in the docs/ directory.

## restore tm but retain generic improvements

I want to restore the ~/bin/tm script to its original functionality.
You can review a duplicate of the file in the docs/ directory: tm_original.
I want to retain any improvements to the script that are unrelated to claude and/or workspaces.
It was a mistake to try to shoehorn additional functionality into the tm script, and I want to separate concerns.

## new script: csb

Some concepts from the original script will be retained.
Linux functionality is required. If there is an alternative tool than jail.nix that works for both linux and macos, we should evaluate that tool.

High level workflow that we need to refine and then build for:

* unlike tm, there does not need to be any tmux integration - tmux can be run and managed by the user - outside the sandbox - only claude it sandboxed.
* in a git repo, use runs `csb [branch-name]`
* the result of running this command should be that a sandboxed claude is running with a working directory that is a worktree for that branch, branched off the current branch
* if the worktree already exists, it should be reused and not recreated
* I imagine that the tm script will be used along side this script to help manage tmux environments in a simple way.

* research needed: We need to be able to define nix development shells along side the claude jailing/sandboxing functionality, so we probably need to keep those separate.
                   Perhaps a repo-specific flake.nix that includes the claude sandboxing utilities so that sandboxing can be pulled in easily when necessary.
* the tools included in the claude sandbox should be the minimum necessary for claude to run effectively, but it does not need to include interactive tools (neovim, tmux, etc) -
  those should be included in the repo-specific flake.nix development shell as necessary. The claude sandbox should be focused on providing a consistent and isolated environment for running claude,
  while the development shell can be more flexible and include additional tools as needed.
