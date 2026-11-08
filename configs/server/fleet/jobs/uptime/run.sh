#!/usr/bin/env bash
# description: Show uptime on each selected VPS (example shell job)
# changes: false
set -euo pipefail
printf '%s: ' "$FLEET_HOST"
uptime
