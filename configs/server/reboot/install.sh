#!/usr/bin/env bash
# description: Schedule unattended upgrade reboot at 03:00
# default: false
set -euo pipefail
[[ -d /etc/apt/apt.conf.d ]] || { echo 'Requires Debian or Ubuntu' >&2; exit 1; }
sudo tee /etc/apt/apt.conf.d/52bootstrap-unattended-upgrades >/dev/null <<'APT'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
APT
sudo chmod 644 /etc/apt/apt.conf.d/52bootstrap-unattended-upgrades
