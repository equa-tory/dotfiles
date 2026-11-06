#!/usr/bin/env bash
# description: Install FRP server service and generate a local auth token
# default: false
set -euo pipefail

source_dir='/@/frp/frp'
if [[ ! -x "$source_dir/frps" || ! -f "$source_dir/frps.toml" ]]; then
  echo "FRP server files not found in $source_dir" >&2
  exit 1
fi
sudo -v
sudo install -d -m 755 /opt/frp /etc/frp
sudo install -m 755 "$source_dir/frps" /opt/frp/frps
sudo install -m 600 "$source_dir/frps.toml" /etc/frp/frps.toml
read -r -s -p 'FRP auth token (blank generates one): ' token
printf '\n'
if [[ -z "$token" ]]; then token="$(openssl rand -hex 32)"; fi
sudo sed -i "s/^auth.token *=.*/auth.token = \"$token\"/" /etc/frp/frps.toml
sudo tee /etc/systemd/system/frps.service >/dev/null <<'UNIT'
[Unit]
Description=FRP Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/frp/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo chmod 600 /etc/frp/frps.toml
sudo systemctl daemon-reload
sudo systemctl enable --now frps.service
printf 'Server token (synchronize securely with client config): %s\n' "$token"
unset token
