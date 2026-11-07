#!/usr/bin/env bash
# srv frp [add|rm|on|off] - manage tunnels in ~/frp/frpc.toml.
# `off` comments a [[proxies]] block out (you already had 5 blocks disabled
# this way - kuma, n8n, smb, minecraft_bedrock, and the broken homeflix one).
# `on` uncomments it back. Every write is validated with python's tomllib
# before it ever touches the real file - that's the same check that caught
# the `I#` typo currently breaking this file.
# Standalone: bash ~/srv/_ops/lib/frp.sh [add|rm|on|off|list]
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/svcctl.sh"
srv_config

BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
h() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

FRPC_TOML="${FRPC_TOML:-$HOME/frp/frpc.toml}"

_valid_toml() {
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$1" 2>&1
}

_require_valid_live() {
  local err
  err="$(_valid_toml "$FRPC_TOML")" && return 0
  echo -e "${RED}$FRPC_TOML doesn't parse - fix that first (see NEXT.md #1):${RESET}" >&2
  echo "$err" | tail -3 >&2
  return 1
}

# All block parsing/editing lives in one python program, dispatched by a
# first argv. Line-based on purpose, not a TOML round-trip: this file mixes
# active blocks with several different hand-typed comment styles
# (#[[proxies]], #\t[[proxies]], the broken I#\t[[proxies]]) and a real
# TOML writer would silently reformat or drop all of that.
_frp_py() {
  local cmd="$1"; shift
  python3 - "$FRPC_TOML" "$cmd" "$@" <<'PY'
import re, sys

path, cmd = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
lines = open(path).read().splitlines()

FIELDS = ("name", "type", "localIP", "localPort", "remotePort")
MARK = re.compile(r'^\s*(?:I#|#)*\s*')

def demark(line):
    """Strip any leading whitespace + comment markers, return (was_marked, bare)."""
    m = re.match(r'^(\s*)((?:I#|#)\s*)?(.*)$', line)
    indent, marker, rest = m.groups()
    return (marker is not None and marker != ""), rest

def find_blocks():
    blocks = []
    i = 0
    while i < len(lines):
        marked, bare = demark(lines[i])
        if bare.strip() == "[[proxies]]":
            start = i
            fields = {}
            j = i + 1
            while j < len(lines):
                _, fbare = demark(lines[j])
                mm = re.match(r'^(\w+)\s*=\s*"?([^"\n]*)"?\s*$', fbare)
                if not mm or mm.group(1) not in FIELDS:
                    break
                fields[mm.group(1)] = mm.group(2)
                j += 1
            blocks.append({"start": start, "end": j, "enabled": not marked, "fields": fields})
            i = j
        else:
            i += 1
    return blocks

blocks = find_blocks()

if cmd == "list":
    for b in blocks:
        f = b["fields"]
        state = "on " if b["enabled"] else "off"
        print(f"{state}\t{f.get('name','?')}\t{f.get('type','?')}\t{f.get('localIP','?')}:{f.get('localPort','?')}\t{f.get('remotePort','?')}")

elif cmd == "toggle":
    name, want_on = args[0], args[1] == "1"
    target = next((b for b in blocks if b["fields"].get("name") == name), None)
    if target is None:
        print(f"no tunnel named '{name}'", file=sys.stderr); sys.exit(2)
    if target["enabled"] == want_on:
        print("nochange"); sys.exit(0)
    out = list(lines)
    for i in range(target["start"], target["end"]):
        _, bare = demark(lines[i])
        out[i] = ("" if want_on else "# ") + bare if bare.strip() else lines[i]
    print("\n".join(out[:target["start"]] + out[target["start"]:target["end"]] + out[target["end"]:]))

elif cmd == "rm":
    name = args[0]
    target = next((b for b in blocks if b["fields"].get("name") == name), None)
    if target is None:
        print(f"no tunnel named '{name}'", file=sys.stderr); sys.exit(2)
    out = lines[:target["start"]] + lines[target["end"]:]
    print("\n".join(out))

elif cmd == "add":
    name, typ, localip, localport, remoteport = args
    for b in blocks:
        if b["fields"].get("name") == name:
            print(f"a tunnel named '{name}' already exists", file=sys.stderr); sys.exit(2)
        if b["enabled"] and b["fields"].get("remotePort") == remoteport:
            print(f"remotePort {remoteport} is already used by '{b['fields'].get('name')}'", file=sys.stderr); sys.exit(2)
    block = (
        f'\n# -------------------------\n# {name}\n# -------------------------\n'
        f'[[proxies]]\nname = "{name}"\ntype = "{typ}"\nlocalIP = "{localip}"\n'
        f'localPort = {localport}\nremotePort = {remoteport}\n'
    )
    print("\n".join(lines) + block, end="")

elif cmd == "get":
    name = args[0]
    target = next((b for b in blocks if b["fields"].get("name") == name), None)
    if target is None:
        sys.exit(2)
    f = target["fields"]
    print(f"{'on' if target['enabled'] else 'off'}\t{f.get('type')}\t{f.get('localIP')}:{f.get('localPort')}\t{f.get('remotePort')}")

else:
    print(f"unknown internal command {cmd}", file=sys.stderr); sys.exit(1)
PY
}

