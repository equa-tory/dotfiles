#!/usr/bin/env bash
# port_audit.sh  Listening ports + UFW coverage
# Usage: sudo bash port_audit.sh

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root:${RESET} sudo bash $0"; exit 1; }

header() { echo -e "\n${BOLD}${CYAN} $* ${RESET}"; }

#  UFW: collect allowed ports 
UFW_ACTIVE=false
declare -A UFW_PORTS
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  UFW_ACTIVE=true
  while IFS= read -r line; do
    if [[ $line =~ \[\ *[0-9]+\]\ +([0-9]+)(/[a-z]+)?\ +ALLOW ]]; then
      UFW_PORTS["${BASH_REMATCH[1]}"]=1
    fi
  done < <(ufw status numbered 2>/dev/null)
fi

#  Collect listening ports (deduplicated by port+proto) 
declare -A SEEN_PORTS
declare -a ROWS

while IFS= read -r line; do
  proto=$(awk '{print $1}' <<< "$line")
  local=$(awk '{print $5}' <<< "$line")
  proc=$(awk '{print $7}' <<< "$line")

  # Extract port number
  port=$(grep -oP '(?<=:)\d+$' <<< "$local") || continue
  [[ -z $port ]] && continue

  key="${proto}:${port}"
  [[ ${SEEN_PORTS[$key]+_} ]] && continue
  SEEN_PORTS[$key]=1

  # Clean process: keep only first name before comma, strip quotes and pid info
  clean=$(sed 's/users:((//' <<< "$proc" | grep -oP '"[^"]+"' | head -1 | tr -d '"')
  [[ -z $clean ]] && clean="?"

  # Bind address: 0.0.0.0 / :: = public, 127.x = local only
  if grep -qP '^(127\.|::1)' <<< "$local"; then
    scope="${DIM}loopback${RESET}"
  else
    scope="public"
  fi

  # UFW status
  if $UFW_ACTIVE; then
    if [[ ${UFW_PORTS[$port]+_} ]]; then
      ufw_col="${GREEN} allowed${RESET}"
    else
      ufw_col="${RED} no rule${RESET}"
    fi
  else
    ufw_col="${DIM}(ufw off)${RESET}"
  fi

  ROWS+=("$(printf '%-6s %-7s %-10s %-18b %b' "$proto" "$port" "$scope" "$ufw_col" "$clean")")
done < <(ss -tulnp 2>/dev/null | tail -n +2 | sort -t: -k2 -n)

#  Output 
header "LISTENING PORTS"
printf "${BOLD}%-6s %-7s %-10s %-18s %s${RESET}\n" "PROTO" "PORT" "SCOPE" "UFW" "PROCESS"
printf '%0.s' {1..65}; echo
for row in "${ROWS[@]}"; do
  echo -e "$row"
done

#  UFW: rules with no listener 
if $UFW_ACTIVE; then
  header "UFW RULES WITHOUT A LISTENER"
  found=0
  for port in "${!UFW_PORTS[@]}"; do
    if [[ ! ${SEEN_PORTS["tcp:$port"]+_} && ! ${SEEN_PORTS["udp:$port"]+_} ]]; then
      echo -e "  ${YELLOW}port $port${RESET}  rule exists but nothing is listening"
      found=1
    fi
  done
  [[ $found -eq 0 ]] && echo -e "  ${GREEN}All UFW-allowed ports have an active listener.${RESET}"

  header "UFW RULES"
  ufw status numbered 2>/dev/null | grep -E '^\[|^To' | grep -v "^To"
fi

echo
