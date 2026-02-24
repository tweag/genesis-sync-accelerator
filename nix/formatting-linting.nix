pkgs:

let
  inherit (pkgs) lib;
  checkFormatting =
    tool: script:
    pkgs.runCommand "check-${lib.getName tool}"
      {
        buildInputs = [
          pkgs.fd
          tool
        ];
        src = ../.;
      }
      ''
        unpackPhase
        cd $sourceRoot

        bash ${script}

        EXIT_CODE=0
        diff -ru $src . || EXIT_CODE=$?

        if [[ $EXIT_CODE != 0 ]]
        then
          echo "*** ${tool.name} found changes that need addressed first"
          exit $EXIT_CODE
        else
          echo $EXIT_CODE > $out
        fi
      '';
  formattingLinting = {
    fourmolu = checkFormatting pkgs.fourmolu ../scripts/ci/run-fourmolu.sh;
    cabal-gild = checkFormatting pkgs.cabal-gild ../scripts/ci/run-cabal-gild.sh;
    nixfmt = checkFormatting pkgs.nixfmt ../scripts/ci/run-nixfmt.sh;
    dos2unix = checkFormatting pkgs.dos2unix ../scripts/ci/run-dos2unix.sh;
    hlint =
      pkgs.runCommand "hlint"
        {
          buildInputs = [ pkgs.hlint ];
          src = ../.;
        }
        ''
          unpackPhase
          cd $sourceRoot

          hlint -j .

          touch $out
        '';
  };
in
formattingLinting
// {
  all = pkgs.releaseTools.aggregate {
    name = "gsa-formatting";
    meta.description = "Run all formatters and linters";
    constituents = lib.collect lib.isDerivation formattingLinting;
  };
}
