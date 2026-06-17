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

          # Wrap claude with our hardened defaults. The jail's $HOME is an
          # ephemeral tmpfs (agent-sandbox default), so the host's ~/.claude /
          # ~/.claude.json — and ~/.ssh, ~/.aws, … — are NOT visible: nothing
          # personal leaks in, and there's no cross-run/cross-agent state.
          #
          # Auth is provided by forwarding CLAUDE_CODE_OAUTH_TOKEN at runtime.
          # agent-sandbox expands the "$VAR" reference in the launching shell, so
          # the token value is never written to the world-readable /nix/store —
          # only the literal string "$CLAUDE_CODE_OAUTH_TOKEN" is. Generate one
          # with `claude setup-token` and export it before launching (csb passes
          # it through). ANTHROPIC_API_KEY is forwarded too if you prefer that.
          mkClaudeSandbox =
            { allowedPackages ? [ ]
            , extraDomains ? { }
            , extraRwDirs ? [ ]
            , extraRwFiles ? [ ]
            , extraRoDirs ? [ ]
            , extraRoFiles ? [ ]
            , env ? { }
            , claudePackage ? pkgs.claude-code
            , outName ? "claude-sandboxed"
              # global = true binds the REAL host ~/.claude + ~/.claude.json
              # (full host config/history/MCP) instead of the per-namespace dir.
              # csb runs this variant for `--ns global`.
            , global ? false
            }:
            let
              # Interactive claude runs first-run login/onboarding on an empty
              # config (its OAuth callback server can't bind a port in the jail),
              # and prompts to "trust" each new folder. Seed a config into the
              # ephemeral $HOME marking onboarding complete AND the cwd trusted, so
              # interactive claude skips both and just uses CLAUDE_CODE_OAUTH_TOKEN.
              # Runs inside the jail, touching only the throwaway tmpfs HOME.
              claudeSeeded = pkgs.writeShellScriptBin "claude" ''
                # Namespace: csb forwards CSB_CLAUDE_CONFIG_DIR (a dir under the
                # bound ~/.csb/claudes parent). When set, claude persists its
                # state there (incl. .claude.json); when empty, use the ephemeral
                # tmpfs ~/.claude.
                if [ -n "''${CSB_CLAUDE_CONFIG_DIR:-}" ]; then
                  export CLAUDE_CONFIG_DIR="$CSB_CLAUDE_CONFIG_DIR"
                fi
                # Merge onboarding-complete + cwd-trust into the .claude.json that
                # claude actually reads (CLAUDE_CONFIG_DIR when set, else $HOME) so
                # interactive claude skips first-run login + folder-trust and uses
                # the forwarded CLAUDE_CODE_OAUTH_TOKEN. Idempotent; preserves any
                # existing state in a persistent namespace.
                _dir="''${CLAUDE_CONFIG_DIR:-$HOME}"
                mkdir -p "$_dir"
                _cfg="$_dir/.claude.json"
                _base='{}'; [ -e "$_cfg" ] && _base="$(cat "$_cfg")"
                _tmp="$(mktemp)"
                printf '%s' "$_base" | ${pkgs.jq}/bin/jq --arg p "$PWD" \
                  '.hasCompletedOnboarding = true
                   | .projects[$p].hasTrustDialogAccepted = true
                   | .projects[$p].projectOnboardingSeenCount = ((.projects[$p].projectOnboardingSeenCount) // 1)' \
                  > "$_tmp" && cat "$_tmp" > "$_cfg" && rm -f "$_tmp"
                exec ${claudePackage}/bin/claude "$@"
              '';
            in
            sandbox.mkSandbox {
              # global: run real claude directly so we NEVER mutate the host's
              # real ~/.claude (claude manages it itself). otherwise: the seed
              # wrapper marks onboarding/trust in the throwaway/namespace config.
              pkg = if global then claudePackage else claudeSeeded;
              binName = "claude";
              inherit outName;
              # Runtime-expanded "$VAR" references (never baked into the store):
              #  - OAuth token for auth (only this one by default; an unset
              #    ANTHROPIC_API_KEY="" could shadow it, so callers add it via env).
              #  - git identity so claude can commit in the jail; csb populates
              #    these from the host's effective `git config`. No file is bound,
              #    so it's portable (works regardless of where gitconfig lives).
              env = {
                CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
                CSB_CLAUDE_CONFIG_DIR = "$CSB_CLAUDE_CONFIG_DIR";
                GIT_AUTHOR_NAME = "$GIT_AUTHOR_NAME";
                GIT_AUTHOR_EMAIL = "$GIT_AUTHOR_EMAIL";
                GIT_COMMITTER_NAME = "$GIT_COMMITTER_NAME";
                GIT_COMMITTER_EMAIL = "$GIT_COMMITTER_EMAIL";
              } // env;
              allowedPackages = defaultAllowedPackages ++ allowedPackages;
              # global: bind the real host config. otherwise: bind the fixed
              # ~/.csb/claudes parent (the specific namespace dir is selected at
              # runtime via CSB_CLAUDE_CONFIG_DIR).
              rwDirs = (if global then [ "$HOME/.claude" ] else [ "$HOME/.csb/claudes" ]) ++ extraRwDirs;
              rwFiles = (if global then [ "$HOME/.claude.json" ] else [ ]) ++ extraRwFiles;
              roDirs = extraRoDirs;
              roFiles = extraRoFiles;
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

          # `--ns global` variant: binds the real host ~/.claude + ~/.claude.json.
          claude-sandboxed-global = (libFor system).mkClaudeSandbox {
            global = true;
            outName = "claude-sandboxed-global";
          };

          # Plain (unsandboxed) claude, for `csb --no-sandbox` — csb runs this
          # inside the repo's own devShell (`nix develop <repo> -c claude`), so
          # it gets the repo's full toolchain without the repo importing csb.
          claude = pkgs.claude-code;
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
