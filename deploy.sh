#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
FORCE_NEW=false

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [--env FILE] [--force-new]

Creates or reuses a Vultr instance, points a Cloudflare DNS A record at it,
deploys Docker Compose with Xray Trojan, and prints a client URI.

Options:
  --env FILE     Load a different env file. Default: ./.env
  --force-new   Ignore the saved instance in .state and create a new VPS
  -h, --help    Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      ENV_FILE="$2"
      shift 2
      ;;
    --force-new)
      FORCE_NEW=true
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

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

need_cmd curl
need_cmd jq
need_cmd ssh
need_cmd scp
need_cmd ssh-keygen
need_cmd openssl
need_cmd base64
need_cmd tar

require_env VULTR_API_KEY
require_env CLOUDFLARE_API_TOKEN
require_env CLOUDFLARE_ZONE_ID
require_env DOMAIN

[ "$DOMAIN" != "t.example.com" ] || die "Set DOMAIN in .env before deploying"

VULTR_REGION="${VULTR_REGION:-nrt}"
VULTR_PLAN="${VULTR_PLAN:-vc2-1c-1gb}"
VULTR_OS_NAME="${VULTR_OS_NAME:-Ubuntu 24.04 x64}"
VULTR_OS_QUERY="${VULTR_OS_QUERY:-Ubuntu 24.04}"
VULTR_LABEL="${VULTR_LABEL:-trojan-${DOMAIN//./-}}"
VULTR_SSH_PUBLIC_KEY_FILE="${VULTR_SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-~/.ssh/id_ed25519}"
GENERATE_SSH_KEY="${GENERATE_SSH_KEY:-true}"
SSH_USER="${SSH_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_WAIT_INTERVAL="${SSH_WAIT_INTERVAL:-10}"
DEPLOY_WAIT_SECONDS="${DEPLOY_WAIT_SECONDS:-900}"
CF_TTL="${CF_TTL:-60}"
CF_PROXIED="${CF_PROXIED:-false}"
CERT_CACHE_DIR="${CERT_CACHE_DIR:-.certs}"
ACME_STAGING="${ACME_STAGING:-false}"
ACME_DNS_PROPAGATION_SECONDS="${ACME_DNS_PROPAGATION_SECONDS:-30}"
CERT_RENEW_BEFORE_SECONDS="${CERT_RENEW_BEFORE_SECONDS:-2592000}"
CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/dns-cloudflare:latest}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"
REMOTE_DIR="${REMOTE_DIR:-/opt/trojan}"
DEPLOY_METHOD="${DEPLOY_METHOD:-cloud-init}"
SUBSCRIPTION_PATH="${SUBSCRIPTION_PATH:-/shuadhTrojan.123}"
DESTROY_OLD_ON_FORCE_NEW="${DESTROY_OLD_ON_FORCE_NEW:-true}"
CERTBOT_CREDENTIALS_FILE=""

[ "$(json_bool "$CF_PROXIED")" = false ] || die "CF_PROXIED must stay false for normal Trojan TCP"
case "$DEPLOY_METHOD" in
  cloud-init|ssh) ;;
  *) die "Unsupported DEPLOY_METHOD: $DEPLOY_METHOD" ;;
esac
[ "${SUBSCRIPTION_PATH#/}" != "$SUBSCRIPTION_PATH" ] || die "SUBSCRIPTION_PATH must start with /"

preflight_api_access() {
  log "Checking Vultr API access"
  vultr_api GET '/account' >/dev/null

  log "Checking Cloudflare zone access"
  cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID" >/dev/null
}

cleanup() {
  if [ -n "${CERTBOT_CREDENTIALS_FILE:-}" ]; then
    rm -f "$CERTBOT_CREDENTIALS_FILE"
  fi
}
trap cleanup EXIT

SSH_PRIVATE_KEY_FILE="$(root_abs_path "$SSH_PRIVATE_KEY_FILE")"
VULTR_SSH_PUBLIC_KEY_FILE="$(root_abs_path "$VULTR_SSH_PUBLIC_KEY_FILE")"

