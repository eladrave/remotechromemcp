#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT

export DOMAIN=chrome.example.test
export MCP_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
export LOGIN_HTPASSWD_FILE=/tmp/remote-chrome-login.htpasswd
export PROJECT_DIR=/opt/remotechromemcp
export PROFILE_DIR=/var/lib/remote-chrome/profile
export CHROME_BIN=/usr/bin/google-chrome
export PLAYWRIGHT_MCP_BIN=/usr/bin/playwright-mcp
export DISPLAY_NUMBER=99
export SCREEN_GEOMETRY=1440x900x24
export MCP_INTERNAL_PORT=8931
export CDP_PORT=9222
export VNC_PORT=5900
export NOVNC_PORT=6080

source "$root_dir/lib/native-config.sh"
render_native_config "$output"

assert_contains() {
  local file=$1
  local expected=$2
  if ! grep -Fq -- "$expected" "$file"; then
    echo "expected $file to contain: $expected" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -Fqi -- "$unexpected" "$file"; then
    echo "expected $file not to contain: $unexpected" >&2
    exit 1
  fi
}

nginx="$output/nginx/playwright-mcp.conf"
systemd="$output/systemd"
expected_files=(
  "$nginx"
  "$systemd/chrome-display.service"
  "$systemd/chrome-window-manager.service"
  "$systemd/chrome-mcp.service"
  "$systemd/chrome-vnc.service"
  "$systemd/chrome-novnc.service"
  "$systemd/playwright-mcp.service"
)

for file in "${expected_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "expected rendered file: $file" >&2
    exit 1
  fi
done

chrome_service="$systemd/chrome-mcp.service"
playwright_service="$systemd/playwright-mcp.service"

assert_contains "$chrome_service" "Environment=DISPLAY=:99"
assert_not_contains "$chrome_service" "--headless"
assert_contains "$playwright_service" "Environment=NODE_OPTIONS=--require=/opt/remotechromemcp/lib/inject-instructions.cjs"

assert_contains "$nginx" "location /login/"
assert_contains "$nginx" "auth_basic "
assert_contains "$nginx" "auth_basic_user_file /tmp/remote-chrome-login.htpasswd;"
assert_contains "$nginx" 'proxy_set_header Upgrade $http_upgrade;'
assert_contains "$nginx" 'proxy_set_header Connection $connection_upgrade;'
assert_contains "$nginx" "location = /0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/mcp"
assert_contains "$nginx" "location = /mcp"
assert_contains "$nginx" 'if ($http_authorization != "Bearer 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")'
assert_contains "$nginx" "return 405;"
assert_contains "$nginx" "access_log off;"
assert_not_contains "$nginx" "Content-Type"

if grep -ERq '@[A-Z0-9_]+@' "$output"; then
  echo "unresolved template marker found under $output" >&2
  exit 1
fi

assert_render_rejected() {
  local label=$1
  shift
  if (
    export "$@"
    render_native_config "$output/rejected-$label" >/dev/null 2>&1
  ); then
    echo "expected native renderer to reject: $label" >&2
    exit 1
  fi
}

assert_render_rejected invalid-domain "DOMAIN=-chrome.example.test"
assert_render_rejected invalid-token "MCP_TOKEN=ABCDEF"
assert_render_rejected invalid-port "CDP_PORT=65536"

echo "native configuration contract passed"
