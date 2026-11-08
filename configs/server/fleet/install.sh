#!/usr/bin/env bash
# description: Install a self-contained fleet directory driven by servers.txt
# default: false
set -euo pipefail
MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${FLEET_HOME:-}" ]]; then
  fleet_dir="$FLEET_HOME"
elif [[ -t 0 ]]; then
  read -r -p "Fleet installation directory [$HOME/fleet]: " fleet_dir
  fleet_dir="${fleet_dir:-$HOME/fleet}"
else
  fleet_dir="$HOME/fleet"
fi
fleet_dir="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$fleet_dir")"
python3 - "$MODULE_DIR" "$fleet_dir" <<'PY'
import os,pathlib,shutil,sys,time
source=pathlib.Path(sys.argv[1]);target=pathlib.Path(sys.argv[2])
if any((p/'.git').exists() for p in [target,*target.parents]):raise SystemExit('Choose a runtime directory outside a Git repository.')
if target==pathlib.Path.home() or target==pathlib.Path('/'):raise SystemExit('Choose a dedicated fleet directory.')
target.mkdir(parents=True,exist_ok=True);target.chmod(0o700)
backup=target/'backups'/('installer-'+str(time.time_ns()))
for name in ['fleet.py','ansible.cfg','requirements.txt','collections.yml','README.md','jobs','engine','templates','tests']:
 src=source/name;dst=target/name
 if dst.exists():
  backup.mkdir(parents=True,exist_ok=True)
  if dst.is_dir():shutil.copytree(dst,backup/name)
  else:shutil.copy2(dst,backup/name)
 if src.is_dir():
  if name=='jobs' and os.environ.get('FLEET_REPLACE_JOBS')!='1':
   for item in src.rglob('*'):
    if '__pycache__' in item.parts or item.suffix=='.pyc':continue
    output=dst/item.relative_to(src)
    if item.is_dir():output.mkdir(parents=True,exist_ok=True)
    elif not output.exists():output.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(item,output)
  else:shutil.copytree(src,dst,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
 else:shutil.copy2(src,dst)
(target/'.fleet-installation').write_text('1\n')
(target/'fleet.py').chmod(0o755)
p=target/'fleet'
if p.exists() and not p.is_symlink():raise SystemExit('An unrelated file exists at '+str(p))
if p.is_symlink():p.unlink()
p.symlink_to('fleet.py')
PY
python3 -m venv "$fleet_dir/venv"
"$fleet_dir/venv/bin/python" -m pip install -r "$fleet_dir/requirements.txt"
ANSIBLE_COLLECTIONS_PATH="$fleet_dir/collections" "$fleet_dir/venv/bin/ansible-galaxy" collection install -r "$fleet_dir/collections.yml" -p "$fleet_dir/collections"
if [[ ! -e "$fleet_dir/servers.txt" && ! -e "$fleet_dir/settings.json" ]]; then
  if [[ -e "$HOME/.config/equa-fleet/inventory.json" ]]; then
    fleet_keys_url="$(python3 -c 'import pathlib,json; p=pathlib.Path.home()/".config/equa-fleet/settings.json"; print(json.loads(p.read_text()).get("keys_url","https://github.com/equa-tory.keys") if p.exists() else "https://github.com/equa-tory.keys")')"
    "$fleet_dir/fleet" init --keys-url "$fleet_keys_url" --import-inventory "$HOME/.config/equa-fleet/inventory.json"
  else
    "$fleet_dir/fleet" init
  fi
fi
mkdir -p "$HOME/.local/bin"
if [[ -e "$HOME/.local/bin/fleet" && ! -L "$HOME/.local/bin/fleet" ]]; then
  cp -p "$HOME/.local/bin/fleet" "$HOME/.local/bin/fleet.backup.$(date +%s)"
fi
ln -sfn "$fleet_dir/fleet.py" "$HOME/.local/bin/fleet"
printf 'Fleet installed in %s\nEdit %s/servers.txt, then run: %s/fleet sync\n' "$fleet_dir" "$fleet_dir" "$fleet_dir"
