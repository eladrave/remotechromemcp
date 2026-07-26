#!/usr/bin/env bash
set -euo pipefail

runtime_dir=/run/remote-chrome
mkdir -p "$runtime_dir"
mcp_body="$(mktemp "$runtime_dir/health-mcp.XXXXXX")"
novnc_body="$(mktemp "$runtime_dir/health-novnc.XXXXXX")"
trap 'rm -f "$mcp_body" "$novnc_body"' EXIT

cdp_version="$(
  curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:9222/json/version
)"
printf '%s' "$cdp_version" | jq -e \
  '(.Browser | startswith("Chrome/")) and
   (."User-Agent" | contains("HeadlessChrome") | not)' >/dev/null

initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compose-health","version":"1.0"}}}'
mcp_code="$(
  curl --silent --show-error --max-time 10 \
    --output "$mcp_body" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data "$initialize_payload" \
    http://127.0.0.1:8931/mcp
)"
[[ "$mcp_code" == 200 ]]
grep -q 'REMOTE_CHROME_PLAYBOOK_VERSION=1' "$mcp_body"

curl --fail --silent --show-error --max-time 5 \
  --output "$novnc_body" \
  http://127.0.0.1:6080/
grep -qi 'noVNC' "$novnc_body"
