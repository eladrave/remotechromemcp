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
    grep -Fq \
      "chown <root:root> <$(dirname "$file")/.${file##*/}.tmp." \
      "$FAKE_COMMAND_LOG" ||
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
cleanup_test_root() {
  local status=$?
  if [[ ${REMOTE_CHROME_KEEP_TEST_ROOT:-0} == 1 && $status -ne 0 ]]; then
    printf 'DEBUG: preserved test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root"
  fi
  exit "$status"
}
trap cleanup_test_root EXIT
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
  '  s_client:*)' \
  '    [[ " $* " == *" -connect chrome.example.com:443 "* ]] || exit 81' \
  '    [[ " $* " == *" -servername chrome.example.com "* ]] || exit 82' \
  '    [[ " $* " == *" -verify_return_error"* ]] || exit 83' \
  '    printf "%s\n" "FIXTURE VERIFIED CERTIFICATE"' \
  '    ;;' \
  '  x509:-noout:-issuer)' \
  '    [[ " $* " == *" -enddate"* ]] || exit 84' \
  '    grep -Fxq "FIXTURE VERIFIED CERTIFICATE" || exit 85' \
  '    printf "%s\n" "issuer=CN = Fixture Test CA" "notAfter=Jul 27 12:00:00 2027 GMT"' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac'

apply_patch_fake "$fake_bin/timeout" \
  'printf "timeout" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  '[[ ${1:-} == 5 ]] || exit 86' \
  'shift' \
  'exec "$@"'

apply_patch_fake "$fake_bin/docker" \
  'printf "docker" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'if [[ " $* " == *" caddy hash-password "* ]]; then' \
  '  IFS= read -r plaintext' \
  '  digest=$(printf "%s" "$plaintext" | sha256sum | cut -c1-53)' \
  '  printf "\0442a\04414\044%s\n" "$digest"' \
  'elif [[ " $* " == *" compose "*" config"* ]]; then' \
  '  env_file=' \
  '  for ((i=1; i<=$#; i++)); do' \
  '    if [[ ${!i} == --env-file ]]; then j=$((i + 1)); env_file=${!j}; fi' \
  '  done' \
  '  token=$(awk -F= '\''$1 == "MCP_TOKEN" { print $2; exit }'\'' "$env_file")' \
  '  if [[ " $* " != *" config --quiet"* || ${REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL:-0} == 1 ]]; then' \
  '    printf "rendered MCP_TOKEN=%s\n" "$token"' \
  '    printf "compose warning MCP_TOKEN=%s\n" "$token" >&2' \
  '  fi' \
  '  [[ ${REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL:-0} != 1 ]]' \
  'elif [[ " $* " == *" compose "*" ps "* ]]; then' \
  '  if [[ ${REMOTE_CHROME_ROLLBACK:-0} == 1 && ${REMOTE_CHROME_FAKE_ROLLBACK_UNHEALTHY:-0} == 1 ]]; then' \
  '    printf "browser unhealthy\nproxy healthy\n"' \
  '  else' \
  '    printf "browser healthy\nproxy healthy\n"' \
  '  fi' \
  'elif [[ " $* " == *" compose "*" down"* && ${REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL:-0} == 1 ]]; then' \
  '  printf "candidate shutdown failed\n" >&2' \
  '  exit 87' \
  'fi'

apply_patch_fake "$fake_bin/systemctl" \
  'printf "systemctl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'case "${1:-}" in' \
  '  is-enabled) [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" ]] ;;' \
  '  is-active) [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active" ]] ;;' \
  '  enable)' \
  '    touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled"' \
  '    if [[ " $* " == *" --now "* ]]; then' \
  '      touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"' \
  '      "$REMOTE_CHROME_CLI_ROOT/remote-chrome" wait-ready' \
  '      [[ ${REMOTE_CHROME_FAKE_SYSTEMCTL_ENABLE_NOW_FAIL:-0} != 1 ]]' \
  '    fi' \
  '    ;;' \
  '  disable) rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" ;;' \
  '  start) touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active" ;;' \
  '  stop) rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active" ;;' \
  'esac'

