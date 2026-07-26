#!/usr/bin/env bash
# status.sh — report the native headed Remote Chrome deployment.
set -euo pipefail

remote_home="${REMOTE_CHROME_HOME:-$HOME}"
token_file="${TOKEN_FILE:-$remote_home/.config/mcp-bearer-token.env}"
login_env_file="${LOGIN_ENV_FILE:-$remote_home/.config/remote-chrome-login.env}"
cdp_port="${CDP_PORT:-9222}"
mcp_port="${MCP_INTERNAL_PORT:-8931}"
novnc_port="${NOVNC_PORT:-6080}"
units=(
  chrome-display.service
  chrome-window-manager.service
  chrome-mcp.service
  chrome-vnc.service
  chrome-novnc.service
  playwright-mcp.service
)
initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"status-check","version":"1.0"}}}'

status_label() {
  local state=$1
  if [[ "$state" == active ]]; then
    printf 'active'
  else
    printf '%s' "$state"
  fi
}

printf 'Remote Chrome MCP status\n\n'
printf 'User services:\n'
for unit in "${units[@]}"; do
  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  [[ -n "$state" ]] || state=unknown
  printf '  %-37s %s\n' "$unit" "$(status_label "$state")"
done

printf '\nCDP browser metadata:\n'
cdp_metadata=$(curl --silent --show-error --max-time 3 \
  "http://127.0.0.1:${cdp_port}/json/version" 2>/dev/null || true)
if [[ -n "$cdp_metadata" ]]; then
  browser=$(printf '%s' "$cdp_metadata" |
    sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  user_agent=$(printf '%s' "$cdp_metadata" |
    sed -n 's/.*"User-Agent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '  Browser: %s\n' "${browser:-unknown}"
  printf '  User agent: %s\n' "${user_agent:-unknown}"
  if [[ "$user_agent" == *HeadlessChrome* || -z "$user_agent" ]]; then
    printf '  Headed check: FAIL\n'
  else
    printf '  Headed check: PASS\n'
  fi
else
  printf '  Unreachable at 127.0.0.1:%s\n' "$cdp_port"
  printf '  Headed check: FAIL\n'
fi

printf '\nPlaywright MCP initialize:\n'
mcp_response=$(curl --silent --show-error --max-time 10 \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  "http://127.0.0.1:${mcp_port}/mcp" \
  -d "$initialize_payload" 2>/dev/null || true)
if [[ -n "$mcp_response" ]]; then
  printf '  Initialize: PASS\n'
  if [[ "$mcp_response" == *REMOTE_CHROME_PLAYBOOK_VERSION=1* ]]; then
    printf '  Playbook marker: PRESENT\n'
  else
    printf '  Playbook marker: MISSING\n'
  fi
else
  printf '  Initialize: FAIL\n'
  printf '  Playbook marker: UNKNOWN\n'
fi

printf '\nnoVNC local HTTP:\n'
novnc_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 3 "http://127.0.0.1:${novnc_port}/" 2>/dev/null || true)
printf '  HTTP status: %s\n' "${novnc_code:-000}"

printf '\nnginx:\n'
nginx_state=$(systemctl is-active nginx 2>/dev/null || true)
printf '  Service: %s\n' "${nginx_state:-unknown}"

domain="${DOMAIN:-}"
if [[ -f "$login_env_file" ]]; then
  # shellcheck disable=SC1090
  source "$login_env_file"
  if [[ -z "$domain" && "${LOGIN_URL-}" =~ ^https://([^/]+)/ ]]; then
    domain=${BASH_REMATCH[1]}
  fi
fi

if [[ -n "$domain" ]]; then
  printf '\nAuthenticated public MCP:\n'
  if [[ -f "$token_file" ]]; then
    # shellcheck disable=SC1090
    source "$token_file"
    public_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 10 \
      -X POST \
      -H "Authorization: Bearer ${BEARER_TOKEN-}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      "https://${domain}/mcp" \
      -d "$initialize_payload" 2>/dev/null || true)
    printf '  https://%s/mcp: HTTP %s\n' "$domain" "${public_code:-000}"
  else
    printf '  Not checked: bearer token file missing\n'
  fi
else
  printf '\nAuthenticated public MCP: not configured (no domain found)\n'
fi
