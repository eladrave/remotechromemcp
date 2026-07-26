#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_mode_owner() {
  local file=$1
  [[ $(stat -c '%a' "$file") == 600 ]] ||
    fail "$file must be mode 600"
  if [[ $EUID -eq 0 ]]; then
    [[ $(stat -c '%U:%G' "$file") == root:root ]] ||
      fail "$file must be root-owned"
  else
    grep -Fq "chown <root:root> <$file.tmp." "$FAKE_COMMAND_LOG" ||
      fail "$file must be installed through the root-ownership boundary"
  fi
}

read_env_value() {
  local file=$1 key=$2 value
  value=$(awk -v key="$key" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      if (value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file") || return 1
  printf '%s' "$value"
}

assert_order() {
  local log=$1
  shift
  local previous=0 needle line
  for needle in "$@"; do
    line=$(grep -n -m1 -Fx -- "$needle" "$log" | cut -d: -f1) ||
      fail "missing ordered transition: $needle"
    ((line > previous)) ||
      fail "transition is out of order: $needle"
    previous=$line
  done
}

test_root="$(mktemp -d /tmp/remote-chrome-vminstall-management.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
[[ -d $test_root && $test_root == /tmp/* && ! -L $test_root ]] ||
  fail 'management test root must be a real directory beneath /tmp'

fake_bin="$test_root/fake-bin"
mkdir "$fake_bin"
fake_log="$test_root/fake-command.log"
: >"$fake_log"
export FAKE_COMMAND_LOG="$fake_log"

apply_patch_fake() {
  local destination=$1
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '%s\n' "$@"
  } >"$destination"
  chmod +x "$destination"
}

apply_patch_fake "$fake_bin/openssl" \
  'printf "openssl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'case "${1:-}:${2:-}:${3:-}" in' \
  '  rand:-hex:32)' \
  '    od -An -N32 -tx1 /dev/urandom | tr -d " \n"' \
  '    printf "\n"' \
  '    ;;' \
  '  rand:-base64:48)' \
  '    head -c 48 /dev/urandom | base64 | tr -d "\n"' \
  '    printf "\n"' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac'

apply_patch_fake "$fake_bin/docker" \
  'printf "docker" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'if [[ " $* " == *" caddy hash-password "* ]]; then' \
  '  IFS= read -r plaintext' \
  '  digest=$(printf "%s" "$plaintext" | sha256sum | cut -c1-53)' \
  '  printf "\0442a\04414\044%s\n" "$digest"' \
  'elif [[ " $* " == *" compose "*" ps "* ]]; then' \
  '  if [[ ${REMOTE_CHROME_ROLLBACK:-0} == 1 && ${REMOTE_CHROME_FAKE_ROLLBACK_UNHEALTHY:-0} == 1 ]]; then' \
  '    printf "browser unhealthy\nproxy healthy\n"' \
  '  else' \
  '    printf "browser healthy\nproxy healthy\n"' \
  '  fi' \
  'fi'

apply_patch_fake "$fake_bin/systemctl" \
  'printf "systemctl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"'

apply_patch_fake "$fake_bin/chown" \
  'printf "chown" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"'

apply_patch_fake "$fake_bin/curl" \
  'printf "curl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'method=GET; headers=; output=; url=' \
  'while (($#)); do' \
  '  case "$1" in' \
  '    --request) method=$2; shift 2 ;;' \
  '    --dump-header) headers=$2; shift 2 ;;' \
  '    --output) output=$2; shift 2 ;;' \
  '    --header) [[ $2 == @* ]] && cat "${2#@}" >/dev/null; shift 2 ;;' \
  '    --write-out) shift 2 ;;' \
  '    --*) shift ;;' \
  '    *) url=$1; shift ;;' \
  '  esac' \
  'done' \
  'status=200' \
  'case "$method:$url" in' \
  '  POST:*/mcp)' \
  '    status=200' \
  '    printf "HTTP/2 200\r\nContent-Type: application/json\r\nMcp-Session-Id: fixture-session\r\n\r\n" >"$headers"' \
  '    printf "{}" >"$output"' \
  '    ;;' \
  '  DELETE:*/mcp) status=202 ;;' \
  '  GET:*/mcp) status=405 ;;' \
  '  GET:*/login/) status=401; printf "HTTP/2 401\r\nWWW-Authenticate: Basic realm=\"Remote Chrome\"\r\n\r\n" >"$headers" ;;' \
  '  GET:*/login/websockify) status=101 ;;' \
  'esac' \
  'printf "%s" "$status"'