apply_patch_fake "$fake_bin/chown" \
  'printf "chown" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"'

apply_patch_fake "$fake_bin/curl" \
  'printf "curl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'method=GET; headers=; output=; url=; header_file=; data=; http1=0; max_time=' \
  'while (($#)); do' \
  '  case "$1" in' \
    '    --request) method=$2; shift 2 ;;' \
    '    --dump-header) headers=$2; shift 2 ;;' \
    '    --output) output=$2; shift 2 ;;' \
  '    --header) [[ $2 == @* ]] && header_file=${2#@}; shift 2 ;;' \
  '    --data-binary) data=$2; shift 2 ;;' \
  '    --http1.1) http1=1; shift ;;' \
  '    --max-time) max_time=$2; shift 2 ;;' \
  '    --write-out) shift 2 ;;' \
  '    --*) shift ;;' \
  '    *) url=$1; shift ;;' \
  '  esac' \
  'done' \
  'auth=; session=; websocket_key=' \
  'if [[ -n $header_file ]]; then' \
  '  auth=$(awk -F": " '\''tolower($1) == "authorization" { print $2; exit }'\'' "$header_file" | tr -d "\r")' \
  '  session=$(awk -F": " '\''tolower($1) == "mcp-session-id" { print $2; exit }'\'' "$header_file" | tr -d "\r")' \
  '  websocket_key=$(awk -F": " '\''tolower($1) == "sec-websocket-key" { print $2; exit }'\'' "$header_file" | tr -d "\r")' \
  'fi' \
  'bearer="Bearer $REMOTE_CHROME_EXPECT_TOKEN"' \
  'basic="Basic $(printf "%s:%s" "$REMOTE_CHROME_EXPECT_USERNAME" "$REMOTE_CHROME_EXPECT_PASSWORD" | base64 -w0)"' \
  'status=500; event=invalid' \
  'case "$method:$url" in' \
  '  POST:https://chrome.example.com/mcp)' \
  '    [[ $auth == "$bearer" && $data == *'\''"method":"initialize"'\''* ]] || exit 91' \
  '    status=200; event=initialize' \
  '    printf "HTTP/2 200\r\nContent-Type: application/json\r\nMcp-Session-Id: fixture-session\r\n\r\n" >"$headers"' \
  '    printf "{}" >"$output"' \
  '    ;;' \
  '  DELETE:https://chrome.example.com/mcp)' \
  '    [[ $auth == "$bearer" && $session == fixture-session ]] || exit 92' \
  '    status=202; event=delete ;;' \
  '  GET:https://chrome.example.com/mcp)' \
  '    [[ $auth == "$bearer" ]] || exit 93' \
  '    status=405; event=get-405 ;;' \
  '  GET:https://chrome.example.com/login/)' \
  '    if [[ -z $auth ]]; then' \
  '      status=401; event=login-401' \
  '      printf "HTTP/2 401\r\nWWW-Authenticate: Basic realm=\"Remote Chrome\"\r\n\r\n" >"$headers"' \
  '    else' \
  '      [[ $auth == "$basic" ]] || exit 94' \
  '      status=200; event=login-200; printf "<title>noVNC</title>" >"$output"' \
  '    fi' \
  '    ;;' \
  '  GET:https://chrome.example.com/login/websockify)' \
  '    [[ $auth == "$basic" && $http1 == 1 && $max_time == 3 ]] || exit 95' \
  '    [[ $(printf "%s" "$websocket_key" | base64 -d 2>/dev/null | wc -c) -eq 16 ]] || exit 96' \
  '    if [[ ${REMOTE_CHROME_FAKE_WEBSOCKET_MODE:-} == timeout-no-101 ]]; then' \
  '      : >"$headers"; printf "000"; exit 28' \
  '    fi' \
  '    if [[ ${REMOTE_CHROME_FAKE_WEBSOCKET_MODE:-} == other-error ]]; then' \
  '      printf "HTTP/1.1 101 Switching Protocols\r\n\r\n" >"$headers"' \
  '      printf "101"; exit 7' \
  '    fi' \
  '    status=101; event=websocket-101' \
  '    printf "HTTP/1.1 101 Switching Protocols\r\n\r\n" >"$headers"' \
  '    printf "%s" "$status"' \
  '    printf "%s\n" "$event" >>"$REMOTE_CHROME_PROTOCOL_LOG"' \
  '    exit 28' \
  '    ;;' \
  '  *) exit 97 ;;' \
  'esac' \
  'printf "%s\n" "$event" >>"$REMOTE_CHROME_PROTOCOL_LOG"' \
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

