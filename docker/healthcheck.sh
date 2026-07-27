#!/usr/bin/env bash
set -euo pipefail

for process_name in Xvfb openbox x11vnc websockify; do
  pgrep --exact "$process_name" >/dev/null
done

cdp_version="$(
  curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:9222/json/version
)"
printf '%s' "$cdp_version" | jq -e \
  '(.Browser | startswith("Chrome/")) and
   (."User-Agent" | contains("HeadlessChrome") | not)' >/dev/null

mcp_code="$(
  curl --silent --show-error --max-time 10 \
    --output /dev/null \
    --write-out '%{http_code}' \
    http://127.0.0.1:8931/mcp
)"
[[ "$mcp_code" == 400 ]]

curl --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:6080/ |
  grep -qi 'noVNC'
