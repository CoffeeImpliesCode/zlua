#!/usr/bin/env bash
# Run a fresh copy: the official tests write files and invoke their interpreter.
set -eu
: "${TMPDIR:?Set TMPDIR to approved local scratch before running conformance}"
zlua_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
source "$zlua_root/tools/setup-env.sh"
zlua_host=$(hostname -s 2>/dev/null || uname -n)
zlua_system=$(uname -s)
zlua_user=${HOST_SCRATCH_USER:-${USER:-}}
if [ -z "$zlua_user" ]; then zlua_user=$(id -un 2>/dev/null || id -u); fi
# Use the shared locality/ownership/checkout policy without global setup changes.
zlua_local_directory "$TMPDIR"
TMPDIR=$(zlua_resolve_directory "$TMPDIR")
[ "$#" -eq 3 ] || { echo 'usage: run.sh WRAPPER SUITE CLI' >&2; exit 1; }
wrapper=$1
suite=$2
cli=$(realpath -- "$3")
[ -x "$wrapper" ] && [ -x "$cli" ] || { echo 'conformance: wrapper or pinned CLI missing' >&2; exit 1; }
for name in lib1 lib11 lib2 lib21 lib2-v2; do
    [ -f "$suite/libs/$name.so" ] || { echo "conformance: missing $name.so" >&2; exit 1; }
done
work=$(mktemp -d "$TMPDIR/zlua-conformance.XXXXXXXX")
[ -d "$work" ] && [ ! -L "$work" ] &&
    [ "$(stat -c %u "$work")" = "$(id -u)" ] ||
    { echo "conformance: scratch work is not a real caller-owned directory: $work" >&2; exit 1; }
# Preserve suite files and logs as run evidence; cleanup belongs to the caller's
# storage policy, which can check ownership, mounts, and live process references.
trap 'echo "conformance: retained run evidence at $work" >&2' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R "$suite/." "$work/"
cd "$work"
# The relative Lua temporary-name template is safe only from this fresh workdir.
[ "$(pwd -P)" = "$work" ] ||
    { echo 'conformance: scratch working-directory mismatch' >&2; exit 1; }
# Zig package hashing/staging omits this empty directory from the official tar.
# attrib.lua populates it to test package paths; no suite files are modified.
mkdir -p libs/P1
# Both ARG-based and literal "lua" subprocesses resolve to the exact pinned CLI.
# Keep the original binary in place so its runtime search paths remain intact.
mkdir bin
ln -s -- "$cli" bin/lua
export PATH="$work/bin:$PATH"
unset LUA_INIT LUA_INIT_5_5 LUA_PATH LUA_PATH_5_5 LUA_CPATH LUA_CPATH_5_5 BASH_ENV ENV
# Use Lua's documented fgets fallback for redirected interactive input. The
# official readline-loader tests still set their own LUA_READLINELIB values.
export LUA_READLINELIB=
status=0
: | "$wrapper" ./bin/lua >conformance.log 2>&1 || status=$?
cat conformance.log
[ "$status" -eq 0 ] || { echo "conformance: wrapper exited $status" >&2; exit "$status"; }
grep -F -x 'final OK !!!' conformance.log >/dev/null || { echo 'conformance: missing final success marker' >&2; exit 1; }
# Official ltests.h deliberately undefines lua_number2strx to exercise Lua's
# own fallback, which omits %a modifiers. Accept only that pinned capability
# diagnostic; leave it and any official warning summary visible in the log.
capability=" >>> modifiers for format '%a' not available <<<"
if grep -E 'testC not active|skipping|tests skipped|cannot load dynamic library' conformance.log >/dev/null; then
    echo 'conformance: official tests reported skipped coverage' >&2
    exit 1
fi
# Message diagnostics start with whitespace before >>>. The ordinary GC
# lifecycle print ">>> closing state <<<" is not a Message diagnostic.
if grep -E '^[[:space:]]+>>>.*<<<[[:space:]]*$' conformance.log |
    grep -F -x -v "$capability" >/dev/null; then
    echo 'conformance: unrecognized official capability diagnostic' >&2
    exit 1
fi
if grep -F -x "$capability" conformance.log >/dev/null; then
    echo "conformance: official T fallback omits %a modifier assertions (reported above)" >&2
fi
