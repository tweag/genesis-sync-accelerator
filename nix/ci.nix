{ inputs, pkgs }:

let
  inherit (pkgs) lib haskell-nix;
  inherit (haskell-nix) haskellLib;
  buildSystem = pkgs.stdenv.buildPlatform.system;

  mkHaskellJobsFor =
    hsPkgs:
    let
      projectHsPkgs = haskellLib.selectProjectPackages hsPkgs.hsPkgs;
      noCross = buildSystem == hsPkgs.pkgs.stdenv.hostPlatform.system;

      isCardanoExe =
        p:
        let
          i = p.identifier;
        in
        i.name == "genesis-sync-accelerator" && i.component-type == "exe";
      setGitRevs = lib.mapAttrsRecursiveCond (as: !lib.isDerivation as) (
        _: p: if isCardanoExe p then pkgs.set-git-rev p else p
      );
    in
    {
      build = setGitRevs (haskellLib.mkFlakePackages projectHsPkgs);
      checks = haskellLib.mkFlakeChecks (haskellLib.collectChecks' projectHsPkgs);
      exes = setGitRevs (
        lib.mapAttrs' (_: p: lib.nameValuePair p.identifier.component-name p) (
          lib.filterAttrs (_: isCardanoExe) (haskellLib.mkFlakePackages projectHsPkgs)
        )
      );
    }
    // lib.optionalAttrs noCross {
      devShell = import ./shell.nix { inherit inputs pkgs hsPkgs; };
      devShellProfiled = import ./shell.nix {
        inherit inputs pkgs;
        hsPkgs = hsPkgs.projectVariants.profiled;
      };
    };

  jobs = lib.filterAttrsRecursive (n: v: n != "recurseForDerivations") ({
    native = {
      haskell = mkHaskellJobsFor pkgs.hsPkgs;
    };
    formattingLinting = import ./formatting-linting.nix pkgs;
  });

  stripDevShells = lib.filterAttrsRecursive (n: _: n != "devShell" && n != "devShellProfiled");

  require =
    jobs:
    pkgs.releaseTools.aggregate {
      name = "required-genesis-sync-accelerator";
      constituents = lib.collect lib.isDerivation (stripDevShells jobs);
    };
in
jobs // { required = lib.mapAttrs (_: require) jobs; }
