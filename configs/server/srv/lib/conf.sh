#!/usr/bin/env bash
# srv conf capture|push|pull|status - config capture into ~/srv/_conf.
# No encryption: real secrets go to ~/srv/_conf/secrets.env (gitignored,
# local only). The repo gets {{PLACEHOLDER}} versions instead. See
# SECRETS.md for why, and the per-secret regeneration guide.
# Standalone: bash ~/srv/_ops/lib/conf.sh capture|push|pull|status
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/config.sh"
srv_config
SECRETS_FILE="$CONF_DIR/secrets.env"
# CONF_DIR is a SUBDIRECTORY of the actual git repo, not the repo root
# (dorm-config also holds ops/). Every git operation below targets
# REPO_DIR, not CONF_DIR. readlink -f first so a relative ".." doesn't
# resolve through a symlink to the wrong parent.
REPO_DIR="$(dirname "$(readlink -f "$CONF_DIR" 2>/dev/null || echo "$CONF_DIR")")"
# One repo for both ops/ and conf/ (your call) means `srv conf push` commits
# and pushes whatever's changed anywhere in the repo, not just the capture -
# that's expected, not a bug: one remote, one push, as decided.

BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
h() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }
ok() { echo -e "  ${GREEN}✓${RESET} $*"; }
skip() { echo -e "  ${DIM}- $* (not found, skipped)${RESET}"; }

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  echo -e "${YELLOW}capturing root-owned configs needs sudo - you may be prompted${RESET}"
  sudo -v
}

# grab SRC DST - copies a root-owned file via sudo, skips quietly if missing
grab() {
  local src="$1" dst="$2"
  if sudo test -f "$src" 2>/dev/null; then
    sudo cat "$src" > "$dst"
    ok "$src"
  else
    skip "$src"
  fi
}

# secretize FILE PATTERN PLACEHOLDER_NAME - finds PATTERN (an extended regex
# with one capture group = the secret value) in FILE, replaces the captured
# value with {{PLACEHOLDER_NAME}} in place, and records the real value in
# secrets.env. Every capture re-copies the source file fresh (so it always
# has the live value in it) - so this always re-applies the substitution,
# even on repeat runs; it only avoids adding a DUPLICATE line to secrets.env.
secretize() {
  local file="$1" pattern="$2" name="$3"
  [[ -f "$file" ]] || return 0
  local value
  value="$(grep -oP "$pattern" "$file" 2>/dev/null | head -1)"
  [[ -z "$value" ]] && return 0   # already a placeholder, or never had one
  sed -i "s|${value}|{{${name}}}|" "$file"
  grep -q "^${name}=" "$SECRETS_FILE" 2>/dev/null || echo "${name}=${value}" >> "$SECRETS_FILE"
  ok "redacted ${name} from $(basename "$file")"
}

