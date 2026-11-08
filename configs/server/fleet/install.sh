#!/usr/bin/env bash
# description: Install fleet SSH controller for keys, Alloy updates, and future tasks
# default: false
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
controller_home="$HOME/.local/share/equa-fleet"
mkdir -p "$controller_home" "$HOME/.local/bin"
python3 -m venv "$controller_home/venv"
"$controller_home/venv/bin/python" -m pip install -r "$MODULE_DIR/requirements.txt"
"$controller_home/venv/bin/ansible-galaxy" collection install -r "$MODULE_DIR/collections.yml" -p "$controller_home/collections"
if [[ -e "$HOME/.local/bin/fleet" && ! -L "$HOME/.local/bin/fleet" ]]; then
  cp -p "$HOME/.local/bin/fleet" "$HOME/.local/bin/fleet.backup.$(date +%s)"
fi
ln -sfn "$MODULE_DIR/fleet.py" "$HOME/.local/bin/fleet"
chmod +x "$MODULE_DIR/fleet.py"
if [[ ! -e "$HOME/.config/equa-fleet/inventory.json" ]]; then
  read -r -p 'Default VPS Linux SSH username [equa]: ' fleet_user
  read -r -p 'Controller private key path [~/.ssh/id_ed25519]: ' fleet_key
  "$HOME/.local/bin/fleet" init --user "${fleet_user:-equa}" --key "${fleet_key:-$HOME/.ssh/id_ed25519}"
fi
printf 'Fleet controller installed. Start with fleet list, fleet configure, then fleet enroll all.\n'