ssh_args() {
  printf '%s\0' \
    -i "$SSH_PRIVATE_KEY_FILE" \
    -o "StrictHostKeyChecking=accept-new" \
    -o "UserKnownHostsFile=$STATE_DIR/known_hosts" \
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
}

ssh_remote() {
  local ip="$1"
  local remote_cmd="$2"
  local args=()
  while IFS= read -r -d '' item; do
    args+=("$item")
  done < <(ssh_args)
  ssh "${args[@]}" "$SSH_USER@$ip" "$remote_cmd"
}

resolve_os_id() {
  if [ -n "${VULTR_OS_ID:-}" ]; then
    printf '%s\n' "$VULTR_OS_ID"
    return
  fi

  local response os_id
  response="$(vultr_api GET '/os?per_page=500')"
  os_id="$(printf '%s' "$response" | jq -r --arg name "$VULTR_OS_NAME" '.os[]? | select(.name == $name) | .id' | head -n 1)"
  if [ -z "$os_id" ]; then
    os_id="$(printf '%s' "$response" | jq -r --arg query "$VULTR_OS_QUERY" '.os[]? | select(.name | ascii_downcase | contains($query | ascii_downcase)) | .id' | head -n 1)"
  fi
  [ -n "$os_id" ] || die "Could not find Vultr OS named '$VULTR_OS_NAME' or matching '$VULTR_OS_QUERY'. Set VULTR_OS_ID explicitly."
  printf '%s\n' "$os_id"
}

ensure_vultr_ssh_key() {
  if [ -n "${VULTR_SSH_KEY_ID:-}" ]; then
    printf '%s\n' "$VULTR_SSH_KEY_ID"
    return
  fi

  if [ ! -f "$SSH_PRIVATE_KEY_FILE" ] && [ "$(json_bool "$GENERATE_SSH_KEY")" = true ]; then
    log "Generating local SSH key: $SSH_PRIVATE_KEY_FILE"
    mkdir -p "$(dirname "$SSH_PRIVATE_KEY_FILE")"
    ssh-keygen -t ed25519 -N '' -f "$SSH_PRIVATE_KEY_FILE" -C "trojan-deploy-$DOMAIN" >/dev/null
  fi

  if [ -f "$SSH_PRIVATE_KEY_FILE" ] && [ ! -f "$VULTR_SSH_PUBLIC_KEY_FILE" ]; then
    log "Deriving SSH public key: $VULTR_SSH_PUBLIC_KEY_FILE"
    ssh-keygen -y -f "$SSH_PRIVATE_KEY_FILE" > "$VULTR_SSH_PUBLIC_KEY_FILE"
  fi

  [ -f "$VULTR_SSH_PUBLIC_KEY_FILE" ] || die "SSH public key not found: $VULTR_SSH_PUBLIC_KEY_FILE"
  [ -f "$SSH_PRIVATE_KEY_FILE" ] || die "SSH private key not found: $SSH_PRIVATE_KEY_FILE"

  local public_key response key_id payload created
  public_key="$(tr -d '\n' < "$VULTR_SSH_PUBLIC_KEY_FILE")"
  response="$(vultr_api GET '/ssh-keys?per_page=500')"
  key_id="$(printf '%s' "$response" | jq -r --arg key "$public_key" '.ssh_keys[]? | select(.ssh_key == $key) | .id' | head -n 1)"

  if [ -n "$key_id" ]; then
    printf '%s\n' "$key_id"
    return
  fi

  log "Uploading SSH public key to Vultr"
  payload="$(jq -n --arg name "trojan-auto-$(date '+%Y%m%d%H%M%S')" --arg key "$public_key" '{name:$name, ssh_key:$key}')"
  created="$(vultr_api POST '/ssh-keys' "$payload")"
  key_id="$(printf '%s' "$created" | jq -r '.ssh_key.id')"
  [ -n "$key_id" ] || die "Vultr did not return an SSH key id"
  printf '%s\n' "$key_id"
}

