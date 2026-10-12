# zlua

`zlua` embeds one build-selected Lua runtime in a Zig program through a common `State` API.
Use `zlua.native` for the selected upstream Zig SDK and `zlua.c` for its C bindings.
The SDK supplies the native library. Do not link or build a second copy.

Use **Zig 0.17.0**. The development shell and CI select it. The manifest minimum is `0.17.0`.
Later Zig versions are not covered.

## Runtime pins

Both source repositories are private. The manifest uses immutable `git+https` revision URLs.

| Backend | Source repository | Runtime version | Revision |
| --- | --- | --- | --- |
| `lua` | [CoffeeImpliesCode/lua](https://github.com/CoffeeImpliesCode/lua) | Lua 5.5.1 | `bde3a070943d5faa03aef1bb143e01a0efe5f837` |
| `luajit` | [CoffeeImpliesCode/luajit](https://github.com/CoffeeImpliesCode/luajit) | LuaJIT 2.1.1788856981 | `6cfaae21afbe113c5310f40495cc15add1e38d68` |

These are the approved `zig-0.17` fork commits. Runtime versions and the common API are unchanged.

`-Dbackend=lua|luajit` selects one runtime. The default is `lua`.
`-Dlinkage=static|dynamic` selects native linkage. The default is `static`.
The build also accepts the standard `-Dtarget` and `-Doptimize` options.
Only the selected runtime enters the module graph.

## Get the sources

This repository is private and uses an HTTPS origin. Authenticate `gh` with an identity that can read the required repositories.
Use `gh auth login`, or supply an authorized `GH_TOKEN`. Do not put a token in a dependency URL.

For a local checkout:

```sh
gh repo clone CoffeeImpliesCode/zlua
cd zlua
```

Private HTTPS fetches require authenticated dependency acquisition. Prime the package cache with the helper:
```sh

if [ -r "$HOME/.local/lib/host-scratch.sh" ]; then
    source "$HOME/.local/lib/host-scratch.sh"
    export ZLUA_SCRATCH_ROOT="$HOST_SCRATCH_ROOT"
fi
if [ -z "${ZLUA_SCRATCH_ROOT:-}" ]; then
    echo "Set ZLUA_SCRATCH_ROOT to existing approved local scratch." >&2
    exit 1
fi
export ZIG_GLOBAL_CACHE_DIR="$ZLUA_SCRATCH_ROOT/zlua-zig-global"
export ZIG_LOCAL_CACHE_DIR="$ZLUA_SCRATCH_ROOT/zlua-zig-local"
export ZIG_LOCAL_PKG_DIR="$ZLUA_SCRATCH_ROOT/zlua-zig-pkg"
bash tools/fetch-deps.sh
```

Without the host helper, set `ZLUA_SCRATCH_ROOT` to an existing, absolute, UID-owned local scratch directory.
Do not use `/tmp`, `/var/tmp`, a network filesystem, or the checkout for scratch or caches.
The helper downloads private archives through `gh`, fetches public dependencies, and checks manifest hashes.
Zig 0.17 uses the explicit `ZIG_LOCAL_PKG_DIR`; legacy checkout `zig-pkg` links are neither needed nor changed.
It unpacks verified sources through `zig fetch --save-exact` in a scratch-only copy
of the manifest; the repository's immutable git URLs are never rewritten.
Use the cache exports it prints for subsequent builds.
To prime only one runtime, run `bash tools/fetch-deps.sh lua` or `bash tools/fetch-deps.sh luajit`.
`integration` primes four dependencies: Lua, LuaJIT, libffi, and the official Lua test suite.
`conformance` primes only Lua and the official test suite.

The helper does not prime a remote `zlua` dependency. Prefer a local `.path` dependency.
For a private remote pin, download its archive through authenticated `gh` and fetch that local archive.
Record the returned hash in your manifest and use the same package cache for the consumer.

### Development shell

Before the first direct CLI call, prepare the external devenv and direnv cache links:

```bash
source tools/setup-env.sh
zlua_capture_caller
zlua_setup "$PWD"
devenv_command=devenv
if [ -x "$HOME/.local/bin/devenv" ]; then
    devenv_command="$HOME/.local/bin/devenv"
fi
"$devenv_command" "${zlua_devenv_options[@]}" shell
```

The `.envrc` performs this setup automatically. Use the host's `~/.local/bin/devenv` wrapper when available.
The shell supplies stock Zig 0.17.0 from a pinned nixos-unstable input, Jujutsu, Git, GitHub CLI, Emscripten, Node, and glibc locales.
It sets tools and local caches but does not fetch dependencies or build SDKs.

The shell sources the host scratch helper when available and preserves caller cache settings.
Set `ZLUA_CACHE_ROOT` or `XDG_CACHE_HOME` on approved local storage if the host does not supply cache settings.
Real cache directories remain outside the checkout. The checkout contains only cache links.

Capture caller cache settings before passing them as typed options:

```bash
source tools/setup-env.sh
zlua_capture_caller
devenv "${zlua_devenv_options[@]}" tasks run zlua:test
```

Replace `zlua:test` with `zlua:check`, `zlua:smoke`, or a backend-specific task.
`gate:zlua` requires the optional host-provided `zig-gate` command. The shell does not install it.

## Add the module to a consumer

In the consumer's `build.zig.zon`, point to your local checkout:

```zig
.dependencies = .{
    .zlua = .{ .path = "zlua" },
},
```
Zig 0.17 requires path dependencies to remain inside the consumer project. Place or
symlink the checkout at `zlua` inside that project; a sibling `../zlua` path is rejected.

In the consumer's `build.zig`, pass the selected options and add only the `zlua` module:

```zig
const dependency = b.dependency("zlua", .{
    .target = target,
    .optimize = optimize,
    .backend = backend,
    .linkage = linkage,
});
executable.root_module.addImport("zlua", dependency.module("zlua"));
```

Here, `target`, `optimize`, `backend`, `linkage`, and `executable` belong to your consumer build.
See [`consumer/smoke/build.zig`](consumer/smoke/build.zig) for a complete build.
Do not add another Lua module or link the native library again. The dependency already supplies those links.

## Use a state

This complete program needs no standard Lua libraries:

```zig
const std = @import("std");
const zlua = @import("zlua");

pub fn main() !void {
    var state = try zlua.State.init();
    defer state.deinit();

    state.run("return 6 * 7", "=example", 1) catch |err| {
        const message = state.toBytes(-1) orelse "non-string Lua error";
        std.debug.print("{s}: {s}\n", .{ @errorName(err), message });
        state.pop(1);
        return err;
    };
    const result = state.toNumber(-1) orelse return error.ExpectedNumber;
    std.debug.print("{s}: {d}\n", .{ @tagName(zlua.backend), result });
    state.pop(1);
}
```

### Stack and errors

- `init` creates a state without standard libraries. `initWithLibraries` creates a state and opens all standard libraries.
- Both constructors return `error.OutOfMemory` if state creation fails. The runtime supplies the allocator.
- `load` accepts text only. It leaves a function on success or an error object on failure.
- `protectedCall` consumes the function below its `nargs` arguments. It replaces them with results or one error object.
- `run` loads text and calls it without arguments. These operations preserve earlier stack values.
- `load` and `run` need three free stack slots to establish the protected loader. Use `checkStack(3)` when availability is uncertain.
- A fixed `nresults` truncates results or adds nil values. `null` keeps all results.
- Protected errors use `SyntaxError`, `MemoryError`, `RuntimeError`, `ErrorInErrorHandler`, or `UnexpectedStatus`.
- Inspect the error object before you remove it. Lua errors can be non-string values.
- `toBytes` returns only actual strings. The returned bytes borrow runtime storage and can include NUL bytes.
- Keep a borrowed string rooted in the open state until you copy it or finish using it.
- `pushBytes` copies its input. `toNumber` accepts numbers and numeric strings, and returns `null` for failed conversions.
- The common numeric API uses `f64`. Use the selected native API for backend-specific exact integer operations.

Use `checkStack` before pushes or fixed result counts that need more stack capacity.
Stack counts must fit `c_int`. `pop(count)` requires `count <= top()`.
`setTop(count)` uses an absolute count and needs enough capacity when it grows the stack.
These are caller preconditions, not release-mode input validation.

### Lifetime and safety

One `State` owns one runtime state. Register `defer state.deinit()` immediately after successful creation.
Repeated `deinit` on the same variable is safe. A copied `State` is not an independent owner.
Do not close a copy, or use a copy after its owner closes.
Do not replace or separately close the `sdk` field.
After close, only `isOpen` and `deinit` remain valid. Close invalidates native handles and borrowed strings.
Serialize calls that use the same state.

Standard libraries expose host facilities, including I/O. This API is **not a sandbox**.
`load` rejects binary chunks. Lua and LuaJIT bytecode formats are runtime-specific and incompatible.
Their source languages also differ. A shared API does not make every script portable.

Protected compilation and calls return Zig errors. Other operations can raise an unprotected Lua error or fatal allocation panic.
Do not let an unprotected Lua `longjmp` cross Zig frames that need `defer` or `errdefer` cleanup.
Native callbacks receive a borrowed active state on the calling thread. They must not close the owning state.
Use the selected runtime's native contract for operations outside the common API.

## Build and test

After cache priming, run these native checks from the checkout:

```sh
for backend in lua luajit; do
    zig build check -Dbackend="$backend"
    zig build test -Dbackend="$backend"
    zig build smoke -Dbackend="$backend"
    (cd consumer/smoke && zig build check -Dbackend="$backend")
    (cd consumer/smoke && zig build run -Dbackend="$backend")
done
```

The default `zig build` runs `check`. It compiles tests and the package smoke program without execution.
`test` executes shared and backend-specific native API tests. `smoke` executes the package smoke program.
The separate consumer checks the real dependency import and native links.
Add `-Dlinkage=dynamic` to select dynamic linkage, or `-Doptimize=ReleaseSafe` to select another optimization mode.

### Lua workload

The 18 tests in [`tests/integration.zig`](tests/integration.zig) run handwritten chunks against the selected runtime, not skript application programs.
They cover arithmetic, results, protected errors, bytecode rejection, binary strings, garbage collection, globals, and C callbacks.
Lua-specific checks cover 64-bit integers, `math.type`, and UTF-8.
LuaJIT-specific checks cover allocation-failure recovery, JIT identity, and built-in `require('ffi')`, not the separate libffi library.
The package and dependency smoke programs check arithmetic, strings, errors, and recovery.

### Official Lua conformance suite

[`consumer/conformance`](consumer/conformance) runs the official [Lua 5.5.1 test archive](https://www.lua.org/tests/lua-5.5.1-tests.tar.gz).
Its immutable SHA-256 is `da07b543872dc0bb2ff12aabd0c248578d78df3eb6b67efdc537a46d455c7f31`.
The consumer instruments the pinned Lua SDK with the suite's `T` module and `ltests`.
It builds all five official C modules and uses the same pinned CLI for child interpreter tests.
It runs normal `all.lua` without `_U`, `_soft`, `_port`, or `_nomsg` restrictions.
LuaJIT cannot run this Lua 5.5 suite. Rejection is not a conformance pass.

Runtime execution requires Linux, Bash, ELF shared libraries, and the `pt_BR` ISO-8859-1 locale.
The development shell supplies `glibcLocales` and readline 8.3p3, with a task-scoped `LD_LIBRARY_PATH`.
The official `-E` loader case needs a discoverable `libreadline.so`, even with redirected input.
Ubuntu 24.04 CI declares installation of `libreadline-dev` and `locales`.
The official signal test also requires a compatible `/bin/sh` child-exit convention.
It expects exit 129 for `sh -c 'kill -s HUP $$'`.
Some shells instead report signal 1. This is a suite portability assumption, not an SDK failure.
Set `TMPDIR` to approved local scratch before execution:

```sh
bash tools/fetch-deps.sh conformance
export TMPDIR="$ZLUA_SCRATCH_ROOT"
(cd consumer/conformance && zig build run --cache-dir "$ZIG_LOCAL_CACHE_DIR/conformance")
```

Use `zlua:test:conformance` for the equivalent devenv task.
[`src/run.sh`](consumer/conformance/src/run.sh) validates local scratch and retains each fresh suite directory and `conformance.log`.
It supplies nonseekable EOF input, clears Lua environment variables, and selects the pinned CLI through a `bin/lua` symlink.
Test-only hooks keep temporary streams in suite scratch without changes to the production SDK or official suite files.
`LUA_READLINELIB=''` selects the redirected-input fallback. Official loader cases override it to test loader errors.

The official `ltests.h` disables `lua_number2strx` to force Lua's fallback in the `T` profile.
That fallback intentionally excludes `%a` precision modifiers. The runner reports and accepts only this known official diagnostic.
It rejects other coverage diagnostics, missing `T`, and locale, file, or library skips.
The unchanged production SDK passed a separate C probe: `string.format('%.3a', 0.5)` returned `0x1.000p-1`.

The full suite sends Ctrl-C and self-SIGKILL to its own test children.
Get a policy exception before execution if your environment prohibits those signals.

### Native libffi integration

[`consumer/libffi`](consumer/libffi) pins the Zig integration on [Codeberg](https://codeberg.org/CoffeeImpliesCode/libffi), not the GitHub upstream mirror.
The revision is `58673112b522a80232071653a8d0173d2fdcf7e3` (libffi 3.8.0).
This is tag `v3.8.0-1`, not the older unsuffixed `v3.8.0` tag.
It is a test-consumer dependency, not a dependency of the public `zlua` module.

**Known Zig 0.17 blocker:** this immutable libffi SDK pin does not build unchanged.
Its `build.zig:26` passes string paths to `Fmt.Options.paths`, which now expects
`Build.LazyPath` (`error: expected type 'Build.LazyPath', found '*const [9:0]u8'`).
After adapting those paths, `build.zig:262` fails with
`error: operator > not allowed for type '?u16'`: C ABI byte/bit sizes are now optional.
The binding's C ABI size selectors also need optional-value handling.
The Lua/LuaJIT module, package tests, and smoke consumer do not depend on libffi.
Native and wasm libffi consumers were proved with a scratch-only local port;
the libffi fork was deliberately not pushed or repinned. The published libffi
consumer and CI jobs that include it remain blocked until that SDK is ported.

```sh
bash tools/fetch-deps.sh integration
for backend in lua luajit; do
    (cd consumer/libffi && zig build test run -Dbackend="$backend")
done
```

[`scenario.lua`](consumer/libffi/src/scenario.lua) calls C functions through libffi with mixed integer/double arguments and executable closures.
Plain Lua callbacks work without LuaJIT's built-in FFI.
[`luajit-roundtrip.lua`](consumer/libffi/src/luajit-roundtrip.lua) calls actual C and callback pointers with context.
It tests built-in FFI callbacks through Zig and `ffi_call`, and built-in FFI → libffi closure → protected Lua calls.
Callbacks remain rooted across garbage collection. The consumer applies targeted `jit.off` and frees callbacks after their final use.
Caught Lua errors leave no stack leak.
Direct FFI checks `-27021597764222981` without Lua `f64` rounding.
The closure, CIF, argument types, and userdata remain live until Lua closes.
Use `zlua:test:libffi` for the equivalent devenv task.

### Emscripten wasm integration

[`consumer/wasm`](consumer/wasm) builds the pinned Lua SDK and a Zig consumer for `wasm32-emscripten`.
It uses skript's static-archive and external-emcc approach, without copied Lua sources or vendored zemscripten.
Node executes the JavaScript and wasm. This does not establish browser support.

With Emscripten and Node on `PATH`, first prepare the approved local cache:

```sh
source tools/setup-env.sh
zlua_setup "$PWD"
embuilder build libc
(cd consumer/wasm && zig build run -Demscripten-sysroot="$EM_CACHE/sysroot")
(cd consumer/wasm && zig build run -Demscripten-sysroot="$EM_CACHE/sysroot" -Doptimize=ReleaseSafe)
(cd consumer/libffi && zig build test run -Dtarget=wasm32-emscripten -Demscripten-sysroot="$EM_CACHE/sysroot")
(cd consumer/libffi && zig build test run -Dtarget=wasm32-emscripten -Demscripten-sysroot="$EM_CACHE/sysroot" -Doptimize=ReleaseSafe)
```

Use `zlua:test:wasm` to run both consumers with the equivalent devenv task.
The consumer needs the installed sysroot from the same Emscripten cache used by `emcc`.
`-Demcc` and `-Dnode` override the executables.
Keep `EM_CACHE` and temporary paths on approved local storage. Emscripten's default cache can use `/tmp`.
When a wrapper removes environment variables, set them inside its shell.

The wasm program checks tables, sorting, loops, libraries, binary strings, Zig callbacks, protected errors, stack prefixes, results, and recovery.
Lua's C objects use wasm exception handling and SjLj. The emcc link needs `-sSUPPORT_LONGJMP=wasm` for precompiled Zig C objects.
The consumer uses the stock Zig 0.17 standard library, which fixes the earlier `STOPSIG` return type.
Debug uses emcc `-g2` names to avoid Binaryen's unsupported DWARF metadata.
Debug and ReleaseSafe retain UBSan, Emscripten assertions, and stack-overflow checks.

The libffi consumer uses static Lua and a private adapter for upstream libffi's C wasm implementation.
This does not establish SDK-level wasm support.
The adapter excludes the deprecated Java Raw API but retains ordinary raw calls, `ffi_call`, and closures.
Exact eight-byte argument storage and Emscripten's wasm BigInt support preserve 64-bit results on wasm32.
The consumer excludes WASI, wasm64, freestanding wasm, and LuaJIT wasm.

For a foreign target, use `check` rather than an execution step:

```sh
zig build check -Dbackend=lua -Dtarget=aarch64-linux-musl
(cd consumer/smoke && zig build check -Dbackend=luajit -Dtarget=x86_64-windows-gnu)
```

A cross-build does not prove runtime execution. Execution needs the target host or a real executor.
The optional host `cross-test` harness uses `cross-test.profile.sh`.
Run it separately with `cross-test -- -Dbackend=lua` and `cross-test -- -Dbackend=luajit`.
Missing executors remain partial or `build_only` coverage, not runtime passes.

WASI is unsupported for both backends. LuaJIT rejects wasm32, wasm64, and riscv64.
Other target behavior depends on the selected upstream SDK. This package does not promise every platform.

### CI declaration and private access

[The workflow](.github/workflows/ci.yml) declares these checks with Zig 0.17.0:

| Job | Declared configurations | Scope |
| --- | ---: | --- |
| Native | 48 | Linux, macOS, Windows × two backends × four optimization modes × two linkage modes. Execute tests, smoke, and both native consumers. |
| Cross | 36 | Eight targets × two backends × Debug/ReleaseSafe, plus four Lua-only riscv64 entries. Compile native consumers and tests only, static linkage. |
| Unsupported | 7 | Reject WASI on both backends, riscv64 on LuaJIT, and four LuaJIT wasm target combinations. |
| Wasm | 2 | Execute both Lua and Lua/libffi Emscripten consumers with Emscripten 6.0.9 and Node in Debug/ReleaseSafe. |
| Conformance | 8 | Execute the official Lua 5.5.1 suite on Linux × four optimization modes × two linkage modes. |

Cross targets cover x86_64 Linux glibc (including 2.28) and musl, aarch64 Linux glibc and musl, Windows x86_64, and macOS x86_64/aarch64.
Lua-only riscv64 entries cover Linux glibc and musl.
These counts describe workflow configuration, not completed runs or verified platform support.

Local Zig 0.17.0 checks on Linux x86_64 glibc 2.39:

- Package `check test smoke` and dependency consumer `check run`: both backends, Debug and ReleaseSafe, static and dynamic linkage (eight configurations, 18 package tests in each).
- The final package/consumer matrix used the pushed SDK commits and isolated package/global caches initialized empty, with no local-fork overrides: all 16 commands succeeded after authenticated archive priming and hash verification.
- Official conformance `check run`: four optimization/linkage configurations, each exiting zero with `final OK !!!`; Debian bookworm Dash 0.5.12-2 was isolated as `/bin/sh`, without modifying the host or suite. Only the documented official `%a` fallback omission was accepted.
- Node: both wasm consumers ran in Debug and ReleaseSafe using Emscripten 6.0.9 and Node 24.21.0. The libffi consumer used the scratch-only port described above.
- Native libffi `check test run`: both backends, Debug and ReleaseSafe, both linkages, with that scratch-only port.
- Lua SDK: 20 tests per mode; LuaJIT SDK: 29 per mode, native CLI self-checks and installed-header assertions. Both SDKs also passed explicit-provider runtime-loaded tests, smoke and separate consumers in both modes. Upstream source-integrity checks passed.

These are local results, not GitHub Actions, browser, foreign-platform, or Nix derivation verification.

Historical local checks with Zig 0.16.0 (not Zig 0.17 verification):

- Native libffi: 16 Linux x86_64 configurations, covering both backends, four optimization modes, and both linkage modes.
- Conformance: eight optimization/linkage configurations and the devenv task passed with isolated Debian bookworm Dash 0.5.12-2.
  Each suite run exited zero with `final OK !!!` and only the known `%a` modifier omission.
- Node: four runs, covering both wasm consumers in Debug and ReleaseSafe.
- QEMU: three musl runs, covering Lua and LuaJIT on AArch64, and Lua on riscv64.
- Cross-builds: 36 configurations compiled. These do not establish foreign runtime execution.
- Negative guards: 21 checks passed.

Native Windows/macOS, browser execution, and GitHub Actions remain unverified, including the declared Ubuntu conformance job.

CI requires a read-only `ZLUA_DEPENDENCIES_TOKEN` secret with contents access to **both** private runtime source repositories.
The default GitHub Actions token does not grant that cross-repository access.
The workflow fails with an explicit diagnostic when the secret is absent.
Fork pull requests cannot access the secret and therefore fail this prerequisite. The workflow does not silently skip private dependencies.

## License

No project license has been chosen for `zlua`. This repository does not grant a project license.
Lua and LuaJIT retain their upstream license terms in their dependency repositories.
The official Lua test suite uses the [Lua MIT license](https://www.lua.org/license.html).
Review those terms separately before distribution.
