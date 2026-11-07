#!/usr/bin/env bash
# description: Install the srv command and its bundled modules
# default: false
set -euo pipefail

source "$BOOTSTRAP_ROOT/lib/common.sh"
source_dir="$BOOTSTRAP_ROOT/configs/server/srv"
target="$HOME/.local/bin/srv"
mkdir -p "$HOME/.local/bin"
if [[ -e "$target" && ! -L "$target" ]]; then
  backup_file "$target"
  rm -f -- "$target"
fi
ln -sfn -- "$source_dir/srv" "$target"
printf 'Installed srv at %s\n' "$target"
