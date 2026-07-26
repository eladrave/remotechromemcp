#!/usr/bin/env bash
set -uo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/native-config.sh
source "$root_dir/lib/native-config.sh"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
failures=0

run_test() {
  local name=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

run_setup() {
  local sandbox=$1
  local domain=$2
  shift 2
  env -u DOMAIN -u CERTBOT_EMAIL -u EMAIL \
    REMOTE_CHROME_DRY_RUN=1 \
    REMOTE_CHROME_ROOT="$sandbox" \
    REMOTE_CHROME_HOME="$sandbox/home" \
    CHROME_BIN=/bin/true \
    PLAYWRIGHT_MCP_BIN=/bin/true \
    "$@" \
    bash "$root_dir/setup.sh" \
      --non-interactive \
      --domain "$domain" \
      --email operator@example.test
}

prepare_profile_and_token() {
  local sandbox=$1
  mkdir -p "$sandbox/home/.config/chrome-mcp-profile"
  printf 'profile-state\n' > "$sandbox/home/.config/chrome-mcp-profile/Cookies"
  printf 'BEARER_TOKEN=%064d\n' 0 > "$sandbox/home/.config/mcp-bearer-token.env"
  chmod 600 "$sandbox/home/.config/mcp-bearer-token.env"
}

test_dry_run_root_and_override_confinement() {
  local sandbox="$test_root/confinement"
  local outside="$test_root/outside"
  mkdir -p "$sandbox" "$outside"
  ln -s "$outside" "$test_root/root-link"

  if (
    unset REMOTE_CHROME_ROOT
    REMOTE_CHROME_DRY_RUN=1
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
  if (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_ROOT="$sandbox/../confinement"
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
  if (
    unset REMOTE_CHROME_DRY_RUN
    REMOTE_CHROME_ROOT="$sandbox"
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
  if (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_ROOT="$test_root/root-link"
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
  if (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_ROOT="$sandbox"
    REMOTE_CHROME_HOME="$outside"
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
  if (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_ROOT="$sandbox"
    REMOTE_CHROME_HOME="$sandbox/home"
    TOKEN_FILE="$sandbox/../outside/token"
    native_initialize_paths >/dev/null 2>&1
  ); then
    return 1
  fi
}

test_uninstall_rejects_dry_run_escape() {
  local sandbox="$test_root/uninstall-confinement"
  local outside="$test_root/uninstall-outside"
  mkdir -p "$sandbox/home/.config/systemd/user" "$outside"
  printf 'keep\n' > "$outside/sentinel"

  if printf 'yes\n' | REMOTE_CHROME_DRY_RUN=1 \
    bash "$root_dir/uninstall.sh" >/dev/null 2>&1; then
    return 1
  fi
  if printf 'yes\n' | REMOTE_CHROME_DRY_RUN=1 \
    REMOTE_CHROME_ROOT="$sandbox" \
    REMOTE_CHROME_HOME="$sandbox/home" \
    SYSTEMD_USER_DIR="$outside" \
    bash "$root_dir/uninstall.sh" >/dev/null 2>&1; then
    return 1
  fi
  [[ -f "$outside/sentinel" ]]
}

test_profile_deletion_target_matrix() {
  local sandbox="$test_root/delete-targets"
  local home="$sandbox/home"
  local expected="$home/.config/chrome-mcp-profile"
  local outside="$test_root/arbitrary-profile"
  mkdir -p "$expected" "$outside"
  ln -s "$outside" "$home/.config/profile-link"

  local candidate
  for candidate in \
    / \
    "$home" \
    "$home/.config" \
    "$outside" \
    "$home/.config/profile-link" \
    "$home/.config/../.config/chrome-mcp-profile"; do
    if native_validate_profile_deletion_target \
      "$candidate" "$expected" "$home" "$sandbox" >/dev/null 2>&1; then
      return 1
    fi
  done
  native_validate_profile_deletion_target \
    "$expected" "$expected" "$home" "$sandbox" >/dev/null 2>&1
}

test_backup_marker_collision_and_stop_failure() {
  local sandbox="$test_root/backup"
  prepare_profile_and_token "$sandbox"

  run_setup "$sandbox" chrome.example.test \
    REMOTE_CHROME_DRY_RUN_ACTIVATION_RESULT=fail >/dev/null 2>&1 || true
  local backup_marker="$sandbox/home/.config/remote-chrome-profile-backup-complete"
  [[ -f "$backup_marker" ]] || return 1
  local first_archive
  first_archive=$(cat "$backup_marker")
  [[ -f "$first_archive" ]] || return 1

  run_setup "$sandbox" chrome.example.test \
    REMOTE_CHROME_DRY_RUN_ACTIVATION_RESULT=fail >/dev/null 2>&1 || true
  [[ "$(cat "$backup_marker")" == "$first_archive" ]] || return 1
  local archives
  archives=$(find "$sandbox/home/.config/remote-chrome-backups" \
    -maxdepth 1 -name 'chrome-mcp-profile-*.tar.gz' | wc -l)
  [[ "$archives" == 1 ]] || return 1

  local stop_sandbox="$test_root/stop-failure"
  prepare_profile_and_token "$stop_sandbox"
  if run_setup "$stop_sandbox" chrome.example.test \
    REMOTE_CHROME_DRY_RUN_STOP_RESULT=fail >/dev/null 2>&1; then
    return 1
  fi
  [[ ! -e "$stop_sandbox/home/.config/remote-chrome-profile-backup-complete" ]]
}

test_absent_units_satisfy_stop_requirement() {
  local fake_bin="$test_root/stop-state/bin"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *" is-active "* ]]; then exit 3; fi' \
    'if [[ "$*" == *" stop "* ]]; then exit 5; fi' \
    'exit 1' > "$fake_bin/systemctl"
  chmod +x "$fake_bin/systemctl"
  PATH="$fake_bin:$PATH" REMOTE_CHROME_DRY_RUN=0 native_stop_active_browser
}

test_rollback_runtime_order_and_prior_state() {
  local sandbox="$test_root/rollback"
  local log="$sandbox/commands.log"
  prepare_profile_and_token "$sandbox"
  if run_setup "$sandbox" chrome.example.test \
    REMOTE_CHROME_DRY_RUN_ACTIVE_UNITS="chrome-display.service chrome-mcp.service" \
    REMOTE_CHROME_DRY_RUN_NGINX_ACTIVE=1 \
    REMOTE_CHROME_DRY_RUN_ACTIVATION_RESULT=fail \
    REMOTE_CHROME_COMMAND_LOG="$log" >/dev/null 2>&1; then
    return 1
  fi
  [[ -f "$log" ]] || return 1

  local expected="$sandbox/expected.log"
  printf '%s\n' \
    'capture-active chrome-display.service chrome-mcp.service' \
    'capture-nginx active' \
    'stop playwright-mcp.service' \
    'stop chrome-mcp.service' \
    'rollback-stop playwright-mcp.service' \
    'rollback-stop chrome-novnc.service' \
    'rollback-stop chrome-vnc.service' \
    'rollback-stop chrome-mcp.service' \
    'rollback-stop chrome-window-manager.service' \
    'rollback-stop chrome-display.service' \
    'rollback-daemon-reload' \
    'rollback-start chrome-display.service' \
    'rollback-start chrome-mcp.service' \
    'rollback-nginx-reload' > "$expected"

  diff -u "$expected" "$log"
}

make_status_fakes() {
  local fake_bin=$1
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *"/json/version"* ]]; then' \
    '  printf '"'"'%s\n'"'"' '"'"'{"Browser":"Chrome/1","User-Agent":"Chrome/1"}'"'"'' \
    '  exit 0' \
    'fi' \
    'if [[ "$*" == *":8931/mcp"* ]]; then' \
    '  case "${FAKE_MCP_MODE:-success}" in' \
    '    404) printf '"'"'not found'"'"'; exit 22 ;;' \
    '    500) printf '"'"'server error'"'"'; exit 22 ;;' \
    '    error) printf '"'"'%s'"'"' '"'"'{"jsonrpc":"2.0","id":1,"error":{"code":-32603}}'"'"'; exit 0 ;;' \
    '    success) printf '"'"'%s'"'"' '"'"'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","instructions":"REMOTE_CHROME_PLAYBOOK_VERSION=1"}}'"'"'; exit 0 ;;' \
    '  esac' \
    'fi' \
    'if [[ "$*" == *":6080/"* ]]; then printf '"'"'200'"'"'; exit 0; fi' \
    'exit 1' > "$fake_bin/curl"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '"'"'inactive\n'"'"'' > "$fake_bin/systemctl"
  chmod +x "$fake_bin/curl" "$fake_bin/systemctl"
}

