#!/usr/bin/env bash
# description: Set Zsh as the current user's login shell
# default: false
# after: desktop/packages
set -euo pipefail
zsh_path="$(command -v zsh || true)"
[[ -n "$zsh_path" ]] || { echo 'Install Zsh first' >&2; exit 1; }
grep -Fxq "$zsh_path" /etc/shells || { echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null; }
chsh -s "$zsh_path"
echo "Login shell changed to $zsh_path; start a new login session to use it."
