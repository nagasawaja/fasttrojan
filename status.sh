#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

usage() {
  cat <<'USAGE'
Usage: ./status.sh [--env FILE]

Shows local state, Cloudflare DNS state, local resolver result, and Vultr
instance state. This is useful when multiple computers manage the same node.

Options:
  --env FILE   Load a different env file. Default: ./.env
  -h, --help   Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      ENV_FILE="$2"
      shift 2
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

require_env CLOUDFLARE_API_TOKEN
require_env CLOUDFLARE_ZONE_ID
require_env DOMAIN

local_instance_id="$(state_get instance_id || true)"
local_ip="$(state_get main_ip || true)"
local_dns_record_id="$(state_get dns_record_id || true)"
local_subscription_path="$(state_get subscription_path || true)"
[ -n "$local_subscription_path" ] || local_subscription_path="${SUBSCRIPTION_PATH:-/shuadhTrojan.123}"

encoded_domain="$(urlencode "$DOMAIN")"
cf_response="$(cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$encoded_domain&per_page=100")"
cf_id="$(printf '%s' "$cf_response" | jq -r '.result[0].id // empty')"
cf_ip="$(printf '%s' "$cf_response" | jq -r '.result[0].content // empty')"
cf_ttl="$(printf '%s' "$cf_response" | jq -r '.result[0].ttl // empty')"
cf_proxied="$(printf '%s' "$cf_response" | jq -r 'if (.result[0] | has("proxied")) then (.result[0].proxied | tostring) else empty end')"

resolver_ip=""
if command -v dig >/dev/null 2>&1; then
  resolver_ip="$(dig +short "$DOMAIN" A | tail -n 1)"
elif command -v nslookup >/dev/null 2>&1; then
  resolver_ip="$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1)"
fi

authoritative_ip=""
if command -v dig >/dev/null 2>&1; then
  authoritative_ip="$(dig +short @1.1.1.1 "$DOMAIN" A | tail -n 1)"
fi

vultr_summary="not checked"
if [ -n "${VULTR_API_KEY:-}" ] && [ -n "$local_instance_id" ]; then
  tmp="$(mktemp)"
  vultr_http_status="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    -H 'Content-Type: application/json' \
    "$VULTR_API_BASE/instances/$local_instance_id")"
  vultr_response="$(cat "$tmp")"
  rm -f "$tmp"
  case "$vultr_http_status" in
    2*)
      vultr_summary="$(printf '%s' "$vultr_response" | jq -r '.instance | "\(.id) \(.main_ip) \(.status)/\(.power_status)/\(.server_status)"' 2>/dev/null || printf 'unavailable')"
      ;;
    404)
      vultr_summary="not found"
      ;;
    *)
      vultr_summary="HTTP $vultr_http_status"
      ;;
  esac
fi

printf 'Domain:              %s\n' "$DOMAIN"
printf 'Local state IP:      %s\n' "${local_ip:-missing}"
printf 'Cloudflare A record: %s\n' "${cf_ip:-missing}"
printf 'Cloudflare record ID: %s\n' "${cf_id:-missing}"
printf 'Cloudflare TTL:      %s\n' "${cf_ttl:-missing}"
printf 'Cloudflare proxied:  %s\n' "${cf_proxied:-missing}"
printf 'System resolver IP:  %s\n' "${resolver_ip:-unavailable}"
printf '1.1.1.1 resolver IP: %s\n' "${authoritative_ip:-unavailable}"
printf 'Vultr instance:      %s\n' "$vultr_summary"
printf 'Subscription path:   %s\n' "${local_subscription_path:-missing}"
printf 'Subscription URL:    https://%s%s\n' "$DOMAIN" "$local_subscription_path"

if [ "$vultr_summary" = "not found" ]; then
  printf '\nWARNING: local state points to a Vultr instance that no longer exists.\n'
  printf 'Next deploy will create a new instance, or you can run: ./deploy.sh --force-new\n'
fi

if [ -n "$local_dns_record_id" ] && [ -n "$cf_id" ] && [ "$local_dns_record_id" != "$cf_id" ]; then
  printf '\nWARNING: local DNS record id differs from Cloudflare.\n'
fi

if [ -n "$local_ip" ] && [ -n "$cf_ip" ] && [ "$local_ip" != "$cf_ip" ]; then
  printf '\nWARNING: local state IP differs from Cloudflare A record.\n'
fi

if [ -n "$cf_ip" ] && [ -n "$resolver_ip" ] && [ "$cf_ip" != "$resolver_ip" ]; then
  printf '\nWARNING: system resolver is not seeing the current Cloudflare IP yet.\n'
  if [ "$(uname -s)" = "Darwin" ]; then
    printf 'Run: ./scripts/flush-macos-dns.sh\n'
  fi
fi
