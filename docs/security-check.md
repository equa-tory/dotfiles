# Manual server security checks

Use this checklist after installation and whenever the server network or SSH setup changes.

- Confirm you can open a second SSH session with the intended account and key before changing SSH settings.
- Check `sudo sshd -t` before reloading SSH; keep the current session open until a new login works.
- Check `sudo systemctl status fail2ban` and `sudo fail2ban-client status sshd`.
- Check `sudo unattended-upgrade --dry-run --debug` and review `/var/log/unattended-upgrades/`.
- Check `sudo ufw status verbose` and confirm only intended inbound ports are allowed.
- Confirm SSH root and password login are disabled and key login works for the intended account.
- Check `sudo visudo -c` and verify sudo access for the intended administrator.
- Confirm boot recovery access and that an emergency console or provider console is available.
- Check `sudo systemd-analyze cat-config systemd/journald.conf` and verify persistent journal storage and its size limit.
- Confirm unattended-upgrades reboot scheduling is set to 03:00 and review pending reboot behavior.
- Check Docker-published ports against UFW rules; Docker can manage firewall rules independently.
- Review listening ports with `sudo ss -tulpn`; allow only services you intend to expose.
- Confirm Grafana is protected by a private network or firewall and Loki is not exposed publicly.
- Back up service and SSH configuration before manual edits.

This checklist is a reference, not an automatic hardening policy. The Security module
allows OpenSSH before enabling UFW and validates `sshd` before reloading it. Confirm
the actual SSH port and a working recovery path before relying on those defaults.
