{
  description = "SOPS secrets — dev shell (age, sops, mkpasswd, just)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Checks secretsEntry below; it has no inputs of its own.
    nixos-bootstrap.url = "github:julian-kragt/nixos-bootstrap";
  };

  outputs =
    inputs@{ nixpkgs, nixos-bootstrap, ... }:
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
      # The layout from secretsEntry, checked, for installers:
      #   nix eval --json .#installerSecretsData
      installerSecretsData = nixos-bootstrap.lib.secretsInstallerData inputs;

      # This repository's layout: where each kind of secret file is and which template
      # it follows. nixos-bootstrap checks it (installerSecretsData above); the
      # configuration and the installer read every path from it. See DESIGN.md.
      secretsEntry = {
        # "per-host": one file per host and user, <hostUserPath>/<host>-<user>.yaml.
        # "shared":   one file per user for every host they are on, <sharedUserPath>/<user>.yaml.
        # "both":     each user has both files.
        userMode = "per-host";

        hostPath = "hosts";
        hostTemplatePath = "templates/host.yaml";

        # Set for "per-host" and "both", null for "shared".
        hostUserPath = "host-users";
        hostUserTemplatePath = "templates/user.yaml";

        # Set for "shared" and "both", null for "per-host". For example:
        #   sharedUserPath = "users";
        #   sharedUserTemplatePath = "templates/shared-user.yaml";
        sharedUserPath = null;
        sharedUserTemplatePath = null;
      };

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
