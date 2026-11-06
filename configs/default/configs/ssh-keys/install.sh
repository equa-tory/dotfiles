#!/usr/bin/env bash
# description: Add GitHub public SSH keys to current user's authorized_keys
# default: true
set -euo pipefail
url='https://github.com/equa-tory.keys'
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location "$url" > "$tmp"
if ! grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-[^ ]+) [A-Za-z0-9+/=]+' "$tmp"; then
  echo 'No valid-looking public keys fetched; refusing to modify authorized_keys' >&2
  exit 1
fi
# Preserve other keys. Never overwrite authorized_keys.
while IFS= read -r key; do
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]] || continue
  grep -Fqx -- "$key" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"
done < "$tmp"
echo 'Public keys merged into authorized_keys'
