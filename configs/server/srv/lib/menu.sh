#!/usr/bin/env bash
# srv menu (bare `srv`) - arrow-key / type-to-filter picker over the 6
# commands srv has left. Typed commands (`srv live`, `srv frp add ...`)
# are unchanged - plain output, no menu, no clear. This is only the
# friendly bare-invocation entrypoint.
# Standalone: bash ~/srv/_ops/lib/menu.sh
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
STATE_DIR="$OPS_DIR/.state"
MENU_LAST_FILE="$STATE_DIR/menu_last"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"

# No TTY (piped, cron, TERM=dumb) - a menu can't work there anyway. live.sh
# already prints one snapshot and exits when it isn't a real terminal, so
# that's the sane fallback here too.
if ! _ui_is_tty; then
  exec bash "$OPS_DIR/lib/live.sh"
fi

ORDER=(
  "Live watch - GPU / ollama / top, updates every second"
  "Clean up junk - tick what to delete, runs as soon as you confirm the tick"
  "Xray - link, subscription, switch servers, start/stop/enable"
  "Frp - toggle/add/remove tunnels, start/stop/enable the service"
  "Push my changes - save configs to github"
  "Pull latest - get configs from github"
)

mkdir -p "$STATE_DIR"
default=""
[[ -f "$MENU_LAST_FILE" ]] && default="$(cat "$MENU_LAST_FILE" 2>/dev/null)"

while true; do
  ui_clear
  choice="$(ui_menu "srv - what do you want to do?" "$default" "${ORDER[@]}")" || { ui_clear; exit 0; }
  default="$choice"
  echo "$choice" > "$MENU_LAST_FILE" 2>/dev/null
  ui_clear
  case "$choice" in
    "Live watch"*)    bash "$OPS_DIR/lib/live.sh" ;;
    "Clean up junk"*) bash "$OPS_DIR/lib/space.sh" prune ;;
    "Xray"*)          bash "$OPS_DIR/lib/xray.sh" ;;
    "Frp"*)           bash "$OPS_DIR/lib/frp.sh" ;;
    "Push my changes"*) bash "$OPS_DIR/lib/conf.sh" sync ;;
    "Pull latest"*)   bash "$OPS_DIR/lib/conf.sh" pull ;;
  esac
  echo
  read -rsn1 -p "press any key to go back to the menu... "
  echo
done
