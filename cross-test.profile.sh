# Shared runtime suite through the sibling cross-test harness.
# Run twice: cross-test -- -Dbackend=lua and
# cross-test -- -Dbackend=luajit.
# The default backend is Lua; one run never represents both backends.
# Native targets execute. Foreign targets execute only when cross-test finds
# a real executor; missing executors must remain partial/build_only, not pass.
# CI separately compiles Lua riscv64 glibc/musl and verifies explicit rejection
# of WASI on both backends and riscv64 on LuaJIT. Unsupported-target rejection
# is not execution coverage and is deliberately not mixed into this matrix.
CROSS_MATRIX=(
    'x86_64-linux-gnu|auto'
    'aarch64-linux-gnu|auto'
    'x86_64-linux-musl|auto'
    'aarch64-linux-musl|auto'
    'x86_64-windows-gnu|auto'
    'x86_64-macos|auto'
    'aarch64-macos|auto'
)
CROSS_BUILD_STEP=test
CROSS_BUILD_ARGS=(-fqemu)
CROSS_REQUIRE_RUNNERS=0
CROSS_JOBS=2
CROSS_BUILD_JOBS=4
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800
