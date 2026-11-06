# Manual server security checks

Use this checklist after installation and whenever the server network or SSH setup changes.

- Confirm you can open a second SSH session with the intended account and key before changing SSH settings.
- Check `sudo sshd -t` before reloading SSH; keep the current session open until a new login works.
- Check `sudo systemctl status fail2ban` and `sudo fail2ban-client status sshd`.
- Check `sudo unattended-upgrade --dry-run --debug` and review `/var/log/unattended-upgrades/`.
- Review listening ports with `sudo ss -tulpn`; allow only services you intend to expose.
- Confirm Grafana is protected by a private network or firewall and Loki is not exposed publicly.
- Back up service and SSH configuration before manual edits.

This checklist is a reference, not an automatic hardening policy. Do not enable a firewall or change SSH access until you have confirmed the allowed ports and a working recovery path.
