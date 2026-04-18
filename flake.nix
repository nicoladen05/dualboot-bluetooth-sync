{
  description = "Wrap sync-bluetooth-keys.sh with its runtime dependencies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        rec {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "dualboot-bluetooth-sync";
            version = "0.1.0";
            src = self;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin"
              cp "$src/sync-bluetooth-keys.sh" "$out/bin/sync-bluetooth-keys"
              chmod +x "$out/bin/sync-bluetooth-keys"

              wrapProgram "$out/bin/sync-bluetooth-keys" \
                --prefix PATH : "${
                  lib.makeBinPath [
                    pkgs.bash
                    pkgs.bluez
                    pkgs.chntpw
                    pkgs.coreutils
                    pkgs.gawk
                    pkgs.gnugrep
                    pkgs.python3
                    pkgs.systemd
                    pkgs.util-linux
                  ]
                }"

              runHook postInstall
            '';

            meta = with lib; {
              description = "Sync Bluetooth pairing keys from a Windows partition into BlueZ";
              platforms = platforms.linux;
              mainProgram = "sync-bluetooth-keys";
            };
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/sync-bluetooth-keys";
        };
      });
    };
}
