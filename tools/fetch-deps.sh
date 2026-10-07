#!/usr/bin/env bash
set -euo pipefail

# Private GitHub sources are downloaded through gh; Zig 0.16 does not fetch
# SSH URLs or use Git credential helpers for its native HTTPS fetcher.
caller_global_cache=${ZIG_GLOBAL_CACHE_DIR-}
caller_local_cache=${ZIG_LOCAL_CACHE_DIR-}
if [[ -f "$HOME/.local/lib/host-scratch.sh" ]]; then
    source "$HOME/.local/lib/host-scratch.sh"
fi
[[ -z "$caller_global_cache" ]] || export ZIG_GLOBAL_CACHE_DIR="$caller_global_cache"
[[ -z "$caller_local_cache" ]] || export ZIG_LOCAL_CACHE_DIR="$caller_local_cache"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
backend=${1:-all}
case "$backend" in lua|luajit|all|integration|conformance) ;; *) echo 'usage: bash tools/fetch-deps.sh [lua|luajit|all|integration|conformance]' >&2; exit 2 ;; esac
scratch=${ZLUA_SCRATCH_ROOT:-${buildhost_SCRATCH_ROOT:-${RUNNER_TEMP:-}}}
if [[ -z "$scratch" ]]; then
    echo 'Set ZLUA_SCRATCH_ROOT to an approved UID-owned local scratch directory (not /tmp, /var/tmp, or NFS).' >&2
    exit 1
fi

