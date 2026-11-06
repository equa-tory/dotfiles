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