list_tunnels() {
  h "FRP TUNNELS"
  local active enabled
  active="$(systemctl is-active frp 2>/dev/null || true)"
  enabled="$(systemctl is-enabled frp 2>/dev/null || true)"
  echo -e "  service: $([[ "$active" == active ]] && echo -e "${GREEN}active${RESET}" || echo -e "${RED}${active:-unknown}${RESET}")  boot: $([[ "$enabled" == enabled ]] && echo -e "${GREEN}enabled${RESET}" || echo -e "${YELLOW}${enabled:-disabled}${RESET}")"
  echo
  _frp_py list | awk -F'\t' '{printf "  %-3s %-16s %-4s %-24s -> %s\n", $1, $2, $3, $4, $5}'
}

# writes a new version of the file (piped in on stdin), validates it,
# shows a diff, then installs it - shared by add/rm/toggle so there's
# exactly one place that touches the real file. No y/n gate - running
# `srv frp add/rm/on/off` (or picking it in the menu) is already the
# decision; the diff above is shown so you can see exactly what changed.
_apply() {
  local new_content="$1" verb="$2"
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$new_content" > "$tmp"

  local err
  err="$(_valid_toml "$tmp")"
  if [[ -n "$err" ]]; then
    echo -e "${RED}that change would break the file - not writing it${RESET}" >&2
    echo "$err" | tail -3 >&2
    rm -f "$tmp"
    return 1
  fi
  echo -e "  ${GREEN}✓${RESET} still valid TOML"

  h "diff"
  diff -u "$FRPC_TOML" "$tmp" | tail -n +3 || true
  echo -e "  ${DIM}$verb, restarting frp (drops all tunnels for a second, ssh included)${RESET}"

  cp "$FRPC_TOML" "${FRPC_TOML}.prev"
  cp "$tmp" "$FRPC_TOML"
  rm -f "$tmp"
  echo -e "  ${GREEN}✓${RESET} previous file kept at ${FRPC_TOML}.prev"
  if sudo systemctl restart frp; then
    echo -e "  ${GREEN}✓${RESET} frp restarted"
  else
    echo -e "  ${RED}restart failed${RESET} - check: sudo journalctl -u frp -n 30" >&2
    return 1
  fi
}

add_tunnel() {
  local name="${1:-}" typ="${2:-}" localaddr="${3:-}" remoteport="${4:-}"
  if [[ -z "$name" || -z "$typ" || -z "$localaddr" || -z "$remoteport" ]]; then
    cat >&2 <<'EOF'
srv frp add <name> <tcp|udp> <local-ip:port> <remote-port>
  example:  srv frp add minecraft tcp 192.168.1.50:25565 25566
EOF
    return 1
  fi
  [[ "$typ" == tcp || "$typ" == udp ]] || { echo "type must be tcp or udp" >&2; return 1; }
  [[ "$localaddr" == *:* ]] || { echo "local-ip:port must contain a ':'" >&2; return 1; }
  local localip="${localaddr%:*}" localport="${localaddr##*:}"

  if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${localport}\$"; then
    echo -e "  ${YELLOW}note:${RESET} nothing on this box looks like it's listening on port $localport right now"
  fi

  local new; new="$(_frp_py add "$name" "$typ" "$localip" "$localport" "$remoteport")" || return 1
  _apply "$new" "add '$name'"
}

