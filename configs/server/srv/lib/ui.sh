#!/usr/bin/env bash
# lib/ui.sh - shared arrow-key menu widgets. Pure bash, no dependencies (no
# fzf, no whiptail) - srv is a disaster-recovery tool and has to work on a
# box that isn't fully set up yet.
#
# Sourced by other lib/*.sh files, not meant to run standalone.
#
#   choice=$(ui_menu "pick one:" "$default" "a" "b" "c")
#     ↑↓ or j/k move, enter picks. Digits 1-9 next to the first 9 VISIBLE
#     rows jump-and-select immediately - after filtering, the numbers
#     re-attach to whatever's still on screen, so a filtered list is always
#     number-pickable. Type any other letter to filter the list live
#     (archinstall-style: matches from the start of the option text,
#     case-insensitive); backspace removes a character, Esc clears the
#     filter (or cancels if it's already empty). q cancels only while the
#     filter is empty - otherwise it's just a "q" typed into the filter.
#     $default is an option's exact text to start the cursor on, or "" for
#     the top.
#   mapfile -t picked < <(ui_multi "pick some:" "$preselected" "a" "b" "c")
#     same navigation as ui_menu, plus: space toggles the highlighted row,
#     digits 1-9 toggle that row (don't confirm), a/n select all/none -
#     a/n and j/k only do that while the filter is empty, same reasoning as
#     q above. Enter confirms (exit 1 if nothing ticked); q/Esc cancels
#     (exit 2, so callers can tell "cancelled" from "ticked nothing").
#     $preselected is a newline-separated string
#     of option texts to start pre-checked, or "" for none.
#   ui_confirm "really do this?"      # single keypress, y/n, returns 0/1
#   ui_clear                          # clear screen, TTY-safe
#
# Every widget prints a one-line footer reminding you which keys do what -
# this file is the one place that has to get "how do I get out of this"
# right, so it's never a guess.
#
# All widgets fall back to a plain numbered prompt when stdout/stdin isn't a
# real terminal (piped, cron, TERM=dumb) - never emit raw escape codes there,
# and no filtering there either (nothing to redraw against). Menu chrome
# goes to stderr; only the actual answer goes to stdout, so
# `choice=$(ui_menu ...)` composes normally in a pipeline.
set -uo pipefail

# Clears the screen for the interactive menu flow only - callers should never
# use this around a plain typed command's output (srv frp, srv ports 8888,
# anything that might be piped/redirected/scripted). A no-op when not a real
# terminal, so it's always safe to call unconditionally from menu code.
ui_clear() { _ui_is_tty && clear >&2; return 0; }

_UI_CYAN='\033[0;36m'; _UI_DIM='\033[2m'; _UI_RESET='\033[0m'

# Checks fd 0 (keys) and fd 2 (where the menu chrome is drawn) - NOT fd 1.
# Callers always use `choice=$(ui_menu ...)`, and command substitution always
# turns stdout into a pipe even when the real terminal is fully interactive -
# checking -t 1 here would make every real call see a "fake" non-tty and
# permanently fall back to the plain numbered prompt.
_ui_is_tty() { [[ -t 0 && -t 2 && "${TERM:-dumb}" != "dumb" ]]; }
_ui_cursor_hide() { printf '\033[?25l' >&2; }
_ui_cursor_show() { printf '\033[?25h' >&2; }

# read one keypress, expanding arrow-key escape sequences (ESC [ A / B) into
# a single 3-char token so callers can match it in one case arm.
_ui_read_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ $key == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.01 rest
    key+="$rest"
  fi
  printf '%s' "$key"
}

# moves the cursor up over $1 drawn lines and blanks each one, leaving the
# cursor back at the top of that block - shared by ui_menu/ui_multi's exit
# paths (both the "confirmed" and "cancelled" cases redraw nothing after).
_ui_clear_lines() {
  local lines="$1" i
  printf '\033[%dA' "$lines" >&2
  for ((i = 0; i < lines; i++)); do printf '\033[2K\n' >&2; done
  printf '\033[%dA' "$lines" >&2
}

# computes which indices of $1 (a nameref to an options array) match $2
# (the current filter, "" = everything) into the nameref array $3. Matches
# from the start of the option text, case-insensitive.
_ui_filter_visible() {
  local -n _fv_opts="$1"
  local filter="$2"
  local -n _fv_out="$3"
  _fv_out=()
  local i
  if [[ -z "$filter" ]]; then
    for i in "${!_fv_opts[@]}"; do _fv_out+=("$i"); done
    return 0
  fi
  local lf="${filter,,}" lo
  for i in "${!_fv_opts[@]}"; do
    lo="${_fv_opts[$i],,}"
    [[ "$lo" == "$lf"* ]] && _fv_out+=("$i")
  done
}

