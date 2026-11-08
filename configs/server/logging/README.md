# Fleet logs: install one collector per VPS

Alloy on each VPS -> Caddy HTTPS on hip-nid -> existing private Loki tunnel -> Loki/Grafana on dorm.

The public ingestion URL is `https://equatory.ddns.net:3443/loki/api/v1/push`.
Caddy requires BOTH a listed source IP and a valid agent username/password. It accepts only POST to that exact path. Query/admin APIs return 404. Each VPS only needs Alloy, with outbound TCP 3443; do not install a separate Grafana/Loki stack or give it an FRP token.

| Machine label | Source IPv4 |
| --- | --- |
| hip-japan | 45.66.166.180 |
| hip-usa | 213.108.3.101 |
| hip-fin | 193.32.179.127 |
| hip-nid | 171.22.30.82 |
| nuxt-fin | 31.76.226.14 |

The existing gateway VPS now emits new logs under `hip-nid`; older logs retain the historical `equatory` label until retention expires.

The inventory and default endpoint live in `fleet.json`. These are the source IPs Caddy must actually see: if a VPS sends traffic through a VPN, NAT, IPv6, or another outbound proxy, add that real egress IP explicitly. X-Forwarded-For cannot bypass this allowlist. IP allowlisting supplements passwords; it does not replace them.

## Add one VPS

Copy/clone dotfiles to that VPS, then run as its normal sudo-capable user:

```bash
cd ~/dotfiles
./install.sh --only server/alloy
```

The module prompts for the machine label, endpoint, username/password, and Docker collection. Enter the matching label/username from the table. Password input is hidden. Automatic package installation uses the official Grafana APT repository on Debian/Ubuntu; on another systemd Linux distribution install Alloy yourself first and rerun the module.

The five initial credentials are already provisioned. Read the appropriate file privately:

- On dorm: `~/.local/share/equa-logging/credentials/hip-japan.json` (and the other names).
- On hip-nid: `sudo cat /etc/equa-logging/credentials/hip-japan.json`.

Do not commit or post these files. Give each VPS only its own credential. The installer verifies TLS, IP access, and authentication with a test log before changing Alloy. It installs a systemd service override with its HTTP UI bound to loopback and stores the password at `/etc/alloy/loki.password`, root:alloy 0640. Existing credentials can be retained by leaving password input blank. Backups live under `/var/backups/equa-logging` (root-only). Validation/start failures restore the agent's prior files.

After installation, emit a log and check the service:

```bash
logger -t alloy-check 'VPS log collection check'
sudo systemctl status alloy --no-pager
sudo journalctl -u alloy -n 30 --no-pager
```

Open Grafana -> Fleet Logs -> Machine -> your chosen name. Dashboard time filters matter. The endpoint test log confirms transport; the logger event confirms actual journal collection.

Journal and selected text-file logs are collected. Docker collection is optional, and Grafana/Loki/Alloy containers are excluded by default to reduce noise. Application file collection follows current files from their end; journal catch-up is bounded to 24 hours. Docker socket access is privileged; enabling it adds Alloy to the docker group. Other groups are adm and systemd-journal. This is log collection, not CPU/RAM metrics.

## Configure or change Caddy on hip-nid

```bash
./install.sh --only server/loki-caddy
```

Prompts cover the HTTPS site, existing loopback Loki upstream, source IPs, and the private directory for new credentials. It reads existing users from `/etc/equa-logging/gateway.json`, preserving their passwords. Missing fleet users receive separate generated passwords, saved outside Git. Caddy must already be installed. The module supports the older `basicauth` spelling used by your Caddy 2.6, and `basic_auth` on newer Caddy.

Managed routing is in `/etc/caddy/equa-logging.caddy`, imported by `/etc/caddy/Caddyfile`. Other Caddy sites are preserved. Config is validated before Caddy reload; no FRP config or connection is modified. For a new domain, point DNS to this host and ensure Caddy can obtain its certificate. The existing endpoint already has HTTPS. With a public AAAA record, include the intended VPS IPv6 source addresses too, or clients using IPv6 will be denied.

To add another machine, add its name/IP to `fleet.json`, rerun the gateway module on hip-nid, then run the agent module on the new VPS. To revoke a user, remove its hash from the `users` object in `/etc/equa-logging/gateway.json` AND remove/disable that machine in `fleet.json`, then rerun the module; otherwise the inventory would recreate that user. A username can be used from any allowlisted address; these are trusted agents sharing one Loki store, not isolated tenants.

The existing raw port 3100 is blocked for external IPv4/IPv6 traffic by `logging-backends-private.service`. Keep it enabled. The gateway module configures Caddy only; on a fresh host it does not create firewall rules or an FRP tunnel. Its upstream must already exist on loopback. Your current upstream is `127.0.0.1:3100` through the existing tunnel. Do not open raw Loki to the Internet.

Expected responses: unlisted source -> 403; listed source without a valid password -> 401; valid POST -> 204; query/admin paths -> 404; GET to the push path from an allowed source -> 405.

## Central Grafana/Loki host only

```bash
./install.sh --only server/grafana-loki
```

This installs the central Docker Compose stack and both dashboards, with an optional local Alloy container. It prompts for the runtime directory, Grafana bind IP/port, Loki loopback port, admin password, retention days, local host label, and Docker collection. It requires Docker Engine plus Compose and permission to use Docker. It never installs Docker silently.

Fresh defaults: Grafana on `127.0.0.1:3003`, Loki on `127.0.0.1:3200`, 30-day retention, anonymous login and signup disabled. Set Grafana's bind IP explicitly to its LAN address if you want LAN access. The optional local Alloy runs as root with journal/Docker socket mounts and a loopback UI. It skips its own observability containers by default.

An existing stack must be updated in its existing directory so its Compose volumes are preserved. The installer refuses unrelated existing containers and conflicting ports, preserves an explicit datasource UID, and validates generated Alloy/Loki/Compose configs before updating files. If an old datasource has no UID in YAML, obtain its UID in Grafana and add that UID first. Runtime configs and admin passwords stay outside Git. UI edits to provisioned dashboards can be replaced when the templates are installed again.

Your live home stack remains at `/home/equa/logging`; copying these modules into dotfiles does not reinstall it. Updating retention affects stored age, not a fixed disk quota. Dashboards show up to 1000 lines per query by default.

## Checks and references

Renderer tests: `python3 -m unittest discover -s configs/server/logging/tests -v`.
Installers require interactive prompts and are not a noninteractive fleet deployment tool. No login details for the other four VPS machines are stored here; run the agent installer on them yourself.

Official documentation:
- https://grafana.com/docs/alloy/latest/set-up/install/linux/
- https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/
- https://grafana.com/docs/loki/latest/operations/authentication/
- https://caddyserver.com/docs/caddyfile/matchers#remote-ip