create_instance() {
  local cloud_init_file="$1"
  local os_id ssh_key_id cloud_init_b64 payload response instance_id
  os_id="$(resolve_os_id)" || return 1
  [ -n "$os_id" ] || die "Resolved empty Vultr OS id"
  ssh_key_id="$(ensure_vultr_ssh_key)" || return 1
  [ -n "$ssh_key_id" ] || die "Resolved empty Vultr SSH key id"
  cloud_init_b64="$(base64_file "$cloud_init_file")"

  payload="$(jq -n \
    --arg region "$VULTR_REGION" \
    --arg plan "$VULTR_PLAN" \
    --arg instance_label "$VULTR_LABEL" \
    --arg hostname "$VULTR_LABEL" \
    --arg user_data "$cloud_init_b64" \
    --arg ssh_key_id "$ssh_key_id" \
    --arg firewall_group_id "${VULTR_FIREWALL_GROUP_ID:-}" \
    --argjson os_id "$os_id" \
    '{
      "region": $region,
      "plan": $plan,
      "os_id": $os_id,
      "label": $instance_label,
      "hostname": $hostname,
      "user_data": $user_data,
      "enable_ipv6": true,
      "activation_email": false,
      "sshkey_id": [$ssh_key_id],
      "tags": ["trojan", "ephemeral"]
    } + (if $firewall_group_id != "" then {"firewall_group_id": $firewall_group_id} else {} end)')" || return 1

  log "Creating Vultr instance: region=$VULTR_REGION plan=$VULTR_PLAN os=$os_id"
  response="$(vultr_api POST '/instances' "$payload")" || return 1
  instance_id="$(printf '%s' "$response" | jq -r '.instance.id')"
  [ -n "$instance_id" ] || die "Vultr did not return an instance id"
  printf '%s\n' "$instance_id"
}

vultr_instance_http_status() {
  local instance_id="$1"
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    -H 'Content-Type: application/json' \
    "$VULTR_API_BASE/instances/$instance_id"
}

wait_instance_ip() {
  local instance_id="$1"
  local deadline ip status response http_status tmp
  deadline=$(( $(date +%s) + DEPLOY_WAIT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    tmp="$(mktemp)"
    http_status="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: Bearer $VULTR_API_KEY" \
      -H 'Content-Type: application/json' \
      "$VULTR_API_BASE/instances/$instance_id")"
    response="$(cat "$tmp")"
    rm -f "$tmp"

    case "$http_status" in
      2*) ;;
      404) die "Vultr instance not found: $instance_id. Local state is stale; rerun deploy.sh to create a new instance." ;;
      *)
        printf 'HTTP %s from %s/instances/%s\n%s\n' "$http_status" "$VULTR_API_BASE" "$instance_id" "$response" >&2
        exit 1
        ;;
    esac

    ip="$(printf '%s' "$response" | jq -r '.instance.main_ip // empty')"
    status="$(printf '%s' "$response" | jq -r '.instance.status // empty')"
    if [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ]; then
      log "Vultr instance has IP $ip, status=$status"
      printf '%s\n' "$ip"
      return
    fi
    log "Waiting for Vultr instance IP, status=$status"
    sleep 5
  done

  die "Timed out waiting for Vultr instance IP"
}

ensure_instance() {
  local cloud_init_file="$1"
  local existing_id instance_id ip http_status reused
  reused=false
  existing_id=""
  if [ "$FORCE_NEW" = false ]; then
    existing_id="$(state_get instance_id || true)"
  fi

  if [ -n "$existing_id" ]; then
    http_status="$(vultr_instance_http_status "$existing_id")"
    case "$http_status" in
      200)
        log "Reusing instance from state: $existing_id"
        instance_id="$existing_id"
        reused=true
        ;;
      404)
        log "State instance no longer exists on Vultr: $existing_id"
        instance_id=""
        ;;
      *)
        die "Failed checking state instance $existing_id: HTTP $http_status"
        ;;
    esac
  fi

  if [ -z "${instance_id:-}" ]; then
    instance_id="$(create_instance "$cloud_init_file")" || die "Failed to create Vultr instance"
    [ -n "$instance_id" ] || die "Failed to create Vultr instance"
  fi

  ip="$(wait_instance_ip "$instance_id")" || die "Failed waiting for Vultr instance IP"
  printf '%s %s %s\n' "$instance_id" "$ip" "$reused"
}

