#!/usr/bin/env bash
# description: Set the complete server hostname (prompted, with backups)
# default: false
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$MODULE_DIR/hostname.py"
