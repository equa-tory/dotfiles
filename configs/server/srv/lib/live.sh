#!/usr/bin/env bash
# srv live [edit|undo|reset] - live-refreshing view of what's running.
# Narrow/vertical on purpose - built for half a monitor, not a wide table.
# 'q' to quit, 'e' to edit which sections are shown, 'u' to undo the last
# config change (works from inside the view, even if a section is broken).
#
# Uses tmux (one pane per section, stacked vertically) when it's installed,
# so a slow section only ever blanks its own pane instead of the whole
# view - falls back to a single redrawing loop when tmux isn't available,
# same as before. Both paths paint the whole frame in one write (cursor-home
# + clear-to-end, never a bare `clear`) so there's no visible blank flash
# while the slower sections are still gathering data.
#
# Non-TTY: prints one snapshot and exits - never loops when piped/scripted.
# Standalone: bash ~/srv/_ops/lib/live.sh [edit | undo | reset | pane <section-id>]
set -uo pipefail
OPS_DIR="${OPS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
STATE_DIR="$OPS_DIR/.state"
LIVE_CONF="$STATE_DIR/live.conf"
LIVE_PREV="$STATE_DIR/live.conf.prev"   # the config before the last change - see undo_conf
DEFAULT_CONF=$'gpu\nollama\ntop'
# a custom line's command gets this long (seconds) and this many lines - a
# slow or chatty command must never freeze or scroll the whole view.
CUSTOM_TIMEOUT=3
CUSTOM_MAX_LINES=12
# shellcheck disable=SC1091
source "$OPS_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$OPS_DIR/lib/config.sh"
srv_config

BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
RED='\033[0;31m'; RESET='\033[0m'
h() { echo -e "${BOLD}${CYAN}== $* ==${RESET}"; }

# docker's background-refresh state - see section_docker
_DOCKER_CACHE_FILE="$STATE_DIR/.docker_cache"
_DOCKER_REFRESH_PID=""

# built-in section catalog - id (used in live.conf) + label (shown when
# editing). Order here is also the order offered in the editor.
CATALOG_IDS=(gpu ollama top docker tunnels disk)
CATALOG_LABELS=(
  "GPU (util, memory, temp, power)"
  "Ollama (loaded models)"
  "Top processes (real CPU%, not ps's lifetime average)"
  "Docker (name, CPU%, ports, status)"
  "Tunnels + failed units (named)"
  "Disk usage (used / free / total)"
)

catalog_label_for() {
  local id="$1" i
  for i in "${!CATALOG_IDS[@]}"; do
    [[ "${CATALOG_IDS[$i]}" == "$id" ]] && { echo "${CATALOG_LABELS[$i]}"; return; }
  done
  echo "$id"
}
catalog_id_for_label() {
  local label="$1" i
  for i in "${!CATALOG_LABELS[@]}"; do
    [[ "${CATALOG_LABELS[$i]}" == "$label" ]] && { echo "${CATALOG_IDS[$i]}"; return; }
  done
  echo ""
}

ensure_conf() {
  mkdir -p "$STATE_DIR"
  # reseed on "missing" AND on "exists but has no real section id" (e.g.
  # unchecking everything in the editor with no custom lines used to write
  # two blank lines - see edit_config's own fix below for why that can't
  # happen going forward, this is the self-heal for a file already in that
  # state, or hand-edited empty) - a real dead end otherwise, since
  # tmux_live() refuses to open any pane with zero sections enabled and
  # there'd be nowhere left to press 'e'.
  if [[ ! -s "$LIVE_CONF" ]] || ! grep -q '[^[:space:]]' "$LIVE_CONF" 2>/dev/null; then
    printf '%s\n' "$DEFAULT_CONF" > "$LIVE_CONF"
  fi
}

