#!/usr/bin/env bash
set -euo pipefail

caller_global_cache=${ZIG_GLOBAL_CACHE_DIR-}
caller_local_cache=${ZIG_LOCAL_CACHE_DIR-}
caller_package_directory=${ZIG_LOCAL_PKG_DIR-}
[[ -z "$caller_global_cache" ]] || export ZIG_GLOBAL_CACHE_DIR="$caller_global_cache"
[[ -z "$caller_local_cache" ]] || export ZIG_LOCAL_CACHE_DIR="$caller_local_cache"
[[ -z "$caller_package_directory" ]] || export ZIG_LOCAL_PKG_DIR="$caller_package_directory"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
backend=${1:-all}
case "$backend" in lua|luajit|all|integration|conformance) ;; *) echo 'usage: bash tools/fetch-deps.sh [lua|luajit|all|integration|conformance]' >&2; exit 2 ;; esac
scratch_root=${ZLUA_SCRATCH_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}
case "$scratch_root" in /*) ;; *) echo 'Scratch root must be an absolute path.' >&2; exit 1 ;; esac
if [[ ! -d "$scratch_root" || ! -w "$scratch_root" ]]; then
    echo 'Scratch root must be an existing writable directory.' >&2
    exit 1
fi
scratch_root=$(cd -- "$scratch_root" && pwd -P)
if [[ -O "$scratch_root" ]]; then
    scratch=$scratch_root
else
    [[ -k "$scratch_root" ]] || { echo 'Shared scratch root must have the sticky bit set.' >&2; exit 1; }
    scratch=$(mktemp -d "$scratch_root/zlua-scratch.XXXXXXXX")
fi
if [[ ! -d "$scratch" || ! -O "$scratch" || -L "$scratch" ]]; then
    echo 'Scratch must be a real directory owned by the current user.' >&2
    exit 1
fi
scratch=$(cd -- "$scratch" && pwd -P)
local_directory() {
    local directory=$1 filesystem physical
    if [[ ! -d "$directory" || ! -O "$directory" ]]; then
        echo "Unsafe directory: $directory" >&2; exit 1
    fi
    physical=$(cd -- "$directory" && pwd -P)
    case "$physical" in
        "$root"|"$root/"*) echo "Prohibited scratch/cache location: $physical" >&2; exit 1 ;;
    esac
    case "$(uname -s)" in
        Linux) filesystem=$(stat -f -c %T -- "$physical") ;;
        Darwin) filesystem=$(/usr/bin/stat -f %T "$physical") ;;
        *) echo "Cannot verify local filesystem on $(uname -s): $physical" >&2; exit 1 ;;
    esac
    case "$filesystem" in
        ext2/ext3|ext4|ext3|ext2|xfs|btrfs|zfs|f2fs|apfs|hfs|tmpfs) ;;
        *) echo "Unapproved or remote filesystem ($filesystem): $physical" >&2; exit 1 ;;
    esac
}
prepare_directory() {
    local directory=$1 ancestor=$1 component
    local missing=()
    case "$directory" in /*) ;; *) echo "Directory must be absolute: $directory" >&2; exit 1 ;; esac
    while [[ ! -e "$ancestor" ]]; do
        [[ ! -L "$ancestor" ]] || { echo "Dangling directory symlink: $ancestor" >&2; exit 1; }
        missing+=("${ancestor##*/}")
        ancestor=${ancestor%/*}
        [[ -n "$ancestor" ]] || ancestor=/
    done
    [[ ! -L "$ancestor" ]] || { echo "Symlinked cache ancestor: $ancestor" >&2; exit 1; }
    local_directory "$ancestor"
    while [[ ${#missing[@]} -gt 0 ]]; do
        component=${missing[${#missing[@]}-1]}
        unset "missing[$((${#missing[@]} - 1))]"
        case "$component" in ''|.|..) echo 'Unsafe cache path component.' >&2; exit 1 ;; esac
        ancestor="$ancestor/$component"
        mkdir -- "$ancestor"
        local_directory "$ancestor"
    done
    local_directory "$directory"
}
local_directory "$scratch"
command -v zig >/dev/null || { echo 'Zig 0.17.0 is required.' >&2; exit 1; }
work=$(mktemp -d "$scratch/zlua-fetch.XXXXXXXX")
# Failure diagnostics are retained. Success cleanup touches only regular files
# created in this private work directory, never recursive trees or shared caches.
umask 077
export TMPDIR="$work" TMP="$work" TEMP="$work"
export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$scratch/zlua-zig-global}
export ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-$scratch/zlua-zig-local}
for directory in "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"; do
    prepare_directory "$directory"
done
# Zig 0.17 selects the package cache through its environment, not checkout links.
package_directory=${ZIG_LOCAL_PKG_DIR:-${ZLUA_CACHE_ROOT:+$ZLUA_CACHE_ROOT/pkg}}
package_directory=${package_directory:-$scratch/zlua-zig-pkg}
prepare_directory "$package_directory"
export ZIG_LOCAL_PKG_DIR="$package_directory"
# Stock fetch only unpacks to the local package directory with --save. Keep its
# manifest edits in private scratch; the repository's git URLs stay unchanged.
cp -- "$root/build.zig" "$root/build.zig.zon" "$work/"
fetch_package() {
    (cd -- "$work" && zig fetch "--save-exact=$1" --pkg-dir "$package_directory" "$2") || return
    local name_pattern="^[[:space:]]*[.]$1[[:space:]]*=[[:space:]]*[.][{]"
    local selected=0 line
    while IFS= read -r line; do
        if [[ "$line" =~ $name_pattern ]]; then
            selected=1
        elif [[ "$selected" == 1 && "$line" =~ $hash_pattern ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return
        fi
    done < "$work/build.zig.zon"
    echo "Saved dependency hash missing for $1." >&2
    return 1
}
url_pattern='^[[:space:]]*\.url[[:space:]]*=[[:space:]]*"(git\+https://github\.com/CoffeeImpliesCode/(lua|luajit)(\?ref=[^"#]+)?#[0-9a-f]{40})",[[:space:]]*$'
hash_pattern='^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"([^"]+)",[[:space:]]*$'
url='' count=0
while IFS= read -r line; do
    if [[ "$line" =~ $url_pattern ]]; then
        [[ -z "$url" ]] || { echo 'Manifest URL without following hash.' >&2; exit 1; }
        url=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[2]}
    elif [[ "$line" =~ $hash_pattern && -n "$url" ]]; then
        expected=${BASH_REMATCH[1]}
        if [[ "$backend" == all || "$backend" == integration || "$backend" == "$name" || ( "$backend" == conformance && "$name" == lua ) ]]; then
            echo "Fetching $name at $url" >&2
            actual=$(fetch_package "$name" "$url")
            if [[ "$actual" != "$expected" ]]; then
                printf 'Dependency hash mismatch for %s: expected %s, received %s\n' "$name" "$expected" "$actual" >&2
                exit 1
            fi
            count=$((count + 1))
        fi
        url=''
    fi
done < "$root/build.zig.zon"
expected_count=1
[[ "$backend" != all && "$backend" != integration ]] || expected_count=2
if [[ "$count" -ne "$expected_count" || -n "$url" ]]; then
    echo 'Manifest must contain immutable git+https GitHub URL/hash pairs for requested dependencies.' >&2
    exit 1
fi
if [[ "$backend" == integration ]]; then
    ffi_manifest="$root/consumer/libffi/build.zig.zon"
    ffi_url='' ffi_hash=''
    ffi_url_pattern='^[[:space:]]*\.url[[:space:]]*=[[:space:]]*"(git\+https://codeberg\.org/CoffeeImpliesCode/libffi[^"]*#[0-9a-f]{40})",[[:space:]]*$'
    while IFS= read -r line; do
        if [[ "$line" =~ $ffi_url_pattern ]]; then
            ffi_url=${BASH_REMATCH[1]}
        elif [[ "$line" =~ $hash_pattern && -n "$ffi_url" ]]; then
            ffi_hash=${BASH_REMATCH[1]}
        fi
    done < "$ffi_manifest"
    [[ -n "$ffi_url" && -n "$ffi_hash" ]] || { echo 'Missing immutable libffi URL/hash pair.' >&2; exit 1; }
    actual=$(fetch_package libffi "$ffi_url")
    [[ "$actual" == "$ffi_hash" ]] || { echo "Dependency hash mismatch for libffi: expected=$ffi_hash actual=$actual" >&2; exit 1; }
    count=$((count + 1))
fi
if [[ "$backend" == integration || "$backend" == conformance ]]; then
    suite_manifest="$root/consumer/conformance/build.zig.zon"
    suite_url='' suite_hash=''
    suite_url_pattern='^[[:space:]]*\.url[[:space:]]*=[[:space:]]*"(https://www\.lua\.org/tests/lua-[0-9.]+-tests\.tar\.gz)",[[:space:]]*$'
    while IFS= read -r line; do
        if [[ "$line" =~ $suite_url_pattern ]]; then
            suite_url=${BASH_REMATCH[1]}
        elif [[ "$line" =~ $hash_pattern && -n "$suite_url" ]]; then
            suite_hash=${BASH_REMATCH[1]}
        fi
    done < "$suite_manifest"
    [[ -n "$suite_url" && -n "$suite_hash" ]] || { echo 'Missing pinned official Lua test-suite URL/hash pair.' >&2; exit 1; }
    actual=$(fetch_package lua_tests "$suite_url")
    [[ "$actual" == "$suite_hash" ]] || { echo "Dependency hash mismatch for Lua tests: expected=$suite_hash actual=$actual" >&2; exit 1; }
    count=$((count + 1))
fi
for file in "$work/build.zig" "$work/build.zig.zon"; do
    [[ -e "$file" ]] || continue
    if [[ -f "$file" && -O "$file" && ! -L "$file" ]] && command -v lsof >/dev/null && ! lsof -- "$file" >/dev/null 2>&1; then
        if ! command -v mountpoint >/dev/null || ! mountpoint -q -- "$file"; then
            unlink -- "$file"
        fi
    else
        printf 'Retaining diagnostic file; cleanup safety could not be established: %s\n' "$file" >&2
    fi
done
if [[ -d "$work" && -O "$work" && ! -L "$work" ]]; then
    rmdir -- "$work" 2>/dev/null || true
fi
printf 'Verified %s immutable dependency package(s); cache=%s\n' "$count" "$ZIG_GLOBAL_CACHE_DIR"
printf 'For subsequent builds use: export ZIG_GLOBAL_CACHE_DIR=%q ZIG_LOCAL_CACHE_DIR=%q ZIG_LOCAL_PKG_DIR=%q\n' "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_LOCAL_PKG_DIR"
