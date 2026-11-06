#!/usr/bin/env bash
# description: Configure Docker registry mirrors
# default: false
set -euo pipefail
host="${MIRROR_HOST:-192.168.1.50}"
if ! command -v docker >/dev/null && [[ ! -d /etc/docker ]]; then echo 'Docker is not installed; skipped'; exit 0; fi
command -v jq >/dev/null || { echo 'jq is required to preserve Docker settings' >&2; exit 1; }
sudo mkdir -p /etc/docker
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [[ -s /etc/docker/daemon.json ]]; then sudo cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"; sudo cat /etc/docker/daemon.json > "$tmp"; else printf '{}\n' > "$tmp"; fi
jq --arg a "http://$host:8091" --arg b "http://$host:8093" '. + {"registry-mirrors":[$a,$b],"insecure-registries":((."insecure-registries" // []) + [($a|sub("http://";"")),($b|sub("http://";""))] | unique)}' "$tmp" | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl is-active --quiet docker && sudo systemctl reload docker || true