# the only way live.conf gets written: config on stdin, refuses an empty one,
# writes via a temp file (a crash can't leave it half-written) and keeps the
# config it replaces as live.conf.prev so `u` / `srv live undo` can go back.
save_conf() {
  local tmp="$LIVE_CONF.tmp.$$"
  mkdir -p "$STATE_DIR"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$tmp"
    echo "refusing to save an empty live-watch config" >&2
    return 1
  fi
  if [[ -s "$LIVE_CONF" ]] && ! cmp -s "$LIVE_CONF" "$tmp"; then
    cp -f "$LIVE_CONF" "$LIVE_PREV"
  fi
  mv -f "$tmp" "$LIVE_CONF"
}

# swaps live.conf with live.conf.prev - so undoing twice is a redo.
undo_conf() {
  if [[ ! -s "$LIVE_PREV" ]]; then
    echo "nothing to undo - no earlier live-watch config saved" >&2
    return 1
  fi
  local tmp="$LIVE_CONF.swap.$$"
  cp -f "$LIVE_CONF" "$tmp" 2>/dev/null
  mv -f "$LIVE_PREV" "$LIVE_CONF"
  [[ -f "$tmp" ]] && mv -f "$tmp" "$LIVE_PREV"
  echo "restored the previous live-watch config (run undo again to redo)"
}

reset_conf() {
  printf '%s\n' "$DEFAULT_CONF" | save_conf && echo "live-watch reset to defaults (undo brings back the old one)"
}

# Full-screen / interactive programs can't be a live section: they draw their
# own screen and grab the keyboard, so the view freezes and q/e stop working.
# Prints a reason and returns 0 if the command is one of them.
_custom_blocked() {
  local cmd="$1" first rest
  first="${cmd#"${cmd%%[![:space:]]*}"}"
  [[ "$first" == sudo\ * ]] && first="${first#sudo }"
  rest="${first#* }"; first="${first%% *}"; first="${first##*/}"
  case "$first" in
    top)
      echo "'top' is full-screen - the built-in Top section already covers it"; return 0 ;;
    htop|btop|bpytop|atop|glances|nvtop|nvitop|iotop|iftop|nload|vim|vi|nano|less|more|man|mc|tmux|screen|ssh|watch)
      echo "'$first' is interactive/full-screen and would freeze the view - use a one-shot command instead"; return 0 ;;
    tail|journalctl)
      if [[ " $rest " == *" -f "* || " $rest " == *" --follow "* ]]; then
        echo "'$first -f' never finishes - drop the -f"; return 0
      fi ;;
  esac
  return 1
}

_term_cols() {
  local c
  c="$(stty size 2>/dev/null </dev/tty | awk '{print $2}')"
  echo "${c:-80}"
}

section_gpu() {
  h "GPU"
  if ! command -v nvidia-smi &>/dev/null; then
    echo -e "  ${DIM}no nvidia-smi found on this box${RESET}"
    return
  fi
  local name util mem_used mem_total temp power_draw power_limit
  while IFS=',' read -r name util mem_used mem_total temp power_draw power_limit; do
    name="${name## }"; util="${util## }"; mem_used="${mem_used## }"; mem_total="${mem_total## }"
    temp="${temp## }"; power_draw="${power_draw## }"; power_limit="${power_limit## }"
    printf "  %-16s %4s%%  %s/%sM  %s°C  %.0f/%.0fW\n" \
      "$name" "$util" "$mem_used" "$mem_total" "$temp" "$power_draw" "$power_limit"
  done < <(nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit \
             --format=csv,noheader,nounits 2>/dev/null)
}

section_ollama() {
  h "OLLAMA"
  if ! command -v ollama &>/dev/null; then
    echo -e "  ${DIM}not installed${RESET}"; return
  fi
  local out
  out="$(ollama ps 2>/dev/null | tail -n +2)"
  if [[ -z "$out" ]]; then
    echo -e "  ${DIM}no models loaded${RESET}"
  else
    echo "$out" | sed 's/^/  /'
  fi
}

