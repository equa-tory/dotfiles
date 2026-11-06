#!/usr/bin/env bash
# description: Install the repository Neovim configuration
# default: false
set -euo pipefail
source "$BOOTSTRAP_ROOT/lib/common.sh"
install_config_link "$BOOTSTRAP_ROOT/configs/default/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"
echo 'Neovim config linked'
