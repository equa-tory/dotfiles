#!/usr/bin/env bash
# description: Notify the ILO API when this server boots
# default: false
set -euo pipefail

systemd_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

read -r -p 'ILO API boot endpoint [http://equatory.ddns.net:5005/boot]: ' endpoint
endpoint="${endpoint:-http://equatory.ddns.net:5005/boot}"
read -r -s -p 'Shared auth token: ' auth_token
printf '\n'
[[ -n "$auth_token" ]] || { echo 'Auth token is required' >&2; exit 1; }
read -r -p 'Boot message [LOCAL SERVER ON]: ' message
message="${message:-LOCAL SERVER ON}"

sudo -v
sudo install -d -m 755 /opt/ilo-boot-notify /etc/ilo-boot-notify
sudo tee /opt/ilo-boot-notify/client.sh >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/curl --fail --silent --show-error --max-time 15 \
  -X POST "$ILO_NOTIFY_ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H "X-Auth: $ILO_NOTIFY_AUTH" \
  --data-binary "$(/usr/bin/python3 -c 'import json,os; print(json.dumps({"msg":os.environ["ILO_NOTIFY_MESSAGE"]}))')"
SCRIPT
sudo chmod 755 /opt/ilo-boot-notify/client.sh
sudo tee /etc/ilo-boot-notify/client.env >/dev/null <<EOF
ILO_NOTIFY_ENDPOINT=$(systemd_quote "$endpoint")
ILO_NOTIFY_AUTH=$(systemd_quote "$auth_token")
ILO_NOTIFY_MESSAGE=$(systemd_quote "$message")
EOF
sudo chmod 600 /etc/ilo-boot-notify/client.env
unset auth_token
sudo tee /etc/systemd/system/ilo-boot-notify-client.service >/dev/null <<'UNIT'
[Unit]
Description=Notify ILO API when this server boots
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/ilo-boot-notify/client.env
ExecStart=/opt/ilo-boot-notify/client.sh

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now ilo-boot-notify-client.service
