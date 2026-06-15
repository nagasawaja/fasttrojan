#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script is only for macOS." >&2
  exit 1
fi

echo "Flushing macOS DNS cache. sudo may ask for your password."
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
echo "macOS DNS cache flushed."

