#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/configure-docker-mirror.sh MIRROR_URL [MIRROR_URL...]

Example:
  sudo ./scripts/configure-docker-mirror.sh https://your-id.mirror.aliyuncs.com

This writes /etc/docker/daemon.json with registry-mirrors and restarts Docker.
If /etc/docker/daemon.json already exists, it is backed up first.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -lt 1 ]; then
  usage
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo or as root." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "Missing jq. Install it first, for example: apt-get update && apt-get install -y jq" >&2
  exit 1
}

mkdir -p /etc/docker

if [ -f /etc/docker/daemon.json ]; then
  backup="/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  cp /etc/docker/daemon.json "$backup"
  echo "Backed up existing daemon.json to $backup"
fi

tmp="$(mktemp)"
if [ -f /etc/docker/daemon.json ]; then
  jq --argjson mirrors "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    '. + {"registry-mirrors": $mirrors}' \
    /etc/docker/daemon.json > "$tmp"
else
  jq -n --argjson mirrors "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    '{"registry-mirrors": $mirrors}' > "$tmp"
fi

install -m 0644 "$tmp" /etc/docker/daemon.json
rm -f "$tmp"

systemctl daemon-reload
systemctl restart docker

echo "Docker registry mirrors configured:"
docker info 2>/dev/null | sed -n '/Registry Mirrors:/,/Live Restore Enabled:/p'

