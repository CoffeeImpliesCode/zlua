# Changelog

## Unreleased

### Changed

- Require Zig 0.17.0 in package manifests, build graphs, and CI. The development shell checks the compiler on PATH.
- Pin the public Lua v5.5.1 and LuaJIT v2.1.1788856981 SDK releases without changing the common State API.
- Update the optional libffi consumer to the Zig 0.17 SDK port.
- Use `ZIG_LOCAL_PKG_DIR` for packages and a scratch manifest for optional cache priming.
- Remove private dependency authentication from CI and dependency acquisition.

### Added

- Build-selected Lua or LuaJIT runtime with static or dynamic linkage.
- Common `State` operations for lifetime, stacks, text compilation, protected calls, globals, callbacks, and scalar values.
- Selected SDK and C bindings through `native` and `c`, plus compile-time `backend` identity.
- Text-only loading, retained error objects, binary-safe strings, and a common `f64` numeric interface.
- Package tests, smoke program, standalone consumer, official Lua conformance consumer, and Emscripten/Node consumer.
- Optional libffi call and closure consumer, including LuaJIT built-in FFI roundtrips and exact signed 64-bit results.
- CI declarations for native Linux, macOS, Windows, cross-compilation, and unsupported-target checks.

### Fixed

- Keep parsing and LuaJIT result transfer inside protected calls so allocation failures do not escape through Zig frames.

### Known limitations

- No project license has been chosen. Dependencies retain their upstream terms.