destroy_old_instance_if_needed() {
  local old_instance_id="$1"
  local new_instance_id="$2"
  local tmp http_status body

  [ "$FORCE_NEW" = true ] || return
  [ "$(json_bool "$DESTROY_OLD_ON_FORCE_NEW")" = true ] || return
  [ -n "$old_instance_id" ] || return
  [ "$old_instance_id" != "$new_instance_id" ] || return

  tmp="$(mktemp)"
  http_status="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    -H 'Content-Type: application/json' \
    "$VULTR_API_BASE/instances/$old_instance_id")"
  body="$(cat "$tmp")"
  rm -f "$tmp"

  case "$http_status" in
    2*)
      log "Destroyed previous Vultr instance: $old_instance_id"
      ;;
    404)
      log "Previous Vultr instance already gone: $old_instance_id"
      ;;
    *)
      printf 'WARNING: failed to destroy previous Vultr instance %s: HTTP %s\n%s\n' "$old_instance_id" "$http_status" "$body" >&2
      ;;
  esac
}

ensure_trojan_password() {
  local existing
  if [ -n "${TROJAN_PASSWORD:-}" ]; then
    printf '%s\n' "$TROJAN_PASSWORD"
    return
  fi

  existing=""
  if [ "$FORCE_NEW" = false ]; then
    existing="$(state_get trojan_password || true)"
  fi
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return
  fi

  openssl rand -base64 32 | tr -d '\n'
}

ensure_certificate() {
  local fullchain private_key cert_cache_abs cf_ini staging_arg

  if [ -n "${CERT_FULLCHAIN_FILE:-}" ] || [ -n "${CERT_PRIVATE_KEY_FILE:-}" ]; then
    [ -n "${CERT_FULLCHAIN_FILE:-}" ] || die "CERT_PRIVATE_KEY_FILE is set but CERT_FULLCHAIN_FILE is empty"
    [ -n "${CERT_PRIVATE_KEY_FILE:-}" ] || die "CERT_FULLCHAIN_FILE is set but CERT_PRIVATE_KEY_FILE is empty"
    fullchain="$(root_abs_path "$CERT_FULLCHAIN_FILE")"
    private_key="$(root_abs_path "$CERT_PRIVATE_KEY_FILE")"
    [ -f "$fullchain" ] || die "Certificate fullchain not found: $fullchain"
    [ -f "$private_key" ] || die "Certificate private key not found: $private_key"
    printf '%s\n%s\n' "$fullchain" "$private_key"
    return
  fi

  cert_cache_abs="$(root_abs_path "$CERT_CACHE_DIR")"
  mkdir -p "$cert_cache_abs"
  chmod 700 "$cert_cache_abs"

  fullchain="$cert_cache_abs/live/$DOMAIN/fullchain.pem"
  private_key="$cert_cache_abs/live/$DOMAIN/privkey.pem"
  if [ -f "$fullchain" ] && [ -f "$private_key" ]; then
    if openssl x509 -checkend "$CERT_RENEW_BEFORE_SECONDS" -noout -in "$fullchain" >/dev/null 2>&1; then
      log "Using cached certificate for $DOMAIN"
      printf '%s\n%s\n' "$fullchain" "$private_key"
      return
    fi
    log "Cached certificate exists but is within renewal window"
  fi

  require_env ACME_EMAIL
  [ "$ACME_EMAIL" != "you@example.com" ] || die "Set ACME_EMAIL in .env or provide CERT_FULLCHAIN_FILE/CERT_PRIVATE_KEY_FILE"
  need_cmd docker

  cf_ini="$STATE_DIR/cloudflare-certbot.ini"
  CERTBOT_CREDENTIALS_FILE="$cf_ini"
  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > "$cf_ini"
  umask 022

  staging_arg=""
  if [ "$(json_bool "$ACME_STAGING")" = true ]; then
    staging_arg="--staging"
  fi

  log "Ensuring Let's Encrypt certificate via Cloudflare DNS-01 for $DOMAIN"
  # shellcheck disable=SC2086
  docker run --rm \
    -v "$cert_cache_abs:/etc/letsencrypt" \
    -v "$cf_ini:/cloudflare.ini:ro" \
    "$CERTBOT_IMAGE" certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /cloudflare.ini \
    --dns-cloudflare-propagation-seconds "$ACME_DNS_PROPAGATION_SECONDS" \
    --non-interactive \
    --agree-tos \
    --email "$ACME_EMAIL" \
    --key-type ecdsa \
    --keep-until-expiring \
    -d "$DOMAIN" \
    $staging_arg >&2

  rm -f "$CERTBOT_CREDENTIALS_FILE"
  CERTBOT_CREDENTIALS_FILE=""

  fullchain="$cert_cache_abs/live/$DOMAIN/fullchain.pem"
  private_key="$cert_cache_abs/live/$DOMAIN/privkey.pem"
  [ -f "$fullchain" ] || die "Certbot finished but fullchain was not found: $fullchain"
  [ -f "$private_key" ] || die "Certbot finished but private key was not found: $private_key"
  printf '%s\n%s\n' "$fullchain" "$private_key"
}