# Secret replacement must reject every symlinked managed component and must
# not trust the old predictable .tmp.$$ name.
secret_attack_root="$REMOTE_CHROME_TEST_ROOT/secret-attacks"
mkdir -p "$secret_attack_root/managed" "$secret_attack_root/attacker"
ln -s "$secret_attack_root/attacker" "$secret_attack_root/managed/symlink-parent"
if printf 'secret\n' |
  vm_write_secret_file "$secret_attack_root/managed/symlink-parent/value" \
    2>"$secret_attack_root/symlink-rejection.stderr"; then
  fail 'secret writer must reject a symlinked parent inside a managed root'
fi
[[ ! -e $secret_attack_root/attacker/value ]] ||
  fail 'symlinked-parent attack must not create an attacker-controlled file'
predictable_destination="$secret_attack_root/managed/predictable"
predictable_victim="$secret_attack_root/attacker/victim"
printf 'unchanged\n' >"$predictable_victim"
ln -s "$predictable_victim" "${predictable_destination}.tmp.$$"
printf 'replacement\n' | vm_write_secret_file "$predictable_destination"
[[ $(<"$predictable_victim") == unchanged ]] ||
  fail 'precreated predictable temporary symlink must never be followed'
[[ $(<"$predictable_destination") == replacement ]] ||
  fail 'secret writer must still atomically install through an unpredictable temporary'
[[ $(stat -c '%a' "$predictable_destination") == 600 ]] ||
  fail 'secret writer temporary and destination must be mode 600'

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
  mkdir -p "$release/vminstall/lib"
  printf 'services: {}\n' >"$release/compose.yaml"
  printf 'services: {}\n' >"$release/vminstall/compose.vm.yaml"
  if [[ -f vminstall/remote-chrome ]]; then
    cp vminstall/remote-chrome "$release/vminstall/remote-chrome"
    chmod +x "$release/vminstall/remote-chrome"
    cp vminstall/lib/common.sh vminstall/lib/config.sh \
      vminstall/lib/activate.sh "$release/vminstall/lib/"
  fi
}