ui_menu() {
  local title="$1" default="$2"; shift 2
  local -a opts=("$@")
  local n=${#opts[@]}
  (( n == 0 )) && return 1

  if ! _ui_is_tty; then
    echo -e "$title" >&2
    local i
    for i in "${!opts[@]}"; do printf "  %d) %s\n" "$((i + 1))" "${opts[$i]}" >&2; done
    local reply
    read -r -p "choose [1-$n, q to cancel]: " reply
    [[ "$reply" == "q" ]] && return 1
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= n )); then
      echo "${opts[$((reply - 1))]}"; return 0
    fi
    echo "invalid choice" >&2; return 1
  fi

  local sel=0 key drawn=0 i filter=""
  if [[ -n "$default" ]]; then
    for i in "${!opts[@]}"; do [[ "${opts[$i]}" == "$default" ]] && { sel=$i; break; }; done
  fi
  trap '_ui_cursor_show; printf "\n" >&2; exit 130' INT TERM
  _ui_cursor_hide
  local -a visible
  local total_lines=$((n + 2))
  while true; do
    _ui_filter_visible opts "$filter" visible
    local vn=${#visible[@]}
    if (( vn == 0 )); then sel=0; elif (( sel >= vn )); then sel=$((vn - 1)); fi

    (( drawn )) && printf '\033[%dA' "$total_lines" >&2
    if [[ -n "$filter" ]]; then
      printf '\033[2K%b  %bfilter: %s%b\n' "$title" "$_UI_DIM" "$filter" "$_UI_RESET" >&2
    else
      printf '\033[2K%b\n' "$title" >&2
    fi
    local row oi label num
    for ((row = 0; row < n; row++)); do
      if (( row < vn )); then
        oi="${visible[$row]}"; label="${opts[$oi]}"
        num=""; (( row < 9 )) && num="$((row + 1)))"
        if (( row == sel )); then
          printf '\033[2K%b▸ %2s %s%b\n' "$_UI_CYAN" "$num" "$label" "$_UI_RESET" >&2
        else
          printf '\033[2K  %2s %s\n' "$num" "$label" >&2
        fi
      else
        printf '\033[2K\n' >&2
      fi
    done
    printf '\033[2K%b↑↓ move · 1-9 pick · type to filter · enter choose · q back%b\n' "$_UI_DIM" "$_UI_RESET" >&2
    drawn=1

    key="$(_ui_read_key)"
    case "$key" in
      $'\x1b[A') (( vn > 0 )) && (( sel = (sel - 1 + vn) % vn )) ;;
      $'\x1b[B') (( vn > 0 )) && (( sel = (sel + 1) % vn )) ;;
      k) [[ -z "$filter" ]] && { (( vn > 0 )) && (( sel = (sel - 1 + vn) % vn )); } || filter+="$key" ;;
      j) [[ -z "$filter" ]] && { (( vn > 0 )) && (( sel = (sel + 1) % vn )); } || filter+="$key" ;;
      [1-9])
        i=$((key - 1))
        if (( i < vn )); then
          _ui_clear_lines "$total_lines"
          _ui_cursor_show; trap - INT TERM
          echo "${opts[${visible[$i]}]}"; return 0
        fi
        ;;
      ""|$'\n'|$'\r')
        (( vn == 0 )) && continue
        _ui_clear_lines "$total_lines"
        _ui_cursor_show; trap - INT TERM
        echo "${opts[${visible[$sel]}]}"; return 0
        ;;
      q|Q)
        if [[ -z "$filter" ]]; then
          _ui_clear_lines "$total_lines"
          _ui_cursor_show; trap - INT TERM
          return 1
        fi
        filter+="$key"
        ;;
      $'\x1b')
        if [[ -n "$filter" ]]; then
          filter=""
        else
          _ui_clear_lines "$total_lines"
          _ui_cursor_show; trap - INT TERM
          return 1
        fi
        ;;
      $'\x7f'|$'\x08')
        filter="${filter%?}"
        ;;
      *)
        [[ "$key" =~ ^[[:print:]]$ ]] && filter+="$key"
        ;;
    esac
  done
}

