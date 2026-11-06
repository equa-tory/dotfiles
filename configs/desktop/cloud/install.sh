#!/usr/bin/env bash
# description: Install cloud helper into ~/.local/bin
# default: false
set -euo pipefail
url='https://raw.githubusercontent.com/equa-tory/cloud/main/cloud'
mkdir -p "$HOME/.local/bin"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location "$url" -o "$tmp"
install -m 755 "$tmp" "$HOME/.local/bin/cloud"
echo 'Installed ~/.local/bin/cloud'
