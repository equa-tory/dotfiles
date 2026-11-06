#!/usr/bin/env bash
# description: Configure Pacman mirror cache
# default: false
set -euo pipefail
host="${MIRROR_HOST:-192.168.1.50}"
list=/etc/pacman.d/mirrorlist
[[ -f "$list" ]] || { echo 'Pacman is not installed' >&2; exit 1; }
curl --fail --silent --show-error --max-time 4 "http://$host:3142/lastsync" -o /dev/null || { echo "Pacman mirror $host is unreachable; unchanged"; exit 0; }
line="Server = http://$host:3142/\$repo/os/\$arch"
if ! grep -qxF "$line" "$list"; then
  sudo cp -a "$list" "$list.bootstrap-bak.$(date +%Y%m%d-%H%M%S)"
  { printf '%s\n' "$line"; grep -vxF "$line" "$list" || true; } | sudo tee "$list" >/dev/null
fi
