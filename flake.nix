{
  description = "Reproducible development environment for the ETH AOS Barrelfish handout";

  inputs = {
    # The handout targets Ubuntu 18.04-era tools: GCC 7 and GHC 8.0.2.
    # Keep this input non-flake so the historical Nixpkgs tree can be used.
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-18.09";
      flake = false;
    };
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      haskell = pkgs.haskell.packages.ghc802.ghcWithPackages (hp: with hp; [
        MissingH
        aeson
        aeson-pretty
        async
        bytestring-trie
        ghc-mtl
        ghc-paths
        haskell-src-exts
        parsec
        pretty-simple
        random
      ]);

      aarch64 = pkgs.pkgsCross.aarch64-multiplatform;
      aarch64CC = aarch64.stdenv.cc;
      aarch64Binutils = aarch64.binutils;

      # Hake assumes Debian's aarch64-linux-gnu-* executable names, while
      # Nixpkgs uses the canonical aarch64-unknown-linux-gnu-* triplet.
      toolchainAliases = pkgs.runCommand "barrelfish-toolchain-aliases" { } ''
        mkdir -p "$out/bin"

        ln -s ${pkgs.stdenv.cc}/bin/gcc "$out/bin/x86_64-linux-gnu-gcc"
        ln -s ${pkgs.stdenv.cc}/bin/g++ "$out/bin/x86_64-linux-gnu-g++"
        for tool in ar ld objcopy objdump ranlib strip; do
          ln -s ${pkgs.binutils}/bin/$tool "$out/bin/x86_64-linux-gnu-$tool"
        done
        ln -s ${pkgs.gdb}/bin/gdb "$out/bin/gdb-multiarch"

        ln -s ${aarch64CC}/bin/aarch64-unknown-linux-gnu-gcc \
          "$out/bin/aarch64-linux-gnu-gcc"
        ln -s ${aarch64CC}/bin/aarch64-unknown-linux-gnu-g++ \
          "$out/bin/aarch64-linux-gnu-g++"
        for tool in ar ld objcopy objdump ranlib strip; do
          ln -s ${aarch64Binutils}/bin/aarch64-unknown-linux-gnu-$tool \
            "$out/bin/aarch64-linux-gnu-$tool"
        done
      '';

      # The generated Makefile links host tools with -lelf-freebsd and adds
      # /usr/include/freebsd. Nixpkgs' libelf implements the same API under
      # standard Unix names, so expose the layout expected by the handout.
      libelfFreebsdCompat = pkgs.runCommand "libelf-freebsd-compat" { } ''
        mkdir -p "$out/include/freebsd" "$out/lib"
        ln -s ${pkgs.libelf}/include/libelf.h "$out/include/freebsd/libelf.h"
        ln -s ${pkgs.libelf}/include/gelf.h "$out/include/freebsd/gelf.h"
        ln -s ${pkgs.libelf}/include/nlist.h "$out/include/freebsd/nlist.h"
        ln -s ${pkgs.libelf}/lib/libelf.a "$out/lib/libelf-freebsd.a"
        ln -s ${pkgs.libelf}/lib/libelf.so "$out/lib/libelf-freebsd.so"
      '';

      configure = pkgs.writeShellScriptBin "bf-configure" ''
        set -euo pipefail

        root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        if [[ ! -f "$root/hake/Main.hs" ]]; then
          echo "bf-configure: run this command from the Barrelfish source tree" >&2
          exit 1
        fi

        mkdir -p "$root/build"
        cd "$root/build"
        "$root/hake/hake.sh" -s "$root" -a armv8 "$@"
      '';

      build = pkgs.writeShellScriptBin "bf-build" ''
        set -euo pipefail

        root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        if [[ ! -f "$root/build/Makefile" ]]; then
          ${configure}/bin/bf-configure
        fi

        jobs="''${NIX_BUILD_CORES:-$(nproc)}"
        make -C "$root/build" -j"$jobs" armv8_a57_qemu_image
      '';

      run = pkgs.writeShellScriptBin "bf-run" ''
        set -euo pipefail

        root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        if [[ ! -f "$root/build/armv8_a57_qemu_image" ]]; then
          ${build}/bin/bf-build
        fi

        exec make -C "$root/build" qemu_a57
      '';

      shell = pkgs.mkShell {
        name = "eth-aos-barrelfish";

        buildInputs = with pkgs; [
          autoconf
          automake
          bc
          binutils
          bison
          cmake
          coreutils
          cpio
          curl
          file
          findutils
          flex
          gdb
          git
          gmp
          gnumake
          gnugrep
          gnused
          haskell
          libusb1
          m4
          pkgconfig
          python2
          python2Packages.pexpect
          python2Packages.requests
          qemu
          which

          aarch64CC
          aarch64Binutils
          configure
          build
          run
          toolchainAliases
          libelfFreebsdCompat
        ];

        NIX_CFLAGS_COMPILE = "-I${libelfFreebsdCompat}/include/freebsd";
        NIX_LDFLAGS = "-L${libelfFreebsdCompat}/lib";

        shellHook = ''
          echo "ETH AOS Barrelfish environment"
          echo "  bf-configure  generate build/Makefile for ARMv8"
          echo "  bf-build      build the QEMU ARMv8 image"
          echo "  bf-run        build if needed, then boot it in QEMU"
        '';
      };
    in
    {
      devShells.${system}.default = shell;

      packages.${system} = {
        default = shell;
        inherit configure build run toolchainAliases libelfFreebsdCompat;
      };

      apps.${system} = {
        configure = {
          type = "app";
          program = "${configure}/bin/bf-configure";
        };
        build = {
          type = "app";
          program = "${build}/bin/bf-build";
        };
        run = {
          type = "app";
          program = "${run}/bin/bf-run";
        };
      };
    };
}
