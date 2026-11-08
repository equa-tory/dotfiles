#!/usr/bin/env bash
# description: Install Alloy VPS agent with HTTPS credentials and named logs
# default: false
# after: server/logging/loki-caddy
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$MODULE_DIR/../agent.py"
