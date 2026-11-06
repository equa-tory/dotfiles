#!/usr/bin/env bash
# description: Clone Torii dotfiles and run its interactive installer
# default: false
set -euo pipefail

folder="$HOME/.local/share/torii-dotfiles"
if [[ -d "$folder/.git" ]]; then
  git -C "$folder" pull --ff-only
else
  git clone https://github.com/equa-tory/torii-dotfiles.git "$folder"
fi
"$folder/install.sh"
