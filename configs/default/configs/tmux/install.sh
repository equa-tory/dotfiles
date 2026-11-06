#!/usr/bin/env bash
# description: Install a simple tmux configuration
# default: true
set -euo pipefail

source "$BOOTSTRAP_ROOT/lib/common.sh"
source_file="$BOOTSTRAP_ROOT/configs/default/.config/tmux/tmux.conf"
target="$HOME/.config/tmux/tmux.conf"
install_config_link "$source_file" "$target"
ensure_source_line "$HOME/.tmux.conf" 'source-file "$HOME/.config/tmux/tmux.conf"'
echo 'tmux config installed'