ui_multi() {
  local title="$1" preselected="$2"; shift 2
  local -a opts=("$@")
  local n=${#opts[@]}
  (( n == 0 )) && return 1

  if ! _ui_is_tty; then
    echo -e "$title" >&2
    local i
    for i in "${!opts[@]}"; do printf "  %d) %s\n" "$((i + 1))" "${opts[$i]}" >&2; done
    echo -e "${_UI_DIM}numbers separated by spaces, 'a' for all, blank to cancel${_UI_RESET}" >&2
    local reply; read -r -p "> " reply
    [[ -z "$reply" ]] && return 2
    if [[ "$reply" == "a" ]]; then printf '%s\n' "${opts[@]}"; return 0; fi
    local idx; local -a picked=()
    for idx in $reply; do
      [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= n )) && picked+=("${opts[$((idx - 1))]}")
    done
    (( ${#picked[@]} == 0 )) && return 1
    printf '%s\n' "${picked[@]}"; return 0
  fi

  local -a checked=()
  local i p
  for ((i = 0; i < n; i++)); do
    checked[i]=0
    if [[ -n "$preselected" ]]; then
      while IFS= read -r p; do
        [[ "$p" == "${opts[$i]}" ]] && checked[i]=1
      done <<< "$preselected"
    fi
  done
  local sel=0 key drawn=0 cnt filter=""
  trap '_ui_cursor_show; printf "\n" >&2; exit 130' INT TERM
  _ui_cursor_hide
  local -a visible
  local total_lines=$((n + 3))
  while true; do
    _ui_filter_visible opts "$filter" visible
    local vn=${#visible[@]}
    if (( vn == 0 )); then sel=0; elif (( sel >= vn )); then sel=$((vn - 1)); fi

    (( drawn )) && printf '\033[%dA' "$total_lines" >&2
    if [[ -n "$filter" ]]; then
      printf '\033[2K%b  %bfilter: %s%b\n' "$title" "$_UI_DIM" "$filter" "$_UI_RESET" >&2
    else
      printf '\033[2K%b\n' "$title" >&2
    fi
    local row oi box label num
    for ((row = 0; row < n; row++)); do
      if (( row < vn )); then
        oi="${visible[$row]}"; label="${opts[$oi]}"
        box='[ ]'; (( checked[oi] )) && box='[x]'
        num=""; (( row < 9 )) && num="$((row + 1)))"
        if (( row == sel )); then
          printf '\033[2K%b▸ %2s %s %s%b\n' "$_UI_CYAN" "$num" "$box" "$label" "$_UI_RESET" >&2
        else
          printf '\033[2K  %2s %s %s\n' "$num" "$box" "$label" >&2
        fi
      else
        printf '\033[2K\n' >&2
      fi
    done
    cnt=0; for i in "${!checked[@]}"; do (( checked[i] )) && ((cnt++)); done
    if [[ -n "$filter" ]]; then
      printf '\033[2K%b%d selected  filter: %s%b\n' "$_UI_DIM" "$cnt" "$filter" "$_UI_RESET" >&2
    else
      printf '\033[2K%b%d selected%b\n' "$_UI_DIM" "$cnt" "$_UI_RESET" >&2
    fi
    printf '\033[2K%bspace tick · 1-9 tick · a all · n none · type to filter · enter confirm · q back%b\n' "$_UI_DIM" "$_UI_RESET" >&2
    drawn=1

    key="$(_ui_read_key)"
    case "$key" in
      $'\x1b[A') (( vn > 0 )) && (( sel = (sel - 1 + vn) % vn )) ;;
      $'\x1b[B') (( vn > 0 )) && (( sel = (sel + 1) % vn )) ;;
      k) [[ -z "$filter" ]] && { (( vn > 0 )) && (( sel = (sel - 1 + vn) % vn )); } || filter+="$key" ;;
      j) [[ -z "$filter" ]] && { (( vn > 0 )) && (( sel = (sel + 1) % vn )); } || filter+="$key" ;;
      " ")
        (( vn > 0 )) && { oi="${visible[$sel]}"; (( checked[oi] = checked[oi] ? 0 : 1 )); }
        ;;
      [1-9])
        i=$((key - 1))
        if (( i < vn )); then
          sel=$i; oi="${visible[$i]}"
          (( checked[oi] = checked[oi] ? 0 : 1 ))
        fi
        ;;
      a|A)
        if [[ -z "$filter" ]]; then for ((i = 0; i < n; i++)); do checked[i]=1; done; else filter+="$key"; fi
        ;;
      n|N)
        if [[ -z "$filter" ]]; then for ((i = 0; i < n; i++)); do checked[i]=0; done; else filter+="$key"; fi
        ;;
      ""|$'\n'|$'\r')
        _ui_clear_lines "$total_lines"
        _ui_cursor_show; trap - INT TERM
        local any=0
        for i in "${!checked[@]}"; do (( checked[i] )) && { echo "${opts[$i]}"; any=1; }; done
        (( any )) && return 0 || return 1
        ;;
      q|Q)
        if [[ -z "$filter" ]]; then
          _ui_clear_lines "$total_lines"
          _ui_cursor_show; trap - INT TERM
          return 2
        fi
        filter+="$key"
        ;;
      $'\x1b')
        if [[ -n "$filter" ]]; then
          filter=""
        else
          _ui_clear_lines "$total_lines"
          _ui_cursor_show; trap - INT TERM
          return 2
        fi
        ;;
      $'\x7f'|$'\x08')
        filter="${filter%?}"
        ;;
      *)
        [[ "$key" =~ ^[[:print:]]$ ]] && filter+="$key"
        ;;
    esac
  done
}

ui_confirm() {
  local prompt="$1" key
  if ! _ui_is_tty; then
    local reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
    return
  fi
  printf '%s [y/n] ' "$prompt" >&2
  IFS= read -rsn1 key
  printf '%s\n' "${key:-n}" >&2
  [[ "$key" =~ ^[Yy]$ ]]
}