# `ps`'s %CPU is a lifetime average (cputime / total elapsed time), which is
# why `ps` itself used to show up at ~1000% - it's brand new, so that ratio
# is huge and means nothing "live". `top -bn2` takes two samples 0.2s apart
# and computes a real delta between them - the second batch is the real
# number, the first is meaningless (no prior sample to diff against).
section_top() {
  h "TOP PROCESSES"
  local sampled
  sampled="$(top -bn2 -d 0.2 2>/dev/null | awk '
    /^top -/ { batch++; next }
    batch == 2 && $0 ~ /^ *[0-9]+/ { print }
  ')"
  if [[ -z "$sampled" ]]; then
    echo -e "  ${DIM}top unavailable, falling back to ps (lifetime average, not live):${RESET}"
    ps -eo comm,pcpu --sort=-pcpu --no-headers 2>/dev/null | head -5 | \
      awk '{printf "  %-16s %5s%%\n", $1, $2}'
    return
  fi
  echo "$sampled" | awk -v cores="$(nproc 2>/dev/null || echo 1)" '
    $NF == "top" || $NF == "ps" { next }
    {
      cpu = $9; cmd = $NF; extra = ""
      if (cpu + 0 >= 100) extra = sprintf("  (%.1f/%d cores)", cpu / 100, cores)
      printf "  %-16s %6.1f%%%s\n", cmd, cpu, extra
      n++
    }
    n >= 5 { exit }
  '
}

# "Up 8 hours (healthy)" -> "up 8h ✓", "Restarting (1) 11 seconds ago" ->
# "restart×1", "Exited (0) 2 hours ago" -> "exited(0) 2h" - one word instead
# of a whole sentence, so a container's row fits on one line.
_docker_status_short() {
  local raw="$1" out n unit u
  # docker's own duration humanizer rounds the 1-2x-unit range to "About a
  # minute"/"About an hour"/"About a day" instead of a number - handle
  # those before the numeric pattern below, or "Up About an hour" falls
  # through to the else branch unshortened.
  if [[ "$raw" =~ ^Up\ Less\ than\ a\ second ]]; then
    out="up <1s"
    [[ "$raw" == *"(healthy)"* ]] && out+=" ✓"
    [[ "$raw" == *"(unhealthy)"* ]] && out+=" ✗"
  elif [[ "$raw" =~ ^Up\ About\ an?\ (minute|hour|day) ]]; then
    unit="${BASH_REMATCH[1]}"
    case "$unit" in minute) u=m ;; hour) u=h ;; day) u=d ;; esac
    out="up ~1${u}"
    [[ "$raw" == *"(healthy)"* ]] && out+=" ✓"
    [[ "$raw" == *"(unhealthy)"* ]] && out+=" ✗"
  elif [[ "$raw" =~ ^Up\ ([0-9]+)\ (second|minute|hour|day|week)s? ]]; then
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in second) u=s ;; minute) u=m ;; hour) u=h ;; day) u=d ;; week) u=w ;; esac
    out="up ${n}${u}"
    [[ "$raw" == *"(healthy)"* ]] && out+=" ✓"
    [[ "$raw" == *"(unhealthy)"* ]] && out+=" ✗"
  elif [[ "$raw" =~ ^Restarting\ \(([0-9]+)\) ]]; then
    out="restart×${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^Exited\ \(([0-9]+)\)\ ([0-9]+)\ (second|minute|hour|day|week)s?\ ago ]]; then
    n="${BASH_REMATCH[2]}"; unit="${BASH_REMATCH[3]}"
    case "$unit" in second) u=s ;; minute) u=m ;; hour) u=h ;; day) u=d ;; week) u=w ;; esac
    out="exited(${BASH_REMATCH[1]}) ${n}${u}"
  elif [[ "$raw" == Created* ]]; then
    out="created"
  else
    out="$raw"
  fi
  echo "$out"
}

