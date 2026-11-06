#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3 is needed for the interactive menu (install python3 first).' >&2
  exit 1
fi
exec python3 "$ROOT/manager.py" "$@"
