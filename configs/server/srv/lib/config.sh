#!/usr/bin/env bash
# lib/config.sh - machine-specific settings, so the rest of srv doesn't
# hard-code dorm's paths. Sourced by any module that needs one of these:
#   HOME_DIR       your home dir
#   BACKUP_ROOT    where `srv backup` writes snapshots (<app>/<timestamp>/)
#   CONF_DIR       where `srv conf capture` writes redacted configs
#   SYSTEMD_DIR    where systemd unit files live
#   NGINX_DIR      nginx's config root (sites-available/, snippets/, ...)
#   WATCH_DISKS    array of mount points `srv live`'s disk section watches
#   PKG_MGR        detected package manager (apt/pacman/unknown) - recorded
#                  for later, nothing branches on it yet
#
# Real values live in .state/srv.conf - per-machine, gitignored (.state/ is
# already in .gitignore). srv.conf.example (committed) documents every key
# with dorm's own values as the example. A missing key is never fatal - it
# falls back to a detected default, so dorm's behavior today is unchanged
# even before srv.conf exists.
# Not meant to run standalone - sourced by other lib/*.sh files.
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$OPS_DIR/.state}"
SRV_CONF="$STATE_DIR/srv.conf"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"

# Probes the live machine and sets DETECTED_* vars - never touches the real
# HOME_DIR/BACKUP_ROOT/... vars, so calling this doesn't clobber values
# already loaded from srv.conf.
srv_config_detect() {
  DETECTED_HOME_DIR="$HOME"

  if [[ -d /mnt/nas/backups ]]; then
    DETECTED_BACKUP_ROOT="/mnt/nas/backups/state"
  else
    DETECTED_BACKUP_ROOT="$HOME/backups"
  fi

  # OPS_DIR is already resolved through symlinks (readlink -f above) - its
  # sibling conf/ is the real repo path, not the ~/srv/_conf symlink.
  if [[ -d "$OPS_DIR/../conf" ]]; then
    DETECTED_CONF_DIR="$(cd "$OPS_DIR/../conf" && pwd)"
  else
    DETECTED_CONF_DIR="$HOME/srv/_conf"
  fi

  DETECTED_SYSTEMD_DIR="/etc/systemd/system"
  DETECTED_NGINX_DIR="/etc/nginx"

  if [[ -d /mnt/nas/mirror/archlinux/pool/packages ]]; then
    DETECTED_ARCH_MIRROR_ROOT="/mnt/nas/mirror/archlinux"
  else
    DETECTED_ARCH_MIRROR_ROOT=""
  fi
  DETECTED_ARCH_MIRROR_UPSTREAM="rsync://mirrors.kernel.org/archlinux/"

  DETECTED_WATCH_DISKS=()
  local m
  while IFS= read -r m; do
    [[ -n "$m" && "$m" != "/boot" ]] && DETECTED_WATCH_DISKS+=("$m")
  done < <(findmnt -rno TARGET -t ext2,ext3,ext4,xfs,btrfs,cifs,nfs,nfs4,ntfs,vfat,exfat 2>/dev/null)
  (( ${#DETECTED_WATCH_DISKS[@]} == 0 )) && DETECTED_WATCH_DISKS=(/)

  if command -v pacman &>/dev/null; then DETECTED_PKG_MGR=pacman
  elif command -v apt &>/dev/null; then DETECTED_PKG_MGR=apt
  else DETECTED_PKG_MGR=unknown
  fi
}

# loads srv.conf if present, then fills any still-unset var with its
# detected default. Safe to call repeatedly.
srv_config_load() {
  srv_config_detect
  if [[ -f "$SRV_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$SRV_CONF"
  fi
  HOME_DIR="${HOME_DIR:-$DETECTED_HOME_DIR}"
  BACKUP_ROOT="${BACKUP_ROOT:-$DETECTED_BACKUP_ROOT}"
  CONF_DIR="${CONF_DIR:-$DETECTED_CONF_DIR}"
  SYSTEMD_DIR="${SYSTEMD_DIR:-$DETECTED_SYSTEMD_DIR}"
  NGINX_DIR="${NGINX_DIR:-$DETECTED_NGINX_DIR}"
  PKG_MGR="${PKG_MGR:-$DETECTED_PKG_MGR}"
  ARCH_MIRROR_ROOT="${ARCH_MIRROR_ROOT:-$DETECTED_ARCH_MIRROR_ROOT}"
  ARCH_MIRROR_UPSTREAM="${ARCH_MIRROR_UPSTREAM:-$DETECTED_ARCH_MIRROR_UPSTREAM}"
  if [[ -z "${WATCH_DISKS+x}" || ${#WATCH_DISKS[@]} -eq 0 ]]; then
    WATCH_DISKS=("${DETECTED_WATCH_DISKS[@]}")
  fi
}

srv_config_save() {
  mkdir -p "$STATE_DIR"
  {
    echo "# srv.conf - this machine's settings, written by 'srv setup'."
    echo "# Not committed (.state/ is gitignored) - see ../srv.conf.example"
    echo "# for what each key means."
    echo "HOME_DIR=$(printf '%q' "$HOME_DIR")"
    echo "BACKUP_ROOT=$(printf '%q' "$BACKUP_ROOT")"
    echo "CONF_DIR=$(printf '%q' "$CONF_DIR")"
    echo "SYSTEMD_DIR=$(printf '%q' "$SYSTEMD_DIR")"
    echo "NGINX_DIR=$(printf '%q' "$NGINX_DIR")"
    echo "PKG_MGR=$(printf '%q' "$PKG_MGR")"
    echo "ARCH_MIRROR_ROOT=$(printf '%q' "$ARCH_MIRROR_ROOT")"
    echo "ARCH_MIRROR_UPSTREAM=$(printf '%q' "$ARCH_MIRROR_UPSTREAM")"
    printf 'WATCH_DISKS=('
    local d
    for d in "${WATCH_DISKS[@]}"; do printf '%q ' "$d"; done
    printf ')\n'
  } > "$SRV_CONF"
}

# first run: show what was detected, offer use/edit/use-without-saving.
# Non-interactive callers (cron, piped) just get the detected values saved
# silently - same end state, no prompt nobody could answer.
_srv_config_use_detected() {
  HOME_DIR="$DETECTED_HOME_DIR"; BACKUP_ROOT="$DETECTED_BACKUP_ROOT"
  CONF_DIR="$DETECTED_CONF_DIR"; SYSTEMD_DIR="$DETECTED_SYSTEMD_DIR"
  NGINX_DIR="$DETECTED_NGINX_DIR"; PKG_MGR="$DETECTED_PKG_MGR"
  ARCH_MIRROR_ROOT="$DETECTED_ARCH_MIRROR_ROOT"
  ARCH_MIRROR_UPSTREAM="$DETECTED_ARCH_MIRROR_UPSTREAM"
  WATCH_DISKS=("${DETECTED_WATCH_DISKS[@]}")
}

# shared by srv_config_first_run (silent auto-detect) and srv_config_setup
# ('srv setup', explicit re-detect) - only the header line differs.
_srv_config_prompt() {
  local header="$1"
  srv_config_detect
  echo -e "\033[1m${header}\033[0m"
  echo "  backups   -> $DETECTED_BACKUP_ROOT"
  echo "  conf      -> $DETECTED_CONF_DIR"
  echo "  systemd   -> $DETECTED_SYSTEMD_DIR"
  echo "  disks     -> ${DETECTED_WATCH_DISKS[*]}"
  echo "  packages  -> $DETECTED_PKG_MGR"
  echo "  arch mirror -> ${DETECTED_ARCH_MIRROR_ROOT:-not found}"
  echo

  if ! _ui_is_tty; then
    _srv_config_use_detected
    srv_config_save
    return 0
  fi

  local choice
  choice="$(ui_menu "use these settings?" "" "use these" "edit" "just this run, don't save")" || choice="just this run, don't save"
  case "$choice" in
    "use these")
      _srv_config_use_detected
      srv_config_save
      echo -e "\033[0;32m✓\033[0m saved to $SRV_CONF"
      ;;
    edit)
      local reply
      read -r -p "backup root [$DETECTED_BACKUP_ROOT]: " reply; BACKUP_ROOT="${reply:-$DETECTED_BACKUP_ROOT}"
      read -r -p "conf dir [$DETECTED_CONF_DIR]: " reply; CONF_DIR="${reply:-$DETECTED_CONF_DIR}"
      read -r -p "systemd dir [$DETECTED_SYSTEMD_DIR]: " reply; SYSTEMD_DIR="${reply:-$DETECTED_SYSTEMD_DIR}"
      HOME_DIR="$DETECTED_HOME_DIR"; NGINX_DIR="$DETECTED_NGINX_DIR"; PKG_MGR="$DETECTED_PKG_MGR"
      ARCH_MIRROR_ROOT="$DETECTED_ARCH_MIRROR_ROOT"; ARCH_MIRROR_UPSTREAM="$DETECTED_ARCH_MIRROR_UPSTREAM"
      WATCH_DISKS=("${DETECTED_WATCH_DISKS[@]}")
      srv_config_save
      echo -e "\033[0;32m✓\033[0m saved to $SRV_CONF"
      ;;
    *)
      _srv_config_use_detected
      echo -e "\033[2musing detected values for this run only, not saved\033[0m"
      ;;
  esac
}

srv_config_first_run() { _srv_config_prompt "no srv.conf yet - detected:"; }

# 'srv setup' - explicit, on-demand re-detect (e.g. after adding a drive,
# or moving the repo). Same prompt as first-run, just honest that a
# srv.conf already exists and this offers to replace it.
srv_config_setup() { _srv_config_prompt "re-detecting settings for this machine:"; }

# main entrypoint: load if srv.conf exists, otherwise run the first-run flow
# (which also creates it). Every module that needs a setting calls this.
srv_config() {
  if [[ -f "$SRV_CONF" ]]; then
    srv_config_load
  else
    srv_config_first_run
  fi
}
