{
  description = "SOPS secrets — dev shell (age, sops, mkpasswd, just)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      inherit (nixpkgs) lib;
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            age
            sops
            mkpasswd
            just
          ];
          shellHook = ''
            echo "nix-secrets devshell: age, sops, mkpasswd, just (run 'just' for the recipes)"
          '';
        };
      });
    };
}
