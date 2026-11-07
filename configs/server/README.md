Server modules are installed from `configs/server/<module>/install.sh`.
FRP client and server are separate modules. Each prompts for the directory containing
its binary and TOML config; blank input skips the optional module. You can set
`FRP_SOURCE_DIR` to avoid the prompt. Each then prompts for a token; blank input
generates one. Copy the printed value securely to the other side so both configs match.
Grafana prompts for its admin password; blank input generates one. Secrets are stored
in local config files with mode 0600 and are never written to this repository.
The reboot module schedules unattended-upgrade reboots for 03:00.
`ilo-boot-notify/client` installs a boot-time POST client and
`ilo-boot-notify/server` installs the Flask API on port 5005. Enter the same
shared auth token on both machines; the API module also prompts for the Telegram
bot token and chat ID. Values are stored in `/etc/ilo-boot-notify/*.env` with
mode 0600. The server implementation is installed locally and reads secrets
from its environment file. If UFW is enabled, allow TCP port 5005 only from the
client machines or networks that need to reach the API.
The Alloy installer is a placeholder until its configuration is ready.
See `docs/security-check.md` for post-install manual checks.
The `srv` module installs the current modular server helper to
`~/.local/bin/srv`; its source and modules are in `configs/server/srv/`.
