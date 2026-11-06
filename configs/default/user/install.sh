#!/usr/bin/env bash
# description: Create a sudo user with an interactively entered password
# default: false
set -euo pipefail
if [[ $EUID -eq 0 ]]; then
  echo 'Run this module as a normal user; sudo is used for account creation.' >&2
  exit 1
fi
read -r -p 'New username: ' username
[[ "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo 'Invalid username' >&2; exit 1; }
if id "$username" >/dev/null 2>&1; then
  echo "User already exists: $username" >&2
  exit 1
fi
read -r -s -p "Password for $username: " password
printf '\n'
[[ -n "$password" ]] || { echo 'Password must not be blank' >&2; exit 1; }
sudo useradd --create-home --groups sudo --shell /bin/bash "$username"
printf '%s:%s\n' "$username" "$password" | sudo chpasswd
unset password
echo "Created sudo user $username"
