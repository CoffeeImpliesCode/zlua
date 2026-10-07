#!/usr/bin/env bash
# Source from .envrc before invoking devenv, and from the generated shell/tasks.
# Bash 3.2-compatible: caller data travels as values, never evaluated shell text.
zlua_cache_variables='ZLUA_CACHE_ROOT XDG_CACHE_HOME ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR EM_CACHE GATE_CACHE_DIR GATE_CROSS_OUTPUT UV_CACHE_DIR PIP_CACHE_DIR npm_config_cache BUN_INSTALL_CACHE_DIR CCACHE_DIR GOCACHE GOMODCACHE CARGO_TARGET_DIR APPTAINER_CACHEDIR APPTAINER_TMPDIR TMPDIR TMP TEMP'

zlua_capture_caller() {
  local name marker
  # Typed CLI options cross both sandbox filtering and pure Nix evaluation.
  # Indexed arguments preserve spaces and metacharacters without evaluating data.
  zlua_devenv_options=()
  for name in $zlua_cache_variables; do
    marker="_ZLUA_CALLER_$name"
    if declare -p "$name" >/dev/null 2>&1; then
      export "$marker=${!name}"
      zlua_devenv_options[${#zlua_devenv_options[@]}]=--option
      zlua_devenv_options[${#zlua_devenv_options[@]}]="env.$marker:string"
      zlua_devenv_options[${#zlua_devenv_options[@]}]="${!name}"
    else
      unset "$marker"
    fi
  done
}

zlua_restore_caller() {
  local name marker
  for name in $zlua_cache_variables; do
    marker="_ZLUA_CALLER_$name"
    if declare -p "$marker" >/dev/null 2>&1; then
      export "$name=${!marker}"
    fi
  done
}

# Resolve existing symlinks using the host shell, including macOS /private/tmp.
# For a not-yet-created suffix, require plain components to avoid ambiguous '..'.
zlua_resolve_directory() {
  local path="$1" suffix='' component
  case "$path" in /*) ;; *) return 1 ;; esac
  while [ ! -e "$path" ]; do
    [ ! -L "$path" ] || return 1
    component=${path##*/}
    case "$component" in ''|.|..) return 1 ;; esac
    suffix="/$component$suffix"
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  path=$(cd -- "$path" && pwd -P) || return 1
  if [ "$path" = / ]; then
    printf '/%s\n' "${suffix#/}"
  else
    printf '%s%s\n' "$path" "$suffix"
  fi
}

zlua_local_directory() {
  local path="$1" resolved ancestor fs
  resolved=$(zlua_resolve_directory "$path") || {
    printf 'zlua: cache must be an absolute directory path: %s\n' "$path" >&2
    return 1
  }
  case "$resolved" in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*|/private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*|"$zlua_root"|"$zlua_root"/*)
      printf 'zlua: refusing cache in system temporary storage or checkout: %s\n' "$resolved" >&2
      return 1 ;;
  esac
  case "$zlua_host" in
    buildhost*)
      case "$resolved" in
        /home/tmp/"$zlua_user"/*|/home/tmp2/"$zlua_user"/*|/vol/tmp/"$zlua_user"/*|/vol/tmp2/"$zlua_user"/*) ;;
        *) printf 'zlua: cache is not under approved local user storage: %s\n' "$resolved" >&2; return 1 ;;
      esac ;;
  esac
  ancestor="$resolved"
  while [ ! -e "$ancestor" ]; do
    ancestor=${ancestor%/*}
    [ -n "$ancestor" ] || ancestor=/
  done
  case "$zlua_system" in
    Linux) fs=$(findmnt -n -o FSTYPE --target "$ancestor") || return 1 ;;
    Darwin) fs=$(/usr/bin/stat -f %T "$ancestor") || return 1 ;;
    *) printf 'zlua: unsupported cache filesystem inspection on %s\n' "$zlua_system" >&2; return 1 ;;
  esac
  case "$fs" in
    ext4|ext3|ext2|xfs|btrfs|zfs|f2fs|apfs|hfs) ;;
    *) printf 'zlua: refusing non-local cache filesystem %s: %s\n' "$fs" "$resolved" >&2; return 1 ;;
  esac
  if [ ! -O "$ancestor" ]; then
    printf 'zlua: refusing cache below an unowned directory: %s\n' "$ancestor" >&2
    return 1
  fi
  (umask 077; mkdir -p -- "$resolved") || return 1
  [ -d "$resolved" ] && [ -O "$resolved" ]
}

zlua_setup() {
  local zlua_root zlua_host zlua_user zlua_system name marker path target resolved hash
  local -a saved_names saved_values
  saved_names=() saved_values=()
  zlua_root=$(cd -- "$1" && pwd -P) || return 1
  # Keep direct-shell values too, when no outer direnv markers were supplied.
  for name in $zlua_cache_variables; do
    if declare -p "$name" >/dev/null 2>&1; then
      saved_names[${#saved_names[@]}]="$name"
      saved_values[${#saved_values[@]}]="${!name}"
    fi
  done
  if [ -r "$HOME/.local/lib/host-scratch.sh" ]; then
    source "$HOME/.local/lib/host-scratch.sh" || return 1
  fi
  for ((name=0; name<${#saved_names[@]}; name++)); do
    export "${saved_names[$name]}=${saved_values[$name]}"
  done
  zlua_restore_caller
  if [ -z "${ZLUA_CACHE_ROOT:-}" ]; then
    if [ -z "${XDG_CACHE_HOME:-}" ]; then
      echo 'zlua: export ZLUA_CACHE_ROOT or XDG_CACHE_HOME on approved local storage.' >&2
      return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      hash=$(printf %s "$zlua_root" | sha256sum) || return 1
    else
      hash=$(printf %s "$zlua_root" | shasum -a 256) || return 1
    fi
    export ZLUA_CACHE_ROOT="$XDG_CACHE_HOME/zlua/${hash:0:16}"
  fi
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ZLUA_CACHE_ROOT/build}"
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ZLUA_CACHE_ROOT/global}"
  export EM_CACHE="${EM_CACHE:-$ZLUA_CACHE_ROOT/emscripten}"
  export GATE_CACHE_DIR="${GATE_CACHE_DIR:-$ZLUA_CACHE_ROOT/gate}"
  export GATE_CROSS_OUTPUT="${GATE_CROSS_OUTPUT:-$ZLUA_CACHE_ROOT/cross-test}"
  export GATE_EXCLUDE="${GATE_EXCLUDE:-/[.]zig-cache/ /zig-out/ /zig-pkg/ /.jj/ /.devenv/ /.direnv/}"
  zlua_host=$(hostname -s 2>/dev/null || uname -n) || return 1
  zlua_system=$(uname -s) || return 1
  zlua_user=${HOST_SCRATCH_USER:-${USER:-}}
  if [ -z "$zlua_user" ]; then zlua_user=$(id -un 2>/dev/null || id -u) || return 1; fi
  for name in $zlua_cache_variables; do
    if declare -p "$name" >/dev/null 2>&1; then
      zlua_local_directory "${!name}" || return 1
    fi
  done
  for name in .devenv .direnv .zig-cache zig-pkg; do
    case "$name" in
      .devenv) target="$ZLUA_CACHE_ROOT/devenv" ;;
      .direnv) target="$ZLUA_CACHE_ROOT/direnv" ;;
      .zig-cache) target="$ZIG_LOCAL_CACHE_DIR" ;;
      zig-pkg) target="$ZLUA_CACHE_ROOT/pkg" ;;
    esac
    path="$zlua_root/$name"
    if [ -L "$path" ]; then
      [ -O "$path" ] || { printf 'zlua: refusing unowned link: %s\n' "$path" >&2; return 1; }
      resolved=$(zlua_resolve_directory "$path") || return 1
      zlua_local_directory "$resolved" || return 1
      case "$name" in
        .devenv|.direnv)
          target=$(zlua_resolve_directory "$target") || return 1
          [ "$resolved" = "$target" ] || {
            printf 'zlua: existing %s link does not match configured cache root: %s\n' "$name" "$target" >&2
            return 1
          } ;;
      esac
    elif [ -e "$path" ]; then
      printf 'zlua: refusing real cache path %s; relocate it manually before invoking devenv.\n' "$path" >&2
      return 1
    else
      zlua_local_directory "$target" || return 1
      ln -s -- "$target" "$path" || return 1
    fi
  done
}
