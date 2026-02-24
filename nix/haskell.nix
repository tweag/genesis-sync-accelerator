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
    compiler-nix-name = "ghc967";
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
