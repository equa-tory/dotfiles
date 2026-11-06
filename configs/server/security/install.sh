#!/usr/bin/env bash
# description: Install basic server security updates and intrusion protection
# default: false
set -euo pipefail

# Ask for sudo credentials now so the package commands do not fail halfway through.
sudo -v
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y unattended-upgrades fail2ban
  sudo systemctl enable --now fail2ban
  sudo dpkg-reconfigure -f noninteractive unattended-upgrades
else
  echo 'This starter security installer currently supports Debian and Ubuntu only.' >&2
  exit 1
fi
printf 'Review the manual checks in %s/docs/security-check.md\n' "$BOOTSTRAP_ROOT"
