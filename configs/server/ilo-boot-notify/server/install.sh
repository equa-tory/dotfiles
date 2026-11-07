#!/usr/bin/env bash
# description: Install the ILO boot notification API
# default: false
set -euo pipefail

systemd_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

source_dir='/@/t'
[[ -f "$source_dir/requirements.txt" ]] || { echo "ILO API requirements not found in $source_dir" >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is required' >&2; exit 1; }
read -r -s -p 'Shared auth token (must match client): ' auth_token
printf '\n'
[[ -n "$auth_token" ]] || { echo 'Auth token is required' >&2; exit 1; }
read -r -s -p 'Telegram bot token: ' telegram_token
printf '\n'
[[ -n "$telegram_token" ]] || { echo 'Telegram bot token is required' >&2; exit 1; }
read -r -p 'Telegram chat ID: ' chat_id
[[ -n "$chat_id" ]] || { echo 'Telegram chat ID is required' >&2; exit 1; }

sudo -v
sudo install -d -m 755 /opt/ilo-boot-notify
sudo install -m 644 "$source_dir/requirements.txt" /opt/ilo-boot-notify/requirements.txt
sudo tee /opt/ilo-boot-notify/server.py >/dev/null <<'PY'
import os
import requests
from flask import Flask, abort, request

app = Flask(__name__)

@app.post('/boot')
def boot():
    if request.headers.get('X-Auth') != os.environ['ILO_NOTIFY_AUTH']:
        abort(403)
    payload = request.get_json(silent=True) or {}
    message = payload.get('msg', 'server on')
    response = requests.get(
        f"https://api.telegram.org/bot{os.environ['TELEGRAM_BOT_TOKEN']}/sendMessage",
        params={'chat_id': os.environ['TELEGRAM_CHAT_ID'], 'text': message},
        timeout=15,
    )
    response.raise_for_status()
    return 'ok'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5005)
PY
sudo python3 -m venv /opt/ilo-boot-notify/venv
sudo /opt/ilo-boot-notify/venv/bin/pip install --disable-pip-version-check -r /opt/ilo-boot-notify/requirements.txt
sudo install -d -m 755 /etc/ilo-boot-notify
sudo tee /etc/ilo-boot-notify/server.env >/dev/null <<EOF
ILO_NOTIFY_AUTH=$(systemd_quote "$auth_token")
TELEGRAM_BOT_TOKEN=$(systemd_quote "$telegram_token")
TELEGRAM_CHAT_ID=$(systemd_quote "$chat_id")
EOF
sudo chmod 600 /etc/ilo-boot-notify/server.env
unset auth_token telegram_token
sudo tee /etc/systemd/system/ilo-boot-notify-server.service >/dev/null <<'UNIT'
[Unit]
Description=ILO Boot Notification API
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/ilo-boot-notify
EnvironmentFile=/etc/ilo-boot-notify/server.env
ExecStart=/opt/ilo-boot-notify/venv/bin/python /opt/ilo-boot-notify/server.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
sudo chown -R www-data:www-data /opt/ilo-boot-notify
sudo systemctl daemon-reload
sudo systemctl enable --now ilo-boot-notify-server.service
