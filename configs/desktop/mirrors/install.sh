#!/usr/bin/env bash
# description: Set up pacman cache and Nexus mirrors from Torii dotfiles
# default: false
set -euo pipefail

folder="$HOME/.local/share/torii-dotfiles"
if [[ ! -d "$folder/.git" ]]; then
  git clone https://github.com/equa-tory/torii-dotfiles.git "$folder"
fi
"$folder/packages/mirrors.sh"