# host-side ports only, deduped (the 0.0.0.0/[::] pair for the same port
# collapses to one entry), sorted numerically. "host" for a host-network
# container. A published-nothing-but-exposed port (no "->" in docker's
# own .Ports string, e.g. n8n mid-bug: "5678/tcp") is flagged
# "!unpublished" instead of silently looking the same as a real port -
# that flag is exactly what would have caught the n8n bug on sight.
_docker_port_summary() {
  local ports="$1" net="$2"
  [[ "$net" == "host" ]] && { echo "host"; return; }
  [[ -z "$ports" ]] && { echo "-"; return; }
  local -a hostports=() unpub=()
  local IFS=',' p hp cp
  for p in $ports; do
    p="${p# }"
    [[ -z "$p" ]] && continue
    if [[ "$p" == *"->"* ]]; then
      hp="${p%%->*}"; hp="${hp##*:}"
      printf '%s\n' "${hostports[@]}" | grep -qxF "$hp" || hostports+=("$hp")
    else
      cp="${p%%/*}"
      printf '%s\n' "${unpub[@]}" | grep -qxF "$cp" || unpub+=("$cp")
    fi
  done
  local out=""
  (( ${#hostports[@]} > 0 )) && out="$(printf '%s\n' "${hostports[@]}" | sort -n | paste -sd, -)"
  if (( ${#unpub[@]} > 0 )); then
    local u; u="$(printf '%s\n' "${unpub[@]}" | sort -n | paste -sd, -)"
    [[ -n "$out" ]] && out+="  "
    out+="${u} !unpublished"
  fi
  [[ -z "$out" ]] && out="-"
  echo "$out"
}

section_docker() {
  h "DOCKER"
  if ! command -v docker &>/dev/null; then
    echo -e "  ${DIM}not installed${RESET}"; return
  fi
  # `docker stats --no-stream` normally takes ~2s (samples a CPU delta), but
  # under some terminal conditions it can hang far longer than that and
  # even resist `timeout` - confirmed while building this. Never run it in
  # the foreground: kick off a detached background refresh (stdin closed,
  # so it can't be waiting on anything from us either). `docker ps -a`
  # below has no such sampling delay, so it's safe to run directly every
  # frame - the refresh stays running in case a future section wants CPU%
  # again, but this section itself no longer prints it (per your ask to
  # minimize text: state + ports/host is the info that matters here).
  if [[ -z "$_DOCKER_REFRESH_PID" ]] || ! kill -0 "$_DOCKER_REFRESH_PID" 2>/dev/null; then
    (
      timeout -s KILL 5 docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' </dev/null 2>/dev/null \
        > "${_DOCKER_CACHE_FILE}.tmp"
      mv -f "${_DOCKER_CACHE_FILE}.tmp" "$_DOCKER_CACHE_FILE" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    _DOCKER_REFRESH_PID=$!
  fi

  local name status net ports short pmsg
  while IFS=$'\t' read -r name status net ports; do
    [[ -z "$name" ]] && continue
    short="$(_docker_status_short "$status")"
    pmsg="$(_docker_port_summary "$ports" "$net")"
    printf "  %-14s %-12s %s\n" "$name" "$short" "$pmsg"
  done < <(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Networks}}\t{{.Ports}}' 2>/dev/null | head -8)
}

section_tunnels() {
  h "TUNNELS"
  local frp xray
  frp="$(systemctl is-active frp 2>/dev/null || true)"; frp="${frp:-unknown}"
  xray="$(systemctl is-active xray 2>/dev/null || true)"; xray="${xray:-unknown}"
  printf "  frp: %-10s xray: %-10s\n" "$frp" "$xray"

  local -a names=()
  local u
  while IFS= read -r u; do names+=("$u"); done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sed 's/\.service$//')
  local n=${#names[@]}
  if (( n == 0 )); then
    echo -e "  ${GREEN}0 failed units${RESET}"
  else
    local shown="${names[0]}"
    (( n >= 2 )) && shown+=", ${names[1]}"
    (( n > 2 )) && shown+=" (+$((n - 2)) more)"
    echo -e "  ${RED}${n} failed: ${shown}${RESET}"
  fi
}

section_disk() {
  h "DISK"
  local d fstype tag size used avail pct
  for d in "${WATCH_DISKS[@]}"; do
    # an autofs mount (like our cifs share) shows as TWO stacked lines
    # (autofs, then the real fstype once triggered) - the last line is
    # always the one that actually answers "what kind of filesystem is
    # this really", tail -1 to skip past autofs's stacking line.
    fstype="$(findmnt -rno FSTYPE "$d" 2>/dev/null | tail -1)"
    if [[ -z "$fstype" ]]; then
      printf "  %-12s %b(unreachable)%b\n" "$d" "$DIM" "$RESET"
      continue
    fi
    tag=""
    case "$fstype" in cifs|nfs|nfs4) tag=" (remote)" ;; esac
    read -r size used avail pct _ < <(df -h --output=size,used,avail,pcent "$d" 2>/dev/null | tail -1)
    printf "  %-12s%-9s %5s used  %5s free  of %5s  (%s)\n" "$d" "$tag" "$used" "$avail" "$size" "$pct"
  done
}

# Runs one custom command safely: never through eval in this shell (an `exit`
# or `cd` in it would hit the live view itself), no stdin (it can't eat the
# q/e/u keys), hard time limit. Not in a subshell on purpose - leaves the raw
# output in _CUSTOM_OUT and the exit code in _CUSTOM_RC (124 = timed out).
_custom_exec() {
  _CUSTOM_OUT="$(TERM=dumb timeout -s KILL "$CUSTOM_TIMEOUT" bash -c "$1" </dev/null 2>&1)"
  _CUSTOM_RC=$?
  (( _CUSTOM_RC == 137 )) && _CUSTOM_RC=124
  return 0
}

# stdin -> indented, escape codes stripped, capped to CUSTOM_MAX_LINES lines
# and the terminal width.
_custom_format() {
  local cols; cols="$(_term_cols)"
  LC_ALL=C sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' | LC_ALL=C tr -d '\000-\010\013-\037' | \
    awk -v max="$CUSTOM_MAX_LINES" -v cols="$cols" '
      NR <= max { print "  " substr($0, 1, cols - 2); next }
      { extra++ }
      END { if (extra) printf "  ... (+%d more lines)\n", extra }
    '
}

section_custom() {
  local label="$1" cmd="$2" reason
  h "$label"
  if reason="$(_custom_blocked "$cmd")"; then
    echo -e "  ${RED}skipped:${RESET} ${DIM}${reason}${RESET}"
    echo -e "  ${DIM}press e to remove it, or u to undo the last change${RESET}"
    return
  fi
  _custom_exec "$cmd"
  if (( _CUSTOM_RC == 124 )); then
    echo -e "  ${RED}timed out after ${CUSTOM_TIMEOUT}s${RESET} ${DIM}- press e to remove it, or u to undo${RESET}"
  elif [[ -z "$_CUSTOM_OUT" ]]; then
    echo -e "  ${DIM}(no output$( (( _CUSTOM_RC != 0 )) && echo ", exit $_CUSTOM_RC"))${RESET}"
  else
    printf '%s\n' "$_CUSTOM_OUT" | _custom_format
    (( _CUSTOM_RC != 0 )) && echo -e "  ${DIM}(exit $_CUSTOM_RC)${RESET}"
  fi
}

render_section() {
  local id="$1"
  case "$id" in
    gpu)      section_gpu ;;
    ollama)   section_ollama ;;
    top)      section_top ;;
    docker)   section_docker ;;
    tunnels)  section_tunnels ;;
    disk)     section_disk ;;
    custom:*)
      local rest="${id#custom:}"
      section_custom "${rest%%:*}" "${rest#*:}"
      ;;
  esac
}