upsert_dns_record() {
  local ip="$1"
  local encoded_domain response record_id payload proxied
  encoded_domain="$(urlencode "$DOMAIN")"
  response="$(cloudflare_api GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$encoded_domain&per_page=100")"
  record_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
  proxied="$(json_bool "$CF_PROXIED")"

  payload="$(jq -n \
    --arg name "$DOMAIN" \
    --arg content "$ip" \
    --arg comment "temporary service managed by deploy.sh" \
    --argjson ttl "$CF_TTL" \
    --argjson proxied "$proxied" \
    '{type:"A", name:$name, content:$content, ttl:$ttl, proxied:$proxied, comment:$comment}')"

  if [ -n "$record_id" ]; then
    log "Updating Cloudflare A record $DOMAIN -> $ip"
    response="$(cloudflare_api PATCH "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" "$payload")"
  else
    log "Creating Cloudflare A record $DOMAIN -> $ip"
    response="$(cloudflare_api POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$payload")"
  fi

  record_id="$(printf '%s' "$response" | jq -r '.result.id')"
  [ -n "$record_id" ] || die "Cloudflare did not return a DNS record id"
  printf '%s\n' "$record_id"
}

write_state() {
  local instance_id="$1"
  local ip="$2"
  local dns_record_id="$3"
  local password="$4"
  local client_uri="$5"
  local tmp

  tmp="$(mktemp)"
  jq -n \
    --arg domain "$DOMAIN" \
    --arg instance_id "$instance_id" \
    --arg main_ip "$ip" \
    --arg region "$VULTR_REGION" \
    --arg plan "$VULTR_PLAN" \
    --arg dns_record_id "$dns_record_id" \
    --arg trojan_password "$password" \
    --arg client_uri "$client_uri" \
    --arg remote_dir "$REMOTE_DIR" \
    --arg subscription_path "$SUBSCRIPTION_PATH" \
    --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      domain: $domain,
      instance_id: $instance_id,
      main_ip: $main_ip,
      region: $region,
      plan: $plan,
      dns_record_id: $dns_record_id,
      trojan_password: $trojan_password,
      client_uri: $client_uri,
      remote_dir: $remote_dir,
      subscription_path: $subscription_path,
      updated_at: $updated_at
    }' > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  printf '%s\n' "$client_uri" > "$STATE_DIR/client-uri.txt"
  chmod 600 "$STATE_DIR/client-uri.txt"
}

