# Fleet: edit one server list, then sync

The controller is installed in `~/fleet` on `192.168.1.50`. This directory contains the command, settings, Ansible dependencies, and tasks. It does not need to remain linked to the dotfiles repo. `~/.local/bin/fleet` is a convenience link to the installed command.

## Add or change a server

Edit `~/fleet/servers.txt`:

```text
# Plain user@ip works:
root@203.0.113.10

# An optional name gives friendlier task output:
my-server user@server.example.com

# Optional SSH port and private key path:
other user@server.example.org:2222 key=/home/me/.ssh/another_key

# IPv6:
v6 root@[2001:db8::10]:2222
```

Then run in that directory:

```bash
./fleet sync
```

That one command reads the latest file, checks SSH access, enrolls the controller's public key on hosts that need it, and merges the public keys from `https://github.com/equa-tory.keys`. Already accessible hosts skip enrollment/password prompts. New hosts may ask you to verify their SSH fingerprint and enter their existing login password once. The user comes from `servers.txt`; there is no separate per-server configuration questionnaire.

No SSH tool can enroll an entirely inaccessible server without an initial working credential or provider-console provisioning. This tool handles the SSH prompts interactively; it does not store passwords or disable host-key checks. Your controller private key stays on the controller. If no controller key exists, interactive sync runs ssh-keygen to create one. Use ssh-agent for a passphrase-protected key.

## Typical workflow

```bash
cd ~/fleet
nano servers.txt
./fleet sync --plan      # show targets, no SSH connections or changes
./fleet sync             # enroll where needed, then merge GitHub public keys
./fleet status
./fleet alloy-update --limit my-server --check -K
./fleet alloy-update -K
```

`fleet sync my-server` selects one name; comma-separated names and shell-quoted globs also work. `fleet sync --enroll-only` just enrolls the controller key. The older `fleet enroll` command is an alias for enrollment only and now defaults to all servers.

Every command rereads `servers.txt`. Changing a user or IP takes effect immediately; adding/removing lines changes which hosts receive future tasks. The private Ansible inventory under `.state/` is generated automatically, not a file you maintain. Removing a host line stops targeting it; it does not delete keys or uninstall software from that remote server.

All entries are validated before connecting. Duplicate names/servers and malformed addresses fail with a line number. Enrollment continues past an inaccessible host, reports the failures, and can be safely repeated. Only ready hosts receive key synchronization. Existing unrelated authorized keys are preserved.

The provided source URL is configurable in `settings.json`, alongside the default controller private-key path. These are defaults, not private-key contents or passwords. `fleet configure` can change these two defaults; server details belong in `servers.txt`.

## Jobs are directories and files

```text
jobs/
  ssh-keys/
    run.py          # fetch/validate keys on the controller
    tasks.yml       # merge them on the VPS machines
  alloy-update/
    run.yml         # package-update tasks; shows APT source first
  status/
    run.yml
  uptime/
    run.sh          # example plain shell job
```

The CLI discovers these directories each time. There is no command registry to edit.

```bash
./fleet jobs
./fleet run uptime --limit hip-fin
./fleet run ssh-keys --check
./fleet run alloy-update --limit hip-fin --check -K
```

Short commands such as `fleet status`, `fleet keys` (an alias for ssh-keys), and `fleet alloy-update` still work, but they are generated from the job directories, not built into the runner. `fleet sync` runs jobs marked `# on-sync: true` after enrollment; by default that is only ssh-keys.

### Add a shell job

Create `jobs/my-job/run.sh`:

```bash
#!/usr/bin/env bash
# description: Show disk space
# changes: false
# sudo: false
# serial: 1
set -euo pipefail
printf '%s\n' "$FLEET_HOST"
df -h /
```

Then run `./fleet run my-job --limit hip-fin`. No Python change, rebuild, install step, or JSON manifest is needed. You can copy the starter at `templates/job/run.sh`. Nested directories work too, e.g. `jobs/maintenance/disks/run.sh` -> `fleet run maintenance/disks`.

Shell jobs run **on each selected VPS**, with Bash. `# sudo: true` requests remote privilege escalation; use `-K` if sudo needs a password. `# serial: 1` is the safe default and stops the job on failure. `# changes: false` marks a read-only script. `FLEET_HOST`, `FLEET_JOB_NAME`, and `FLEET_VARS_JSON` are available in the remote environment. Extra values supplied using `--set name=value` are available in that JSON; the script decides how to use them. Each script is copied by Ansible and run remotely; arbitrary companion files are not uploaded automatically. Use a YAML job when it needs files/templates or richer configuration.

### Other job types and metadata