export PATH="$fake_bin:$PATH"
export REMOTE_CHROME_SKIP_MAIN=1
# shellcheck source=../vminstall/installer-main.sh
source vminstall/installer-main.sh

for required_function in \
  vm_prepare_config vm_generate_credentials vm_render_compose_env \
  vm_activate_release vm_rollback_release vm_verify_public_stack \
  vm_print_connection_handoff; do
  declare -F "$required_function" >/dev/null ||
    fail "$required_function is undefined"
done

REMOTE_CHROME_TEST_ROOT="$test_root/first-install"
mkdir "$REMOTE_CHROME_TEST_ROOT"
vm_init_paths
DOMAIN=chrome.example.com
ACME_EMAIL=ops@example.com
REMOTE_CHROME_DATA_DIR="$REMOTE_CHROME_TEST_ROOT/data/../data"
GCS_BUCKET=fixture-backups
BACKUP_SCHEDULE='*-*-* 03:00:00'
ROTATE_CREDENTIALS=0
SELECTED_VERSION=v1.2.3
REMOTE_CHROME_TRANSITION_LOG="$REMOTE_CHROME_TEST_ROOT/transitions.log"
REMOTE_CHROME_TTY="$REMOTE_CHROME_TEST_ROOT/installer.tty"
: >"$REMOTE_CHROME_TTY"

vm_prepare_config
credentials_candidate="$REMOTE_CHROME_CONFIG_ROOT/credentials.env.candidate"
compose_candidate="$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate"
install_candidate="$REMOTE_CHROME_CONFIG_ROOT/install.env.candidate"
service_candidate="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate"
for candidate in \
  "$credentials_candidate" "$compose_candidate" "$install_candidate"; do
  [[ -f $candidate ]] || fail "missing candidate configuration: $candidate"
  assert_file_mode_owner "$candidate"
done

first_token=$(read_env_value "$credentials_candidate" MCP_TOKEN)
first_password=$(read_env_value "$credentials_candidate" LOGIN_PASSWORD)
first_hash=$(read_env_value "$compose_candidate" LOGIN_PASSWORD_HASH)
[[ $first_token =~ ^[0-9a-f]{64}$ ]] ||
  fail 'first install token must be 64 lowercase hex characters'
