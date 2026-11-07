#!/usr/bin/env bash
# description: Download FRP and configure a client service
# default: false
set -euo pipefail
source "$BOOTSTRAP_ROOT/configs/server/frp/common.sh"

read -r -p 'FRP server hostname or IP: ' server_addr
[[ -n "$server_addr" ]] || { echo 'Server address is required' >&2; exit 1; }
read -r -p 'FRP server port [7000]: ' server_port
server_port="${server_port:-7000}"
frp_validate_port "$server_port" || { echo 'Invalid server port' >&2; exit 1; }
read -r -s -p 'Shared auth token (blank generates one): ' token
printf '\n'
if [[ -z "$token" ]]; then token="$(openssl rand -hex 32)"; fi
read -r -p 'Local TCP service port to expose (blank for no proxy): ' local_port
if [[ -n "$local_port" ]]; then
  frp_validate_port "$local_port" || { echo 'Invalid local port' >&2; exit 1; }
  read -r -p 'Remote TCP port to expose: ' remote_port
  frp_validate_port "$remote_port" || { echo 'Invalid remote port' >&2; exit 1; }
fi

sudo -v
frp_install_binary frpc
server_addr_toml="$(frp_toml_quote "$server_addr")"
token_toml="$(frp_toml_quote "$token")"
sudo install -d -m 755 /etc/frp
{
  printf 'serverAddr = %s\nserverPort = %s\n\n' "$server_addr_toml" "$server_port"
  printf 'auth.method = "token"\nauth.token = %s\n' "$token_toml"
  if [[ -n "$local_port" ]]; then
    printf '\n[[proxies]]\nname = "tcp-%s-%s"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' \
      "$local_port" "$remote_port" "$local_port" "$remote_port"
  fi
} | sudo tee /etc/frp/frpc.toml >/dev/null
sudo chmod 600 /etc/frp/frpc.toml
sudo /opt/frp/frpc verify -c /etc/frp/frpc.toml
sudo tee /etc/systemd/system/frpc.service >/dev/null <<'UNIT'
[Unit]
Description=FRP Client Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/opt/frp/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now frpc.service
printf 'Client token (use the same value on the FRP server): %s\n' "$token"
unset token
