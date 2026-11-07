#!/usr/bin/env bash
# description: Configure Pacman mirror cache
# default: false
set -euo pipefail
host="${MIRROR_HOST:-192.168.1.50}"
list=/etc/pacman.d/mirrorlist
if ! command -v pacman >/dev/null 2>&1; then
  echo 'Pacman is not installed on this system; mirror setup skipped'
  exit 0
fi
[[ -f "$list" ]] || { echo "Pacman is installed but $list is missing" >&2; exit 1; }
curl --noproxy '*' --fail --silent --show-error --max-time 4 "http://$host:3142/lastsync" -o /dev/null || { echo "Pacman mirror $host is unreachable; unchanged"; exit 0; }
line="Server = http://$host:3142/\$repo/os/\$arch"
if ! grep -qxF "$line" "$list"; then
  sudo cp -a "$list" "$list.bootstrap-bak.$(date +%Y%m%d-%H%M%S)"
  { printf '%s\n' "$line"; grep -vxF "$line" "$list" || true; } | sudo tee "$list" >/dev/null
fi
