#!/usr/bin/env bash
# description: Configure UFW, SSH hardening, Fail2ban, and persistent journald
# default: false
set -euo pipefail

# Ask for sudo credentials now so the package commands do not fail halfway through.
sudo -v
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y unattended-upgrades fail2ban ufw
  sudo systemctl enable --now fail2ban
  sudo dpkg-reconfigure -f noninteractive unattended-upgrades
else
  echo 'This starter security installer currently supports Debian and Ubuntu only.' >&2
  exit 1
fi
# Allow the standard SSH service before enabling UFW.
sudo ufw allow OpenSSH
sudo ufw --force enable

# Install a managed drop-in, test the full effective config, then reload.
sudo install -d -m 755 /etc/ssh/sshd_config.d
dropin=/etc/ssh/sshd_config.d/90-bootstrap-hardening.conf
tmp="$(mktemp)"
cat > "$tmp" <<'SSH'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSH
sudo install -m 644 "$tmp" "$dropin"
rm -f "$tmp"
if ! sudo sshd -t; then
  echo 'sshd validation failed; removing the new drop-in' >&2
  sudo rm -f "$dropin"
  exit 1
fi
sudo systemctl reload ssh || sudo systemctl reload sshd

sudo install -d -m 755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/90-bootstrap-persistent.conf >/dev/null <<'JOURNAL'
[Journal]
Storage=persistent
SystemMaxUse=500M
JOURNAL
sudo systemctl restart systemd-journald
printf 'Review the manual checks in %s/docs/security-check.md\n' "$BOOTSTRAP_ROOT"
