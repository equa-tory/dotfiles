#!/usr/bin/env bash
# description: Install packages listed in packages.txt
# default: true
set -euo pipefail

# Read one package name per line; ignore blank lines and comments.
packages=()
while IFS= read -r package; do
  [[ -z "$package" || "$package" == \#* ]] && continue
  packages+=("$package")
done < "$BOOTSTRAP_ROOT/configs/default/tools/packages.txt"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y "${packages[@]/openssh/openssh-client}"
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm "${packages[@]}"
elif command -v brew >/dev/null 2>&1; then
  brew install "${packages[@]}"
else
  echo 'Unsupported package manager' >&2
  exit 1
fi