- `run.yml`: an Ansible playbook targeting the `fleet` group. Supports files, packages, templates, handlers, and native check mode.
- `run.py`: a controller-side Python job. It receives a private context-file path in `FLEET_JOB_CONTEXT`, plus `FLEET_HOME` and `FLEET_JOB_DIR`. The bundled ssh-keys job demonstrates calling the common Ansible runner. `# runner: controller` can also make a Bash entry run locally.

Exactly one entry (`run.sh`, `run.yml`, or `run.py`) belongs in a job directory. Header comments provide optional `description`, `aliases`, `options`, `sudo`, `serial`, `changes`, `on-sync`, and `check` metadata. See the bundled jobs for examples. `# options: version=fleet_alloy_version` adds a job-specific `--version` option to its shorthand command. `fleet run <name>` supports generic `--set variable=value` for all jobs; e.g. `--set fleet_alloy_version=1.21.3-1` for an exact available APT package version. Options and names are discovered automatically.

`--plan` lists targets and never executes shell/controller entry scripts. `--check` previews Ansible jobs, skips remote shell scripts, and skips controller scripts unless they explicitly declare `# check: true`; such a controller job must honor check mode. A shell script cannot safely predict what it would change. Use a real YAML job for a useful dry run of updates/config changes.

Existing `playbooks/<name>.yml` custom jobs remain runnable as legacy jobs; new directories take precedence. Move custom work into `jobs/<name>/run.yml` when convenient.

### Where Alloy updates come from

`jobs/alloy-update/run.yml` upgrades the existing **native Debian/Ubuntu package** through that VPS's configured APT sources. Your installed Grafana source is `https://apt.grafana.com stable main`. The job now prints `apt-cache policy alloy` first, showing the source and candidate version. It does not download Alloy from dotfiles or an unexplained URL.

The job validates config, preserves config/password files, upgrades Alloy, validates again, restarts if changed, and checks readiness. It runs one server at a time and stops on failure. It does not change Amnezia containers, Docker Alloy, or the whole OS. Package downgrade rollback is not automatic. You can inspect or edit the job like any other file.

### SSH keys and privileged jobs

`jobs/ssh-keys/run.py` reads the HTTPS key source from `settings.json`, currently `https://github.com/equa-tory.keys`. It validates downloaded public keys with ssh-keygen before applying them through `tasks.yml`. It adds keys without deleting unrelated ones; removing a key from GitHub does not automatically revoke existing access. The optional `--key-user` on the `keys`/`ssh-keys` shorthand or `--set fleet_key_user=equa` can select another existing account with suitable privileges.

The target Linux account is the user on each servers.txt line. `-K` prompts for sudo when needed; root or passwordless-sudo logins do not need it. One invocation uses one sudo password, so use `--limit` for hosts with different sudo passwords. Passwords are not saved.

These tasks can be reused by a future dashboard. No public API or dashboard is installed; CPU/RAM/disk graphs would need a metrics backend separately. New entries in servers.txt manage SSH targets; they do not automatically create Loki credentials, expand the Caddy allowlist, or install Alloy.

## Install or reinstall

Select **server → fleet** in dotfiles, or:

```bash
./install.sh --only server/fleet
```

The installer prompts for a dedicated runtime directory (default `~/fleet`). For a scripted install:

```bash
FLEET_HOME="$HOME/fleet" bash configs/server/fleet/install.sh
```

It copies the application and tasks into that directory and installs user-owned Ansible dependencies there. Existing `servers.txt`, `settings.json`, and job files are preserved on reinstall; new bundled jobs are added and prior application files are backed up under `backups/`. To intentionally replace bundled job files with dotfiles versions, set `FLEET_REPLACE_JOBS=1` during installation; backups are still made and unrelated custom jobs are retained. A first install migrates the previous `~/.config/equa-fleet/inventory.json` if present, keeping each login, address, port, and key path. Otherwise it creates an empty commented server list. Legacy settings/dependencies are left intact so migration is reversible.

Keep this directory outside Git: it holds runtime state and host details. The installation marker `.fleet-installation` lets the command locate its bundled dependencies/settings. You can run `./fleet` from any working directory or use the `fleet` link from PATH. A copied Python virtual environment is not portable between machines; run the installer on a new controller and copy only the server list/settings as appropriate, keeping private keys secure.

Requires Python with venv/pip, SSH tools (`ssh`, `ssh-copy-id`, `ssh-keygen`), and initial network access for dependencies. Only the controller needs Ansible; targets need SSH/Python and appropriate sudo access for privileged tasks. No VPS agent daemon or API port is added.

Checks: `python3 -m unittest discover -s tests -v`; `python3 tests/integration_keys.py`. The integration test changes only a temporary file, verifying preview is read-only, existing keys survive, and repeated synchronization is idempotent.
