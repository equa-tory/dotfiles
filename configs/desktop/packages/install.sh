#!/usr/bin/env bash
# description: Install desktop CLI tools and Git support
# default: false
set -euo pipefail
if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm zsh neovim ripgrep fd zoxide fzf git
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get -o DPkg::Lock::Timeout=600 update
  sudo apt-get -o DPkg::Lock::Timeout=600 install -y zsh neovim ripgrep fd-find zoxide fzf git
elif command -v brew >/dev/null 2>&1; then
  brew install zsh neovim ripgrep fd zoxide fzf git
else
  echo 'Unsupported package manager' >&2; exit 1
fi
