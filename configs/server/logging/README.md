# Fleet monitoring

Start at http://192.168.1.50:3003/d/fleet-overview in the deployed installation. Navigation is Overview · Usage · Problems · Services · Security · All logs. Machine and time selections travel with navigation links. The previous /d/fleet-logs and /d/fleet-security links and Loki datasource UID are retained.

The expected hosts are dorm, hip-japan, hip-usa, hip-fin, hip-nid and nuxt-fin. Host metrics start at deployment; historical logs remain available. Disk forecasts need nearly six hours of regular samples. Grafana evaluates every minute and must be running to evaluate alerts. Its own complete outage cannot be reported by these rules. No external notification destination or SMTP service is configured.

## Roles and installation

Run the normal dotfiles menu, or select one role:

```sh
./install.sh --only server/logging/grafana-loki
./install.sh --only server/logging/loki-caddy
./install.sh --only server/logging/alloy
```

The hub installs Grafana, Loki and private Prometheus, with optional local containerized Alloy. Prometheus retains up to 30 days or 10 GB, whichever is reached first; WAL/head data add some disk overhead. Its receiver and query API bind only to loopback. The central runtime directory must remain the same on reinstall to preserve Compose volumes and the Grafana database. The hub preserves the installed datasource UID and saves choices in hub.json and .env.

The gateway requires an existing Caddy installation and loopback Loki upstream. It preserves other sites, IP restrictions and registered passwords. Only POST /loki/api/v1/push and POST /api/v1/write are routed, with the same source-IP allowlist and Basic authentication. Query and admin paths return 404. IP allowlisting is supplementary authentication for trusted machines sharing one store. Allow inbound HTTPS on the configured port (3443 in this installation).

Metrics use a separate supervised SSH reverse tunnel. No FRP configuration, token or service is changed. Bootstrap its dedicated Ed25519 key on the home host, supply its PUBLIC key when the gateway installer offers the forwarding account, then enable the tunnel from the hub installer. The gateway account has no shell sessions, no password login, only remote TCP forwarding, and only the configured 127.0.0.1 listening port. Verify the gateway SSH host key in the tunnel user's known_hosts before starting. Private keys remain on the home host. The defaults are gateway loopback port 19090 and home Prometheus port 9090; usernames, SSH address/port and key path are prompted and saved outside Git.

Agents need Alloy and systemd. Automatic package installation supports Debian/Ubuntu through Grafana's official repository; install Alloy yourself on other distributions. Agent credentials are separate from Grafana's admin password. Import a mode-0600 JSON credential or enter the agent's existing password. On reinstall, blank retains /etc/alloy/loki.password; existing Docker choices, host label, endpoint, interfaces and GPU setting are retained. New settings are prompted. Native Alloy's UI remains on loopback. Credentials and runtime state stay outside Git.

Agents collect host CPU, RAM, external NIC counters and persistent filesystems every 30 seconds using Alloy's embedded Unix exporter. The installer detects default-route interfaces and lets you override them; select physical external interfaces, not both bridges/tunnels and their underlying NICs. Deployed interfaces: ens224 on dorm and ens3 on all five VPS machines. Temporary and overlay filesystems are excluded; dashboards and disk alerts exclude read-only mounts. The local container mounts host /proc, /sys, root and the GPU textfile directory read-only.

A one-minute journal heartbeat detects stopped logs independently of metrics. The account watcher records an initial username/UID baseline in /var/lib/fleet-monitoring/accounts.json and reports only subsequently added usernames and UIDs. It includes service accounts and labels them. It never reads password hashes. Optional NVIDIA collection runs nvidia-smi with a timeout, writes an atomic textfile, and replaces old GPU readings with failure health when collection fails. GPU dashboard queries also reject stale collection timestamps.

## Configuration and operations

