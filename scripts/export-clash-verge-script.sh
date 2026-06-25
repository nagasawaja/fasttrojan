#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib.sh
. "$ROOT_DIR/scripts/lib.sh"

STATE_DIR="${STATE_DIR:-$ROOT_DIR/.state}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/trojan-state.json}"
OUTPUT_FILE="${1:-$STATE_DIR/clash-verge-script.js}"

need_cmd jq

[ -f "$STATE_FILE" ] || die "State file not found: $STATE_FILE"

domain="$(state_get domain)"
proxy_stack="$(state_get proxy_stack || true)"
password="$(state_get trojan_password)"

[ -n "$proxy_stack" ] || proxy_stack="trojan"
[ -n "$domain" ] || die "Missing domain in state"
[ "$proxy_stack" = "trojan" ] || die "Clash Verge enhancement script is only supported for Trojan deployments"
[ -n "$password" ] || die "Missing trojan_password in state"

mkdir -p "$(dirname "$OUTPUT_FILE")"
chmod 700 "$(dirname "$OUTPUT_FILE")"

jq -n \
  --arg name "trojan-$domain" \
  --arg server "$domain" \
  --arg password "$password" \
  '{
    name: $name,
    type: "trojan",
    server: $server,
    port: 443,
    password: $password,
    sni: $server,
    "skip-cert-verify": false,
    network: "tcp"
  }' > "$STATE_DIR/.clash-node.json"

node_json="$(cat "$STATE_DIR/.clash-node.json")"
rm -f "$STATE_DIR/.clash-node.json"

cat > "$OUTPUT_FILE" <<EOF
// Clash Verge Rev profile enhancement script.
// Attach this script to your existing subscription profile.
// It appends your private Trojan node after each subscription update, so rules
// and proxy groups from the subscription keep working.

function main(config) {
  const node = $node_json;
  const groupNameHints = [
    "节点选择",
    "手动选择",
    "代理",
    "PROXY",
    "Proxy",
    "GLOBAL",
  ];

  config.proxies = Array.isArray(config.proxies) ? config.proxies : [];
  config["proxy-groups"] = Array.isArray(config["proxy-groups"]) ? config["proxy-groups"] : [];

  const existingIndex = config.proxies.findIndex((proxy) => proxy && proxy.name === node.name);
  if (existingIndex >= 0) {
    config.proxies[existingIndex] = node;
  } else {
    config.proxies.unshift(node);
  }

  const shouldPatchGroup = (group) => {
    if (!group || !Array.isArray(group.proxies)) return false;
    if (groupNameHints.includes(group.name)) return true;
    return group.type === "select" && /(节点|选择|代理|Proxy|PROXY|手动)/.test(group.name || "");
  };

  for (const group of config["proxy-groups"]) {
    if (!shouldPatchGroup(group)) continue;
    group.proxies = group.proxies.filter((name) => name !== node.name);
    group.proxies.unshift(node.name);
  }

  return config;
}
EOF

chmod 600 "$OUTPUT_FILE"
printf 'Wrote %s\n' "$OUTPUT_FILE"
