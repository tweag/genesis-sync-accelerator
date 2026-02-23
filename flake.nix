{
  nixConfig = {
    extra-substituters =
      [ "https://cache.iog.io" "https://genesis-sync-accelerator.cachix.org" ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "genesis-sync-accelerator.cachix.org-1:/usH0+ZtxuHMWbx5teUFACvRZV1+LdBtjwoYruy4OGY="
    ];
    allow-import-from-derivation = true;
  };
  inputs = {
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hls = {
      url = "github:haskell/haskell-language-server/2.11.0.0";
      flake = false;
    };
  };
  outputs = inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        #"aarch64-linux"
        "aarch64-darwin"
      ];
    in inputs.flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          inherit (inputs.haskellNix) config;
          overlays = [
            inputs.iohkNix.overlays.crypto
            inputs.haskellNix.overlay
            inputs.iohkNix.overlays.haskell-nix-crypto
            inputs.iohkNix.overlays.haskell-nix-extra
            (import ./nix/tools.nix inputs)
            (import ./nix/haskell.nix inputs)
          ];
        };
        hydraJobs = import ./nix/ci.nix { inherit inputs pkgs; };
      in {
        devShells = rec {
          default = haskell;
          haskell = hydraJobs.native.haskell.devShell;
          haskell-profiled = hydraJobs.native.haskell.devShellProfiled;

          integration-test = pkgs.mkShell {
            packages = [
              pkgs.hsPkgs.hsPkgs.genesis-sync-accelerator.components.exes.genesis-sync-accelerator
              pkgs.hsPkgs.hsPkgs.cardano-node.components.exes.cardano-node
              pkgs.hsPkgs.hsPkgs.ouroboros-consensus-cardano.components.exes.db-analyser
              pkgs.python3
              pkgs.curl
              pkgs.jq
              pkgs.iproute2
            ];
          };
        };
        inherit hydraJobs;
        legacyPackages = pkgs;
        packages = hydraJobs.native.haskell // {
          default = hydraJobs.native.haskell.exes.genesis-sync-accelerator;
        };
      });
}
