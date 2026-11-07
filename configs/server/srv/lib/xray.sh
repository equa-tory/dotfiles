#!/usr/bin/env bash
# srv xray [import "vless://..."] - show/replace the one outbound in
# /usr/local/etc/xray/config.json. Only outbounds[0] (or, once automatic
# failover is on, a set of tagged outbounds) is ever touched - both
# inbounds (socks :1080, http :1081) are left exactly as they are, because
# frp's transport.proxyURL depends on socks:1080.
#
# Every outbound this tool builds gets mux enabled (concurrency 8) -
# see parse_vless(). Not something the vless:// link itself carries, so
# it's a fixed default applied here rather than read from anywhere.
#
# Also keeps a saved list of servers (.state/xray-servers.json, machine-
# local, never committed - these are your VPS proxy credentials) so you
# can paste a subscription URL once and switch between servers without
# re-pasting a link every time, or turn on automatic failover (xray's own
# observatory + leastPing balancer) across whichever servers are saved.
# Standalone: bash ~/srv/_ops/lib/xray.sh [import "vless://..."]
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

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
SERVERS_FILE="${SERVERS_FILE:-$OPS_DIR/.state/xray-servers.json}"

# _xray_py SCRIPT [ARGS...] - runs a small python3 program against the
# config, keeps all JSON parsing/writing in one language instead of sed.
_xray_py() {
  python3 - "$@"
}

status() {
  h "XRAY"
  if [[ ! -f "$XRAY_CONF" ]]; then
    echo "no config at $XRAY_CONF"
    return 1
  fi
  local active enabled
  active="$(systemctl is-active xray 2>/dev/null || true)"
  enabled="$(systemctl is-enabled xray 2>/dev/null || true)"
  if [[ "$active" == active ]]; then echo -e "  service: ${GREEN}active${RESET}"; else echo -e "  service: ${RED}${active:-unknown}${RESET}"; fi
  if [[ "$enabled" == enabled ]]; then
    echo -e "  boot:    ${GREEN}enabled${RESET}"
  else
    echo -e "  boot:    ${YELLOW}${enabled:-disabled}${RESET} - won't come back after a reboot (sudo systemctl enable xray)"
  fi
  _xray_py "$XRAY_CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
obs = cfg.get("outbounds") or [{}]
def mux_str(ob):
    m = ob.get("mux") or {}
    if not m.get("enabled"):
        return "off"
    return f"on (concurrency {m.get('concurrency','?')})"

if len(obs) > 1:
    print(f"  outbounds: {len(obs)} (automatic failover on)")
    for ob in obs:
        vnext = ((ob.get("settings") or {}).get("vnext") or [{}])[0]
        print(f"    {ob.get('tag','?'):<10} {ob.get('protocol','?')} -> {vnext.get('address','?')}:{vnext.get('port','?')}  mux: {mux_str(ob)}")
else:
    ob = obs[0]
    vnext = ((ob.get("settings") or {}).get("vnext") or [{}])[0]
    rs = ((ob.get("streamSettings") or {}).get("realitySettings") or {})
    print(f"  outbound: {ob.get('protocol','?')} -> {vnext.get('address','?')}:{vnext.get('port','?')}")
    if rs:
        print(f"  reality:  sni={rs.get('serverName','?')} fp={rs.get('fingerprint','?')}")
    print(f"  mux:      {mux_str(ob)}")
for ib in cfg.get("inbounds", []):
    print(f"  inbound:  {ib.get('protocol','?')} on {ib.get('listen','?')}:{ib.get('port','?')}")
PY
}

# parses a vless:// URI into a JSON outbound block on stdout - never touches
# the live config, just prints. Kept separate from write_config so import()
# can diff before asking to write anything.
parse_vless() {
  local link="$1"
  _xray_py "$link" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote

link = sys.argv[1]
if not link.startswith("vless://"):
    print("not a vless:// link", file=sys.stderr); sys.exit(1)

u = urlparse(link)
uuid = u.username
host = u.hostname
port = u.port
if not (uuid and host and port):
    print("couldn't parse uuid/host/port out of that link", file=sys.stderr); sys.exit(1)
q = {k: v[0] for k, v in parse_qs(u.query).items()}

outbound = {
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": host,
            "port": port,
            "users": [{"id": uuid, "encryption": q.get("encryption", "none")}],
        }]
    },
    "streamSettings": {
        "network": q.get("type", "tcp"),
        "security": q.get("security", "reality"),
    },
}
if outbound["streamSettings"]["security"] == "reality":
    outbound["streamSettings"]["realitySettings"] = {
        "serverName": q.get("sni", ""),
        "fingerprint": q.get("fp", "chrome"),
        "publicKey": q.get("pbk", ""),
        "shortId": q.get("sid", ""),
        "spiderX": q.get("spx", ""),
    }
