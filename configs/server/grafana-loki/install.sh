#!/usr/bin/env bash
# description: Install Grafana and Loki with Docker Compose
# default: false
set -euo pipefail

folder="$HOME/.local/share/grafana-loki"
mkdir -p "$folder/grafana/provisioning/datasources" "$folder/loki"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/docker-compose.yml" "$folder/"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/grafana/provisioning/datasources/loki.yaml" "$folder/grafana/provisioning/datasources/"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/loki/config.yaml" "$folder/loki/"
if [[ ! -f "$folder/.env" ]]; then
  umask 077
  printf 'GRAFANA_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$folder/.env"
fi
chmod 600 "$folder/.env"
(cd "$folder" && docker compose up -d)