rm_tunnel() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: srv frp rm <name>" >&2; return 1; }
  local new; new="$(_frp_py rm "$name")" || return 1
  _apply "$new" "remove '$name'"
}

toggle_tunnel() {
  local name="${1:-}" want="$2"
  [[ -z "$name" ]] && { echo "usage: srv frp ${want} <name>" >&2; return 1; }
  local on=0; [[ "$want" == on ]] && on=1
  local new
  new="$(_frp_py toggle "$name" "$on")" || return 1
  if [[ "$new" == "nochange" ]]; then
    echo "'$name' is already ${want}"
    return 0
  fi
  _apply "$new" "turn ${want} '$name'"
}

# --- interactive wrappers (TTY only) - each just collects parameters and
# calls the existing add_tunnel/rm_tunnel/toggle_tunnel above; no new
# write-path logic, only new ways to reach it.

interactive_toggle() {
  local -a opts=()
  mapfile -t opts < <(_frp_py list | awk -F'\t' '{state=($1=="on ")?"on":"off"; printf "%s (%s)\n", $2, state}')
  if (( ${#opts[@]} == 0 )); then echo "no tunnels defined"; return; fi
  local pick; pick="$(ui_menu "toggle which tunnel?" "" "${opts[@]}")" || return
  local name="${pick%% (*}"
  local want=on; [[ "$pick" == *"(on)"* ]] && want=off
  toggle_tunnel "$name" "$want"
}

interactive_add() {
  local name typ localaddr remoteport
  read -r -p "name (e.g. minecraft): " name
  [[ -z "$name" ]] && { echo "cancelled"; return; }
  typ="$(ui_menu "type?" "" tcp udp)" || { echo "cancelled"; return; }
  read -r -p "local ip:port (e.g. 192.168.1.50:25565): " localaddr
  read -r -p "remote port on the VPS (e.g. 25566): " remoteport
  add_tunnel "$name" "$typ" "$localaddr" "$remoteport"
}

interactive_rm() {
  local -a names=()
  mapfile -t names < <(_frp_py list | awk -F'\t' '{print $2}')
  if (( ${#names[@]} == 0 )); then echo "no tunnels defined"; return; fi
  local pick; pick="$(ui_menu "remove which tunnel?" "" "${names[@]}")" || return
  rm_tunnel "$pick"
}

case "${1:-}" in
  add) shift; _require_valid_live || exit 1; add_tunnel "$@" ;;
  rm)  shift; _require_valid_live || exit 1; rm_tunnel "$@" ;;
  on)  shift; _require_valid_live || exit 1; toggle_tunnel "${1:-}" on ;;
  off) shift; _require_valid_live || exit 1; toggle_tunnel "${1:-}" off ;;
  "")
    if ! _require_valid_live; then exit 1; fi
    list_tunnels
    # non-TTY (piped/scripted) stays list-only, unchanged - the menu below
    # is only for a real terminal.
    if _ui_is_tty; then
      while true; do
        choice="$(ui_menu "frp - what do you want to do?" "" \
          "Toggle a tunnel on/off" \
          "Add a tunnel" \
          "Remove a tunnel" \
          "Service (start/stop/restart/enable at boot/disable)")" || break
        case "$choice" in
          "Toggle a tunnel"*) interactive_toggle ;;
          "Add a tunnel"*)    interactive_add ;;
          "Remove a tunnel"*) interactive_rm ;;
          "Service"*)         svcctl_menu "frp" frp ;;
        esac
        echo
        if ! _require_valid_live; then
          echo "the file no longer parses - fix it, then re-run srv frp" >&2
          break
        fi
        list_tunnels
      done
    fi
    ;;
  *) echo "srv frp [add|rm|on|off]" >&2; exit 1 ;;
esac
