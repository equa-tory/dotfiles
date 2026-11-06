# equa-bootstrap

A local, modular CLI installer for Debian/Ubuntu, Arch, and macOS.

## Start

```bash
cd ~/.config/dotfiles
chmod +x install.sh
./install.sh              # arrows / j,k: move; space: toggle; a/n: all on/off; Enter: run; q: quit
./install.sh --list
./install.sh --dry-run
./install.sh --only terminal
./install.sh --profile default
```

The chosen profile or `--only` commands still ask for confirmation on interactive terminals. A non-interactive invocation currently executes directly; avoid piping unknown code into it.

## Add a module

Put a shell script anywhere under `configs/<profile>/.../install.sh`:

```bash
#!/usr/bin/env bash
# description: A short explanation displayed in the menu
# default: false
set -euo pipefail
# install/configure your app here
```

Folders become group nodes; groups can be selected with Space. Newly added scripts are discovered automatically; no central registry to edit. Put extra scripts/templates next to install.sh (but only an `install.sh` is shown in the menu).

The default tools installer reads package names from `configs/default/tools/packages.txt`. Tool configuration installers live separately under `configs/default/.config/<tool>/`, so package installation and configuration can be selected independently. For example, select `default/tools` to install packages and `default/.config/tmux` to install the tmux configuration.

Modules run as the invoking user. Use `sudo` only for the specific operations that need it. Never run the top-level manager with sudo because that would put aliases in root's home. To reconfigure an installed module, select it again. Installers must be idempotent and store secrets outside the repo, with permission 0600.

## Scope and limitations

- Implemented: shell aliases/TERM fallback, package list, GitHub SSH keys, local tmux/Neovim configs, desktop tools and mirrors, explicit Torii launcher, FRP, Alloy placeholder, Grafana/Loki, and server security settings.
- System administration installers **must** validate environment/ports before changing configs and must refuse to lock out the current SSH connection.
- `--dry-run` lists selected scripts; it cannot predict each installer’s side effects yet.
- Current `--profile` replaces the default selection (it does not automatically include common modules); use interactive menu for combinations.
- The optional default user module creates an administrator account after prompting for its username and password.
- Most macOS tools need Homebrew installed separately.
- Avoid exposing Loki (auth disabled) or Grafana directly on an unrestricted public address.

## Package list

`configs/default/tools/packages.txt` contains one package name per line. The default package module reads
this file and maps the names to the supported package manager.