build_bundle() {
  local password="$1"
  local fullchain="$2"
  local private_key="$3"
  local bundle_dir="$STATE_DIR/build"

  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir/xray" "$bundle_dir/nginx/html" "$bundle_dir/certs"

  cp "$ROOT_DIR/templates/docker-compose.yml" "$bundle_dir/docker-compose.yml"
  sed \
    -e "s#__DOMAIN__#${DOMAIN}#g" \
    -e "s#__SUBSCRIPTION_PATH__#${SUBSCRIPTION_PATH}#g" \
    "$ROOT_DIR/templates/nginx-default.conf" > "$bundle_dir/nginx/default.conf"
  cp "$ROOT_DIR/templates/fallback-index.html" "$bundle_dir/nginx/html/index.html"
  cp "$ROOT_DIR/b.yaml" "$bundle_dir/nginx/html${SUBSCRIPTION_PATH}"
  cp "$fullchain" "$bundle_dir/certs/fullchain.pem"
  cp "$private_key" "$bundle_dir/certs/privkey.pem"
  chmod 644 "$bundle_dir/nginx/html/index.html" "$bundle_dir/nginx/html${SUBSCRIPTION_PATH}"
  chmod 644 "$bundle_dir/certs/fullchain.pem" "$bundle_dir/certs/privkey.pem"
  printf 'XRAY_IMAGE=%s\n' "$XRAY_IMAGE" > "$bundle_dir/.env"

  jq -n \
    --arg domain "$DOMAIN" \
    --arg password "$password" \
    '{
      log: {loglevel: "warning"},
      inbounds: [
        {
          tag: "trojan-in",
          listen: "0.0.0.0",
          port: 443,
          protocol: "trojan",
          settings: {
            clients: [
              {password: $password, email: "default"}
            ],
            fallbacks: [
              {dest: "nginx:8080"}
            ]
          },
          streamSettings: {
            network: "tcp",
            security: "tls",
            tlsSettings: {
              serverName: $domain,
              minVersion: "1.2",
              alpn: ["http/1.1"],
              certificates: [
                {
                  certificateFile: "/usr/local/etc/xray/certs/fullchain.pem",
                  keyFile: "/usr/local/etc/xray/certs/privkey.pem"
                }
              ]
            }
          }
        }
      ],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ]
    }' > "$bundle_dir/xray/config.json"

  printf '%s\n' "$bundle_dir"
}

build_cloud_init_file() {
  local bundle_dir="$1"
  local archive="$STATE_DIR/trojan-bundle.tar.gz"
  local cloud_init_file="$STATE_DIR/cloud-init-rendered.yml"
  local archive_b64

  tar -czf "$archive" -C "$bundle_dir" .
  archive_b64="$(base64_file "$archive")"

  {
    printf '#cloud-config\n'
    printf 'package_update: true\n'
    printf 'package_upgrade: false\n'
    printf 'packages:\n'
    printf '  - ca-certificates\n'
    printf '  - curl\n'
    printf 'write_files:\n'
    printf '  - path: /root/trojan-bundle.tar.gz\n'
    printf '    owner: root:root\n'
    printf "    permissions: '0600'\n"
    printf '    encoding: b64\n'
    printf '    content: %s\n' "$archive_b64"
    printf 'runcmd:\n'
    printf '  - install -m 0755 -d /etc/apt/keyrings\n'
    printf '  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc\n'
    printf '  - chmod a+r /etc/apt/keyrings/docker.asc\n'
    printf '  - sh -c '"'"'. /etc/os-release && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list'"'"'\n'
    printf '  - apt-get update\n'
    printf '  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin\n'
    printf '  - systemctl enable --now docker\n'
    printf '  - mkdir -p %s\n' "$REMOTE_DIR"
    printf '  - tar -xzf /root/trojan-bundle.tar.gz -C %s\n' "$REMOTE_DIR"
    printf '  - cd %s && docker compose pull && docker compose up -d --remove-orphans\n' "$REMOTE_DIR"
    printf '  - rm -f /root/trojan-bundle.tar.gz\n'
    printf '  - date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ > %s/.cloud-init-deployed\n' "$REMOTE_DIR"
  } > "$cloud_init_file"

  chmod 600 "$archive" "$cloud_init_file"
  printf '%s\n' "$cloud_init_file"
}

