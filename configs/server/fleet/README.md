# fleet: one command for the VPS machines

The controller is `equa@192.168.1.50`. It uses SSH and Ansible to execute trusted tasks. No management API, web listener, or remote daemon is installed on the VPS machines. FRP, VPN containers, and Grafana are not changed by this module.

## Start on the controller

The command and dependencies are installed under `~/.local/bin/fleet` and `~/.local/share/equa-fleet`. The initial inventory contains your five VPS names/IPs and provisionally uses the Linux login `equa`.

```bash
fleet list
fleet enroll all
```

`enroll` prompts for the actual Linux SSH user of each machine (`root`, `equa`, etc.), verifies its SSH host fingerprint through the normal SSH prompt, and adds this controller's **public** SSH key using `ssh-copy-id`. Enter the VPS's existing login password if needed. Private keys stay on the controller; login passwords are not saved. Check the host fingerprint against a trusted source such as the VPS console before accepting a new host.

The default controller key is `~/.ssh/id_ed25519`. To use a different one, run `fleet configure`. If the chosen key does not exist, create it first with `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_fleet` and select that path. Use ssh-agent for a passphrase-protected key. Do not copy private keys into dotfiles or onto the VPS machines.

You can enroll one machine at a time: `fleet enroll hip-fin`. Once each target accepts the controller key and its host key is trusted, normal fleet commands need no per-host login interaction. Changed or unknown host keys fail closed during bulk commands.

## Everyday commands

```bash
fleet status                         # connectivity and Alloy status/version
fleet keys --plan                    # show selected hosts, no connections
fleet keys --check                   # preview key changes
fleet keys                           # fetch public keys from equa-tory.keys and merge everywhere
fleet alloy-update --limit hip-fin --check -K
fleet alloy-update --limit hip-fin -K # update just Finland first
fleet alloy-update -K                 # update Alloy throughout the fleet, one server at a time
```

`-K` asks for the sudo password when needed; it is not saved. Root logins or passwordless sudo do not need `-K`. A single invocation uses one sudo password, so use `--limit` to separate machines with different sudo passwords. This does not grant passwordless sudo or weaken SSH policy.

From Torii, you can use the controller directly:

```bash
ssh -t equa@192.168.1.50 '~/.local/bin/fleet keys'
ssh -t equa@192.168.1.50 '~/.local/bin/fleet alloy-update -K'
```

### SSH-key synchronization

The HTTPS source is `https://github.com/equa-tory.keys`. The controller downloads it once, validates every public key using `ssh-keygen`, then merges keys into each target's login account. Invalid/empty downloads fail before applying anything. Existing unrelated keys are retained. Removing a key from GitHub does not automatically revoke copies already installed; revocation is a separate deliberate operation.

By default, keys are installed for each machine's `ansible_user`. `fleet keys --key-user equa -K` can target another existing Linux account and needs suitable privileges. An initial working SSH login is required: a machine cannot install new access keys for a controller that has no way to log in yet.

### Alloy updates

This task updates an already installed **native Debian/Ubuntu Alloy package**, preserving the existing config and password file. It validates config before updating, upgrades only Alloy using the target's existing APT repositories, suppresses package-triggered service restarts, validates again, and restarts Alloy if the package changed. It checks the loopback Alloy readiness endpoint. It stops the rollout on failure; it does not automatically downgrade a newly installed package after an error. This is not a configuration deployment or a whole-OS update. Docker Alloy and Amnezia containers are left alone.

Optional: `fleet alloy-update --version '<exact APT version>' -K` selects a specific available package version; automatic downgrades are not enabled.

## Settings and future tasks

Private controller settings are outside Git:

- `~/.config/equa-fleet/inventory.json`: target IPs, users, SSH ports, and private-key **paths**, not key contents.
- `~/.config/equa-fleet/settings.json`: public key source URL.

Use `fleet configure` to change logins/ports/key paths/source, or edit the inventory to add another host. The dotfiles logging fleet file seeds a fresh inventory only; later edits do not overwrite existing controller settings. No passwords belong in the inventory.

Add a trusted Ansible playbook at `~/.config/equa-fleet/playbooks/<task>.yml` (or commit a reusable one under this module's `playbooks`). Target the `fleet` inventory group and run:

```bash
fleet run <task> --limit hip-fin --check
fleet run <task> --limit hip-fin -K
```

These tasks are the reusable backend for a future dashboard. Grafana still displays logs; CPU/RAM/disk graphs would need a metrics backend added separately. No dashboard or API has been deployed as part of this controller.

## Install on another controller

```bash
./install.sh --only server/fleet
```

The installer creates a user-owned Python virtual environment for Ansible and installs its SSH-key collection. It prompts for the initial SSH user and key path, preserves existing inventory, and links the `fleet` command. Requires Python 3 with venv/pip, OpenSSH tools (`ssh`, `ssh-copy-id`, `ssh-keygen`), and network access for initial dependencies. There is no root daemon or API port. Only the controller needs Ansible; targets need SSH/Python, plus sudo for privileged tasks.

Checks:

```bash
python3 -m unittest discover -s configs/server/fleet/tests -v
python3 configs/server/fleet/tests/integration_keys.py
```

The integration test changes only a temporary file, checking that preview is read-only, existing keys survive, and repeated synchronization is idempotent. Production key synchronization and Alloy updates are not automatically run by the installer.

References: [Ansible SSH connections](https://docs.ansible.com/projects/ansible/latest/inventory_guide/connection_details.html), [authorized_key](https://docs.ansible.com/projects/ansible/latest/collections/ansible/posix/authorized_key_module.html), [APT package updates](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_module.html).
