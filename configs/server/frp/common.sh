#!/usr/bin/env bash

frp_validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

frp_toml_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

frp_linux_arch() {
  case "$(uname -m)" in
    x86_64) printf amd64 ;;
    aarch64|arm64) printf arm64 ;;
    armv7l|armv7) printf arm_hf ;;
    armv6l) printf arm ;;
    i386|i686) printf 386 ;;
    riscv64) printf riscv64 ;;
    *) echo "Unsupported FRP architecture: $(uname -m)" >&2; return 1 ;;
  esac
}

frp_install_binary() {
  local binary="$1" arch release_info version url digest tmpdir archive extracted
  command -v curl >/dev/null || { echo 'curl is required to download FRP' >&2; return 1; }
  command -v tar >/dev/null || { echo 'tar is required to unpack FRP' >&2; return 1; }
  command -v sha256sum >/dev/null || { echo 'sha256sum is required to verify FRP' >&2; return 1; }
  arch="$(frp_linux_arch)"
  release_info="$(curl --fail --silent --show-error --location \
    https://api.github.com/repos/fatedier/frp/releases/latest)"
  read -r version url digest < <(python3 -c '
import json, sys
release = json.load(sys.stdin)
version = release["tag_name"].removeprefix("v")
asset_name = f"frp_{version}_linux_{sys.argv[1]}.tar.gz"
asset = next((item for item in release.get("assets", []) if item["name"] == asset_name), None)
if asset is None:
    raise SystemExit(f"No official FRP release asset found for {asset_name}")
digest = (asset.get("digest") or "").removeprefix("sha256:")
if not digest:
    raise SystemExit(f"GitHub release did not provide a SHA-256 digest for {asset_name}")
print(version, asset["browser_download_url"], digest)
' "$arch" <<< "$release_info")
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  archive="$tmpdir/frp.tar.gz"
  curl --fail --silent --show-error --location "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status || {
    echo 'FRP release checksum verification failed' >&2
    return 1
  }
  tar -xzf "$archive" -C "$tmpdir"
  extracted="$(find "$tmpdir" -type f -name "$binary" -print -quit)"
  [[ -n "$extracted" && -x "$extracted" ]] || { echo "FRP archive did not contain $binary" >&2; return 1; }
  sudo install -d -m 755 /opt/frp
  sudo install -m 755 "$extracted" "/opt/frp/$binary"
  echo "Installed official FRP v$version $binary"
}