Central runtime: /home/equa/logging in this installation. Expected hosts and per-host thresholds live in monitoring.json, outside generated dashboard JSON. Defaults: CPU 90%, outgoing 100 Mbps, outgoing packets 10,000/s, disk 70% used with a 24-hour fill forecast. Per-host keys are cpu_percent, outgoing_mbps, outgoing_pps, disk_used_percent and disk_fill_hours. The top-level gpu_hosts list records machines expected to have a GPU collector, so a stopped collector is shown as Unavailable rather than No supported GPU.

After editing the runtime machine list/thresholds, regenerate and reload:

```sh
python3 configs/server/logging/monitoring.py \
  --runtime /path/to/runtime \
  --config /path/to/runtime/monitoring.json \
  --loki-uid YOUR_EXISTING_LOKI_UID
cd /path/to/runtime
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
docker kill --signal=HUP prometheus
docker restart grafana
```

Adding a machine also requires an agent credential, gateway source-IP allowlist update and agent install. Removing a host removes its expected-host recording and provisions deletion of its heartbeat rule. Source fleet.json supplies new-install defaults; other users should replace its domain/IP/name inventory or enter their own settings.

Native agent choices: /etc/alloy/fleet-monitoring.json. Gateway choices/hashes: /etc/equa-logging/gateway.json. Tunnel choices: /etc/equa-logging/metrics-forwarding.json on the gateway and metrics-tunnel.json on the hub. Protected credentials: ~/.local/share/equa-logging/credentials or /etc/equa-logging/credentials. Copy only a machine's own credential to that machine. Do not commit runtime .env, password files, registry files or private keys.

Useful checks:

```sh
docker compose ps
docker exec alloy alloy validate /etc/alloy/config.alloy
systemctl status fleet-metrics-tunnel
systemctl list-timers 'fleet-*'
sudo journalctl -u alloy -n 30 --no-pager
```

All logs uses a literal, case-sensitive Contains text filter. Presets separately supply error/exception/SSH/sudo/package patterns or journal/Docker source selectors. Clear filters retains machines and time. Problems text matching is a search aid, not a complete exception detector. Security separates accepted SSH authentication, failures, sudo, new accounts and Fail2ban. Login/account alerts group events by host over five minutes; continuous events can keep one alert active.

CPU and bandwidth require a five-minute average above threshold for 15 minutes; packet rate uses a one-minute average for five minutes. Disk prediction requires a persistent downward trend and almost six hours of history, then 15 minutes above the condition. Network alerts indicate suspicious traffic; they neither prove DDoS nor block anything. Missing logs and metrics are evaluated explicitly for each expected machine; backend query errors remain Grafana Error states.

## Validation and rollback

```sh
python3 -m unittest discover -s configs/server/logging/tests -v
python3 configs/server/logging/tests/prometheus_fixtures.py /tmp/monitoring-fixtures
docker run --rm --network none --entrypoint promtool \
  -v /tmp/monitoring-fixtures:/fixtures:ro -w /fixtures \
  prom/prometheus:v3.7.3 test rules tests.yml
```

For a disposable Loki backend, run python3 configs/server/logging/tests/security_fixtures.py --loki-url http://127.0.0.1:13200. This writes clearly labeled synthetic streams and checks successful login/new-account expressions without creating real accounts.

Fixtures cover sustained CPU, byte and packet thresholds, counter resets, sufficient/insufficient and flat disk history, and a missing host while another stays healthy. Helper tests cover account baseline/service accounts, GPU failure replacement, navigation, literal-search rendering and repeated metrics configuration. The deployment additionally tests synthetic Loki login/account fixtures, a controlled heartbeat pause/firing/recovery, fresh six-host measurements and GPU readings, ingestion denials, and existing Caddy/FRP health.

Hub backups live under the runtime backups directory; native/gateway backups under /var/backups/equa-logging (root-only). Restore backed-up config files, validate Alloy/Caddy/Compose/Prometheus, then restart/reload only the affected services. Do not remove or recreate the existing data volumes. Keep the pre-existing logging-backends-private.service enabled: it protects the legacy raw Loki tunnel independently of this metrics transport.

Official references: [Alloy Unix exporter](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.unix/), [remote write](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.remote_write/), [Grafana alert provisioning](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/).