# plain text of the whole frame - used for the non-tty snapshot and as the
# thing paint() wraps in cursor-home/clear-to-end escapes.
render_frame() {
  echo -e "${BOLD}live${RESET}  ${DIM}(q quit, e edit, u undo last edit)${RESET}"
  echo
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    render_section "$id"
  done < "$LIVE_CONF"
}

# writes a whole frame in one shot - cursor to top-left, the frame's text,
# then clear-to-end-of-screen - instead of `clear` (blank the whole screen)
# then redrawing section by section, which is what used to cause a visible
# flash on every refresh while the slower sections were still gathering data.
paint() {
  local text; text="$(render_frame)"
  printf '\033[H%s\033[J' "$text"
}

# ui_multi checkboxes over the built-in catalog (pre-checked from the
# current config), then loop offering to add/remove custom command lines.
# Nothing is written until the very end, and q/Esc anywhere before that
# leaves the saved config untouched. Writes live.conf via save_conf (keeps
# the old one for undo): built-ins first (catalog order), custom lines after,
# in the order they were added.
edit_config() {
  ensure_conf
  if ! _ui_is_tty; then
    echo "srv live edit needs an interactive terminal" >&2
    return 1
  fi

  local -a enabled_ids=() custom_lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == custom:* ]]; then
      custom_lines+=("$line")
    else
      enabled_ids+=("$line")
    fi
  done < "$LIVE_CONF"

  local preselected="" id
  for id in "${enabled_ids[@]}"; do
    preselected+="$(catalog_label_for "$id")"$'\n'
  done

  # $(...) rather than mapfile < <(...) so the exit code survives: 2 means
  # q/Esc (cancel - keep everything as it was), 1 just means none ticked.
  local picked rc
  picked="$(ui_multi "which built-in sections?" "$preselected" "${CATALOG_LABELS[@]}")"
  rc=$?
  if (( rc == 2 )); then
    echo -e "${DIM}cancelled - nothing changed${RESET}"
    return 0
  fi
  local -a new_ids=()
  local label
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    id="$(catalog_id_for_label "$label")"
    [[ -n "$id" ]] && new_ids+=("$id")
  done <<< "$picked"

  echo -e "${DIM}custom lines: run any one-line shell command as its own section${RESET}"
  echo -e "${DIM}(one-shot commands only - no htop/top/watch/tail -f; ${CUSTOM_TIMEOUT}s limit, ${CUSTOM_MAX_LINES} lines shown)${RESET}"
  local cl rest
  while (( ${#custom_lines[@]} > 0 )); do
    echo "current custom lines:"
    for cl in "${custom_lines[@]}"; do
      rest="${cl#custom:}"
      echo "  - ${rest%%:*}: ${rest#*:}"
    done
    ui_confirm "remove one?" || break
    local -a display=()
    for cl in "${custom_lines[@]}"; do
      rest="${cl#custom:}"
      display+=("${rest%%:*}")
    done
    local to_remove
    to_remove="$(ui_menu "remove which?" "" "${display[@]}")" || continue
    local -a kept=()
    local removed=0
    for cl in "${custom_lines[@]}"; do
      rest="${cl#custom:}"
      if (( ! removed )) && [[ "${rest%%:*}" == "$to_remove" ]]; then
        removed=1
        continue
      fi
      kept+=("$cl")
    done
    custom_lines=("${kept[@]}")
  done
  while ui_confirm "add a custom line?"; do
    local clabel ccmd reason keep
    read -r -p "label: " clabel
    read -r -p "command: " ccmd
    clabel="${clabel//:/-}"   # ':' separates the fields in live.conf
    clabel="${clabel#"${clabel%%[![:space:]]*}"}"; clabel="${clabel%"${clabel##*[![:space:]]}"}"
    if [[ -z "$clabel" || -z "${ccmd//[[:space:]]/}" ]]; then
      echo -e "${DIM}need both a label and a command - skipped${RESET}"
      continue
    fi
    if reason="$(_custom_blocked "$ccmd")"; then
      echo -e "${RED}not added:${RESET} $reason"
      continue
    fi
    # try it once before saving, so a typo shows up here and not as a
    # broken pane later.
    _custom_exec "$ccmd"
    echo -e "${DIM}test run:${RESET}"
    if (( _CUSTOM_RC == 124 )); then
      echo -e "  ${RED}timed out after ${CUSTOM_TIMEOUT}s${RESET}"
    elif [[ -z "$_CUSTOM_OUT" ]]; then
      echo -e "  ${DIM}(no output, exit $_CUSTOM_RC)${RESET}"
    else
      printf '%s\n' "$_CUSTOM_OUT" | _custom_format
      (( _CUSTOM_RC != 0 )) && echo -e "  ${RED}(exit $_CUSTOM_RC)${RESET}"
    fi
    if (( _CUSTOM_RC != 0 )); then
      ui_confirm "it didn't run cleanly - add it anyway?" || continue
    else
      ui_confirm "looks right - add it?" || continue
    fi
    custom_lines+=("custom:${clabel}:${ccmd}")
  done

  # nothing enabled at all would leave the view with no pane to press 'e' in
  # (save_conf refuses that too) - keep whatever was on disk instead.
  if [[ ${#new_ids[@]} -eq 0 && ${#custom_lines[@]} -eq 0 ]]; then
    echo -e "${DIM}nothing picked - keeping your current configuration${RESET}"
    return 0
  fi

  {
    (( ${#new_ids[@]} > 0 )) && printf '%s\n' "${new_ids[@]}"
    (( ${#custom_lines[@]} > 0 )) && printf '%s\n' "${custom_lines[@]}"
  } | save_conf && echo -e "${DIM}saved - press u in the live view to undo this${RESET}"
}

# --- tmux mode: one pane per enabled section, stacked vertically ---

# runs inside one tmux pane (or, without tmux, is never called - the
# fallback loop below calls paint() directly instead). Takes one or more
# section ids - more than one means this pane is showing several sections
# grouped together (see tmux_live's capacity guard), stacked with a blank
# line between them. Its own 1s-timeout key read, same q/e handling as the
# fallback loop, so any pane can be the one you press q or e in.
pane_loop() {
  local -a ids=("$@")
  trap '_ui_cursor_show' EXIT INT TERM
  _ui_cursor_hide
  local key text id
  while true; do
    text=""
    for id in "${ids[@]}"; do
      text+="$(render_section "$id")"$'\n'
    done
    printf '\033[H%s\033[J' "$text"
    IFS= read -rsn1 -t 1 key || key=""
    case "$key" in
      q|Q)
        tmux kill-session -t srv-live 2>/dev/null
        break
        ;;
      e|E)
        _ui_cursor_show
        printf '\033[H\033[J'
        edit_config
        # the section list may have changed - the only clean way to
        # reshape a tmux layout is to rebuild it, so drop a flag and let
        # the outer tmux_live() (still waiting on `tmux attach`) relaunch.
        touch "$STATE_DIR/.live_restart"
        tmux kill-session -t srv-live 2>/dev/null
        break
        ;;
      u|U)
        # panic button: back to the config before the last edit, then
        # rebuild the layout the same way 'e' does.
        undo_conf >/dev/null 2>&1
        touch "$STATE_DIR/.live_restart"
        tmux kill-session -t srv-live 2>/dev/null
        break
        ;;
    esac
  done
}

tmux_live() {
  local session="srv-live"
  tmux kill-session -t "$session" 2>/dev/null || true

  local -a ids=()
  local line
  while IFS= read -r line; do [[ -n "$line" ]] && ids+=("$line"); done < "$LIVE_CONF"
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "no sections enabled - run: srv live edit" >&2
    return 1
  fi

  # how many panes actually fit: each needs a title line (pane-border-status
  # top) plus at least 2 lines of content, so 3 total. `split-window -v`
  # splits whatever pane is CURRENTLY ACTIVE, which is always the one just
  # created - so heights used to go 1/2, 1/4, 1/8, 1/16 and the 5th split
  # failed silently with nothing telling you why, capping this at 4 panes no
  # matter how many sections were enabled. Re-equalising after every split
  # (below) fixes that; this guard is the other half - past what actually
  # fits, sections group into the last pane instead of a split failing.
  local term_rows
  term_rows="$(stty size < /dev/tty 2>/dev/null | awk '{print $1}')"
  term_rows="${term_rows:-24}"
  local max_panes=$(( term_rows / 3 ))
  (( max_panes < 1 )) && max_panes=1

  # Groups are joined with \x1f (ASCII unit separator), not a plain space -
  # a custom line's id is "custom:<label>:<command>" and the command
  # itself almost always contains spaces ("ollama list", "docker ps"), so
  # splitting groups apart on space later would tear a single id in two.
  # \x1f can't appear in anything typed at a `read -r -p` prompt, so it's
  # safe as a delimiter that never collides with real id content.
  local -a pane_groups=()
  if (( ${#ids[@]} <= max_panes )); then
    pane_groups=("${ids[@]}")
  else
    local i
    for ((i = 0; i < max_panes - 1; i++)); do pane_groups+=("${ids[$i]}"); done
    local overflow; overflow="$(printf '%s\x1f' "${ids[@]:$((max_panes - 1))}")"
    overflow="${overflow%$'\x1f'}"
    pane_groups+=("$overflow")
    local overflow_display="${ids[*]:$((max_panes - 1))}"
    echo "srv live: ${#ids[@]} sections but only $max_panes panes fit at ${term_rows} rows -" \
         "grouped into the last pane: ${overflow_display// /, }" >&2
  fi

  local self grp id id_args label pane_id first=1
  self="$(printf '%q' "$(readlink -f "${BASH_SOURCE[0]}")")"
  for grp in "${pane_groups[@]}"; do
    local -a group_ids=()
    if [[ "$grp" == *$'\x1f'* ]]; then
      IFS=$'\x1f' read -ra group_ids <<<"$grp"
    else
      group_ids=("$grp")
    fi
    id_args=""
    for id in "${group_ids[@]}"; do
      [[ -z "$id" ]] && continue
      id_args+="$(printf '%q ' "$id")"
    done
    if (( ${#group_ids[@]} > 1 )); then
      label="combined (${#group_ids[@]})"
    elif [[ "$grp" == custom:* ]]; then
      label="${grp#custom:}"; label="${label%%:*}"
    else
      label="$(catalog_label_for "$grp")"
    fi
    if (( first )); then
      pane_id="$(tmux new-session -d -s "$session" -P -F '#{pane_id}' "bash $self pane $id_args")"
      first=0
    else
      pane_id="$(tmux split-window -v -t "$session" -P -F '#{pane_id}' "bash $self pane $id_args")"
    fi
    tmux select-pane -t "$pane_id" -T "$label" 2>/dev/null
    # re-equalise after EVERY split, not once at the end - otherwise the
    # next split still divides an already-shrunk pane instead of a fair
    # share of the window.
    tmux select-layout -t "$session" even-vertical
  done
  tmux set-option -t "$session" pane-border-status top 2>/dev/null
  tmux set-option -t "$session" status off 2>/dev/null
  tmux attach-session -t "$session"

  if [[ -f "$STATE_DIR/.live_restart" ]]; then
    rm -f "$STATE_DIR/.live_restart"
    tmux_live
  fi
}

if [[ "${1:-}" == "pane" ]]; then
  ensure_conf
  shift
  pane_loop "$@"
  exit 0
fi

if [[ "${1:-}" == "edit" ]]; then
  edit_config
  exit $?
fi

if [[ "${1:-}" == "undo" ]]; then
  ensure_conf
  undo_conf
  exit $?
fi

if [[ "${1:-}" == "reset" ]]; then
  ensure_conf
  reset_conf
  exit $?
fi

ensure_conf

if ! _ui_is_tty; then
  render_frame
  exit 0
fi

if command -v tmux &>/dev/null; then
  tmux_live
  exit 0
fi

# no tmux - single-process loop, same paint() as each tmux pane uses.
trap '_ui_cursor_show; printf "\n" >&2' EXIT INT TERM
_ui_cursor_hide
key=""
while true; do
  paint
  IFS= read -rsn1 -t 1 key || key=""
  case "$key" in
    q|Q) break ;;
    e|E)
      _ui_cursor_show
      printf '\033[H\033[J'
      edit_config
      _ui_cursor_hide
      ;;
    u|U) undo_conf >/dev/null 2>&1 ;;
  esac
done
