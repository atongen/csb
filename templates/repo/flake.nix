{
  description = "Developer shell";

  # A normal, standalone dev flake — no dependency on csb. csb consumes this
  # repo from the outside: `csb <branch>` runs its own generic sandbox here, and
  # `csb --no-sandbox <branch>` runs claude inside THIS devShell. Add packages /
  # overlay / container outputs later following a standard multi-env layout.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              git
              # <-- add your toolchain here (ruby, nodejs, cargo, …) and any
              #     native-build/runtime deps + lib-path env in a shellHook.
            ];
          };
        });
    };
}
