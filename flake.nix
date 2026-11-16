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
        telltale-with-ui = self.packages.${prev.system}.telltale-with-ui;
      };

      nixosModules.telltale = import ./nixos-module.nix { inherit self; };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          cleanSource = lib.cleanSourceWith {
            src = ./.;
            filter = path: type:
              let
                rel = lib.removePrefix (toString ./. + "/") (toString path);
              in
              lib.any (prefix: lib.hasPrefix prefix rel) [
                "Cargo.toml"
                "Cargo.lock"
                "crates"
                "presets"
                "rust-toolchain.toml"
              ];
          };

          uiDist = pkgs.buildNpmPackage {
            pname = "telltale-ui";
            version = "0.1.0";
            src = ./ui;
            npmDepsHash = "sha256-K+/v+7CS8Vc5Pbw/deRrAEuXVze3MzFYN3yFCLPvFbE=";
            preBuild = ''
              mkdir -p ../docs/help
              cp ${./docs/help/topics.json} ../docs/help/topics.json
            '';
            installPhase = ''
              mkdir -p $out
              cp -r dist $out/
            '';
            meta = {
              description = "TelltaleDNS web UI";
              homepage = "https://github.com/paimonsoror/telltaledns";
              license = with lib.licenses; [ asl20 mit ];
              maintainers = [ ];
              platforms = lib.platforms.linux;
            };
          };

          mkTelltale = { withUi ? false }:
            let
              src =
                if withUi then
                  pkgs.runCommand "telltale-src-with-ui" { } ''
                    mkdir -p $out
                    cp -r ${cleanSource}/. $out/
                    mkdir -p $out/ui
                    cp -r ${uiDist}/dist $out/ui/
                  ''
                else
                  cleanSource;
            in
            pkgs.rustPlatform.buildRustPackage {
              pname = "telltale${lib.optionalString withUi "-with-ui"}";
              inherit version src;

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
                description = "TelltaleDNS resolver${lib.optionalString withUi " (with web UI)"}";
                homepage = "https://github.com/paimonsoror/telltaledns";
                license = with lib.licenses; [ asl20 mit ];
                maintainers = [ ];
                mainProgram = "telltale";
                platforms = lib.platforms.linux;
              };
            };
        in
        {
          default = mkTelltale { };
          telltale = self.packages.${system}.default;
          telltale-with-ui = mkTelltale { withUi = true; };
        });

      checks = forAllSystems (system: {
        telltale = self.packages.${system}.default;
      });
    };
}
