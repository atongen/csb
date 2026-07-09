{
  description = "csb — Claude Code in per-branch git worktrees: repo devShell + env scrub + deny-list sandbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, claude-code }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # nixpkgs with the claude-code overlay (fresh official binaries) and the
      # unfree claude-code binary allowed.
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ claude-code.overlays.default ];
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
      };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          # The orchestrator script (worktree + launch). Primary install is via
          # `make install` into ~/bin; this output is for `nix run`/profile use.
          csb = pkgs.writeShellApplication {
            name = "csb";
            runtimeInputs = [ pkgs.git pkgs.coreutils ];
            text = builtins.readFile ./bin/csb;
          };

          # The claude binary csb launches inside the repo's own devShell
          # (`nix develop <repo> --command ... claude`) — supplied from csb's
          # flake so consuming repos stay decoupled from csb.
          claude = pkgs.claude-code;
        } // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          # Deny-list wrapper on Linux. csb resolves this to a store path at
          # launch so the sandbox doesn't depend on bubblewrap being installed
          # on the host. (macOS uses /usr/bin/sandbox-exec — nothing to build.)
          bwrap = pkgs.bubblewrap;
        });

      # csb dogfoods itself: `csb <branch>` (or --here) runs claude in this
      # devShell to edit/lint the script. Standalone, like the repo template.
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.git
              pkgs.neovim            # editor for interactive shell work
              pkgs.shellcheck
              pkgs.bashInteractive   # `complete`/readline — mkShell's default bash lacks progcomp
              pkgs.bash-completion   # programmable Tab completion (git, etc.)
            ];

            # `csb -s` launches a fresh interactive bash with a redirected HOME,
            # so expose the bash-completion entry script for an interactive rc to
            # source. Loading completion (and prompt styling) is a personal /
            # interactive concern, kept out of the flake — seed a .bashrc into the
            # sandbox HOME via seed_home= (`. "$BASH_COMPLETION"`), or launch with
            # a profile's `args=bash --rcfile <path>`.
            shellHook = ''
              export BASH_COMPLETION="${pkgs.bash-completion}/share/bash-completion/bash_completion"
            '';
          };
        });

      apps = forAllSystems (system: {
        csb = {
          type = "app";
          program = "${self.packages.${system}.csb}/bin/csb";
        };
        default = self.apps.${system}.csb;
      });

      # `nix flake init -t github:atongen/csb` scaffolds a consuming repo.
      templates.default = {
        path = ./templates/repo;
        description = "Repo flake: a standalone devShell that csb runs claude in";
      };
      templates.repo = self.templates.default;
    };
}