wait_for_ssh() {
  local ip="$1"
  local deadline
  deadline=$(( $(date +%s) + DEPLOY_WAIT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh_remote "$ip" true >/dev/null 2>&1; then
      log "SSH is ready on $ip"
      return
    fi
    log "Waiting for SSH on $ip"
    sleep "$SSH_WAIT_INTERVAL"
  done

  die "Timed out waiting for SSH on $ip"
}

deploy_remote_bundle() {
  local ip="$1"
  local bundle_dir="$2"
  local args=()
  while IFS= read -r -d '' item; do
    args+=("$item")
  done < <(ssh_args)

  wait_for_ssh "$ip"
  log "Waiting for cloud-init and Docker installation"
  ssh_remote "$ip" 'cloud-init status --wait'
  ssh_remote "$ip" 'docker --version && docker compose version'

  log "Uploading Docker bundle to $ip:$REMOTE_DIR"
  ssh_remote "$ip" "mkdir -p '$REMOTE_DIR'"
  scp "${args[@]}" -r "$bundle_dir"/. "$SSH_USER@$ip:$REMOTE_DIR/"

  log "Starting Xray Trojan service"
  ssh_remote "$ip" "cd '$REMOTE_DIR' && docker compose pull && docker compose up -d --remove-orphans && docker compose ps"
}

wait_for_https() {
  local ip="$1"
  local deadline
  deadline=$(( $(date +%s) + DEPLOY_WAIT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl --http1.1 -fsS --resolve "$DOMAIN:443:$ip" --connect-timeout 5 --max-time 10 "https://$DOMAIN/" >/dev/null 2>&1; then
      log "HTTPS fallback is ready on $DOMAIN ($ip)"
      return
    fi
    log "Waiting for HTTPS fallback on $DOMAIN ($ip)"
    sleep 10
  done

  die "Timed out waiting for HTTPS fallback on $DOMAIN ($ip)"
}

main() {
  local old_instance_id password cert_info fullchain private_key instance_info instance_id ip instance_reused dns_record_id client_uri bundle_dir cloud_init_file

  preflight_api_access
  old_instance_id="$(state_get instance_id || true)"
  password="$(ensure_trojan_password)"
  cert_info="$(ensure_certificate)"
  fullchain="$(printf '%s\n' "$cert_info" | sed -n '1p')"
  private_key="$(printf '%s\n' "$cert_info" | sed -n '2p')"

  bundle_dir="$(build_bundle "$password" "$fullchain" "$private_key")"
  if [ "$DEPLOY_METHOD" = "cloud-init" ]; then
    cloud_init_file="$(build_cloud_init_file "$bundle_dir")"
  else
    cloud_init_file="$ROOT_DIR/templates/cloud-init.yml"
  fi

  instance_info="$(ensure_instance "$cloud_init_file")"
  instance_id="$(printf '%s' "$instance_info" | awk '{print $1}')"
  ip="$(printf '%s' "$instance_info" | awk '{print $2}')"
  instance_reused="$(printf '%s' "$instance_info" | awk '{print $3}')"

  if [ "$DEPLOY_METHOD" = "cloud-init" ]; then
    if [ "$instance_reused" = true ]; then
      log "Reused cloud-init instance; local bundle changes are not applied. Use ./deploy.sh --force-new to rebuild the server."
    fi
    wait_for_https "$ip"
  else
    deploy_remote_bundle "$ip" "$bundle_dir"
  fi

  dns_record_id="$(upsert_dns_record "$ip")"

  client_uri="trojan://$(urlencode "$password")@$DOMAIN:443?security=tls&type=tcp&sni=$(urlencode "$DOMAIN")#$(urlencode "$VULTR_LABEL")"
  write_state "$instance_id" "$ip" "$dns_record_id" "$password" "$client_uri"
  destroy_old_instance_if_needed "$old_instance_id" "$instance_id"

  printf '\nDeployment complete.\n'
  printf 'Domain: %s\n' "$DOMAIN"
  printf 'IP: %s\n' "$ip"
  printf 'Subscription URL: https://%s%s\n' "$DOMAIN" "$SUBSCRIPTION_PATH"
  printf 'State: %s\n' "$STATE_FILE"
  printf 'Client URI:\n%s\n' "$client_uri"
}

main
