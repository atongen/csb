{
  description = "Sandboxed Development Environment with jail.nix and claude-code-nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    jail-nix.url = "git+https://git.sr.ht/~alexdavid/jail.nix";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, jail-nix, claude-code }:
    let
      system = "x86_64-linux";

      # Apply the claude-code overlay and allow the unfree binary
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ claude-code.overlays.default ];
        config = {
          allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [
            "claude-code"
          ];
        };
      };

      # Initialize the jail library
      jail = jail-nix.lib.init pkgs;

      # Best-of-breed terminal development tools and language toolchains
      devTools = with pkgs; [
        coreutils # provides dircolors (fixes bash warning)
        less      # provides lesspipe (fixes bash warning)
        git
        neovim
        tmux
        ripgrep
        fzf
        jq
        btop
        zoxide
        starship

        # Toolchains
        cargo
        rustc
        ruby
      ];

      # Sandboxed Claude Code executable
      jailed-claude = jail "claude" (pkgs.writeShellScriptBin "claude" ''
        # Execute the properly Nix-packaged claude binary directly
        exec ${pkgs.claude-code}/bin/claude "$@"
      '') (with jail.combinators; [
        network
        mount-cwd

        # Grant Claude the ability to use the tools we defined above
        (add-pkg-deps devTools)

        # Explicit read/write access for Claude's config/auth state
        (readwrite (noescape "~/.claude"))
        (readwrite (noescape "~/.claude.json"))
      ]);

    in {
      devShells.${system}.default = pkgs.mkShell {
        # Inject the devTools and the locked-down Claude executable
        packages = devTools ++ [ jailed-claude ];

        shellHook = ''
          # Ensure the required bwrap mount point exists on the host
          mkdir -p ~/.claude

          export SHELL_ENV="sandboxed"
          echo "======================================================="
          echo "🛠️  Terminal Environment Loaded."
          echo "📦 Tools available: tmux, neovim, git, rg, fzf, etc."
          echo "🔒 Run 'claude' to launch the agent in a bubblewrap jail."
          echo "======================================================="
        '';
      };
    };
}
