#!/usr/bin/env bash
# description: Install FRP client service and generate a local auth token
# default: false
set -euo pipefail

source_dir="${FRP_SOURCE_DIR:-}"
if [[ -z "$source_dir" && -t 0 ]]; then
  read -r -p 'FRP files directory (blank skips this module): ' source_dir
fi
if [[ -z "$source_dir" ]]; then
  echo 'FRP client skipped: set FRP_SOURCE_DIR or enter a source directory.'
  exit 0
fi
if [[ ! -x "$source_dir/frpc" || ! -f "$source_dir/frpc.toml" ]]; then
  echo "FRP client files not found in $source_dir (need frpc and frpc.toml)" >&2
  exit 1
fi
sudo -v
sudo install -d -m 755 /opt/frp /etc/frp
sudo install -m 755 "$source_dir/frpc" /opt/frp/frpc
sudo install -m 600 "$source_dir/frpc.toml" /etc/frp/frpc.toml
read -r -s -p 'FRP auth token (blank generates one): ' token
printf '\n'
if [[ -z "$token" ]]; then token="$(openssl rand -hex 32)"; fi
sudo sed -i "s/^auth.token *=.*/auth.token = \"$token\"/" /etc/frp/frpc.toml
sudo tee /etc/systemd/system/frpc.service >/dev/null <<'UNIT'
[Unit]
Description=FRP Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/frp/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo chmod 600 /etc/frp/frpc.toml
sudo systemctl daemon-reload
sudo systemctl enable --now frpc.service
printf 'Client token (synchronize securely with server config): %s\n' "$token"
unset token
