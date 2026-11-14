{
  description = "TelltaleDNS — filtering, encrypted, observable DNS resolver";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      workspace = lib.fromTOML (builtins.readFile ./Cargo.toml);
      version = workspace.workspace.package.version;
      commit = self.dirtyShortRev or self.shortRev or "unknown";
      date = self.lastModifiedDate or "unknown";

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
    in
    {
      overlays.default = final: prev: {
        telltale = self.packages.${prev.system}.default;
      };

      nixosModules.telltale = import ./nixos-module.nix { inherit self; };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "telltale";
            inherit version;
            src = ./.;

            cargoLock = {
              lockFile = ./Cargo.lock;
            };

            outputs = [ "out" ];

            nativeBuildInputs = with pkgs; [
              perl
              pkg-config
            ];

            buildInputs = with pkgs; [
              sqlite
              zstd
            ];

            env = {
              TELLTALE_BUILD_VERSION = version;
              TELLTALE_BUILD_COMMIT = commit;
              TELLTALE_BUILD_DATE = date;
              TELLTALE_BUILD_CHANNEL = "stable";
            };

            # Tests touch the network and local sockets; run them in a checked-out tree with
            # `cargo test` rather than inside the sandbox.
            doCheck = false;

            meta = {
              description = "TelltaleDNS resolver";
              homepage = "https://github.com/paimonsoror/telltaledns";
              license = with lib.licenses; [ asl20 mit ];
              maintainers = [ ];
              mainProgram = "telltale";
              platforms = lib.platforms.linux;
            };
          };

          telltale = self.packages.${system}.default;
        });

      checks = forAllSystems (system: {
        telltale = self.packages.${system}.default;
      });
    };
}
