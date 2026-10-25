# zlua

Experimental Zig wrapper for Lua and LuaJIT with one build-selected runtime and a common `State` API.
`zlua.native` exposes the selected SDK. `zlua.c` exposes its C bindings.
The SDK supplies the native library. Do not link a second copy.

## Requirements

Use Zig **0.17.0**. Dependencies are public and pinned by revision and package hash:

| Backend | Source | Runtime |
| --- | --- | --- |
| `lua` (default) | [CoffeeImpliesCode/lua v5.5.1](https://github.com/CoffeeImpliesCode/lua/tree/v5.5.1) | Lua 5.5.1 |
| `luajit` | [CoffeeImpliesCode/luajit v2.1.1788856981](https://github.com/CoffeeImpliesCode/luajit/tree/v2.1.1788856981) | LuaJIT 2.1.1788856981 |

Zig fetches the selected runtime during the build. No private dependency token is required.
`-Dbackend=lua|luajit` selects the runtime. `-Dlinkage=static|dynamic` selects linkage (default: static).
Standard `-Dtarget` and `-Doptimize` options are available.
WASI is unsupported. LuaJIT also rejects riscv64 and WebAssembly. Other target support depends on the selected SDK.

## Build and test

```sh
zig build
for backend in lua luajit; do
    zig build test smoke -Dbackend="$backend"
    (cd consumer/smoke && zig build check run -Dbackend="$backend")
done
```

The default build runs `check`, which compiles tests and the smoke program without execution.
`test` runs shared and backend-specific runtime tests. `smoke` runs the package example.
`consumer/smoke` checks the dependency import and native links.
Add `-Doptimize=ReleaseSafe` or `-Dlinkage=dynamic` to test other configurations.
For foreign targets, use `check` rather than an execution step:

```sh
zig build check -Dbackend=lua -Dtarget=aarch64-linux-musl
```

The optional devenv shell supplies Emscripten, Node, readline, and locales. It requires Zig 0.17.0 on `PATH`.
`.envrc` prepares external caches. For direct shell entry:

```sh
source tools/setup-env.sh
zlua_capture_caller
zlua_setup "$PWD"
devenv "${zlua_devenv_options[@]}" shell
```

Set `ZLUA_CACHE_ROOT` on local storage when the host does not supply cache settings.
The optional `tools/fetch-deps.sh [lua|luajit|all|conformance|integration]` primes packages and checks manifest hashes.
It selects scratch storage from `ZLUA_SCRATCH_ROOT`, then `RUNNER_TEMP`, then `TMPDIR` or `/tmp`.
The selected root must be an existing, absolute, writable local directory outside the checkout; the helper creates a private directory when needed.
Use its printed cache exports for subsequent builds. Normal Zig builds do not need this helper.

## Add the module

Place or symlink the checkout at `zlua` inside your consumer project.
Zig 0.17 rejects path dependencies outside the package root.
In `build.zig.zon`:

```zig
.dependencies = .{
    .zlua = .{ .path = "zlua" },
},
```

In the consumer's `build.zig`, pass its target and optimization mode:

```zig
const dependency = b.dependency("zlua", .{
    .target = target,
    .optimize = optimize,
    .backend = .lua,
    .linkage = .static,
});
executable.root_module.addImport("zlua", dependency.module("zlua"));
```

See [`consumer/smoke/build.zig`](consumer/smoke/build.zig) for a complete build.

```zig
const zlua = @import("zlua");

pub fn main() !void {
    var state = try zlua.State.init();
    defer state.deinit();
    try state.run("return 6 * 7", "=example", 1);
    const answer = state.toNumber(-1) orelse return error.ExpectedNumber;
    if (answer != 42) return error.UnexpectedResult;
    state.pop(1);
}
```

## State ownership and errors

- `init` creates a state without libraries. `initWithLibraries` opens all standard libraries. Both can return `error.OutOfMemory`.
- One `State` owns one runtime state. Copies borrow that state. Never close a copy or replace or separately close `sdk`.
- Repeated `deinit` on the same variable is safe. After close, only `isOpen` and `deinit` remain valid.
- Serialize access to a state. Callbacks borrow the active state on the calling thread and must not close it.
- `load` accepts text only. It leaves a function on success or an error object on failure.
- `protectedCall` consumes the function and its arguments, then leaves results or one error object.
- `run` loads and calls without arguments. Earlier stack values remain. `load` and `run` need three free stack slots.
- `nresults = null` keeps all results. A fixed count truncates results or adds nil values.
- Protected errors are `SyntaxError`, `MemoryError`, `RuntimeError`, `ErrorInErrorHandler`, or `UnexpectedStatus`.
- Inspect the error object before removing it. Errors can contain non-string values.
- `toBytes` borrows actual strings, including NUL bytes. Keep the string rooted in an open state until use ends or you copy it.
- `pushBytes` copies bytes. `toNumber` accepts numbers and numeric strings, or returns `null`.
- Common numbers use `f64`. Use the native API for backend-specific exact integers.
- Use `checkStack` before operations that need more capacity. Stack counts must fit `c_int`.
- `pop(count)` requires `count <= top()`. `setTop(count)` uses an absolute count and needs capacity when it grows.

Standard libraries expose host I/O. This API is **not a sandbox**.
Lua and LuaJIT differ in source language and bytecode. Binary chunks are rejected.
Operations outside protected compilation and calls can raise unprotected Lua errors or allocation panics.
Do not let Lua `longjmp` cross Zig frames that need `defer` or `errdefer` cleanup.

## Additional consumers

- [`consumer/conformance`](consumer/conformance) runs the pinned official Lua 5.5.1 suite with `T`/`ltests` and five C fixtures.
  It requires Linux, Bash, ELF shared libraries, readline and the `pt_BR` ISO-8859-1 locale.
  Scratch selection is `ZLUA_SCRATCH_ROOT`, then `RUNNER_TEMP`, then `TMPDIR` or `/tmp`; the runner retains its fresh suite directory there.
  Run `zig build check` or `zig build run` in that directory. LuaJIT cannot run this suite.
  The signal test requires `/bin/sh` to report a nested shell's HUP termination as a nonzero exit, not a signal.
  The suite sends Ctrl-C and SIGKILL to its own children. The runner retains its suite directory and `conformance.log`.
  It accepts only the official `T` profile's known `%a` precision-modifier omission. Other skips and coverage diagnostics fail.
- [`consumer/wasm`](consumer/wasm) runs Lua with Emscripten and Node. Put `emcc`, `embuilder`, and `node` on `PATH`.
  Run `embuilder build libc`, then `zig build run -Demscripten-sysroot="$EM_CACHE/sysroot"` in that directory.
  Use the same Emscripten cache for compilation and linking. `-Demcc` and `-Dnode` override executables.
  This consumer uses wasm exception handling and SjLj. It does not establish browser support.
- [`consumer/libffi`](consumer/libffi) tests calls and closures through the [Codeberg libffi SDK](https://codeberg.org/CoffeeImpliesCode/libffi).
  Run `zig build check test run -Dbackend=lua` or `-Dbackend=luajit` in that directory.
  Its wasm adapter supports static Lua with `-Dtarget=wasm32-emscripten -Demscripten-sysroot="$EM_CACHE/sysroot"`.
  Core zlua and the other consumers do not depend on libffi.

## License

MIT, see [LICENSE](LICENSE); separately fetched Lua 5.5.1, LuaJIT, and conformance-suite materials retain their upstream terms.
