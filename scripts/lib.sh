#!/usr/bin/env bash

if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

STATE_DIR="${STATE_DIR:-$ROOT_DIR/.state}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/trojan-state.json}"
VULTR_API_BASE="${VULTR_API_BASE:-https://api.vultr.com/v2}"
CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

load_env() {
  local env_file="$1"
  [ -f "$env_file" ] || die "Env file not found: $env_file. Copy .env.example to .env first."
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

require_env() {
  local name="$1"
  eval "local value=\${$name:-}"
  [ -n "$value" ] || die "Missing required env: $name"
}

expand_path() {
  local value="$1"
  case "$value" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

root_abs_path() {
  local value="$1"
  value="$(expand_path "$value")"
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$value" ;;
  esac
}

base64_file() {
  base64 < "$1" | tr -d '\n'
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

json_bool() {
  local value
  value="$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true|1|yes|y|on) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

api_request() {
  local method="$1"
  local url="$2"
  local token="$3"
  local data="${4:-}"
  local tmp status body
  tmp="$(mktemp)"

  if [ -n "$data" ]; then
    status="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      --data "$data")"
  else
    status="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json')"
  fi

  body="$(cat "$tmp")"
  rm -f "$tmp"

  case "$status" in
    2*) printf '%s\n' "$body" ;;
    *)
      printf 'HTTP %s from %s\n%s\n' "$status" "$url" "$body" >&2
      exit 1
      ;;
  esac
}

vultr_api() {
  api_request "$1" "$VULTR_API_BASE$2" "$VULTR_API_KEY" "${3:-}"
}

cloudflare_api() {
  local response
  response="$(api_request "$1" "$CLOUDFLARE_API_BASE$2" "$CLOUDFLARE_API_TOKEN" "${3:-}")"
  if [ -n "$response" ] && printf '%s' "$response" | jq -e 'has("success") and .success == false' >/dev/null 2>&1; then
    printf 'Cloudflare API returned success=false:\n%s\n' "$response" >&2
    exit 1
  fi
  printf '%s\n' "$response"
}

state_get() {
  local key="$1"
  [ -f "$STATE_FILE" ] || return 0
  jq -r --arg key "$key" '.[$key] // empty' "$STATE_FILE"
}
