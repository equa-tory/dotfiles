#!/usr/bin/env bash
# description: Download FRP and configure a client service
# default: false
set -euo pipefail
source "$BOOTSTRAP_ROOT/configs/server/frp/common.sh"

read -r -p 'FRP server hostname or IP: ' server_addr
[[ -n "$server_addr" ]] || { echo 'Server address is required' >&2; exit 1; }
read -r -p 'FRP transport protocol [quic/tcp, default quic]: ' protocol
protocol="${protocol:-quic}"
[[ "$protocol" == quic || "$protocol" == tcp ]] || { echo 'Protocol must be quic or tcp' >&2; exit 1; }
if [[ "$protocol" == quic ]]; then default_port=10801; else default_port=10800; fi
read -r -p "FRP server port [$default_port]: " server_port
server_port="${server_port:-$default_port}"
frp_validate_port "$server_port" || { echo 'Invalid server port' >&2; exit 1; }
read -r -p 'SOCKS5 proxy URL [socks5://127.0.0.1:1080]: ' proxy_url
proxy_url="${proxy_url:-socks5://127.0.0.1:1080}"
if [[ "$protocol" == quic ]]; then
  read -r -p 'QUIC keepalive seconds [10]: ' quic_keepalive
  quic_keepalive="${quic_keepalive:-10}"
  read -r -p 'QUIC max idle seconds [30]: ' quic_idle
  quic_idle="${quic_idle:-30}"
  read -r -p 'QUIC max incoming streams [100000]: ' quic_streams
  quic_streams="${quic_streams:-100000}"
  for value in "$quic_keepalive" "$quic_idle" "$quic_streams"; do
    [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 )) || {
      echo 'QUIC settings must be positive integers' >&2
      exit 1
    }
  done
fi
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
  if [[ -n "$proxy_url" ]]; then
    proxy_toml="$(frp_toml_quote "$proxy_url")"
    printf '\ntransport.proxyURL = %s\n' "$proxy_toml"
  fi
  printf '\ntransport.protocol = %s\n' "$(frp_toml_quote "$protocol")"
  if [[ "$protocol" == quic ]]; then
    printf 'transport.quic.keepalivePeriod = %s\n' "$quic_keepalive"
    printf 'transport.quic.maxIdleTimeout = %s\n' "$quic_idle"
    printf 'transport.quic.maxIncomingStreams = %s\n' "$quic_streams"
  fi
  printf '\nlog.level = "info"\n'
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
