#!/usr/bin/env bash
# description: Universal shell aliases and tool fallbacks (bash/zsh)
# default: true
set -euo pipefail
source "$BOOTSTRAP_ROOT/lib/common.sh"
mkdir -p "$HOME/.config/shell"
if ! cmp -s "$BOOTSTRAP_ROOT/configs/default/shell/aliases.sh" "$HOME/.config/shell/aliases.sh"; then
  backup_file "$HOME/.config/shell/aliases.sh"
  cp "$BOOTSTRAP_ROOT/configs/default/shell/aliases.sh" "$HOME/.config/shell/aliases.sh"
fi
ensure_source_line "$HOME/.bashrc" '[[ -r "$HOME/.config/shell/aliases.sh" ]] && source "$HOME/.config/shell/aliases.sh"'
ensure_source_line "$HOME/.zshrc" '[[ -r "$HOME/.config/shell/aliases.sh" ]] && source "$HOME/.config/shell/aliases.sh"'
echo "Universal aliases installed"
