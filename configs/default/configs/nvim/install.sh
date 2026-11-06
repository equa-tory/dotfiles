#!/usr/bin/env bash
# description: Install Neovim config from Torii dotfiles
# default: false
set -euo pipefail

folder="$HOME/.local/share/torii-dotfiles"
if [[ ! -d "$folder/.git" ]]; then
  git clone https://github.com/equa-tory/torii-dotfiles.git "$folder"
fi
"$folder/install.sh" --only nvim
