#!/usr/bin/env bash
# description: Install packages listed in packages.txt
# default: true
set -euo pipefail

# Read one package name per line; ignore blank lines and comments.
packages=()
while IFS= read -r package; do
  [[ -z "$package" || "$package" == \#* ]] && continue
  packages+=("$package")
done < "$BOOTSTRAP_ROOT/configs/default/tools/packages.txt"

if command -v apt-get >/dev/null 2>&1; then
  # Ubuntu installers often leave the installation ISO enabled as an APT
  # source. Disable only active CD-ROM stanzas, preserving a one-time backup.
  sudo python3 - <<'PY'
from pathlib import Path
import re
import shutil

paths = [Path('/etc/apt/sources.list')]
source_dir = Path('/etc/apt/sources.list.d')
if source_dir.is_dir():
    paths.extend(p for p in source_dir.iterdir() if p.suffix in {'.list', '.sources'})

for path in paths:
    if not path.is_file():
        continue
    original = path.read_text()
    updated = original
    if path.suffix == '.sources':
        stanzas = re.split(r'(\n\s*\n)', original)
        for i in range(0, len(stanzas), 2):
            stanza = stanzas[i]
            uris = re.search(r'^URIs:\s*(.+(?:\n[ \t]+.+)*)', stanza, re.I | re.M)
            if not uris or not re.search(r'(?:cdrom:|file:/+cdrom)', uris.group(1), re.I):
                continue
            enabled = re.search(r'^Enabled:\s*(\S+)', stanza, re.I | re.M)
            if enabled:
                stanza = re.sub(r'^Enabled:\s*\S+', 'Enabled: no', stanza, count=1, flags=re.I | re.M)
            else:
                stanza = stanza.rstrip() + '\nEnabled: no'
            stanzas[i] = stanza
        updated = ''.join(stanzas)
    else:
        updated = re.sub(
            r'^(\s*deb(?:-src)?\s+[^\n]*(?:cdrom:|file:/+cdrom)[^\n]*)$',
            r'# disabled by equa-bootstrap: \1', original, flags=re.I | re.M
        )
    if updated != original:
        backup = path.with_name(path.name + '.bootstrap-bak')
        if not backup.exists():
            shutil.copy2(path, backup)
        path.write_text(updated)
        print(f'Disabled stale CD-ROM APT source in {path}')
PY
  sudo apt-get update
  sudo apt-get install -y "${packages[@]/openssh/openssh-client}"
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm "${packages[@]}"
elif command -v brew >/dev/null 2>&1; then
  brew install "${packages[@]}"
else
  echo 'Unsupported package manager' >&2
  exit 1
fi