setup_activation_fixture() {
  local root=$1
  mkdir -p "$root"
  REMOTE_CHROME_TEST_ROOT=$root
  vm_init_paths
  export REMOTE_CHROME_TEST_ROOT REMOTE_CHROME_INSTALL_ROOT \
    REMOTE_CHROME_CONFIG_ROOT REMOTE_CHROME_SYSTEMD_ROOT \
    REMOTE_CHROME_CLI_ROOT
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
  {
    printf '%s\n' \
      'CERTIFICATE_STATUS=ready' \
      'CERTIFICATE_ISSUER=CN = Prior Fixture CA' \
      'CERTIFICATE_EXPIRES=Jul 27 12:00:00 2026 GMT'
  } >"$REMOTE_CHROME_CONFIG_ROOT/certificate.env"
  chmod 0600 "$REMOTE_CHROME_CONFIG_ROOT/certificate.env"
  install -d -m 0755 "$REMOTE_CHROME_CLI_ROOT"
  if [[ -f vminstall/remote-chrome ]]; then
    install -m 0755 vminstall/remote-chrome \
      "$REMOTE_CHROME_CLI_ROOT/remote-chrome"
  fi

  SELECTED_VERSION=v2.0.0
  STAGED_RELEASE_DIR="$REMOTE_CHROME_INSTALL_ROOT/releases/.staging-v2.0.0-$$"
  mkdir -p "$STAGED_RELEASE_DIR/vminstall/lib"
  printf 'services: {}\n' >"$STAGED_RELEASE_DIR/compose.yaml"
  printf 'services: {}\n' >"$STAGED_RELEASE_DIR/vminstall/compose.vm.yaml"
  if [[ -f vminstall/remote-chrome ]]; then
    cp vminstall/remote-chrome "$STAGED_RELEASE_DIR/vminstall/remote-chrome"
    chmod +x "$STAGED_RELEASE_DIR/vminstall/remote-chrome"
    cp vminstall/lib/common.sh vminstall/lib/config.sh \
      vminstall/lib/activate.sh "$STAGED_RELEASE_DIR/vminstall/lib/"
  fi
  REMOTE_CHROME_TRANSITION_LOG="$root/transitions.log"
  : >"$REMOTE_CHROME_TRANSITION_LOG"
  REMOTE_CHROME_TTY="$root/installer.tty"
  : >"$REMOTE_CHROME_TTY"
  COMMAND_LOG="$root/installer-command.log"
  : >"$COMMAND_LOG"
  export REMOTE_CHROME_FAKE_SYSTEMD_STATE="$root/systemd-state"
  mkdir -p "$REMOTE_CHROME_FAKE_SYSTEMD_STATE"
  touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" \
    "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"
  export REMOTE_CHROME_PROTOCOL_LOG="$root/protocol.log"
  : >"$REMOTE_CHROME_PROTOCOL_LOG"
  export REMOTE_CHROME_EXPECT_TOKEN
  REMOTE_CHROME_EXPECT_TOKEN=$(
    read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" MCP_TOKEN
  )
  export REMOTE_CHROME_EXPECT_USERNAME=remotechrome
  export REMOTE_CHROME_EXPECT_PASSWORD
  REMOTE_CHROME_EXPECT_PASSWORD=$(
    read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" LOGIN_PASSWORD
  )
  : >"$fake_log"
}

success_root="$test_root/activation-success"
setup_activation_fixture "$success_root"
prior_token=$(read_env_value "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" MCP_TOKEN)
vm_activate_release >"$success_root/stdout" 2>"$success_root/stderr"
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
  "docker <compose> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/compose.yaml> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/vminstall/compose.vm.yaml> <--env-file> <$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate> <config> <--quiet>" \
  "systemctl <daemon-reload>" \
  "systemctl <enable> <--now> <remote-chrome.service>"
[[ -x $REMOTE_CHROME_CLI_ROOT/remote-chrome ]] ||
  fail 'ExecStartPost target must be installed before service activation'
grep -Fq ' <ps> ' "$fake_log" ||
  fail 'the installed ExecStartPost wait-ready target must execute successfully'
[[ $(stat -c '%a' "$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log") == 600 ]] ||
  fail 'Compose diagnostics must be retained only in a root-only mode-600 file'
[[ $(<"$REMOTE_CHROME_PROTOCOL_LOG") == $'initialize\ndelete\nget-405\nlogin-401\nlogin-200\nwebsocket-101' ]] ||
  fail 'public verification must perform the complete strict protocol in order'
grep -Fq ' <--http1.1> <--max-time> <3>' "$fake_log" ||
  fail 'WebSocket verification must use a bounded three-second request'
grep -Fxq \
  'timeout <5> <openssl> <s_client> <-connect> <chrome.example.com:443> <-servername> <chrome.example.com> <-verify_return_error>' \
  "$fake_log" ||
  fail 'certificate metadata probe must be bounded and validate domain SNI'
