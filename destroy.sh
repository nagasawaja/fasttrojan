#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ASSUME_YES=false
KEEP_DNS=false
KEEP_STATE=false

usage() {
  cat <<'USAGE'
Usage: ./destroy.sh [--env FILE] [--yes] [--keep-dns] [--keep-state]

Destroys the Vultr instance recorded in .state/trojan-state.json and, unless
--keep-dns is set, deletes the Cloudflare DNS record recorded in state.

Options:
  --env FILE     Load a different env file. Default: ./.env
  --yes          Do not prompt for confirmation
  --keep-dns     Leave the Cloudflare DNS record in place
  --keep-state   Leave local .state files in place
  -h, --help     Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      ENV_FILE="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --keep-dns)
      KEEP_DNS=true
      shift
      ;;
    --keep-state)
      KEEP_STATE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

# shellcheck source=scripts/lib.sh
. "$ROOT_DIR/scripts/lib.sh"

load_env "$ENV_FILE"

need_cmd curl
need_cmd jq

require_env VULTR_API_KEY

DOMAIN="${DOMAIN:-$(state_get domain || true)}"
INSTANCE_ID="${VULTR_INSTANCE_ID:-$(state_get instance_id || true)}"
DNS_RECORD_ID="$(state_get dns_record_id || true)"

[ -n "$INSTANCE_ID" ] || die "No instance id found. Set VULTR_INSTANCE_ID or keep $STATE_FILE."

if [ "$KEEP_DNS" = false ]; then
  require_env CLOUDFLARE_API_TOKEN
  require_env CLOUDFLARE_ZONE_ID
  [ -n "$DNS_RECORD_ID" ] || die "No Cloudflare DNS record id in state. Use --keep-dns or delete the record manually."
fi

if [ "$ASSUME_YES" = false ]; then
  printf 'This will destroy Vultr instance: %s\n' "$INSTANCE_ID"
  if [ "$KEEP_DNS" = false ]; then
    printf 'This will delete Cloudflare DNS record: %s (%s)\n' "$DNS_RECORD_ID" "${DOMAIN:-unknown domain}"
  fi
  printf 'Type "destroy" to continue: '
  read -r answer
  [ "$answer" = destroy ] || die "Aborted"
fi

log "Destroying Vultr instance $INSTANCE_ID"
vultr_api DELETE "/instances/$INSTANCE_ID" >/dev/null

if [ "$KEEP_DNS" = false ]; then
  log "Deleting Cloudflare DNS record $DNS_RECORD_ID"
  cloudflare_api DELETE "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$DNS_RECORD_ID" >/dev/null
fi

if [ "$KEEP_STATE" = false ]; then
  rm -rf "$STATE_DIR/build"
  rm -f \
    "$STATE_FILE" \
    "$STATE_DIR/client-uri.txt" \
    "$STATE_DIR/known_hosts" \
    "$STATE_DIR/cloudflare-certbot.ini" \
    "$STATE_DIR/cloud-init-rendered.yml" \
    "$STATE_DIR/trojan-bundle.tar.gz"
fi

printf 'Destroy complete.\n'
