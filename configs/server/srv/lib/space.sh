#!/usr/bin/env bash
# srv space [prune] - disk usage report, and cleanup.
# `prune` shows categories that generalize to any Linux box (docker image
# cache, old system logs, an unused Caddy install if present) - tick which
# to clean, ticking it runs it, no extra y/n after. Dorm-specific
# stray-file lists don't live here any more (they go stale fast and were
# never general-purpose - see NEXT.md section 3 for that kind of one-off
# cleanup, done by hand).
# Standalone: bash ~/srv/_ops/lib/space.sh [prune]
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/config.sh"
srv_config

BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
h() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

report() {
  h "DISK USAGE"
  df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null

  h "TOP DIRS UNDER $HOME_DIR"
  du -sh "$HOME_DIR"/*/ 2>/dev/null | sort -hr | head -15

  h "TOP DIRS UNDER MOUNTED DRIVES"
  local d
  for d in "${WATCH_DISKS[@]}"; do
    [[ "$d" == "/" ]] && continue
    [[ -d "$d" ]] || continue
    echo -e "${DIM}$d:${RESET}"
    du -sh "$d"/*/ 2>/dev/null | sort -hr | head -6
  done

  h "DOCKER"
  docker system df 2>/dev/null || echo "docker not installed"

  echo -e "\n${DIM}srv space prune   for safe-to-delete candidates${RESET}"
}

prune_docker_images() {
  h "DOCKER IMAGE CACHE"
  docker system df 2>/dev/null | awk 'NR==1 || /^Images/'
  echo -e "${DIM}removes images not backing any container - Docker volumes are never touched here${RESET}"
  docker image prune -a -f
}

prune_logs() {
  h "OLD SYSTEM LOGS"
  journalctl --disk-usage 2>/dev/null
  echo -e "${DIM}keeping the last 14 days${RESET}"
  sudo journalctl --vacuum-time=14d
}

# checks live whether caddy is worth offering at all - once it's gone,
# stop cluttering the menu with a category that would just say "not found".
_caddy_present() { systemctl list-unit-files caddy.service &>/dev/null; }

prune_caddy() {
  h "CADDY - unused reverse proxy"
  if ! _caddy_present; then
    echo "caddy isn't installed - nothing to do"
    return 0
  fi
  local state; state="$(systemctl is-active caddy 2>/dev/null)"
  echo "state: ${state:-unknown}"
  local vhost; vhost="$(grep -m1 -v '^\s*#' /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')"
  if [[ -n "$vhost" ]]; then
    local resolves="does NOT resolve"
    getent hosts "$vhost" &>/dev/null && resolves="resolves"
    echo "only vhost: $vhost ($resolves on this box)"
  fi
  echo "binds: 80, 443, 2019 (admin API, localhost only)"
  echo -e "${DIM}purging - sudo apt purge caddy, removes /etc/caddy too, undo means reinstalling${RESET}"
  sudo systemctl disable --now caddy
  sudo apt purge -y caddy
  sudo rm -rf /etc/caddy
  echo -e "${GREEN}✓${RESET} caddy removed, 80/443/2019 freed"
}

prune_interactive() {
  h "CLEAN UP JUNK"
  local -a opts=(
    "Docker image cache (checked live, one click)"
    "Old system logs (checked live, one click)"
  )
  _caddy_present && opts+=("Caddy - unused reverse proxy (frees 80/443, one click)")

  local -a picked
  mapfile -t picked < <(ui_multi "what do you want to clean up?" "" "${opts[@]}")

  if [[ ${#picked[@]} -eq 0 ]]; then
    echo -e "${DIM}nothing selected${RESET}"
    return 0
  fi

  local c
  for c in "${picked[@]}"; do
    case "$c" in
      "Docker image cache"*) prune_docker_images ;;
      "Old system logs"*)    prune_logs ;;
      "Caddy"*)               prune_caddy ;;
    esac
  done
}

prune() {
  prune_interactive
  echo -e "\n${DIM}Dorm-specific one-off cleanup (stray files, old tarballs): see NEXT.md, section 3 - done by hand, not from here.${RESET}"
}

case "${1:-}" in
  prune) prune ;;
  *)     report ;;
esac
