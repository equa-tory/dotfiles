#!/usr/bin/env bash
# description: Install Grafana and Loki with Docker Compose
# default: false
set -euo pipefail

folder="$HOME/.local/share/grafana-loki"
mkdir -p "$folder/grafana/provisioning/datasources" "$folder/loki"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/docker-compose.yml" "$folder/"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/grafana/provisioning/datasources/loki.yaml" "$folder/grafana/provisioning/datasources/"
cp "$BOOTSTRAP_ROOT/configs/server/grafana-loki/loki/config.yaml" "$folder/loki/"
read -r -s -p 'Grafana admin password (blank generates one): ' grafana_password
printf '\n'
if [[ -z "$grafana_password" ]]; then grafana_password="$(openssl rand -hex 24)"; fi
umask 077
printf 'GRAFANA_PASSWORD=%s\n' "$grafana_password" > "$folder/.env"
unset grafana_password
chmod 600 "$folder/.env"
(cd "$folder" && docker compose up -d)
printf 'Grafana login: admin / %s\n' "$(sed -n 's/^GRAFANA_PASSWORD=//p' "$folder/.env")"
(cd "$folder" && docker compose up -d)
