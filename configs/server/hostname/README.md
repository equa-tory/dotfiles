# Server hostname

Choose **server → hostname** in the dotfiles menu, or run:

```bash
./install.sh --only server/hostname
```

Enter the complete hostname you want, for example `hip-fin`, `mahi-server`, or `hip-fin.example.net`. No prefix or country suffix is added. The Linux username does not change. Names are normalized to lowercase and must be valid DNS-style labels within Linux's 64-character limit.

The module checks that hostnamectl/systemd is available, validates the name, and updates `/etc/hosts` while preserving other records and the old name as a local alias. It backs up affected files under `/var/backups/equa-hostname/` before applying the hostname through hostnamectl. If applying fails, it attempts to restore the previous names and files. Repeating the current name is a no-op; blank input cancels.

If cloud-init is installed, it asks whether to preserve your chosen hostname and local hosts file. The default writes `/etc/cloud/cloud.cfg.d/99-z-equa-hostname.cfg` with `preserve_hostname: true` and `manage_etc_hosts: false`, so normal cloud-init processing does not reset those files. Other provider-specific automation may have its own settings. Existing cloud-init files are retained.

Before applying, it checks common Caddy/nginx/Apache/Postfix configuration directories for references to the old name. If found, it lists their paths and asks you to review whether the rename should proceed. It does not rewrite those application configurations or public DNS records.

## Connections

An existing IP-based SSH connection normally stays open. The installer does not restart SSH, networking, FRP, or the server. Reconnect your shell later to refresh its prompt. IP-based fleet entries such as `hip-fin equa@193.32.179.127` keep working; the friendly fleet name is separate from the system hostname.

Changing the system hostname does not register a DNS record or make the new name resolve from your laptop. Continue connecting by the existing IP/domain unless you also configure DNS. Applications that derive their identity from the hostname may use the new name after their next restart. Keep a working SSH session open when making administration changes.

Merely installing this menu item does not rename any machine. You choose and apply the name when you run the module on that machine.

Checks: `python3 -m unittest discover -s configs/server/hostname/tests -v`.

References: [hostnamectl](https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html), [cloud-init hostname handling](https://docs.cloud-init.io/en/latest/reference/yaml_examples/update_hostname.html), [cloud-init hosts handling](https://docs.cloud-init.io/en/latest/reference/yaml_examples/update_etc_hosts.html).
