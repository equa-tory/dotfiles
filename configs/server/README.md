Server modules are installed from `configs/server/<module>/install.sh`.
FRP client and server are separate, non-default menu modules. Selecting either
downloads and installs the matching official FRP release for the current Linux
architecture. The client asks for the server address,
token, and an optional local/remote TCP port mapping. The server asks for its bind
port and token. Blank token input generates one; use the same value on both sides.
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
The Alloy module installs named VPS log collectors. The loki-caddy module configures authenticated HTTPS ingestion with an IP allowlist. The grafana-loki module installs the central stack and dashboards. See [logging/README.md](logging/README.md) for setup and your fleet inventory.
See `docs/security-check.md` for post-install manual checks.
The `srv` module installs the current modular server helper to
`~/.local/bin/srv`; its source and modules are in `configs/server/srv/`.
The optional `server/hostname` module prompts for the complete hostname, updates local name resolution with backups, and offers cloud-init persistence. It does not restart network or SSH services. See [hostname/README.md](hostname/README.md).
