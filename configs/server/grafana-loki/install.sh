#!/usr/bin/env bash
# description: Install central Grafana/Loki dashboards and optional local Alloy collector
# default: false
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$MODULE_DIR/../logging/hub.py"
