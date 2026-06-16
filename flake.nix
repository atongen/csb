{
  description = "csb — sandboxed Claude Code in per-branch git worktrees (cross-platform via agent-sandbox.nix)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, agent-sandbox, claude-code }:
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

      lib' = nixpkgs.lib;

      # Parse a `.csb/allowed-domains` file into the attrset agent-sandbox wants:
      #   { "domain" = "*";  "other.com" = [ "GET" "HEAD" ]; }
      # Format: one `domain [METHOD...]` per line; `#` comments and blank lines
      # ignored; methods default to "*". Returns {} if the file is absent.
      readAllowedDomains = path:
        if !builtins.pathExists path then { }
        else
          let
            lines = lib'.splitString "\n" (builtins.readFile path);
            tokens = line:
              builtins.filter (t: builtins.isString t && t != "")
                (builtins.split "[[:space:]]+" line);
            parseLine = line:
              let t = tokens line; in
              if t == [ ] || lib'.hasPrefix "#" (builtins.head t) then null
              else {
                name = builtins.head t;
                # "*" (all methods) is expressed as the string agent-sandbox
                # expects, whether methods are omitted or written explicitly.
                value = let m = builtins.tail t; in if m == [ ] || m == [ "*" ] then "*" else m;
              };
          in
          builtins.listToAttrs (builtins.filter (x: x != null) (map parseLine lines));

      libFor = system:
        let
          pkgs = pkgsFor system;
          sandbox = agent-sandbox.lib.${system};

          # Minimal runtime toolset. git is included so claude can read history
          # (log/diff/blame/show) and commit; the external worktree gitdir is
          # bound automatically by agent-sandbox at launch. No interactive tools
          # (neovim/tmux) — those belong in the repo devShell.
          defaultAllowedPackages = with pkgs; [
            coreutils
            bash
            git
            ripgrep
            less
            cacert
          ];

          # Hardened egress allowlist (DNS otherwise blocked by agent-sandbox).
          defaultDomains = {
            "anthropic.com" = "*";
            "claude.com" = "*";
            "claude.ai" = "*";
            "registry.npmjs.org" = [ "GET" "HEAD" ];
            "github.com" = [ "GET" "HEAD" ];
            "githubusercontent.com" = [ "GET" "HEAD" ];
          };

          # Wrap claude with our hardened defaults. $HOME is an ephemeral tmpfs
          # in the jail (masking ~/.ssh, ~/.aws, …); we persist only claude's own
          # config/auth by binding the real host paths back in. These must exist
          # before launch (csb ensures this).
          mkClaudeSandbox =
            { allowedPackages ? [ ]
            , extraDomains ? { }
            , extraRwDirs ? [ ]
            , extraRwFiles ? [ ]
            , extraRoDirs ? [ ]
            , env ? { }
            , claudePackage ? pkgs.claude-code
            , outName ? "claude-sandboxed"
            }:
            sandbox.mkSandbox {
              pkg = claudePackage;
              binName = "claude";
              inherit outName env;
              allowedPackages = defaultAllowedPackages ++ allowedPackages;
              rwDirs = [ "$HOME/.claude" ] ++ extraRwDirs;
              rwFiles = [ "$HOME/.claude.json" ] ++ extraRwFiles;
              roDirs = extraRoDirs;
              allowedDomains = defaultDomains // extraDomains;
            };
        in
        {
          inherit readAllowedDomains mkClaudeSandbox defaultDomains;
        };
    in
    {
      # Reusable library: consuming repo flakes call
      #   csb.lib.${system}.mkClaudeSandbox { ... }
      #   csb.lib.${system}.readAllowedDomains ./.csb/allowed-domains
      lib = forAllSystems libFor;

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          # The orchestrator script (worktree + launch). Primary install is via
          # ./install.sh into ~/bin; this output is for `nix run`/profile use.
          csb = pkgs.writeShellApplication {
            name = "csb";
            runtimeInputs = [ pkgs.git ];
            text = builtins.readFile ./bin/csb;
          };

          # Example/default sandbox (cwd + ~/.claude only, default domains).
          # Useful for ad-hoc `nix run .#claude-sandboxed` and for validation.
          # NOTE: csb deliberately does NOT fall back to this — a per-repo flake
          # is required so each repo controls its own toolchain and allowlist.
          claude-sandboxed = (libFor system).mkClaudeSandbox { };
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
        description = "Repo flake: interactive devShell + hardened sandboxed claude (csb)";
      };
      templates.repo = self.templates.default;
    };
}