[[ ${#first_password} -ge 64 && $first_password != "$first_token" ]] ||
  fail 'login password must be generated independently from at least 36 random bytes'
grep -Fxq 'openssl <rand> <-base64> <48>' "$fake_log" ||
  fail 'password generation must request at least 36 random bytes'
[[ $first_hash == '$2a$14$'* ]] ||
  fail 'Caddy password hash must use bcrypt'
! grep -Fq -- "$first_password" "$fake_log" ||
  fail 'plaintext login password leaked to command logs'

canonical_data=$(realpath -m "$REMOTE_CHROME_DATA_DIR")
[[ $(read_env_value "$install_candidate" REMOTE_CHROME_DATA_DIR) == "$canonical_data" ]] ||
  fail 'data directory must be stored canonically'
for data_subdir in profile caddy-data caddy-config backups restore-staging; do
  data_path="$canonical_data/$data_subdir"
  [[ -d $data_path && $(realpath -m "$data_path") == "$canonical_data"/* ]] ||
    fail "$data_subdir must remain beneath the canonical data root"
done
touch "$canonical_data/caddy-data/preserve" "$canonical_data/caddy-config/preserve"

grep -Fxq "LOGIN_PASSWORD_HASH='$first_hash'" "$compose_candidate" ||
  fail 'bcrypt value must remain single-quoted for Compose dollar safety'
grep -Fxq 'PROXY_BIND_ADDRESS=0.0.0.0' "$compose_candidate" ||
  fail 'Compose must bind the proxy only on all public interfaces'
grep -Fxq 'PROXY_HTTP_PORT=80' "$compose_candidate" ||
  fail 'Compose must publish only HTTP 80'
grep -Fxq 'PROXY_HTTPS_PORT=443' "$compose_candidate" ||
  fail 'Compose must publish only HTTPS 443'
grep -Fxq 'PLAYWRIGHT_MCP_VERSION=0.0.78' "$compose_candidate" ||
  fail 'Compose must pin the MCP version'

for fixed_service_line in \
  'WorkingDirectory=/opt/remotechromemcp/current' \
  'EnvironmentFile=/etc/remote-chrome/install.env' \
  'ExecStart=/usr/bin/docker compose -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env up -d' \
  'ExecStartPost=/usr/local/sbin/remote-chrome wait-ready' \
  'ExecStop=/usr/bin/docker compose -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env down'; do
  grep -Fxq "$fixed_service_line" "$service_candidate" ||
    fail "systemd service must render fixed absolute paths: $fixed_service_line"
done

# Promote the first candidate as a fixture for a reinstall contract.
for name in install.env compose.env credentials.env; do
  cp "$REMOTE_CHROME_CONFIG_ROOT/$name.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/$name"
  chmod 0600 "$REMOTE_CHROME_CONFIG_ROOT/$name"
done

DOMAIN=changed.example.com
ACME_EMAIL=changed@example.com
REMOTE_CHROME_DATA_DIR="$REMOTE_CHROME_TEST_ROOT/changed-data"
GCS_BUCKET=changed-bucket
BACKUP_SCHEDULE='daily'
ROTATE_CREDENTIALS=0
vm_prepare_config
[[ $(read_env_value "$credentials_candidate" MCP_TOKEN) == "$first_token" ]] ||
  fail 'reinstall must preserve the MCP token'
[[ $(read_env_value "$credentials_candidate" LOGIN_USERNAME) == remotechrome ]] ||
  fail 'reinstall must preserve the login username'
[[ $(read_env_value "$credentials_candidate" LOGIN_PASSWORD) == "$first_password" ]] ||
  fail 'reinstall must preserve the login password'
[[ $(read_env_value "$install_candidate" DOMAIN) == chrome.example.com ]] ||
  fail 'reinstall must preserve the installed domain'
[[ $(read_env_value "$install_candidate" GCS_BUCKET) == fixture-backups ]] ||
  fail 'reinstall must preserve backup bucket settings'
[[ $(read_env_value "$install_candidate" BACKUP_SCHEDULE) == '*-*-* 03:00:00' ]] ||
  fail 'reinstall must preserve backup schedule settings'
[[ -f $canonical_data/caddy-data/preserve &&
   -f $canonical_data/caddy-config/preserve ]] ||
  fail 'reinstall must preserve Caddy state directories'

ROTATE_CREDENTIALS=1
vm_prepare_config
rotated_token=$(read_env_value "$credentials_candidate" MCP_TOKEN)
rotated_password=$(read_env_value "$credentials_candidate" LOGIN_PASSWORD)
[[ $rotated_token =~ ^[0-9a-f]{64}$ && $rotated_token != "$first_token" ]] ||
  fail 'explicit rotation must change the MCP authentication domain'
[[ $rotated_password != "$first_password" ]] ||
  fail 'explicit rotation must change the login authentication domain'

newline_domain="$(printf 'chrome.example.com\ninjected.example.com')"
DOMAIN=$newline_domain
rm -f "$service_candidate"
if vm_prepare_config >/dev/null 2>&1; then
  fail 'configuration values containing newlines must be rejected'
fi
[[ ! -e $service_candidate ]] ||
  fail 'newline rejection must occur before service rendering'

make_release() {
  local root=$1 ref=$2
  local release="$root/opt/remotechromemcp/releases/$ref"
  mkdir -p "$release/vminstall"
  printf 'services: {}\n' >"$release/compose.yaml"
  printf 'services: {}\n' >"$release/vminstall/compose.vm.yaml"
}

setup_activation_fixture() {
  local root=$1
  mkdir -p "$root"
  REMOTE_CHROME_TEST_ROOT=$root
  vm_init_paths
  mkdir -p "$REMOTE_CHROME_INSTALL_ROOT/releases" \
    "$REMOTE_CHROME_CONFIG_ROOT" "$REMOTE_CHROME_SYSTEMD_ROOT"
  make_release "$root" v1.0.0
  ln -s "releases/v1.0.0" "$REMOTE_CHROME_INSTALL_ROOT/current"

  DOMAIN=chrome.example.com
  ACME_EMAIL=ops@example.com
  REMOTE_CHROME_DATA_DIR="$root/var/lib/remote-chrome"
  GCS_BUCKET=fixture-backups
  BACKUP_SCHEDULE='*-*-* 03:00:00'
  ROTATE_CREDENTIALS=0
  SELECTED_VERSION=v1.0.0
  vm_prepare_config
  for name in install.env compose.env credentials.env; do
    cp "$REMOTE_CHROME_CONFIG_ROOT/$name.candidate" \
      "$REMOTE_CHROME_CONFIG_ROOT/$name"
    chmod 0600 "$REMOTE_CHROME_CONFIG_ROOT/$name"
  done
  cp "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service"
  printf 'v1.0.0\n' >"$REMOTE_CHROME_CONFIG_ROOT/active-version"

  SELECTED_VERSION=v2.0.0
  STAGED_RELEASE_DIR="$REMOTE_CHROME_INSTALL_ROOT/releases/.staging-v2.0.0-$$"
  mkdir -p "$STAGED_RELEASE_DIR/vminstall"
  printf 'services: {}\n' >"$STAGED_RELEASE_DIR/compose.yaml"
  printf 'services: {}\n' >"$STAGED_RELEASE_DIR/vminstall/compose.vm.yaml"
  REMOTE_CHROME_TRANSITION_LOG="$root/transitions.log"
  : >"$REMOTE_CHROME_TRANSITION_LOG"
  REMOTE_CHROME_TTY="$root/installer.tty"
  : >"$REMOTE_CHROME_TTY"
  COMMAND_LOG="$root/installer-command.log"
  : >"$COMMAND_LOG"
  : >"$fake_log"
}

success_root="$test_root/activation-success"
setup_activation_fixture "$success_root"
prior_token=$(read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" MCP_TOKEN)
vm_activate_release
[[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v2.0.0 ]] ||
  fail 'current must switch to the candidate only after Compose config succeeds'
[[ $(<"$REMOTE_CHROME_CONFIG_ROOT/active-version") == v2.0.0 ]] ||
  fail 'active version must be recorded after all verification succeeds'
for installed in install.env compose.env credentials.env; do
  assert_file_mode_owner "$REMOTE_CHROME_CONFIG_ROOT/$installed"
done
assert_order "$REMOTE_CHROME_TRANSITION_LOG" \
  release-installed candidate-config-written compose-config-validated \
  current-switched config-installed service-reloaded service-started \
  health-verified public-verified active-recorded
assert_order "$fake_log" \
  "docker <compose> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/compose.yaml> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/vminstall/compose.vm.yaml> <--env-file> <$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate> <config>" \
  "systemctl <daemon-reload>" \
  "systemctl <enable> <--now> <remote-chrome.service>"

vm_print_connection_handoff
installed_token=$(read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" MCP_TOKEN)
installed_password=$(read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" LOGIN_PASSWORD)
installed_hash=$(read_env_value "$REMOTE_CHROME_CONFIG_ROOT/compose.env" LOGIN_PASSWORD_HASH)
for handoff_text in \
  'Remote Chrome is ready.' \
  'Preferred MCP URL: https://chrome.example.com/mcp' \
  "Authorization: Bearer $installed_token" \
  "Compatibility MCP URL: https://chrome.example.com/$installed_token/mcp" \
  'Login URL: https://chrome.example.com/login/' \
  'Login username: remotechrome' \
  "Login password: $installed_password" \
  'Certificate: HTTPS managed by Caddy (ACME)' \
  'Credentials file: /etc/remote-chrome/credentials.env' \
  'Profile: /var/lib/remote-chrome/profile' \
  'Status: sudo remote-chrome status' \
  'Credentials: sudo remote-chrome credentials' \
  'Backup: sudo remote-chrome backup' \
  'Restore: sudo remote-chrome restore' \
  '"url": "https://chrome.example.com/mcp"' \
  "authorization = \"Bearer $installed_token\""; do
  grep -Fq -- "$handoff_text" "$REMOTE_CHROME_TTY" ||
    fail "connection handoff missing: $handoff_text"
done
! grep -Fq -- "$installed_hash" "$REMOTE_CHROME_TTY" ||
  fail 'connection handoff must never expose the bcrypt hash'
! grep -Fq -- "$installed_hash" "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" ||
  fail 'root credentials file must never expose the bcrypt hash'
! grep -Eq 'journalctl|systemd-cat' "$fake_log" ||
  fail 'handoff must never be written through systemd or the journal'
! grep -Fq -- "$installed_password" "$fake_log" ||
  fail 'activation command log leaked the login password'
! grep -Fq -- "$installed_token" "$fake_log" ||
  fail 'activation command log leaked the bearer token'

# Mutating the Compose validation result must keep current on the prior release.
config_fail_root="$test_root/compose-config-failure"
setup_activation_fixture "$config_fail_root"
REMOTE_CHROME_FAIL_AT=compose-config-validated
set +e
vm_activate_release >/dev/null 2>&1
config_fail_status=$?
set -e
unset REMOTE_CHROME_FAIL_AT
[[ $config_fail_status -ne 0 ]] ||
  fail 'injected Compose validation failure must abort activation'
[[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
  fail 'current must not switch when Compose candidate validation fails'

for early_failure_point in release-installed candidate-config-written; do
  early_failure_root="$test_root/early-$early_failure_point"
  setup_activation_fixture "$early_failure_root"
  previous_install_sha=$(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/install.env")
  REMOTE_CHROME_FAIL_AT=$early_failure_point
  set +e
  vm_activate_release >"$early_failure_root/stdout" \
    2>"$early_failure_root/stderr"
  early_failure_status=$?
  set -e
  unset REMOTE_CHROME_FAIL_AT
  [[ $early_failure_status -ne 0 ]] ||
    fail "$early_failure_point injection must abort activation"
  [[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
    fail "$early_failure_point must occur before current is switched"
  [[ $(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/install.env") == \
    "$previous_install_sha" ]] ||
    fail "$early_failure_point must preserve installed configuration"
  ! grep -Fq 'systemctl <enable>' "$fake_log" ||
    fail "$early_failure_point must occur before service activation"
done

post_switch_points=(
  current-switched config-installed service-reloaded service-started
  health-verified public-verified active-recorded
)
for failure_point in "${post_switch_points[@]}"; do
  rollback_root="$test_root/rollback-$failure_point"
  setup_activation_fixture "$rollback_root"
  previous_install_sha=$(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/install.env")
  previous_compose_sha=$(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/compose.env")
  previous_credentials_sha=$(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/credentials.env")
  REMOTE_CHROME_FAIL_AT=$failure_point
  set +e
  vm_activate_release >"$rollback_root/stdout" 2>"$rollback_root/stderr"
  rollback_status=$?
  set -e
  unset REMOTE_CHROME_FAIL_AT
  [[ $rollback_status -ne 0 && $rollback_status -ne 70 ]] ||
    fail "$failure_point must return the activation failure, not success/70"
  [[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
    fail "$failure_point rollback must restore the prior symlink"
  [[ $(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/install.env") == "$previous_install_sha" &&
     $(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/compose.env") == "$previous_compose_sha" &&
     $(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/credentials.env") == "$previous_credentials_sha" ]] ||
    fail "$failure_point rollback must restore all prior environment state"
  [[ $(<"$REMOTE_CHROME_CONFIG_ROOT/active-version") == v1.0.0 ]] ||
    fail "$failure_point rollback must preserve the prior active version"
  grep -Fq ' <down>' "$fake_log" ||
    fail "$failure_point rollback must stop the candidate Compose project"
  grep -Fxq 'systemctl <start> <remote-chrome.service>' "$fake_log" ||
    fail "$failure_point rollback must restart the prior service"
  grep -Fq ' <ps> ' "$fake_log" ||
    fail "$failure_point rollback must health-check the prior version"
done

rollback_health_root="$test_root/rollback-health-failure"
setup_activation_fixture "$rollback_health_root"
REMOTE_CHROME_FAIL_AT=service-started
export REMOTE_CHROME_FAKE_ROLLBACK_UNHEALTHY=1
REMOTE_CHROME_HEALTH_ATTEMPTS=1
set +e
vm_activate_release >"$rollback_health_root/stdout" \
  2>"$rollback_health_root/stderr"
rollback_health_status=$?
set -e
unset REMOTE_CHROME_FAIL_AT REMOTE_CHROME_FAKE_ROLLBACK_UNHEALTHY \
  REMOTE_CHROME_HEALTH_ATTEMPTS
if [[ $rollback_health_status -ne 70 ]]; then
  sed 's/[0-9a-f]\{64\}/[REDACTED]/g' \
    "$rollback_health_root/stderr" >&2
  fail "failed rollback health must return distinct status 70, got $rollback_health_status"
fi
grep -Fq 'rollback health verification failed' \
  "$rollback_health_root/stderr" ||
  fail 'rollback health failure must be reported distinctly'

printf 'PASS: VM protected configuration, activation, rollback, and handoff contracts\n'