certificate_state="$REMOTE_CHROME_CONFIG_ROOT/certificate.env"
[[ -f $certificate_state && $(stat -c '%a' "$certificate_state") == 600 ]] ||
  fail 'verified certificate metadata must be stored in root-only state'
[[ $(read_env_value "$certificate_state" CERTIFICATE_STATUS) == ready &&
   $(read_env_value "$certificate_state" CERTIFICATE_ISSUER) == \
     'CN = Fixture Test CA' &&
   $(read_env_value "$certificate_state" CERTIFICATE_EXPIRES) == \
     'Jul 27 12:00:00 2027 GMT' ]] ||
  fail 'certificate state must contain deterministic readiness, issuer, and expiry'

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
  'Certificate: ready (public HTTPS verified during activation)' \
  'Certificate issuer: CN = Fixture Test CA' \
  'Certificate expires: Jul 27 12:00:00 2027 GMT' \
  'Credentials file: /etc/remote-chrome/credentials.env' \
  'Profile: /var/lib/remote-chrome/profile' \
  'Status: sudo remote-chrome status' \
  'Credentials: sudo remote-chrome credentials' \
  'Backup: sudo remote-chrome backup' \
  'Restore: sudo remote-chrome restore' \
  '"mcpServers": {' \
  '"url": "https://chrome.example.com/mcp"' \
  '[mcp_servers.remote_chrome]' \
  "headers = { Authorization = \"Bearer $installed_token\" }"; do
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
! grep -Fq -- "$installed_token" "$success_root/stdout" 2>/dev/null ||
  fail 'activation stdout leaked the bearer token'
! grep -Fq -- "$installed_token" "$success_root/stderr" 2>/dev/null ||
  fail 'activation stderr leaked the bearer token'

# Exit 28 is acceptable only after a captured 101 handshake, and unrelated
# curl failures remain fatal even if a 101 header was written.
for websocket_mode in timeout-no-101 other-error; do
  websocket_failure_root="$test_root/websocket-$websocket_mode"
  setup_activation_fixture "$websocket_failure_root"
  export REMOTE_CHROME_FAKE_WEBSOCKET_MODE=$websocket_mode
  if vm_verify_public_stack >"$websocket_failure_root/stdout" \
    2>"$websocket_failure_root/stderr"; then
    fail "WebSocket verification accepted invalid curl outcome: $websocket_mode"
  fi
  unset REMOTE_CHROME_FAKE_WEBSOCKET_MODE
done

# Mutating the Compose validation result must keep current on the prior release.
config_fail_root="$test_root/compose-config-failure"
setup_activation_fixture "$config_fail_root"
export REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL=1
set +e
vm_activate_release >"$config_fail_root/stdout" 2>"$config_fail_root/stderr"
config_fail_status=$?
set -e
unset REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL
[[ $config_fail_status -ne 0 ]] ||
  fail 'injected Compose validation failure must abort activation'
