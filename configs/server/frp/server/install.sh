#!/usr/bin/env bash
# description: Download FRP and configure a server service
# default: false
set -euo pipefail
source "$BOOTSTRAP_ROOT/configs/server/frp/common.sh"

read -r -p 'FRP TCP bind port [10800]: ' bind_port
bind_port="${bind_port:-10800}"
frp_validate_port "$bind_port" || { echo 'Invalid bind port' >&2; exit 1; }
read -r -p 'FRP QUIC UDP bind port [10801]: ' quic_port
quic_port="${quic_port:-10801}"
frp_validate_port "$quic_port" || { echo 'Invalid QUIC bind port' >&2; exit 1; }
read -r -s -p 'Shared auth token (blank generates one): ' token
printf '\n'
if [[ -z "$token" ]]; then token="$(openssl rand -hex 32)"; fi

sudo -v
frp_install_binary frps
token_toml="$(frp_toml_quote "$token")"
sudo install -d -m 755 /etc/frp
sudo tee /etc/frp/frps.toml >/dev/null <<EOF
bindAddr = "0.0.0.0"
bindPort = $bind_port
quicBindPort = $quic_port

auth.method = "token"
auth.token = $token_toml

vhostHTTPPort = 0
vhostHTTPSPort = 0
log.level = "info"
EOF
sudo chmod 600 /etc/frp/frps.toml
sudo /opt/frp/frps verify -c /etc/frp/frps.toml
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
sudo systemctl daemon-reload
sudo systemctl enable --now frps.service
printf 'Server token (use the same value on the FRP client): %s\n' "$token"
unset token