# mux multiplexes multiple app connections over fewer proxy connections -
# not carried in the vless:// URI itself, so this is a fixed default
# applied to every outbound this tool builds (single link, subscription
# switch, or each leg of automatic failover - they all go through here).
outbound["mux"] = {"enabled": True, "concurrency": 8}
name = unquote(u.fragment) if u.fragment else ""
print(json.dumps(outbound))
if name:
    print(f"# {name}", file=sys.stderr)
PY
}

# tags a JSON outbound blob with the given tag (used only for automatic
# failover, where outbounds[] has more than one entry and xray's routing
# needs to address each by name).
_tag_outbound() {
  python3 -c "import json,sys; ob=json.loads(sys.argv[1]); ob['tag']=sys.argv[2]; print(json.dumps(ob))" "$1" "$2"
}

_current_vless_hostport() {
  [[ -f "$XRAY_CONF" ]] || return 1
  _xray_py "$XRAY_CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
obs = cfg.get("outbounds") or [{}]
hps = []
for ob in obs:
    vnext = ((ob.get("settings") or {}).get("vnext") or [{}])[0]
    addr, port = vnext.get("address"), vnext.get("port")
    if addr and port:
        hps.append(f"{addr}:{port}")
print(",".join(hps))
PY
}

_failover_enabled() {
  [[ -f "$XRAY_CONF" ]] || return 1
  _xray_py "$XRAY_CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
sys.exit(0 if "observatory" in cfg else 1)
PY
}

# --- saved server list (.state/xray-servers.json, gitignored, machine-
# local - see the file header for why these never go in the git repo) ---

_servers_py() {
  local cmd="$1"; shift
  python3 - "$SERVERS_FILE" "$cmd" "$@" <<'PY'
import json, sys, os, datetime
from urllib.parse import urlparse, unquote

path, cmd = sys.argv[1], sys.argv[2]
args = sys.argv[3:]

def load():
    if not os.path.exists(path):
        return []
    try:
        return json.load(open(path))
    except Exception:
        return []

def save(servers):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(servers, open(path, "w"), indent=2)

def link_uuid(link):
    if not link.startswith("vless://"):
        return None
    return urlparse(link).username

def link_hostport(link):
    # identity of a NODE, not of your account - a subscription commonly
    # reuses the same client UUID across every node it lists, so UUID
    # alone can't tell two different servers apart. host:port can.
    if not link.startswith("vless://"):
        return None
    u = urlparse(link)
    if not (u.hostname and u.port):
        return None
    return f"{u.hostname}:{u.port}"

def link_label(link):
    u = urlparse(link)
    if u.fragment:
        return unquote(u.fragment)
    return f"{u.hostname}:{u.port}"

servers = load()

if cmd == "list":
    cur = set((args[0] if args else "").split(",")) if args and args[0] else set()
    for s in servers:
        mark = "*" if link_hostport(s["link"]) in cur else " "
        print(f"{mark}\t{s['label']}\t{s.get('added','?')}\t{s['link']}")

elif cmd == "add":
    link = args[0]
    hp = link_hostport(link)
    if hp is None:
        print("not a vless:// link", file=sys.stderr); sys.exit(1)
    for s in servers:
        if link_hostport(s["link"]) == hp:
            print(f"already saved as '{s['label']}'"); sys.exit(0)
    label = link_label(link)
    base, n, existing = label, 2, {s["label"] for s in servers}
    while label in existing:
        label = f"{base} ({n})"; n += 1
    servers.append({"label": label, "link": link, "added": datetime.date.today().isoformat()})
    save(servers)
    print(f"added '{label}'")

elif cmd == "rm":
    label = args[0]
    before = len(servers)
    servers = [s for s in servers if s["label"] != label]
    save(servers)
    print("removed" if len(servers) < before else "no such server", file=sys.stderr if len(servers) == before else sys.stdout)

elif cmd == "get":
    label = args[0]
    for s in servers:
        if s["label"] == label:
            print(s["link"]); sys.exit(0)
    sys.exit(2)

else:
    print(f"unknown internal command {cmd}", file=sys.stderr); sys.exit(1)
PY
}

