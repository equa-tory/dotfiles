#!/usr/bin/env bash
# description: Configure npm, pip, and NuGet to use Nexus
# default: false
set -euo pipefail
host="${MIRROR_HOST:-192.168.1.50}"
nexus="http://$host:8090/repository"
curl --fail --silent --show-error --max-time 4 "$nexus/" -o /dev/null || { echo "Nexus $host is unreachable; unchanged"; exit 0; }
backup() { [[ -e "$1" ]] && ! grep -q 'bootstrap-mirror' "$1" && cp -a "$1" "$1.bootstrap-bak" || true; }
backup "$HOME/.npmrc"
cat > "$HOME/.npmrc" <<EOF
# bootstrap-mirror
registry=$nexus/npm-group/
EOF
mkdir -p "$HOME/.config/pip" "$HOME/.nuget/NuGet"
backup "$HOME/.config/pip/pip.conf"
cat > "$HOME/.config/pip/pip.conf" <<EOF
# bootstrap-mirror
[global]
index-url = $nexus/pypi-proxy/simple/
trusted-host = $host
EOF
backup "$HOME/.nuget/NuGet/NuGet.Config"
cat > "$HOME/.nuget/NuGet/NuGet.Config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- bootstrap-mirror -->
<configuration><packageSources><clear/><add key="home-nuget" value="$nexus/nuget-group/index.json" allowInsecureConnections="true" /></packageSources></configuration>
EOF
