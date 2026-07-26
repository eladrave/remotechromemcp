#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp -d)
sandbox=$(mktemp -d)
trap 'rm -rf "$output" "$sandbox"' EXIT

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
assert_not_contains "$chrome_service" "--no-sandbox"
assert_not_contains "$chrome_service" "User="
assert_contains "$playwright_service" "Environment=NODE_OPTIONS=--require=/opt/remotechromemcp/lib/inject-instructions.cjs"

for service in "$systemd"/*.service; do
  assert_contains "$service" "WantedBy=default.target"
  assert_not_contains "$service" "WantedBy=multi-user.target"
  assert_not_contains "$service" "network.target"
done

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

user_secret="$sandbox/user-secret.env"
REMOTE_CHROME_ROOT=/
if ! native_write_user_secret "$user_secret" "SECRET_VALUE=local"; then
  echo "expected user secret installation not to require privileged writes" >&2
  exit 1
fi
if [[ "$(stat -c '%u:%a' "$user_secret")" != "$(id -u):600" ]]; then
  echo "expected user secret to remain user-owned with mode 600" >&2
  exit 1
fi

if ! (
  health_attempts=0
  native_health_checks_once() {
    ((health_attempts += 1))
    ((health_attempts >= 3))
  }
  REMOTE_CHROME_HEALTHCHECK_ATTEMPTS=3
  REMOTE_CHROME_HEALTHCHECK_DELAY=0
  native_wait_for_health_checks
  [[ "$health_attempts" == 3 ]]
); then
  echo "expected activation health checks to wait for service readiness" >&2
  exit 1
fi

##############################################################################
# Native installer and migration contracts
##############################################################################
test_home="$sandbox/home"
test_profile="$test_home/.config/chrome-mcp-profile"
test_token_file="$test_home/.config/mcp-bearer-token.env"
test_login_file="$test_home/.config/remote-chrome-login.env"
test_htpasswd_file="$sandbox/etc/nginx/.remote-chrome-login.htpasswd"
test_marker="$test_home/.config/remote-chrome-headed-migration"
test_units="$test_home/.config/systemd/user"
mkdir -p "$test_profile"
printf '%s\n' 'profile-state' > "$test_profile/Cookies"
printf '%s\n' 'stale-lock' > "$test_profile/SingletonLock"
printf '%s\n' 'BEARER_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$test_token_file"
chmod 600 "$test_token_file"

run_dry_setup() {
  REMOTE_CHROME_DRY_RUN=1 \
  REMOTE_CHROME_ROOT="$sandbox" \
  REMOTE_CHROME_HOME="$test_home" \
  CHROME_BIN=/bin/true \
  PLAYWRIGHT_MCP_BIN=/bin/true \
    bash "$root_dir/setup.sh" \
      --non-interactive \
      --domain chrome.example.test \
      --email operator@example.test
}

setup_first_output=$(run_dry_setup)
setup_second_output=$(run_dry_setup)

assert_contains <(printf '%s\n' "$setup_first_output") \
  "APT packages: xvfb openbox x11vnc novnc websockify apache2-utils"

for secret_file in "$test_token_file" "$test_login_file" "$test_htpasswd_file"; do
  if [[ ! -f "$secret_file" ]]; then
    echo "expected secret file: $secret_file" >&2
    exit 1
  fi
  if [[ "$(stat -c '%a' "$secret_file")" != "600" ]]; then
    echo "expected mode 600 for secret file: $secret_file" >&2
    exit 1
  fi
done

login_password=$(sed -n 's/^LOGIN_PASSWORD=//p' "$test_login_file")
if ((${#login_password} < 32)); then
  echo "expected login password to contain at least 32 characters" >&2
  exit 1
fi
assert_contains "$test_login_file" "LOGIN_USERNAME="
assert_contains "$test_login_file" "LOGIN_URL=https://chrome.example.test/login/"

if [[ "$(cat "$test_token_file")" != \
  "BEARER_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]; then
  echo "expected existing bearer token to be preserved" >&2
  exit 1
fi

first_login_secret=$(cat "$test_login_file")
run_dry_setup >/dev/null
if [[ "$(cat "$test_login_file")" != "$first_login_secret" ]]; then
  echo "expected rerun to preserve login credentials" >&2
  exit 1
fi

backup_requests=$(printf '%s\n%s\n' "$setup_first_output" "$setup_second_output" |
  grep -Fc "Backing up Chrome profile before headed migration" || true)
if [[ "$backup_requests" != "1" ]]; then
  echo "expected exactly one headed migration profile backup request, got $backup_requests" >&2
  exit 1
fi
if [[ ! -f "$test_marker" ]]; then
  echo "expected headed migration marker after successful dry-run activation" >&2
  exit 1
fi
shopt -s nullglob
profile_backups=("$test_home"/.config/remote-chrome-backups/chrome-mcp-profile-*.tar.gz)
shopt -u nullglob
if ((${#profile_backups[@]} != 1)); then
  echo "expected exactly one profile backup, got ${#profile_backups[@]}" >&2
  exit 1
fi
if tar -tzf "${profile_backups[0]}" | grep -q 'Singleton'; then
  echo "expected profile backup to exclude Singleton locks" >&2
  exit 1
fi

for unit in chrome-display chrome-window-manager chrome-mcp chrome-vnc chrome-novnc playwright-mcp; do
  if [[ ! -f "$test_units/$unit.service" ]]; then
    echo "expected installed user unit: $test_units/$unit.service" >&2
    exit 1
  fi
done

printf '%s\n' 'previous chrome service configuration' > "$test_units/chrome-mcp.service"
rm -f "$test_marker"
if REMOTE_CHROME_DRY_RUN=1 \
  REMOTE_CHROME_DRY_RUN_ACTIVATION_RESULT=fail \
  REMOTE_CHROME_ROOT="$sandbox" \
  REMOTE_CHROME_HOME="$test_home" \
  CHROME_BIN=/bin/true \
  PLAYWRIGHT_MCP_BIN=/bin/true \
    bash "$root_dir/setup.sh" \
      --non-interactive \
      --domain chrome.example.test \
      --email operator@example.test >/dev/null 2>&1; then
  echo "expected simulated activation failure" >&2
  exit 1
fi
if [[ "$(cat "$test_units/chrome-mcp.service")" != "previous chrome service configuration" ]]; then
  echo "expected activation failure to restore previous user-unit configuration" >&2
  exit 1
fi
if [[ -e "$test_marker" ]]; then
  echo "expected failed activation not to write migration marker" >&2
  exit 1
fi

# Return the dry-run root to an activated state for uninstall assertions.
run_dry_setup >/dev/null

if grep -Eq 'systemctl[[:space:]]+--user[[:space:]]+(stop|restart)|rm[[:space:]].*Singleton' \
  "$root_dir/login.sh"; then
  echo "login.sh must not stop/restart Chrome services or delete profile locks" >&2
  exit 1
fi

printf 'yes\n' | \
  REMOTE_CHROME_DRY_RUN=1 \
  REMOTE_CHROME_ROOT="$sandbox" \
  REMOTE_CHROME_HOME="$test_home" \
    bash "$root_dir/uninstall.sh" >/dev/null

for preserved in "$test_profile" "$test_token_file" "$test_login_file"; do
  if [[ ! -e "$preserved" ]]; then
    echo "expected default uninstall to preserve: $preserved" >&2
    exit 1
  fi
done

printf 'yes\n' | \
  REMOTE_CHROME_DRY_RUN=1 \
  REMOTE_CHROME_ROOT="$sandbox" \
  REMOTE_CHROME_HOME="$test_home" \
    bash "$root_dir/uninstall.sh" --delete-profile >/dev/null

if [[ -e "$test_profile" ]]; then
  echo "expected --delete-profile to remove: $test_profile" >&2
  exit 1
fi
for preserved_secret in "$test_token_file" "$test_login_file"; do
  if [[ ! -f "$preserved_secret" ]]; then
    echo "expected uninstall to preserve secret: $preserved_secret" >&2
    exit 1
  fi
done

echo "native configuration contract passed"
