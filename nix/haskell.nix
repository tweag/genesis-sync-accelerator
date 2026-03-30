inputs: final: prev:

let
  inherit (prev) lib;
  fs = lib.fileset;
  inherit (final) haskell-nix;

  forAllProjectPackages =
    cfg:
    args@{ config, lib, ... }:
    {
      options.packages = lib.genAttrs config.package-keys (
        _:
        lib.mkOption {
          type = lib.types.submodule ({ config, lib, ... }: lib.mkIf config.package.isProject (cfg args));
        }
      );
    };
  hsPkgs = haskell-nix.cabalProject {
    src = ./..;
    compiler-nix-name = import ./ghc.nix;
    inputMap = {
      "https://chap.intersectmbo.org/" = inputs.CHaP;
    };
    modules = [
      (forAllProjectPackages (
        { ... }:
        {
          ghcOptions = [ "-Werror" ];
        }
      ))
      # amazonka 2.0 packages re-export duplicate record fields from
      # multiple constructors, which GHC 9.6 rejects by default.
      {
        packages.amazonka.components.library.ghcOptions = [ "-XDuplicateRecordFields" ];
        packages.amazonka-core.components.library.ghcOptions = [ "-XDuplicateRecordFields" ];
        packages.amazonka-s3.components.library.ghcOptions = [ "-XDuplicateRecordFields" ];
        packages.amazonka-sso.components.library.ghcOptions = [ "-XDuplicateRecordFields" ];
        packages.amazonka-sts.components.library.ghcOptions = [ "-XDuplicateRecordFields" ];
        # Haddock builds don't inherit ghcOptions, so disable them for packages
        # that use duplicate record fields (incompatible with GHC 9.8+ by default).
        packages.amazonka.doHaddock = false;
        packages.amazonka-core.doHaddock = false;
        packages.amazonka-s3.doHaddock = false;
        packages.amazonka-sso.doHaddock = false;
        packages.amazonka-sts.doHaddock = false;
      }
    ];
    flake.variants = {
      profiled = {
        modules = [
          {
            enableLibraryProfiling = true;
            enableProfiling = true;
            # https://well-typed.com/blog/2023/03/prof-late/
            profilingDetail = "late";
          }
        ];
      };
    };
  };
in
{
  inherit hsPkgs;
}