test_status_initialize_validation() {
  local sandbox="$test_root/status"
  local fake_bin="$sandbox/bin"
  mkdir -p "$sandbox/home"
  make_status_fakes "$fake_bin"

  local mode output
  for mode in 404 500 error; do
    output=$(PATH="$fake_bin:$PATH" HOME="$sandbox/home" \
      FAKE_MCP_MODE="$mode" bash "$root_dir/status.sh")
    [[ "$output" == *"Initialize: FAIL"* ]] || return 1
  done
  output=$(PATH="$fake_bin:$PATH" HOME="$sandbox/home" \
    FAKE_MCP_MODE=success bash "$root_dir/status.sh")
  [[ "$output" == *"Initialize: PASS"* ]] &&
    [[ "$output" == *"Playbook marker: PRESENT"* ]]
}

test_domain_change_preserves_credentials_and_updates_url() {
  local sandbox="$test_root/domain-change"
  prepare_profile_and_token "$sandbox"
  run_setup "$sandbox" first.example.test >/dev/null || return 1
  local login_file="$sandbox/home/.config/remote-chrome-login.env"
  local username_before password_before
  username_before=$(sed -n 's/^LOGIN_USERNAME=//p' "$login_file")
  password_before=$(sed -n 's/^LOGIN_PASSWORD=//p' "$login_file")

  run_setup "$sandbox" second.example.test >/dev/null || return 1
  [[ "$(sed -n 's/^LOGIN_USERNAME=//p' "$login_file")" == "$username_before" ]] &&
    [[ "$(sed -n 's/^LOGIN_PASSWORD=//p' "$login_file")" == "$password_before" ]] &&
    grep -Fxq 'LOGIN_URL=https://second.example.test/login/' "$login_file"
}

run_test dry_run_root_and_override_confinement test_dry_run_root_and_override_confinement
run_test uninstall_rejects_dry_run_escape test_uninstall_rejects_dry_run_escape
run_test profile_deletion_target_matrix test_profile_deletion_target_matrix
run_test backup_marker_collision_and_stop_failure test_backup_marker_collision_and_stop_failure
run_test absent_units_satisfy_stop_requirement test_absent_units_satisfy_stop_requirement
run_test rollback_runtime_order_and_prior_state test_rollback_runtime_order_and_prior_state
run_test status_initialize_validation test_status_initialize_validation
run_test domain_change_preserves_credentials_and_updates_url \
  test_domain_change_preserves_credentials_and_updates_url

if ((failures)); then
  printf '%d fix-round test(s) failed\n' "$failures" >&2
  exit 1
fi
