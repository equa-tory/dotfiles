#!/usr/bin/env bash
# description: Configure Caddy HTTPS Loki ingestion with VPS IP allowlist and passwords
# default: false
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$MODULE_DIR/../logging/gateway.py"
