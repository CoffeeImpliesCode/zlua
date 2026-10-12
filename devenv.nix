{ pkgs, lib, inputs, ... }:

let
  zigPkgs = import inputs.nixpkgs-unstable { system = pkgs.stdenv.hostPlatform.system; };
  zig = zigPkgs.zig_0_17;
  projectRoot = lib.escapeShellArg (builtins.toString ./.);

  # Runtime configuration preserves caller settings and never builds either SDK.
  setup = ''
    ${builtins.readFile ./tools/setup-env.sh}
    zlua_setup ${projectRoot} || exit 1
    unset -f zlua_setup zlua_capture_caller zlua_restore_caller \
      zlua_resolve_directory zlua_local_directory
    unset zlua_cache_variables
  '';

  backendTasks = backend: lib.listToAttrs (map (step: {
    name = "zlua:${step}:${backend}";
    value = {
      description = "${step} the ${backend} backend";
      exec = ''
        set -e
        ${setup}
        cd ${projectRoot}
        zig build ${step} -Dbackend=${backend} -j8 --summary all \
          --cache-dir "$ZIG_LOCAL_CACHE_DIR/${backend}" "$@"
      '';
    };
  }) [ "test" "smoke" "check" ]);
in
{
  packages = [ zig pkgs.jujutsu pkgs.git pkgs.gh pkgs.coreutils pkgs.emscripten pkgs.nodejs-slim ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux pkgs.glibcLocales pkgs.readline ];

  assertions = [{
    assertion = zig.version == "0.17.0";
    message = "zlua requires Zig 0.17.0, but nixpkgs provides ${zig.version}.";
  }];

  env = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    LOCALE_ARCHIVE = lib.mkDefault "${pkgs.glibcLocales}/lib/locale/locale-archive";
  };

  enterShell = setup;

  tasks = backendTasks "lua" // backendTasks "luajit" //
    lib.listToAttrs (map (step: {
      name = "zlua:${step}";
      value = {
        description = "${step} both Lua and LuaJIT backends";
        exec = ''
          set -e
          ${setup}
          cd ${projectRoot}
          for backend in lua luajit; do
            zig build ${step} -Dbackend="$backend" -j8 --summary all \
              --cache-dir "$ZIG_LOCAL_CACHE_DIR/$backend" "$@"
          done
        '';
      };
    }) [ "test" "smoke" "check" ]) // {
      "zlua:test:wasm" = {
        description = "Execute Lua and Lua/libffi Emscripten consumers with Node";
        exec = ''
          set -e
          ${setup}
          embuilder build libc
          cd ${projectRoot}/consumer/wasm
          zig build run -Demscripten-sysroot="$EM_CACHE/sysroot" -j8 --summary all \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR/wasm" "$@"
          cd ${projectRoot}/consumer/libffi
          zig build run -Dtarget=wasm32-emscripten -Demscripten-sysroot="$EM_CACHE/sysroot" -j8 --summary all \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR/wasm-libffi" "$@"
        '';
      };
      "zlua:test:libffi" = {
        description = "Execute Lua and LuaJIT with the pinned libffi integration consumer";
        exec = ''
          set -e
          ${setup}
          cd ${projectRoot}/consumer/libffi
          for backend in lua luajit; do
            zig build test run -Dbackend="$backend" -j8 --summary all \
              --cache-dir "$ZIG_LOCAL_CACHE_DIR/libffi-$backend" "$@"
          done
        '';
      };
      "zlua:test:conformance" = {
        description = "Execute the full official Lua 5.5.1 conformance suite on Linux";
        exec = ''
          set -e
          ${setup}
          export LD_LIBRARY_PATH="${lib.makeLibraryPath [ pkgs.readline ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          cd ${projectRoot}/consumer/conformance
          zig build run -j8 --summary all \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR/conformance" "$@"
        '';
      };
      "gate:zlua" = {
        description = "Run the optional host-provided Zig gate";
        exec = ''
          set -e
          ${setup}
          cd ${projectRoot}
          if ! command -v zig-gate >/dev/null 2>&1; then
            echo 'zlua: the optional zig-gate command is not installed on this host.' >&2
            exit 1
          fi
          zig-gate
        '';
      };
    };
}