is_system_temp() {
    case "$1" in
        /tmp|/tmp/*|/var/tmp|/var/tmp/*|/private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*) return 0 ;;
        *) return 1 ;;
    esac
}
case "$scratch" in /*) ;; *) echo 'Scratch path must be absolute.' >&2; exit 1 ;; esac
if is_system_temp "$scratch"; then echo 'System temporary directories are prohibited.' >&2; exit 1; fi
if [[ ! -d "$scratch" || ! -O "$scratch" || -L "$scratch" ]]; then
    echo 'Scratch must already exist, be UID-owned, and not be a symlink.' >&2
    exit 1
fi
scratch=$(cd -- "$scratch" && pwd -P)
if is_system_temp "$scratch"; then echo 'Scratch resolves to a prohibited directory.' >&2; exit 1; fi
local_directory() {
    local directory=$1 filesystem physical
    if [[ ! -d "$directory" || ! -O "$directory" ]]; then
        echo "Unsafe directory: $directory" >&2; exit 1
    fi
    physical=$(cd -- "$directory" && pwd -P)
    case "$physical" in
        "$root"|"$root/"*) echo "Prohibited scratch/cache location: $physical" >&2; exit 1 ;;
    esac
    if is_system_temp "$physical"; then echo "Prohibited scratch/cache location: $physical" >&2; exit 1; fi
    case "$(hostname -s)" in
        buildhost*)
            [[ -n "${HOST_SCRATCH_ROOT:-}" ]] || { echo 'No approved buildhost scratch root.' >&2; exit 1; }
            case "$physical/" in
                "$HOST_SCRATCH_ROOT/"*) ;;
                *) echo "Path is outside approved per-user scratch root: $physical" >&2; exit 1 ;;
            esac ;;
    esac
    case "$(uname -s)" in
        Linux) filesystem=$(stat -f -c %T -- "$physical") ;;
        Darwin) filesystem=$(/usr/bin/stat -f %T "$physical") ;;
        *) echo "Cannot verify local filesystem on $(uname -s): $physical" >&2; exit 1 ;;
    esac
    case "$filesystem" in
        ext2/ext3|ext4|ext3|ext2|xfs|btrfs|zfs|f2fs|apfs|hfs) ;;
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
command -v gh >/dev/null || { echo 'GitHub CLI gh is required; authenticate with gh auth login or GH_TOKEN.' >&2; exit 1; }
command -v zig >/dev/null || { echo 'Zig 0.16.0 is required.' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'No authenticated GitHub identity; provide a read-only token authorized for both private dependency repositories.' >&2; exit 1; }
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
if [[ -e "$root/zig-pkg" || -L "$root/zig-pkg" ]]; then
    local_directory "$root/zig-pkg"
    package_directory=$(cd -- "$root/zig-pkg" && pwd -P)
else
    package_directory=${ZLUA_CACHE_ROOT:+$ZLUA_CACHE_ROOT/pkg}
    package_directory=${package_directory:-$scratch/zlua-zig-pkg}
    prepare_directory "$package_directory"
fi
for package_root in "$root" "$root/consumer/smoke" "$root/consumer/wasm" "$root/consumer/libffi" "$root/consumer/conformance"; do
    [[ -d "$package_root" ]] || continue
    [[ -d "$package_root" && -O "$package_root" ]] || { echo "Unsafe package root: $package_root" >&2; exit 1; }
    if [[ ! -e "$package_root/zig-pkg" && ! -L "$package_root/zig-pkg" ]]; then
        ln -s -- "$package_directory" "$package_root/zig-pkg"
    fi
    local_directory "$package_root/zig-pkg"
done
url_pattern='^[[:space:]]*\.url[[:space:]]*=[[:space:]]*"git\+https://github\.com/(CoffeeImpliesCode/(lua|luajit))\.git#([0-9a-f]{40})",[[:space:]]*$'
hash_pattern='^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"([^"]+)",[[:space:]]*$'
repository='' revision='' count=0
while IFS= read -r line; do
    if [[ "$line" =~ $url_pattern ]]; then
        [[ -z "$repository" ]] || { echo 'Manifest URL without following hash.' >&2; exit 1; }
        repository=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[2]}
        revision=${BASH_REMATCH[3]}
    elif [[ "$line" =~ $hash_pattern && -n "$repository" ]]; then
        expected=${BASH_REMATCH[1]}
        if [[ "$backend" == all || "$backend" == integration || "$backend" == "$name" || ( "$backend" == conformance && "$name" == lua ) ]]; then
            archive="$work/$name.tar.gz"
            echo "Fetching $repository at $revision" >&2
            gh api "repos/$repository/tarball/$revision" > "$archive"
            actual=$(cd -- "$root" && zig fetch "$archive")
            if [[ "$actual" != "$expected" ]]; then
                printf 'Dependency hash mismatch for %s: expected %s, received %s\n' "$name" "$expected" "$actual" >&2
                exit 1
            fi
            count=$((count + 1))
        fi
        repository='' revision=''
    fi
done < "$root/build.zig.zon"
expected_count=1
[[ "$backend" != all && "$backend" != integration ]] || expected_count=2
if [[ "$count" -ne "$expected_count" || -n "$repository" ]]; then
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
    actual=$(cd -- "$root" && zig fetch "$ffi_url")
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
    actual=$(cd -- "$root" && zig fetch "$suite_url")
    [[ "$actual" == "$suite_hash" ]] || { echo "Dependency hash mismatch for Lua tests: expected=$suite_hash actual=$actual" >&2; exit 1; }
    count=$((count + 1))
fi
for archive in "$work/lua.tar.gz" "$work/luajit.tar.gz"; do
    [[ -e "$archive" ]] || continue
    if [[ -f "$archive" && -O "$archive" && ! -L "$archive" ]] && command -v lsof >/dev/null && ! lsof -- "$archive" >/dev/null 2>&1; then
        if ! command -v mountpoint >/dev/null || ! mountpoint -q -- "$archive"; then
            unlink -- "$archive"
        fi
    else
        printf 'Retaining diagnostic archive; cleanup safety could not be established: %s\n' "$archive" >&2
    fi
done
if [[ -d "$work" && -O "$work" && ! -L "$work" ]]; then
    rmdir -- "$work" 2>/dev/null || true
fi
printf 'Verified %s immutable dependency package(s); cache=%s\n' "$count" "$ZIG_GLOBAL_CACHE_DIR"
printf 'For subsequent builds use: export ZIG_GLOBAL_CACHE_DIR=%q ZIG_LOCAL_CACHE_DIR=%q\n' "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
