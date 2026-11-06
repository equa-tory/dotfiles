#!/usr/bin/env bash
# description: Unknown TERM fallback before zsh themes/plugins
# default: true
set -euo pipefail
source "$BOOTSTRAP_ROOT/lib/common.sh"
mkdir -p "$HOME/.config/shell"
if ! cmp -s "$BOOTSTRAP_ROOT/configs/default/shell/terminal.zsh" "$HOME/.config/shell/terminal.zsh"; then
  backup_file "$HOME/.config/shell/terminal.zsh"
  cp "$BOOTSTRAP_ROOT/configs/default/shell/terminal.zsh" "$HOME/.config/shell/terminal.zsh"
fi
ensure_source_line "$HOME/.zshrc" '[[ -r "$HOME/.config/shell/terminal.zsh" ]] && source "$HOME/.config/shell/terminal.zsh"' top
# Existing managed line may already be lower in .zshrc; moving it requires a
# deliberate migration, not silently rewriting someone else's configuration.
echo 'Terminal fallback installed; confirm source line precedes prompt plugins'
