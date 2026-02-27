# Contributing to Genesis Sync Accelerator

Thank you for your interest in contributing! We welcome contributions from the community.

## Reporting Issues

- Use [GitHub Issues](../../issues) to report bugs or request features.

## Setting up the build tools

### Using nix

Make sure you have [Nix](https://nixos.org/download.html) installed with flakes support enabled.

You can enter a Nix shell with all dependencies by running:

``` sh
nix develop
```

This will set up the environment with the required GHC version and all necessary libraries and tools.

#### Profiled shell

A profiled dev shell is also available:

``` sh
nix develop .#haskell-profiled
```

#### Nix cache (optional, but recommended)

To speed up the build process (avoid building GHC), you should use the IOHK and project Nix caches. The `flake.nix` already declares them via `nixConfig`, but if your Nix daemon doesn't pick those up, add to `/etc/nix/nix.conf`:

```conf
substituters = https://cache.iog.io https://genesis-sync-accelerator.cachix.org <other substituters you might have>
trusted-public-keys = hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= genesis-sync-accelerator.cachix.org-1:/usH0+ZtxuHMWbx5teUFACvRZV1+LdBtjwoYruy4OGY= <other keys you might have>
```

#### Using direnv (optional, but recommended)

If you have [direnv](https://direnv.net/)  and [nix-direnv](https://github.com/nix-community/nix-direnv) installed, you can set it up to automatically load the Nix environment when you enter the project directory.

1. Create a `.envrc` file in the project root with the following content:

   ```sh
   use flake
   ```

2. Allow the `.envrc` file:

   ```sh
   direnv allow
   ```

3. Now, whenever you `cd` into the project directory, direnv will automatically load the Nix environment.

### Using cabal

In order to work with the project you need to install [GHC](https://www.haskell.org/ghc/)>= 9.6 and [cabal](https://www.haskell.org/cabal/)>=3.4. We suggest installing them using [GHCup](https://www.haskell.org/ghcup/) project.

To install ghcup follow the instructions on site. After installing run

```sh
ghcup tui
```

And select recommended versions of GHC and cabal.

## Building the project

To build the project in the project directory run command:

``` sh
cabal build all
```

### Building with Nix

You can also build the project using Nix directly:

``` sh
nix build
```

## Code style

CI checks formatting and linting. The dev shell provides all required tools:

- [`fourmolu`](https://github.com/fourmolu/fourmolu): Haskell code formatting
- [`hlint`](https://github.com/ndmitchell/hlint): Haskell linting
- [`cabal-gild`](https://github.com/tfausak/cabal-gild): Cabal file formatting
- [`nixfmt`](https://github.com/NixOS/nixfmt): Nix file formatting

``` sh
fourmolu -i app/**/*.hs src/**/*.hs
hlint .
cabal-gild -i genesis-sync-accelerator.cabal
nixfmt nix/*.nix flake.nix
```

## Running Hydra jobs locally

CI runs two Hydra job aggregates. You can build them locally to verify your changes before pushing:

``` sh
# Formatting and linting checks
nix build .#hydraJobs.x86_64-linux.required.formattingLinting --print-build-logs

# Full native build
nix build .#hydraJobs.x86_64-linux.required.native --print-build-logs
```

**Replace `x86_64-linux` with your system if different (e.g. `aarch64-darwin`).**

## How to Contribute

1. **Fork the repository** and create your branch from `main`.
1. **Clone your fork** and set up the project locally, see setting up section.
1. **Make your changes** with clear, descriptive commit messages.
1. **Open a Pull Request** describing your changes and referencing any related issues.

## Code of conduct

This project follows the [Contributor Covenant][cc-homepage] code of conduct.

## License

By contributing, you agree that your contributions will be licensed under the project's license.

---

Thank you for helping improve Genesis Sync Accelerator!

[cc-homepage]: https://www.contributor-covenant.org
