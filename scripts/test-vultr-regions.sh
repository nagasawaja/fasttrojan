#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/test-vultr-regions.sh [--regions CODE[,CODE...]] [--ping-count N] [--bytes N]

Examples:
  ./scripts/test-vultr-regions.sh
  ./scripts/test-vultr-regions.sh --regions nrt,sgp,icn
  ./scripts/test-vultr-regions.sh --bytes 10485760

Options:
  --regions     Comma-separated Vultr region codes to test.
                Default: nrt,osa,icn,sgp
  --ping-count  Number of ICMP echo requests per region. Default: 4
  --bytes       Bytes to download for the throughput test via HTTP range request.
                Default: 10485760 (10 MiB)
  -h, --help    Show this help

The script uses Vultr Looking Glass hosts and tests:
  1. Ping latency and packet loss
  2. Partial download throughput from vultr.com.100MB.bin
USAGE
}

REGIONS="nrt,osa,icn,sgp"
PING_COUNT=4
DOWNLOAD_BYTES=10485760

while [ "$#" -gt 0 ]; do
  case "$1" in
    --regions)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      REGIONS="$2"
      shift 2
      ;;
    --ping-count)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      PING_COUNT="$2"
      shift 2
      ;;
    --bytes)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      DOWNLOAD_BYTES="$2"
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

case "$PING_COUNT" in
  ''|*[!0-9]*)
    echo "Invalid --ping-count: $PING_COUNT" >&2
    exit 1
    ;;
esac

case "$DOWNLOAD_BYTES" in
  ''|*[!0-9]*)
    echo "Invalid --bytes: $DOWNLOAD_BYTES" >&2
    exit 1
    ;;
esac

command -v ping >/dev/null 2>&1 || {
  echo "Missing ping." >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || {
  echo "Missing curl." >&2
  exit 1
}

region_name() {
  case "$1" in
    nrt) printf 'Tokyo' ;;
    osa) printf 'Osaka' ;;
    icn) printf 'Seoul' ;;
    sgp) printf 'Singapore' ;;
    syd) printf 'Sydney' ;;
    *) return 1 ;;
  esac
}

region_host() {
  case "$1" in
    nrt) printf 'hnd-jp-ping.vultr.com' ;;
    osa) printf 'osk-jp-ping.vultr.com' ;;
    icn) printf 'sel-kor-ping.vultr.com' ;;
    sgp) printf 'sgp-ping.vultr.com' ;;
    syd) printf 'syd-au-ping.vultr.com' ;;
    *) return 1 ;;
  esac
}

print_header() {
  printf '%-5s %-10s %-24s %10s %9s %12s %8s\n' \
    'Code' 'Region' 'Host' 'Avg(ms)' 'Loss(%)' 'Speed(Mbps)' 'HTTP'
}

test_ping() {
  local host="$1"
  local output loss avg

  if ! output="$(ping -c "$PING_COUNT" "$host" 2>&1)"; then
    printf 'ERR ERR'
    return
  fi

  loss="$(printf '%s\n' "$output" | awk -F', ' '/packet loss/ {gsub("%", "", $3); print $3}' | head -n 1)"
  avg="$(printf '%s\n' "$output" | awk -F'/' '/min\/avg\/max/ {print $5}' | head -n 1)"

  [ -n "$loss" ] || loss="ERR"
  [ -n "$avg" ] || avg="ERR"
  printf '%s %s' "$avg" "$loss"
}

test_download() {
  local host="$1"
  local url http_code speed

  url="https://$host/vultr.com.100MB.bin"
  if ! output="$(curl -L -sS \
      --connect-timeout 5 \
      --max-time 30 \
      --range "0-$((DOWNLOAD_BYTES - 1))" \
      -o /dev/null \
      -w '%{http_code} %{speed_download}' \
      "$url" 2>&1)"; then
    printf 'ERR ERR'
    return
  fi

  http_code="$(printf '%s\n' "$output" | awk '{print $1}')"
  speed="$(printf '%s\n' "$output" | awk '{print $2}')"

  if [ -z "$http_code" ] || [ -z "$speed" ]; then
    printf 'ERR ERR'
    return
  fi

  speed_mbps="$(awk -v bps="$speed" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')"
  printf '%s %s' "$speed_mbps" "$http_code"
}

print_header

old_ifs="$IFS"
IFS=','
for code in $REGIONS; do
  code="$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]' | xargs)"
  if ! name="$(region_name "$code")"; then
    printf '%-5s %-10s %-24s %10s %9s %12s %8s\n' "$code" 'UNKNOWN' '-' '-' '-' '-' '-'
    continue
  fi
  host="$(region_host "$code")"

  ping_result="$(test_ping "$host")"
  ping_avg="$(printf '%s\n' "$ping_result" | awk '{print $1}')"
  ping_loss="$(printf '%s\n' "$ping_result" | awk '{print $2}')"

  download_result="$(test_download "$host")"
  speed_mbps="$(printf '%s\n' "$download_result" | awk '{print $1}')"
  http_code="$(printf '%s\n' "$download_result" | awk '{print $2}')"

  printf '%-5s %-10s %-24s %10s %9s %12s %8s\n' \
    "$code" "$name" "$host" "$ping_avg" "$ping_loss" "$speed_mbps" "$http_code"
done
IFS="$old_ifs"