capture() {
  need_sudo
  mkdir -p "$CONF_DIR"/{systemd,nginx,samba,docker,dotfiles,frp,xray}
  touch "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"

  h "systemd units (yours)"
  local units=(booru comfyui homeflix mus silly shutter frp xray xray@
               ollama ollama-api ilo-api minecraft minecraft-hrd)
  for u in "${units[@]}"; do
    grab "$SYSTEMD_DIR/${u}.service" "$CONF_DIR/systemd/${u}.service"
  done
  secretize "$CONF_DIR/systemd/ilo-api.service" 'X-Auth: \K[^"]+' ILO_API_TOKEN

  h "nginx"
  for f in "$NGINX_DIR"/sites-available/*; do
    [[ -f "$f" ]] || continue
    grab "$f" "$CONF_DIR/nginx/$(basename "$f")"
  done
  grab "$NGINX_DIR/snippets/local-ssl.conf" "$CONF_DIR/nginx/snippet-local-ssl.conf"
  grab "$NGINX_DIR/snippets/proxy-ws.conf" "$CONF_DIR/nginx/snippet-proxy-ws.conf"
  grab "$NGINX_DIR/proxy_params" "$CONF_DIR/nginx/proxy_params"

  h "samba"
  grab /etc/samba/smb.conf "$CONF_DIR/samba/smb.conf"
  # the guest password is left as a plaintext comment in smb.conf itself (not
  # a config value sed could target normally) - pull it out same as any other secret
  secretize "$CONF_DIR/samba/smb.conf" '\(password \K[0-9a-zA-Z]+(?=\))' SMB_GUEST_PASSWORD

  h "frp"
  if [[ -f "$HOME/frp/frpc.toml" ]]; then
    cp "$HOME/frp/frpc.toml" "$CONF_DIR/frp/frpc.toml"
    secretize "$CONF_DIR/frp/frpc.toml" 'auth\.token = "\K[^"]+' FRP_AUTH_TOKEN
    ok "$HOME/frp/frpc.toml"
  else
    skip "$HOME/frp/frpc.toml"
  fi

  h "xray"
  need_sudo
  if sudo test -f /usr/local/etc/xray/config.json 2>/dev/null; then
    sudo cat /usr/local/etc/xray/config.json > "$CONF_DIR/xray/config.json"
    secretize "$CONF_DIR/xray/config.json" '"id": "\K[^"]+' XRAY_VLESS_UUID
    secretize "$CONF_DIR/xray/config.json" '"publicKey": "\K[^"]+' XRAY_REALITY_PUBKEY
    secretize "$CONF_DIR/xray/config.json" '"shortId": "\K[^"]+' XRAY_REALITY_SHORTID
    secretize "$CONF_DIR/xray/config.json" '"spiderX": "\K[^"]+' XRAY_REALITY_SPIDERX
    ok "/usr/local/etc/xray/config.json"
  else
    skip "/usr/local/etc/xray/config.json"
  fi

  h "docker compose (already secret-free where variables are used properly)"
  for pair in \
    "$HOME/git/n8n/docker-compose.yml:docker/n8n-docker-compose.yml" \
    "$HOME/git/uptime-kuma/docker-compose.yml:docker/uptime-kuma-docker-compose.yml" \
    "$HOME/git/searxng-setup/docker-compose.yml:docker/searxng-docker-compose.yml"
  do
    src="${pair%%:*}"; dst="$CONF_DIR/${pair##*:}"
    if [[ -f "$src" ]]; then cp "$src" "$dst"; ok "$src"; else skip "$src"; fi
  done
  # n8n's actual secret lives in a separate .env next to its compose file
  if [[ -f "$HOME/git/n8n/.env" ]]; then
    cp "$HOME/git/n8n/.env" "$CONF_DIR/docker/n8n.env.example"
    secretize "$CONF_DIR/docker/n8n.env.example" 'N8N_PASSWORD=\K.+' N8N_PASSWORD
    ok "$HOME/git/n8n/.env (as template)"
  fi

  h "dotfiles + scripts"
  for pair in \
    "$HOME/.bashrc:dotfiles/.bashrc" \
    "$HOME/ports.sh:dotfiles/ports.sh" \
    "$HOME/space.sh:dotfiles/space.sh" \
    "$HOME/log.sh:dotfiles/log.sh" \
    "$HOME/issh.sh:dotfiles/issh.sh" \
    "$HOME/ts-restart.sh:dotfiles/ts-restart.sh"
  do
    src="${pair%%:*}"; dst="$CONF_DIR/${pair##*:}"
    if [[ -f "$src" ]]; then cp "$src" "$dst"; ok "$src"; else skip "$src"; fi
  done

  h "system"
  mkdir -p "$CONF_DIR/system"
  crontab -l 2>/dev/null > "$CONF_DIR/system/crontab.txt" && ok "crontab -l"
  grab /etc/fstab "$CONF_DIR/system/fstab"
  dpkg --get-selections 2>/dev/null | awk '$2=="install"{print $1}' > "$CONF_DIR/system/apt-packages.txt" \
    && ok "apt package list ($(wc -l < "$CONF_DIR/system/apt-packages.txt") packages)"

  h "done"
  echo "  captured into: $CONF_DIR"
  echo "  real secret values: $SECRETS_FILE (chmod 600, gitignored, local only)"
  echo -e "  ${DIM}review with: git -C $REPO_DIR status${RESET}"
}

# refuse to push (or even stage) anything that looks like a real secret.
# Broad on purpose: ANY staged path ending in .env is blocked, except our own
# intentional *.env.example templates - better to over-block a legitimate
# file (rename it .env.example and re-capture) than under-block a real leak.
check_no_secrets_staged() {
  local bad
  bad="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | awk '{print $2}' | \
    grep -E '\.env$' | grep -vE '\.env\.example$' )"
  if [[ -n "$bad" ]]; then
    echo -e "${RED}refusing to push - these look like real secret files, not templates:${RESET}"
    echo "$bad" | sed 's/^/  /'
    echo -e "${DIM}if a file legitimately belongs, rename it *.env.example and re-capture${RESET}"
    return 1
  fi
  return 0
}

push() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" init -q
    git -C "$REPO_DIR" branch -M main 2>/dev/null
    echo "initialized git repo at $REPO_DIR"
  fi
  check_no_secrets_staged || return 1
  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    echo -e "${DIM}nothing to commit${RESET}"
  else
    check_no_secrets_staged || { git -C "$REPO_DIR" reset -q; return 1; }
    if git -C "$REPO_DIR" commit -q -m "srv conf capture $(date +%F)"; then
      echo -e "${GREEN}committed${RESET}"
    else
      echo -e "${RED}commit failed${RESET} (see git's error above - often a missing" >&2
      echo -e "git user.name/user.email; set with git config --global ...)" >&2
      return 1
    fi
  fi
  if git -C "$REPO_DIR" remote get-url origin &>/dev/null; then
    git -C "$REPO_DIR" push
  else
    echo -e "${YELLOW}no remote configured yet${RESET} - add one, then:"
    echo "  git -C $REPO_DIR remote add origin git@github.com:equa-tory/dorm-config.git"
    echo "  git -C $REPO_DIR push -u origin main"
  fi

  # keep a readable copy of the one file you actually read on the SMB
  # share, so you never have to manually re-copy the tool there again -
  # non-fatal if /@ isn't mounted right now.
  if [[ -d /@ ]]; then
    cp "$OPS_DIR/NEXT.md" /@/NEXT.md 2>/dev/null && ok "mirrored NEXT.md to /@/NEXT.md"
  fi
}

pull() {
  [[ -d "$REPO_DIR/.git" ]] || { echo "no repo at $REPO_DIR yet" >&2; exit 1; }
  git -C "$REPO_DIR" pull
  echo -e "${YELLOW}note:${RESET} secrets.env is NOT part of the repo - refill it by hand"
  echo "using conf/SECRETS.md as a guide (regenerate, don't restore old values)."
}

# "push my changes" as one step: capture (re-scan live configs into the
# repo) then push. Most people never think to run capture on its own before
# pushing - this is the button the menu and `srv push` actually call; the
# two commands still work separately for scripting.
sync() {
  capture
  push
}

status() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "no repo yet - run: srv conf capture   then   srv conf push"
    return
  fi
  git -C "$REPO_DIR" status -s
  echo
  if git -C "$REPO_DIR" remote get-url origin &>/dev/null; then
    echo "remote: $(git -C "$REPO_DIR" remote get-url origin)"
  else
    echo -e "${YELLOW}no remote configured${RESET}"
  fi
}

case "${1:-}" in
  capture) capture ;;
  push)    push ;;
  pull)    pull ;;
  sync)    sync ;;
  status)  status ;;
  "")
    if _ui_is_tty; then
      choice="$(ui_menu "srv conf - what do you want to do?" "" "push my changes" "pull latest" status)" || exit 0
      case "$choice" in
        "push my changes") sync ;;
        "pull latest")     pull ;;
        status)             status ;;
      esac
    else
      status
    fi
    ;;
  *) echo "srv conf [capture|push|pull|sync|status]" >&2; exit 1 ;;
esac
