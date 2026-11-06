#!/usr/bin/env bash
set -euo pipefail

: "${BOOTSTRAP_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

backup_file() {
  local path="$1"
  if [[ -e "$path" && ! -L "$path" ]]; then
    local backup="$path.bak.$(date +%Y%m%d-%H%M%S)-$$"
    cp -p -- "$path" "$backup"
    echo "Backup: $backup"
  fi
}

# Replace a config target with a symlink to a repo-managed file. Preserve any
# existing file, directory, or symlink before replacing it.
install_config_link() {
  local source="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  if [[ -L "$target" && "$(readlink -f "$target" 2>/dev/null || true)" == "$(readlink -f "$source")" ]]; then
    return
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    local backup="$target.bak.$(date +%Y%m%d-%H%M%S)-$$"
    cp -a -- "$target" "$backup"
    echo "Backup: $backup"
    rm -rf -- "$target"
  fi
  ln -s -- "$source" "$target"
}

# Append a managed source command only if absent; backs up the original before edit.
ensure_source_line() {
  local path="$1" line="$2" placement="${3:-bottom}"
  mkdir -p "$(dirname "$path")"
  touch "$path"
  if grep -Fqx -- "$line" "$path"; then
    if [[ "$placement" != top ]] || [[ "$(head -n 1 "$path")" == "$line" ]]; then
      return
    fi
    backup_file "$path"
    local tmp
    tmp="$(mktemp)"
    { printf '%s\n' "$line"; grep -Fvx -- "$line" "$path" || true; } > "$tmp"
    cat "$tmp" > "$path"
    rm -f "$tmp"
    return
  fi
  backup_file "$path"
  if [[ "$placement" == top ]]; then
    local tmp
    tmp="$(mktemp)"
    { printf '%s\n' "$line"; cat "$path"; } > "$tmp"
    cat "$tmp" > "$path"
    rm -f "$tmp"
  else
    printf '\n%s\n' "$line" >> "$path"
  fi
}
