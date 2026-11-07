#!/usr/bin/env bash
# lib/svcctl.sh - shared start/stop/restart/enable/disable submenu for a
# single systemd unit. Sourced by xray.sh and frp.sh (both control one
# simple unit) instead of duplicating the same 5 actions twice.
# Not a `srv` subcommand - sourced only.
#
#   svcctl_menu "xray" xray     # label to print, unit name to act on
#
# Loops showing current state, offering Start/Stop/Restart/Enable at boot/
# Disable at boot/Back via ui_menu; picking one runs it directly, no y/n
# gate - picking the menu item already is the confirmation. Returns when
# "Back" is picked or the menu is cancelled (q/Esc).
set -uo pipefail

_SVCCTL_BOLD='\033[1m'; _SVCCTL_DIM='\033[2m'; _SVCCTL_GREEN='\033[0;32m'
_SVCCTL_YELLOW='\033[1;33m'; _SVCCTL_RED='\033[0;31m'; _SVCCTL_RESET='\033[0m'

svcctl_menu() {
  local label="$1" unit="$2"
  while true; do
    local active enabled
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    echo
    if [[ "$active" == active ]]; then
      echo -e "  $label: ${_SVCCTL_GREEN}active${_SVCCTL_RESET}"
    else
      echo -e "  $label: ${_SVCCTL_RED}${active:-unknown}${_SVCCTL_RESET}"
    fi
    if [[ "$enabled" == enabled ]]; then
      echo -e "  boot:  ${_SVCCTL_GREEN}enabled${_SVCCTL_RESET}"
    else
      echo -e "  boot:  ${_SVCCTL_YELLOW}${enabled:-disabled}${_SVCCTL_RESET}"
    fi

    local choice
    choice="$(ui_menu "$label service" "" "Start" "Stop" "Restart" "Enable at boot" "Disable at boot" "Back")" || return 0
    case "$choice" in
      Start|Stop|Restart)
        local verb="${choice,,}"
        if sudo systemctl "$verb" "$unit"; then
          echo -e "  ${_SVCCTL_GREEN}✓${_SVCCTL_RESET} $unit ${verb}ed"
        else
          echo -e "  ${_SVCCTL_RED}failed${_SVCCTL_RESET} - check: sudo journalctl -u $unit -n 30" >&2
        fi
        ;;
      "Enable at boot")
        sudo systemctl enable "$unit" && echo -e "  ${_SVCCTL_GREEN}✓${_SVCCTL_RESET} enabled"
        ;;
      "Disable at boot")
        sudo systemctl disable "$unit" && echo -e "  ${_SVCCTL_GREEN}✓${_SVCCTL_RESET} disabled"
        ;;
      Back|"")
        return 0
        ;;
    esac
  done
}
