#!/usr/bin/env bash
# description: Universal shell aliases and tool fallbacks (bash/zsh)
# default: true
set -euo pipefail
source "$BOOTSTRAP_ROOT/lib/common.sh"
install_config_link "$BOOTSTRAP_ROOT/configs/default/shell/shellrc" "$HOME/.config/shell/shellrc"
ensure_source_line "$HOME/.bashrc" '[[ -r "$HOME/.config/shell/shellrc" ]] && source "$HOME/.config/shell/shellrc"'
ensure_source_line "$HOME/.zshrc" '[[ -r "$HOME/.config/shell/shellrc" ]] && source "$HOME/.config/shell/shellrc"'
echo "Universal shell config installed"