list_servers() {
  h "SAVED XRAY SERVERS"
  local cur; cur="$(_current_vless_hostport 2>/dev/null || true)"
  local -a rows=()
  mapfile -t rows < <(_servers_py list "$cur")
  if (( ${#rows[@]} == 0 )); then
    echo "  none saved yet - paste a link or a subscription URL"
    return
  fi
  printf '%s\n' "${rows[@]}" | awk -F'\t' '{printf "  %s %-24s added %s\n", $1, $2, $3}'
}

# fetches a subscription URL and saves every vless:// link it finds.
# Deliberately bypasses this box's own xray proxy env vars - you may be
# fetching a fresh list specifically because the current proxy is the one
# that's broken, so routing this through it would be circular.
fetch_subscription() {
  local url="${1:-}"
  [[ -z "$url" ]] && { echo "usage: paste a subscription URL" >&2; return 1; }

  local raw errfile; errfile="$(mktemp)"
  raw="$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    curl -fsSL --max-time 10 "$url" 2>"$errfile")"
  local rc=$?
  if (( rc != 0 )); then
    echo -e "${RED}couldn't fetch that URL${RESET}" >&2
    cat "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"

  # subscriptions are usually base64 of a newline-separated link list;
  # fall back to treating the response as plain text if that doesn't
  # decode to anything vless-shaped.
  local decoded
  decoded="$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)"
  if [[ -z "$decoded" ]] || ! grep -q '^vless://' <<<"$decoded"; then
    decoded="$raw"
  fi

  local -a links=()
  mapfile -t links < <(grep -o "vless://[^\" '<>]*" <<<"$decoded" || true)
  if (( ${#links[@]} == 0 )); then
    echo -e "${YELLOW}no vless:// links found in that response${RESET}" >&2
    return 1
  fi

  h "importing from subscription"
  local link out added=0
  for link in "${links[@]}"; do
    out="$(_servers_py add "$link")"
    [[ "$out" == added* ]] && ((added++)) || true
    echo "  $out"
  done
  echo -e "  ${GREEN}✓${RESET} $added new server(s) saved (${#links[@]} found)"
}

# --- writing the live config: shared by import_link and the
# enable/disable-failover paths below, so there's exactly one place that
# does the backup-history + restart + re-capture dance. ---
_install_new_config() {
  local tmp="$1"

  local bak; bak="${XRAY_CONF}.$(date +%Y-%m-%d_%H%M).bak"
  sudo cp "$XRAY_CONF" "$bak"
  sudo cp "$tmp" "$XRAY_CONF"
  rm -f "$tmp"
  echo -e "  ${GREEN}✓${RESET} previous config kept at $bak"

  # timestamped backup history, not a single overwritten .prev - keeps the
  # last 5 so you can go back further than just the most recent change.
  local -a old_baks
  mapfile -t old_baks < <(ls -1t "${XRAY_CONF}".*.bak 2>/dev/null | tail -n +6)
  if (( ${#old_baks[@]} > 0 )); then
    sudo rm -f -- "${old_baks[@]}"
    echo -e "  ${DIM}trimmed to the newest 5 backups${RESET}"
  fi

  if sudo systemctl restart xray; then
    echo -e "  ${GREEN}✓${RESET} xray restarted"
  else
    echo -e "  ${RED}restart failed${RESET} - check: sudo journalctl -u xray -n 30" >&2
    return 1
  fi

  # keep the git-tracked copy in sync with placeholders, same as any other
  # secret - reuses conf.sh's existing secretize(), nothing new to maintain.
  if [[ -x "$OPS_DIR/lib/conf.sh" || -f "$OPS_DIR/lib/conf.sh" ]]; then
    echo
    bash "$OPS_DIR/lib/conf.sh" capture >/dev/null 2>&1 && \
      echo -e "  ${DIM}conf/xray/config.json re-captured with the new (redacted) config - run 'srv push' when ready${RESET}"
  fi
}

import_link() {
  local link="${1:-}"
  [[ -z "$link" ]] && { echo "usage: srv xray import \"vless://...\"" >&2; return 1; }
  [[ -f "$XRAY_CONF" ]] || { echo "no config at $XRAY_CONF - can't import into nothing" >&2; return 1; }

  local new_outbound
  new_outbound="$(parse_vless "$link")" || return 1

  local tmp; tmp="$(mktemp --suffix=.json)"
  _xray_py "$XRAY_CONF" "$new_outbound" <<'PY' > "$tmp"
import json, sys
cfg = json.load(open(sys.argv[1]))
new_ob = json.loads(sys.argv[2])
cfg["outbounds"] = [new_ob]
print(json.dumps(cfg, indent=2))
PY

  h "checking the new config"
  # xray needs a .json-suffixed path to auto-detect format, and the check is
  # `run -test -c`, not a top-level -test flag (verified against this box's
  # actual xray binary - `xray -test -config` silently fails to read at all).
  if ! "$XRAY_BIN" run -test -c "$tmp" >/tmp/xray-test.$$ 2>&1; then
    echo -e "${RED}xray rejects this config - not touching anything${RESET}"
    cat /tmp/xray-test.$$ >&2
    rm -f "$tmp" /tmp/xray-test.$$
    return 1
  fi
  rm -f /tmp/xray-test.$$
  echo -e "  ${GREEN}✓${RESET} valid config"

  h "what changes"
  echo "  old outbound(s):"; status 2>/dev/null | grep '  outbound' | sed 's/^/  /'
  echo "  new outbound:"
  _xray_py "$new_outbound" <<'PY'
import json, sys
ob = json.loads(sys.argv[1])
vnext = ob["settings"]["vnext"][0]
rs = ob.get("streamSettings", {}).get("realitySettings", {})
print(f"    {ob['protocol']} -> {vnext['address']}:{vnext['port']}")
if rs:
    print(f"    reality: sni={rs.get('serverName')} pbk={rs.get('publicKey','')[:8]}... sid={rs.get('shortId','')}")
mux = ob.get("mux") or {}
print(f"    mux: {'on (concurrency ' + str(mux.get('concurrency')) + ')' if mux.get('enabled') else 'off'}")
PY

  echo -e "  ${DIM}writing and restarting xray (inbounds untouched - frp keeps working)${RESET}"
  _install_new_config "$tmp"
}

# --- automatic failover: multiple tagged outbounds + observatory +
# leastPing balancer, over whatever's currently saved. Same validate/diff/
# backup/restart path as import_link, via _install_new_config. ---

enable_failover() {
  local -a rows=()
  mapfile -t rows < <(_servers_py list)
  if (( ${#rows[@]} < 2 )); then
    echo -e "${YELLOW}need at least 2 saved servers for automatic failover - only ${#rows[@]} saved right now${RESET}"
    return 1
  fi

  # zero-padded so no tag is a prefix/substring of another (xray's
  # subjectSelector and routing selector both match by prefix) - without
  # this, "proxy-1" would also match "proxy-10", "proxy-11", ... once
  # there are 10+ saved servers.
  local width=${#rows[@]}; width=${#width}
  local -a tagged=()
  local i=1 row label link ob_json tag
  for row in "${rows[@]}"; do
    label="$(cut -f2 <<<"$row")"; link="$(cut -f4 <<<"$row")"
    ob_json="$(parse_vless "$link" 2>/dev/null)" || { echo "  skipping '$label' - couldn't parse" >&2; continue; }
    tag="$(printf 'proxy-%0*d' "$width" "$i")"
    tagged+=("$(_tag_outbound "$ob_json" "$tag")")
    ((i++)) || true
  done
  if (( ${#tagged[@]} < 2 )); then
    echo -e "${RED}fewer than 2 links parsed cleanly - not enabling${RESET}" >&2
    return 1
  fi

  local obs_json
  obs_json="$(printf '%s\n' "${tagged[@]}" | python3 -c "import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin]))")"

  local tmp; tmp="$(mktemp --suffix=.json)"
  _xray_py "$XRAY_CONF" "$obs_json" <<'PY' > "$tmp"
import json, sys
cfg = json.load(open(sys.argv[1]))
new_obs = json.loads(sys.argv[2])
tags = [o["tag"] for o in new_obs]
cfg["outbounds"] = new_obs
# xray's own compiled struct tags say "subjectSelector", not
# "subscribeList" - verified against the actual binary on this box
# (`strings` on the xray-core observatory.Config struct).
cfg["observatory"] = {"subjectSelector": tags, "probeInterval": "10m"}
routing = cfg.get("routing", {})
routing["balancers"] = [b for b in routing.get("balancers", []) if b.get("tag") != "auto-balancer"]
routing["balancers"].append({"tag": "auto-balancer", "selector": tags, "strategy": {"type": "leastPing"}})
rules = [r for r in routing.get("rules", []) if r.get("balancerTag") != "auto-balancer"]
rules.append({"type": "field", "network": "tcp,udp", "balancerTag": "auto-balancer"})
routing["rules"] = rules
cfg["routing"] = routing
print(json.dumps(cfg, indent=2))
PY

  h "checking the automatic-failover config"
  if ! "$XRAY_BIN" run -test -c "$tmp" >/tmp/xray-test.$$ 2>&1; then
    echo -e "${RED}xray rejects this config - not touching anything${RESET}"
    cat /tmp/xray-test.$$ >&2
    rm -f "$tmp" /tmp/xray-test.$$
    return 1
  fi
  rm -f /tmp/xray-test.$$
  echo -e "  ${GREEN}✓${RESET} valid config, ${#tagged[@]} servers, leastPing balancer"
  echo -e "  ${DIM}writing and restarting xray - switching to automatic failover across ${#tagged[@]} servers${RESET}"
  _install_new_config "$tmp"
}

disable_failover() {
  [[ -f "$XRAY_CONF" ]] || { echo "no config at $XRAY_CONF" >&2; return 1; }

  local tmp; tmp="$(mktemp --suffix=.json)"
  _xray_py "$XRAY_CONF" <<'PY' > "$tmp"
import json, sys
cfg = json.load(open(sys.argv[1]))
obs = cfg.get("outbounds") or []
if not obs:
    print("no outbound to keep", file=sys.stderr); sys.exit(1)
keep = dict(obs[0])
keep.pop("tag", None)
cfg["outbounds"] = [keep]
cfg.pop("observatory", None)
routing = cfg.get("routing")
if routing:
    routing["balancers"] = [b for b in routing.get("balancers", []) if b.get("tag") != "auto-balancer"]
    routing["rules"] = [r for r in routing.get("rules", []) if r.get("balancerTag") != "auto-balancer"]
    if routing["balancers"] or routing["rules"]:
        cfg["routing"] = routing
    else:
        cfg.pop("routing", None)
print(json.dumps(cfg, indent=2))
PY

  h "checking the single-outbound config"
  if ! "$XRAY_BIN" run -test -c "$tmp" >/tmp/xray-test.$$ 2>&1; then
    echo -e "${RED}xray rejects this config - not touching anything${RESET}"
    cat /tmp/xray-test.$$ >&2
    rm -f "$tmp" /tmp/xray-test.$$
    return 1
  fi
  rm -f /tmp/xray-test.$$
  echo -e "  ${GREEN}✓${RESET} valid config"
  echo -e "  ${DIM}writing and restarting xray - back to a single outbound, no more automatic failover${RESET}"
  _install_new_config "$tmp"
}

# --- interactive wrappers (TTY only) ---

interactive_add_subscription() {
  local url
  read -r -p "subscription URL: " url
  [[ -z "$url" ]] && { echo "cancelled"; return; }
  fetch_subscription "$url"
}

interactive_switch_server() {
  local -a rows=()
  mapfile -t rows < <(_servers_py list)
  if (( ${#rows[@]} == 0 )); then
    echo "no saved servers yet - paste a link or a subscription first"
    return
  fi
  local -a labels=()
  mapfile -t labels < <(printf '%s\n' "${rows[@]}" | cut -f2)
  local pick; pick="$(ui_menu "switch to which server?" "" "${labels[@]}")" || return
  local link; link="$(_servers_py get "$pick")" || { echo "couldn't find that server" >&2; return 1; }
  import_link "$link"
}

case "${1:-}" in
  import) shift; import_link "${1:-}" ;;
  "")
    status
    # non-TTY (piped/scripted) stays status-only, unchanged - the menu
    # below is only for a real terminal.
    if _ui_is_tty; then
      while true; do
        list_servers
        fo_label="Automatic failover: off"
        _failover_enabled && fo_label="Automatic failover: on"
        choice="$(ui_menu "xray - what do you want to do?" "" \
          "Paste a vless:// link - keeps the old config, writes a new one" \
          "Paste a subscription URL - saves every vless:// link it finds" \
          "Switch server - pick from your saved list" \
          "$fo_label" \
          "Service (start/stop/restart/enable at boot/disable)")" || break
        case "$choice" in
          "Paste a vless:// link"*)
            read -r -p "paste the vless:// link: " link
            if [[ -n "$link" ]]; then
              _servers_py add "$link" >/dev/null 2>&1 || true
              import_link "$link"
            fi
            ;;
          "Paste a subscription URL"*) interactive_add_subscription ;;
          "Switch server"*)            interactive_switch_server ;;
          "Automatic failover"*)
            if _failover_enabled; then disable_failover; else enable_failover; fi
            ;;
          "Service"*) svcctl_menu "xray" xray ;;
        esac
        echo
        status
      done
    fi
    ;;
  *)      echo "srv xray [import \"vless://...\"]" >&2; exit 1 ;;
esac
