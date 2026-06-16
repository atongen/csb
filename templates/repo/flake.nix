{
  description = "Dev shell + hardened sandboxed Claude Code (csb)";

  inputs = {
    csb.url = "github:atongen/csb";
    # Reuse csb's nixpkgs so the sandbox and the dev shell stay in lockstep.
    nixpkgs.follows = "csb/nixpkgs";
  };

  outputs = { self, nixpkgs, csb }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      # Interactive environment for the human. Add your language toolchains and
      # editor/CLI tools here — these are NOT in the sandbox.
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              git
              neovim
              tmux
              ripgrep
              fzf
              jq
              # <-- add repo toolchains here (nodejs, cargo, ruby, …)
            ];
          };
        });

      # Minimal jailed claude for the agent. csb launches this. Keep the toolset
      # lean — only what claude needs at runtime (no editors/tmux).
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          claude-sandboxed = csb.lib.${system}.mkClaudeSandbox {
            # Runtime tools available to claude inside the jail, on top of the
            # built-in minimal set (coreutils, bash, git, ripgrep, less, cacert).
            allowedPackages = with pkgs; [
              # <-- e.g. nodejs, cargo, rustc, ruby, gnumake — match your repo
            ];

            # Extra egress domains, read from a tracked file at the repo root.
            # See .csb/allowed-domains. Merged on top of csb's hardened defaults.
            extraDomains = csb.lib.${system}.readAllowedDomains ./.csb/allowed-domains;
          };
        });
    };
}
