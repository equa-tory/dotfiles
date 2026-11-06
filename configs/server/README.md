Server modules are installed from `configs/server/<module>/install.sh`.
FRP client and server are separate modules. Each prompts for a token; blank input
generates one. Copy the printed value securely to the other side so both configs match.
Grafana prompts for its admin password; blank input generates one. Secrets are stored
in local config files with mode 0600 and are never written to this repository.
The reboot module schedules unattended-upgrade reboots for 03:00.
The Alloy installer is a placeholder until its configuration is ready.
See `docs/security-check.md` for post-install manual checks.
