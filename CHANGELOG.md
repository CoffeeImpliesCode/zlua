# Changelog

## Unreleased

### Added

- Zig 0.16.0 package with one build-selected Lua or LuaJIT runtime.
- Immutable private source pins for Lua 5.5.1 and LuaJIT 2.1.1788856981.
- Common `State` operations for state lifetime, stacks, text compilation, protected calls, globals, callbacks, and scalar values.
- Selected upstream SDK through `native`, its C bindings through `c`, and compile-time backend identity through `backend`.
- Text-only chunk loading, retained error objects, binary-safe strings, and a common `f64` numeric interface.
- `backend` and `linkage` build options with Lua and static linkage as defaults.
- Compile-only `check`, executable integration tests, package smoke, and a separate dependency consumer.
- Explicit unsupported-target diagnostics for WASI on both backends and riscv64 on LuaJIT.
- GitHub CLI archive acquisition with dependency hash checks and local cache priming.
- Devenv tools and local cache setup without automatic SDK builds or source downloads.
- CI declarations for native Linux, macOS, and Windows configurations, cross-builds, and unsupported-target checks.
- Required read-only private dependency access through the `ZLUA_DEPENDENCIES_TOKEN` CI secret.
- Immutable third-party CI action pins for jobs that can access private dependency sources.
- Lua Emscripten runtime consumer with Node execution and protected-error recovery checks.
- Explicit LuaJIT wasm32/wasm64 rejection before dependency resolution.
- Codeberg libffi 3.8.0 consumer pinned to tag `v3.8.0-1`, not the older `v3.8.0` tag.
- Native Lua callbacks and LuaJIT built-in FFI roundtrips through Zig, `ffi_call`, and protected libffi closures.
- C and callback pointers, context arguments, nested callbacks, GC roots, explicit callback frees, and caught-error stack checks.
- Exact signed 64-bit FFI results without Lua `f64` rounding.
- Lua/libffi Node consumer for static `wasm32-emscripten`, with exact integer storage and wasm BigInt support.
- Private adapter for upstream libffi's C wasm backend, without SDK-level wasm support or the deprecated Java Raw API.
- [Official Lua 5.5.1 conformance consumer](consumer/conformance) with pinned `T`/`ltests` instrumentation, five C fixtures, and the same pinned child CLI.
- Normal `all.lua` execution without `_U`, `_soft`, `_port`, or `_nomsg` restrictions, separate from handwritten integration tests.
- Conformance locale and readline setup, isolated input and Lua environment, and retained logs in approved scratch.
- Test-only temporary-file hooks without production SDK changes.
- Explicit reporting of the official `T` profile's intentional `%a` precision-modifier omission. Other coverage diagnostics remain errors.
- Separate production SDK C probe for `string.format('%.3a', 0.5)`.
- `fetch-deps.sh integration` and `conformance` cache priming, plus `zlua:test:conformance` and combined `zlua:test:wasm` tasks.
- Declared conformance CI configurations and the official suite's Lua MIT license, without a new project license.

### Fixed

- Keep parsing and the LuaJIT result handoff inside protected runtime calls so allocation failures do not escape through Zig frames.

See [README.md](README.md) for observed checks, runtime boundaries, and unverified platforms.
No project license has been chosen. Dependencies retain their upstream terms.
