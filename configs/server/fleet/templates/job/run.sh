#!/usr/bin/env bash
# description: Describe what this job does
# sudo: false
# serial: 1
set -euo pipefail
# This script runs on the selected VPS, not the controller.
printf 'Hello from %s\n' "$FLEET_HOST"