[[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
  fail 'current must not switch when Compose candidate validation fails'
[[ ! -e $REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0 ]] ||
  fail 'failed Compose validation must remove its invocation-created release'
grep -Fq ' <down>' "$fake_log" ||
  fail 'failed Compose validation must stop the candidate before removal'
! grep -Fq -- "$REMOTE_CHROME_EXPECT_TOKEN" "$config_fail_root/stdout" ||
  fail 'failed Compose validation leaked the token to stdout'
! grep -Fq -- "$REMOTE_CHROME_EXPECT_TOKEN" "$config_fail_root/stderr" ||
  fail 'failed Compose validation leaked the token to stderr'
! grep -Fq -- "$REMOTE_CHROME_EXPECT_TOKEN" "$fake_log" ||
  fail 'failed Compose validation leaked the token to ordinary logs'
[[ -f $REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log &&
   $(stat -c '%a' "$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log") == 600 ]] ||
  fail 'failed Compose validation must preserve a confined mode-600 diagnostic'
! grep -Fq -- "$REMOTE_CHROME_EXPECT_TOKEN" \
  "$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log" ||
  fail 'preserved Compose diagnostics must redact the token'

# The same release version must be retryable after the failed invocation.
STAGED_RELEASE_DIR="$REMOTE_CHROME_INSTALL_ROOT/releases/.staging-v2.0.0-retry"
mkdir -p "$STAGED_RELEASE_DIR/vminstall/lib"
printf 'services: {}\n' >"$STAGED_RELEASE_DIR/compose.yaml"
printf 'services: {}\n' >"$STAGED_RELEASE_DIR/vminstall/compose.vm.yaml"
cp vminstall/remote-chrome "$STAGED_RELEASE_DIR/vminstall/remote-chrome"
chmod +x "$STAGED_RELEASE_DIR/vminstall/remote-chrome"
cp vminstall/lib/common.sh vminstall/lib/config.sh \
  vminstall/lib/activate.sh "$STAGED_RELEASE_DIR/vminstall/lib/"
: >"$REMOTE_CHROME_TRANSITION_LOG"
: >"$fake_log"
: >"$REMOTE_CHROME_PROTOCOL_LOG"
vm_activate_release >"$config_fail_root/retry.stdout" \
  2>"$config_fail_root/retry.stderr"
[[ $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v2.0.0 ]] ||
  fail 'same-version retry must activate after failed candidate cleanup'

# If candidate shutdown cannot be confirmed before a switch, retain the exact
# protected release, candidate Compose environment, and diagnostics.
pre_switch_down_root="$test_root/pre-switch-down-failure"
setup_activation_fixture "$pre_switch_down_root"
export REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL=1
export REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL=1
set +e
vm_activate_release >"$pre_switch_down_root/stdout" \
  2>"$pre_switch_down_root/stderr"
pre_switch_down_status=$?
set -e
unset REMOTE_CHROME_FAKE_COMPOSE_CONFIG_FAIL \
  REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL
[[ $pre_switch_down_status -ne 0 &&
   $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
  fail 'pre-switch shutdown failure must abort without switching current'
for retained in \
  "$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0" \
  "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
  "$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log" \
  "$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log"; do
  [[ -e $retained && ! -L $retained ]] ||
    fail "pre-switch shutdown failure deleted recovery material: $retained"
done
[[ $(stat -c '%a' \
  "$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log") == 600 ]] ||
  fail 'candidate shutdown diagnostic must remain root-only'
for path in \
  "$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0" \
  "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
  "$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log"; do
  grep -Fq -- "$path" "$pre_switch_down_root/stderr" ||
    fail "shutdown failure must report retained recovery path: $path"
done
! grep -Fq -- "$REMOTE_CHROME_EXPECT_TOKEN" "$pre_switch_down_root/stderr" ||
  fail 'retained-recovery report must not expose the bearer token'

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
  [[ ! -e $REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0 ]] ||
    fail "$early_failure_point must remove its invocation-created release"
done

# Post-switch rollback must restore the prior release but retain candidate
# recovery material whenever candidate Compose down fails.
post_switch_down_root="$test_root/post-switch-down-failure"
setup_activation_fixture "$post_switch_down_root"
REMOTE_CHROME_FAIL_AT=service-started
export REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL=1
set +e
vm_activate_release >"$post_switch_down_root/stdout" \
  2>"$post_switch_down_root/stderr"
post_switch_down_status=$?
set -e
unset REMOTE_CHROME_FAIL_AT REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL
[[ $post_switch_down_status -ne 0 &&
   $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 ]] ||
  fail 'post-switch shutdown failure must restore the prior current release'
for retained in \
  "$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0" \
  "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
  "$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log"; do
  [[ -e $retained && ! -L $retained ]] ||
    fail "post-switch shutdown failure deleted recovery material: $retained"
  grep -Fq -- "$retained" "$post_switch_down_root/stderr" ||
    fail "post-switch recovery report missing retained path: $retained"
done
[[ -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/active ]] ||
  fail 'post-switch shutdown failure must still restore prior active state'

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
  previous_certificate_sha=$(sha256sum \
    "$REMOTE_CHROME_CONFIG_ROOT/certificate.env")
  previous_unit_sha=$(sha256sum \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service")
  previous_cli_sha=$(sha256sum "$REMOTE_CHROME_CLI_ROOT/remote-chrome")
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
  [[ $(sha256sum "$REMOTE_CHROME_CONFIG_ROOT/certificate.env") == \
       "$previous_certificate_sha" ]] ||
    fail "$failure_point rollback must restore prior certificate metadata"
  [[ $(sha256sum "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service") == \
       "$previous_unit_sha" &&
     $(sha256sum "$REMOTE_CHROME_CLI_ROOT/remote-chrome") == \
       "$previous_cli_sha" ]] ||
    fail "$failure_point rollback must restore the prior unit and CLI"
  grep -Fq ' <down>' "$fake_log" ||
    fail "$failure_point rollback must stop the candidate Compose project"
  grep -Fxq 'systemctl <start> <remote-chrome.service>' "$fake_log" ||
    fail "$failure_point rollback must restart the prior service"
  grep -Fq ' <ps> ' "$fake_log" ||
    fail "$failure_point rollback must health-check the prior version"
  [[ -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled &&
     -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/active ]] ||
    fail "$failure_point rollback must restore enabled and active service state"
  [[ ! -e $REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0 ]] ||
    fail "$failure_point rollback must remove its invocation-created release"
done

# A previously enabled but inactive unit must remain inactive, and rollback
# must not invent a health check for a service that was not running.
inactive_root="$test_root/rollback-prior-inactive"
setup_activation_fixture "$inactive_root"
rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"
REMOTE_CHROME_FAIL_AT=service-started
set +e
vm_activate_release >"$inactive_root/stdout" 2>"$inactive_root/stderr"
inactive_status=$?
set -e
unset REMOTE_CHROME_FAIL_AT
[[ $inactive_status -ne 0 && -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled &&
   ! -e $REMOTE_CHROME_FAKE_SYSTEMD_STATE/active ]] ||
  fail 'rollback must restore a previously enabled-but-inactive unit exactly'
! grep -Fxq 'systemctl <start> <remote-chrome.service>' "$fake_log" ||
  fail 'rollback must not start a unit that was previously inactive'

# First-install failure after enable --now partially mutates systemd. Rollback
# must remove every service/CLI/release residue and restore the absent state.
first_install_root="$test_root/first-install-partial-enable"
setup_activation_fixture "$first_install_root"
rm -f "$REMOTE_CHROME_INSTALL_ROOT/current" \
  "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/certificate.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
  "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service" \
  "$REMOTE_CHROME_CLI_ROOT/remote-chrome" \
  "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" \
  "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"
export REMOTE_CHROME_FAKE_SYSTEMCTL_ENABLE_NOW_FAIL=1
set +e
vm_activate_release >"$first_install_root/stdout" \
  2>"$first_install_root/stderr"
first_install_status=$?
set -e
unset REMOTE_CHROME_FAKE_SYSTEMCTL_ENABLE_NOW_FAIL
[[ $first_install_status -ne 0 ]] ||
  fail 'partial first-install enable failure must abort activation'
for residue in \
  "$REMOTE_CHROME_INSTALL_ROOT/current" \
  "$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0" \
  "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/certificate.env" \
  "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
  "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service" \
  "$REMOTE_CHROME_CLI_ROOT/remote-chrome" \
  "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" \
  "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"; do
  [[ ! -e $residue && ! -L $residue ]] ||
    fail "first-install rollback left residue: $residue"
done
grep -Fxq 'systemctl <stop> <remote-chrome.service>' "$fake_log" ||
  fail 'first-install rollback must explicitly stop partial candidate state'
grep -Fxq 'systemctl <disable> <remote-chrome.service>' "$fake_log" ||
  fail 'first-install rollback must explicitly disable partial candidate state'

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
