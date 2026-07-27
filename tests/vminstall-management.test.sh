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
  'command_line=openssl' \
  'for argument in "$@"; do printf -v command_line "%s <%s>" "$command_line" "$argument"; done' \
  'printf "%s\n" "$command_line" >>"$FAKE_COMMAND_LOG"' \
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
  'command_line=timeout' \
  'for argument in "$@"; do printf -v command_line "%s <%s>" "$command_line" "$argument"; done' \
  'printf "%s\n" "$command_line" >>"$FAKE_COMMAND_LOG"' \
  '[[ ${1:-} == 5 ]] || exit 86' \
  'shift' \
  'exec "$@"'

apply_patch_fake "$fake_bin/docker" \
  'if [[ ${REMOTE_CHROME_FAKE_DOCKER_HANG:-0} == 1 ]]; then exec /bin/sleep 30; fi' \
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
  'elif [[ " $* " == *" compose "*" exec -T browser "* ]]; then' \
  '  printf "%s\n" "Chrome/123.0.0.0" "Mozilla/5.0 Chrome/123.0.0.0" "Remote Browser Interaction Playbook"' \
  'elif [[ " $* " == *" compose "*" down"* && ${REMOTE_CHROME_FAKE_COMPOSE_DOWN_FAIL:-0} == 1 ]]; then' \
  '  printf "candidate shutdown failed\n" >&2' \
  '  exit 87' \
  'fi'

apply_patch_fake "$fake_bin/systemctl" \
  'if [[ ${REMOTE_CHROME_FAKE_SYSTEMCTL_HANG:-0} == 1 ]]; then exec /bin/sleep 30; fi' \
  'printf "systemctl" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"' \
  'case "${1:-}" in' \
  '  is-enabled)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.enabled" ]]' \
  '    else' \
  '      [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled" ]]' \
  '    fi' \
  '    ;;' \
  '  is-active)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active" ]]' \
  '    else' \
  '      [[ -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active" ]]' \
  '    fi' \
  '    ;;' \
  '  enable)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      [[ -f "$REMOTE_CHROME_CONFIG_ROOT/active-version" ]] || exit 96' \
  '      [[ -f "$REMOTE_CHROME_CONFIG_ROOT/previous-version" ]] || exit 96' \
  '      [[ ${REMOTE_CHROME_FAKE_TIMER_FAIL:-0} != 1 ]] || exit 97' \
  '      touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.enabled"' \
  '      if [[ " $* " == *" --now "* ]]; then' \
  '        touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active"' \
  '      fi' \
  '    fi' \
  '    [[ ${!#} == remote-chrome-backup.timer ]] || touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled"' \
  '    if [[ " $* " == *" --now "* && ${!#} == remote-chrome.service ]]; then' \
  '      touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"' \
  '      "$REMOTE_CHROME_CLI_ROOT/remote-chrome" wait-ready' \
  '      [[ ${REMOTE_CHROME_FAKE_SYSTEMCTL_ENABLE_NOW_FAIL:-0} != 1 ]]' \
  '    fi' \
  '    ;;' \
  '  disable)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      [[ ${REMOTE_CHROME_FAKE_TIMER_DISABLE_FAIL:-0} != 1 ]] || exit 98' \
  '      rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.enabled" "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active"' \
  '    else' \
  '      rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/enabled"' \
  '    fi' \
  '    ;;' \
  '  start)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active"' \
  '    else' \
  '      touch "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"' \
  '    fi' \
  '    ;;' \
  '  stop)' \
  '    if [[ ${!#} == remote-chrome-backup.timer ]]; then' \
  '      rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active"' \
  '    else' \
  '      rm -f "$REMOTE_CHROME_FAKE_SYSTEMD_STATE/active"' \
  '    fi' \
  '    ;;' \
  'esac'

apply_patch_fake "$fake_bin/chown" \
  'printf "chown" >>"$FAKE_COMMAND_LOG"' \
  'printf " <%s>" "$@" >>"$FAKE_COMMAND_LOG"' \
  'printf "\n" >>"$FAKE_COMMAND_LOG"'

apply_patch_fake "$fake_bin/curl" \
  'if [[ ${REMOTE_CHROME_FAKE_CURL_HANG:-0} == 1 ]]; then exec /bin/sleep 30; fi' \
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
  '    [[ $data == *'\''"method":"initialize"'\''* ]] || exit 91' \
  '    if [[ -z $auth ]]; then' \
  '      status=401; event=anonymous-401' \
  '      printf "HTTP/2 401\r\nContent-Type: application/json\r\n\r\n" >"$headers"' \
  '      printf "%s" '\''{"error":"unauthorized"}'\'' >"$output"' \
  '    else' \
  '      [[ $auth == "$bearer" ]] || exit 91' \
  '      status=200; event=initialize' \
  '      printf "HTTP/2 200\r\nContent-Type: application/json\r\nMcp-Session-Id: fixture-session\r\n\r\n" >"$headers"' \
  '      printf "%s" '\''{"result":{"instructions":"Remote Browser Interaction Playbook"}}'\'' >"$output"' \
  '    fi' \
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

apply_patch_fake "$fake_bin/du" \
  'if [[ ${REMOTE_CHROME_FAKE_DU_HANG:-0} == 1 ]]; then exec /bin/sleep 30; fi' \
  'exec /usr/bin/du "$@"'

apply_patch_fake "$fake_bin/find" \
  'if [[ ${REMOTE_CHROME_FAKE_FIND_HANG:-0} == 1 ]]; then exec /bin/sleep 30; fi' \
  'exec /usr/bin/find "$@"'

apply_patch_fake "$fake_bin/stat" \
  'format=' \
  'if [[ ${1:-} == -c ]]; then format=${2:-}; fi' \
  'target=${!#}' \
  'if [[ -n ${REMOTE_CHROME_FAKE_LEGACY_PATH:-} && $target == "$REMOTE_CHROME_FAKE_LEGACY_PATH" && $format == "%u:%g" ]]; then' \
  '  printf "%s\n" "0:0"' \
  '  exit 0' \
  'fi' \
  'if [[ -n ${REMOTE_CHROME_FAKE_CORRECT_PATH:-} && $target == "$REMOTE_CHROME_FAKE_CORRECT_PATH" && $format == "%u:%g" ]]; then' \
  '  printf "%s\n" "10001:10001"' \
  '  exit 0' \
  'fi' \
  'if [[ -n ${REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT:-} && $format == "%u:%g" ]]; then' \
  '  case "$target" in' \
  '    "$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/profile"|"$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/profile/"*|"$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/caddy-data"|"$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/caddy-data/"*|"$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/caddy-config"|"$REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT/caddy-config/"*)' \
  '      printf "%s\n" "10001:10001"' \
  '      exit 0' \
  '      ;;' \
  '  esac' \
  'fi' \
  'if [[ -n ${REMOTE_CHROME_FAKE_CROSS_DEVICE_PATH:-} && $target == "$REMOTE_CHROME_FAKE_CROSS_DEVICE_PATH" && $format == "%d" ]]; then' \
  '  printf "%s\n" "999999999"' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/stat "$@"'

export PATH="$fake_bin:$PATH"
export REMOTE_CHROME_SKIP_MAIN=1
# shellcheck source=../vminstall/installer-main.sh
source vminstall/installer-main.sh

for required_function in \
  vm_prepare_config vm_generate_credentials vm_render_compose_env \
  vm_activate_release vm_rollback_release vm_verify_public_stack \
  vm_print_connection_handoff vm_migrate_runtime_directory; do
  declare -F "$required_function" >/dev/null ||
    fail "$required_function is undefined"
done

REMOTE_CHROME_TEST_ROOT="$test_root/first-install"
mkdir "$REMOTE_CHROME_TEST_ROOT"
vm_init_paths

migration_root="$REMOTE_CHROME_TEST_ROOT/migration"
migration_escape="$REMOTE_CHROME_TEST_ROOT/migration-escape"
mkdir -p "$migration_root/profile/nested" "$migration_escape"
printf 'profile-content\n' >"$migration_root/profile/nested/content"
printf 'outside-content\n' >"$migration_escape/sentinel"
ln -s "$migration_escape/sentinel" \
  "$migration_root/profile/nested/external-link"
chmod 0755 "$migration_root/profile"
export REMOTE_CHROME_FAKE_LEGACY_PATH="$migration_root/profile"
migration_chowns_before=$(grep -c '^chown <-h> <10001:10001>' "$fake_log" || true)
vm_migrate_runtime_directory "$migration_root/profile" 10001:10001 ||
  fail 'legacy profile ownership and mode must migrate safely'
[[ $(stat -c '%a' "$migration_root/profile") == 700 ]] ||
  fail 'legacy profile migration must set the exact managed directory to mode 0700'
[[ $(<"$migration_root/profile/nested/content") == profile-content &&
   $(<"$migration_escape/sentinel") == outside-content ]] ||
  fail 'legacy profile migration must preserve content and external targets'
[[ -L $migration_root/profile/nested/external-link &&
   $(readlink "$migration_root/profile/nested/external-link") == \
     "$migration_escape/sentinel" ]] ||
  fail 'legacy profile migration must preserve descendant symlinks'
[[ $(grep -c '^chown <-h> <10001:10001>' "$fake_log") \
   -gt $migration_chowns_before ]] ||
  fail 'legacy profile migration must use no-dereference ownership changes'
unset REMOTE_CHROME_FAKE_LEGACY_PATH

ln -s "$migration_escape" "$migration_root/caddy-data"
if vm_migrate_runtime_directory \
  "$migration_root/caddy-data" 10001:10001 >/dev/null 2>&1; then
  fail 'an exact managed bind-directory symlink must be rejected'
fi

ln -s "$migration_escape" "$migration_root/data-root-link"
if vm_create_data_root "$migration_root/data-root-link" >/dev/null 2>&1; then
  fail 'a symlink at the canonical data root must be rejected'
fi

mkdir -p "$migration_root/caddy-config/device-boundary"
printf 'device-content\n' \
  >"$migration_root/caddy-config/device-boundary/content"
chmod 0755 "$migration_root/caddy-config"
export REMOTE_CHROME_FAKE_LEGACY_PATH="$migration_root/caddy-config"
export REMOTE_CHROME_FAKE_CROSS_DEVICE_PATH="$migration_root/caddy-config/device-boundary"
migration_chowns_before=$(grep -c '^chown <-h> <10001:10001>' "$fake_log" || true)
if vm_migrate_runtime_directory \
  "$migration_root/caddy-config" 10001:10001 >/dev/null 2>&1; then
  fail 'managed bind migration must reject a cross-filesystem boundary'
fi
[[ $(grep -c '^chown <-h> <10001:10001>' "$fake_log") \
   -eq $migration_chowns_before ]] ||
  fail 'cross-filesystem rejection must occur before ownership mutation'
[[ $(<"$migration_root/caddy-config/device-boundary/content") == \
   device-content ]] ||
  fail 'cross-filesystem rejection must preserve all content'
unset REMOTE_CHROME_FAKE_LEGACY_PATH REMOTE_CHROME_FAKE_CROSS_DEVICE_PATH

mkdir -p "$migration_root/root-correct/legacy-child"
chmod 0700 "$migration_root/root-correct"
printf 'legacy-child-content\n' \
  >"$migration_root/root-correct/legacy-child/content"
export REMOTE_CHROME_FAKE_CORRECT_PATH="$migration_root/root-correct"
export REMOTE_CHROME_FAKE_LEGACY_PATH="$migration_root/root-correct/legacy-child"
migration_chowns_before=$(grep -c '^chown <-h> <10001:10001>' "$fake_log" || true)
vm_migrate_runtime_directory "$migration_root/root-correct" 10001:10001 ||
  fail 'wrong-owned descendants beneath a correct root must migrate'
[[ $(grep -c '^chown <-h> <10001:10001>' "$fake_log") \
   -gt $migration_chowns_before ]] ||
  fail 'descendant ownership must participate in the migration decision'
[[ $(<"$migration_root/root-correct/legacy-child/content") == \
   legacy-child-content ]] ||
  fail 'descendant ownership migration must preserve content'
unset REMOTE_CHROME_FAKE_CORRECT_PATH REMOTE_CHROME_FAKE_LEGACY_PATH

mkdir "$migration_root/already-correct"
chmod 0700 "$migration_root/already-correct"
export REMOTE_CHROME_FAKE_CORRECT_PATH="$migration_root/already-correct"
migration_chowns_before=$(grep -c '^chown <-h> <10001:10001>' "$fake_log" || true)
vm_migrate_runtime_directory "$migration_root/already-correct" 10001:10001 ||
  fail 'already-correct bind directory must validate'
[[ $(grep -c '^chown <-h> <10001:10001>' "$fake_log") \
   -eq $migration_chowns_before ]] ||
  fail 'already-correct rerun must avoid redundant recursive ownership work'
unset REMOTE_CHROME_FAKE_CORRECT_PATH

mkdir -p "$migration_root/symlink-owner"
chmod 0700 "$migration_root/symlink-owner"
ln -s "$migration_escape/sentinel" \
  "$migration_root/symlink-owner/wrong-owned-link"
export REMOTE_CHROME_FAKE_CORRECT_PATH="$migration_root/symlink-owner"
export REMOTE_CHROME_FAKE_LEGACY_PATH="$migration_root/symlink-owner/wrong-owned-link"
migration_chowns_before=$(grep -c '^chown <-h> <10001:10001>' "$fake_log" || true)
vm_migrate_runtime_directory "$migration_root/symlink-owner" 10001:10001 ||
  fail 'wrong-owned descendant symlinks must migrate without dereferencing'
[[ $(grep -c '^chown <-h> <10001:10001>' "$fake_log") \
   -gt $migration_chowns_before ]] ||
  fail 'descendant symlink ownership must participate in the no-op decision'
[[ -L $migration_root/symlink-owner/wrong-owned-link &&
   $(<"$migration_escape/sentinel") == outside-content ]] ||
  fail 'descendant symlink migration must not mutate its external target'
unset REMOTE_CHROME_FAKE_CORRECT_PATH REMOTE_CHROME_FAKE_LEGACY_PATH

DOMAIN=chrome.example.com
ACME_EMAIL=ops@example.com
REMOTE_CHROME_DATA_DIR="$REMOTE_CHROME_TEST_ROOT/data/../data"
GCS_BUCKET=fixture-backups
BACKUP_SCHEDULE='*-*-* 03:00:00'
DOMAIN_SET=1
EMAIL_SET=1
DATA_DIR_SET=1
GCS_BUCKET_SET=1
BACKUP_SCHEDULE_SET=1
DISABLE_GCS_BACKUP=0
DISABLE_BACKUP_SCHEDULE=0
INSTALLATION_EXISTS=0
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
grep -Fxq "chown <root:10001> <$canonical_data>" "$fake_log" ||
  fail 'fresh data root must grant traversal only to the fixed container group'
[[ $(stat -c '%a' "$canonical_data") == 710 ]] ||
  fail 'fresh data root must be root-owned and group-traversable without broad access'
for data_subdir in profile caddy-data caddy-config backups restore-staging; do
  data_path="$canonical_data/$data_subdir"
  [[ -d $data_path && $(realpath -m "$data_path") == "$canonical_data"/* ]] ||
    fail "$data_subdir must remain beneath the canonical data root"
done
! find "$canonical_data" -maxdepth 1 -printf '%m %p\n' |
  grep -Eq '^777 ' ||
  fail 'runtime directories must never use world-writable mode 777'
for writable_subdir in profile caddy-data caddy-config; do
  grep -Fxq "chown <10001:10001> <$canonical_data/$writable_subdir>" \
    "$fake_log" ||
    fail "$writable_subdir must receive the fixed container UID/GID on creation"
  [[ $(stat -c '%a' "$canonical_data/$writable_subdir") == 700 ]] ||
    fail "$writable_subdir must not be writable outside the container identity"
done
initial_profile_chowns=$(
  grep -Fxc "chown <10001:10001> <$canonical_data/profile>" "$fake_log"
)
export REMOTE_CHROME_FAKE_CORRECT_RUNTIME_ROOT="$canonical_data"
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
  'ExecStart=/usr/bin/docker compose --project-name remote-chrome -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env up -d' \
  'ExecStartPost=/usr/local/sbin/remote-chrome wait-ready' \
  'ExecStop=/usr/bin/docker compose --project-name remote-chrome -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env down'; do
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
DOMAIN_SET=0
EMAIL_SET=0
DATA_DIR_SET=0
GCS_BUCKET_SET=0
BACKUP_SCHEDULE_SET=0
DISABLE_GCS_BACKUP=0
DISABLE_BACKUP_SCHEDULE=0
INSTALLATION_EXISTS=1
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
[[ $(grep -Fxc "chown <10001:10001> <$canonical_data/profile>" "$fake_log") \
   -eq $initial_profile_chowns ]] ||
  fail 'rerun must preserve existing profile ownership without a recursive chown'

printf 'profile-owner-preserved\n' >"$canonical_data/profile/owner-canary"
chmod 0700 "$canonical_data"
root_repair_chowns_before=$(
  grep -Fxc "chown <root:10001> <$canonical_data>" "$fake_log" || true
)
vm_prepare_config
[[ $(stat -c '%a' "$canonical_data") == 710 ]] ||
  fail 'rerun must repair data-root traversal without opening broader access'
[[ $(grep -Fxc "chown <root:10001> <$canonical_data>" "$fake_log") \
   -gt $root_repair_chowns_before ]] ||
  fail 'rerun must repair only the canonical data-root group ownership'
[[ $(<"$canonical_data/profile/owner-canary") == profile-owner-preserved ]] ||
  fail 'data-root traversal repair must preserve profile content'
[[ $(grep -Fxc "chown <10001:10001> <$canonical_data/profile>" "$fake_log") \
   -eq $initial_profile_chowns ]] ||
  fail 'data-root traversal repair must not chown the existing profile'

GCS_BUCKET=updated-backups
BACKUP_SCHEDULE='Mon..Fri 02:30'
GCS_BUCKET_SET=1
BACKUP_SCHEDULE_SET=1
vm_prepare_config
[[ $(read_env_value "$install_candidate" GCS_BUCKET) == updated-backups ]] ||
  fail 'an explicitly supplied GCS bucket must update installed configuration'
[[ $(read_env_value "$install_candidate" BACKUP_SCHEDULE) == \
   'Mon..Fri 02:30' ]] ||
  fail 'an explicitly supplied backup schedule must update installed configuration'

GCS_BUCKET_SET=0
BACKUP_SCHEDULE_SET=0
DISABLE_BACKUP_SCHEDULE=1
vm_prepare_config
[[ $(read_env_value "$install_candidate" GCS_BUCKET) == fixture-backups ]] ||
  fail 'disabling only the schedule must preserve the installed GCS bucket'
[[ -z $(read_env_value "$install_candidate" BACKUP_SCHEDULE) ]] ||
  fail 'the explicit schedule-disable flag must clear only the schedule'
[[ -f $canonical_data/caddy-data/preserve &&
   -f $canonical_data/caddy-config/preserve ]] ||
  fail 'disabling a schedule must not mutate persistent container data'

DISABLE_GCS_BACKUP=1
DISABLE_BACKUP_SCHEDULE=0
vm_prepare_config
[[ -z $(read_env_value "$install_candidate" GCS_BUCKET) &&
   -z $(read_env_value "$install_candidate" BACKUP_SCHEDULE) ]] ||
  fail 'disabling GCS backup must safely clear the bucket and its schedule'
[[ -f $canonical_data/caddy-data/preserve &&
   -f $canonical_data/caddy-config/preserve ]] ||
  fail 'disabling GCS backup must not mutate browser or Caddy data'

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
    cp vminstall/install.sh "$release/vminstall/install.sh"
    chmod +x "$release/vminstall/install.sh"
    cp vminstall/remote-chrome.service.in \
      vminstall/remote-chrome-backup.service.in \
      vminstall/remote-chrome-backup.timer.in "$release/vminstall/"
    cp vminstall/lib/common.sh vminstall/lib/wizard.sh \
      vminstall/lib/release.sh vminstall/lib/config.sh \
      vminstall/lib/activate.sh vminstall/lib/backup.sh \
      "$release/vminstall/lib/"
    if [[ -f vminstall/lib/management.sh ]]; then
      cp vminstall/lib/management.sh "$release/vminstall/lib/management.sh"
    fi
  fi
}

setup_activation_fixture() {
  local root=$1
  mkdir -p "$root"
  mkdir -p "$root/usr/bin"
  cp "$fake_bin"/* "$root/usr/bin/"
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
  DOMAIN_SET=1
  EMAIL_SET=1
  DATA_DIR_SET=1
  GCS_BUCKET_SET=1
  BACKUP_SCHEDULE_SET=1
  DISABLE_GCS_BACKUP=0
  DISABLE_BACKUP_SCHEDULE=0
  INSTALLATION_EXISTS=0
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
    cp vminstall/remote-chrome-backup.service.in \
      vminstall/remote-chrome-backup.timer.in "$STAGED_RELEASE_DIR/vminstall/"
    cp vminstall/lib/common.sh vminstall/lib/wizard.sh \
      vminstall/lib/release.sh \
      vminstall/lib/config.sh vminstall/lib/activate.sh \
      vminstall/lib/management.sh vminstall/lib/backup.sh \
      "$STAGED_RELEASE_DIR/vminstall/lib/"
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
[[ $(<"$REMOTE_CHROME_CONFIG_ROOT/previous-version") == v1.0.0 ]] ||
  fail 'successful activation must atomically record the actual previous current release'
for installed in install.env compose.env credentials.env; do
  assert_file_mode_owner "$REMOTE_CHROME_CONFIG_ROOT/$installed"
done
assert_order "$REMOTE_CHROME_TRANSITION_LOG" \
  release-installed candidate-config-written compose-config-validated \
  current-switched config-installed service-reloaded service-started \
  health-verified public-verified active-recorded backup-timer-configured
assert_order "$fake_log" \
  "docker <compose> <--project-name> <remote-chrome> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/compose.yaml> <-f> <$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0/vminstall/compose.vm.yaml> <--env-file> <$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate> <config> <--quiet>" \
  "systemctl <daemon-reload>" \
  "systemctl <enable> <--now> <remote-chrome.service>"
[[ -x $REMOTE_CHROME_CLI_ROOT/remote-chrome ]] ||
  fail 'ExecStartPost target must be installed before service activation'
grep -Fq ' <ps> ' "$fake_log" ||
  fail 'the installed ExecStartPost wait-ready target must execute successfully'
grep -Fq '/opt/remote-chrome/browser-playbook.md' "$fake_log" ||
  fail 'browser readiness must verify the playbook at its image path'
[[ $(stat -c '%a' "$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log") == 600 ]] ||
  fail 'Compose diagnostics must be retained only in a root-only mode-600 file'
[[ $(<"$REMOTE_CHROME_PROTOCOL_LOG") == $'anonymous-401\ninitialize\ndelete\nget-405\nlogin-401\nlogin-200\nwebsocket-101' ]] ||
  fail 'public verification must perform the complete strict protocol in order'
grep -Fq ' <--http1.1> <--max-time> <3>' "$fake_log" ||
  fail 'WebSocket verification must use a bounded three-second request'
grep -Fxq \
  'openssl <s_client> <-connect> <chrome.example.com:443> <-servername> <chrome.example.com> <-verify_return_error>' \
  "$fake_log" &&
  grep -Fxq 'openssl <x509> <-noout> <-issuer> <-enddate>' "$fake_log" ||
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

timer_failure_root="$test_root/timer-activation-failure"
setup_activation_fixture "$timer_failure_root"
export REMOTE_CHROME_FAKE_TIMER_FAIL=1
set +e
vm_activate_release >"$timer_failure_root/stdout" 2>"$timer_failure_root/stderr"
timer_failure_status=$?
set -e
unset REMOTE_CHROME_FAKE_TIMER_FAIL
[[ $timer_failure_status -ne 0 &&
   $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 &&
   $(<"$REMOTE_CHROME_CONFIG_ROOT/active-version") == v1.0.0 ]] ||
  fail 'post-commit timer activation failure must roll release activation back'

timer_removal_failure_root="$test_root/timer-removal-failure"
setup_activation_fixture "$timer_removal_failure_root"
cp vminstall/remote-chrome-backup.service.in \
  "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service"
cp vminstall/remote-chrome-backup.timer.in \
  "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"
: >"$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.enabled"
: >"$REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active"
sed -i 's/^BACKUP_SCHEDULE=.*$/BACKUP_SCHEDULE=/' \
  "$REMOTE_CHROME_CONFIG_ROOT/install.env"
BACKUP_SCHEDULE_SET=0
export REMOTE_CHROME_FAKE_TIMER_DISABLE_FAIL=1
set +e
vm_activate_release >"$timer_removal_failure_root/stdout" \
  2>"$timer_removal_failure_root/stderr"
timer_removal_failure_status=$?
set -e
unset REMOTE_CHROME_FAKE_TIMER_DISABLE_FAIL
[[ $timer_removal_failure_status -ne 0 &&
   $(readlink "$REMOTE_CHROME_INSTALL_ROOT/current") == releases/v1.0.0 &&
   $(<"$REMOTE_CHROME_CONFIG_ROOT/active-version") == v1.0.0 &&
   -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service &&
   -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer &&
   -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.enabled &&
   -f $REMOTE_CHROME_FAKE_SYSTEMD_STATE/backup-timer.active ]] ||
  fail 'timer schedule-removal failure must roll back release and timer state'

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
cp vminstall/remote-chrome-backup.service.in \
  vminstall/remote-chrome-backup.timer.in "$STAGED_RELEASE_DIR/vminstall/"
cp vminstall/lib/common.sh vminstall/lib/wizard.sh \
  vminstall/lib/release.sh \
  vminstall/lib/config.sh vminstall/lib/activate.sh \
  vminstall/lib/management.sh vminstall/lib/backup.sh \
  "$STAGED_RELEASE_DIR/vminstall/lib/"
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

run_cli() {
  local root=$1
  shift
  REMOTE_CHROME_TEST_ROOT="$root" \
  REMOTE_CHROME_TEST_EUID="${REMOTE_CHROME_TEST_EUID:-0}" \
  REMOTE_CHROME_FAKE_SYSTEMD_STATE="$root/systemd-state" \
  REMOTE_CHROME_PROTOCOL_LOG="$root/protocol.log" \
  REMOTE_CHROME_EXPECT_TOKEN=$(
    read_env_value "$root/etc/remote-chrome/credentials.env" MCP_TOKEN
  ) \
  REMOTE_CHROME_EXPECT_USERNAME=$(
    read_env_value "$root/etc/remote-chrome/credentials.env" LOGIN_USERNAME
  ) \
  REMOTE_CHROME_EXPECT_PASSWORD=$(
    read_env_value "$root/etc/remote-chrome/credentials.env" LOGIN_PASSWORD
  ) \
    "$root/usr/local/sbin/remote-chrome" "$@"
}

make_update_archive() {
  local root=$1 ref=$2
  local source="$root/update-source/remotechromemcp-$ref"
  local archive="$root/remotechromemcp-$ref.tar.gz"
  mkdir -p "$source/vminstall/lib"
  cp compose.yaml "$source/compose.yaml"
  cp vminstall/compose.vm.yaml vminstall/install.sh \
    vminstall/remote-chrome vminstall/remote-chrome.service.in \
    vminstall/remote-chrome-backup.service.in \
    vminstall/remote-chrome-backup.timer.in \
    "$source/vminstall/"
  cp vminstall/lib/common.sh vminstall/lib/wizard.sh \
    vminstall/lib/release.sh vminstall/lib/config.sh \
    vminstall/lib/activate.sh vminstall/lib/backup.sh \
    "$source/vminstall/lib/"
  if [[ -f vminstall/lib/management.sh ]]; then
    cp vminstall/lib/management.sh "$source/vminstall/lib/management.sh"
  fi
  chmod +x "$source/vminstall/install.sh" "$source/vminstall/remote-chrome"
  tar -czf "$archive" -C "$root/update-source" "remotechromemcp-$ref"
  (
    cd "$root"
    sha256sum "remotechromemcp-$ref.tar.gz" \
      >"remotechromemcp-$ref.tar.gz.sha256"
  )
  printf '%s' "$archive"
}

cli_root="$test_root/management-cli"
setup_activation_fixture "$cli_root"
touch "$REMOTE_CHROME_DATA_DIR/profile/session-marker"
printf '%s\n' '{"version":"fixture-backup"}' \
  >"$REMOTE_CHROME_DATA_DIR/backups/20260727T120000Z.manifest"

# The executable location, never caller-controlled roots, selects installed
# libraries. A malicious environment root must remain completely unsourced.
malicious_root="$test_root/malicious-source-root"
mkdir -p "$malicious_root/opt/remotechromemcp/current/vminstall/lib"
for library in common wizard config release activate management; do
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf "sourced %s\\n" >>%q\n' "$library" \
      "$malicious_root/source-canary"
  } >"$malicious_root/opt/remotechromemcp/current/vminstall/lib/$library.sh"
done
REMOTE_CHROME_TEST_ROOT="$malicious_root" \
REMOTE_CHROME_INSTALL_ROOT="$malicious_root/opt/remotechromemcp" \
REMOTE_CHROME_CONFIG_ROOT="$malicious_root/etc/remote-chrome" \
REMOTE_CHROME_SYSTEMD_ROOT="$malicious_root/etc/systemd/system" \
REMOTE_CHROME_CLI_ROOT="$malicious_root/usr/local/sbin" \
REMOTE_CHROME_TEST_EUID=0 \
REMOTE_CHROME_FAKE_SYSTEMD_STATE="$cli_root/systemd-state" \
REMOTE_CHROME_PROTOCOL_LOG="$cli_root/protocol.log" \
REMOTE_CHROME_EXPECT_TOKEN="$REMOTE_CHROME_EXPECT_TOKEN" \
REMOTE_CHROME_EXPECT_USERNAME="$REMOTE_CHROME_EXPECT_USERNAME" \
REMOTE_CHROME_EXPECT_PASSWORD="$REMOTE_CHROME_EXPECT_PASSWORD" \
  "$cli_root/usr/local/sbin/remote-chrome" login \
    >"$cli_root/source-boundary.stdout" \
    2>"$cli_root/source-boundary.stderr"
[[ ! -e $malicious_root/source-canary ]] ||
  fail 'installed CLI must ignore environment-selected source roots before sourcing'
grep -Fxq 'Login URL: https://chrome.example.com/login/' \
  "$cli_root/source-boundary.stdout" ||
  fail 'installed CLI must source libraries beneath its own trusted prefix'

poison_bin="$test_root/poison-bin"
poison_canary="$test_root/poison-canary"
mkdir "$poison_bin"
for poison_tool in tar openssl awk sha256sum docker gcloud; do
  cat >"$poison_bin/$poison_tool" <<EOF
#!/bin/sh
touch "$poison_canary"
exit 99
EOF
  chmod +x "$poison_bin/$poison_tool"
done
cat >"$test_root/poison-bash-env" <<EOF
touch "$poison_canary"
EOF
PATH="$poison_bin:/usr/bin:/bin" \
BASH_ENV="$test_root/poison-bash-env" \
ENV="$test_root/poison-bash-env" \
TAR_OPTIONS="--checkpoint-action=exec=touch=$poison_canary" \
OPENSSL_CONF="$test_root/missing-openssl.cnf" \
OPENSSL_ENGINES="$poison_bin" \
DOCKER_HOST="tcp://attacker.invalid:2375" \
DOCKER_CLI_PLUGIN_EXTRA_DIRS="$poison_bin" \
COMPOSE_FILE="$test_root/attacker-compose.yaml" \
CLOUDSDK_CONFIG="$test_root/attacker-gcloud" \
CLOUDSDK_PYTHON="$poison_bin/python" \
CLOUDSDK_PYTHON_ARGS="-c touch $poison_canary" \
PYTHONPATH="$poison_bin" \
PYTHONHOME="$test_root/attacker-python" \
STORAGE_EMULATOR_HOST="http://attacker.invalid" \
HOME="$test_root/attacker-home" \
XDG_CONFIG_HOME="$test_root/attacker-xdg-config" \
XDG_CACHE_HOME="$test_root/attacker-xdg-cache" \
REMOTE_CHROME_TEST_EUID=0 \
  "$cli_root/usr/local/sbin/remote-chrome" status >"$cli_root/poison.stdout" \
    2>"$cli_root/poison.stderr"
[[ ! -e $poison_canary ]] ||
  fail 'installed root CLI must ignore caller-selected programs and control environment'

set +e
run_cli "$cli_root" >"$cli_root/no-args.stdout" \
  2>"$cli_root/no-args.stderr"
no_args_status=$?
run_cli "$cli_root" unsupported >"$cli_root/unknown.stdout" \
  2>"$cli_root/unknown.stderr"
unknown_status=$?
set -e
[[ $no_args_status -eq 2 && $unknown_status -eq 2 ]] ||
  fail 'missing and unknown CLI commands must exit 2'
grep -Fq 'Usage: remote-chrome' "$cli_root/no-args.stderr" ||
  fail 'missing CLI command must print usage'
grep -Fq 'Usage: remote-chrome' "$cli_root/unknown.stderr" ||
  fail 'unknown CLI command must print usage'

: >"$REMOTE_CHROME_PROTOCOL_LOG"
run_cli "$cli_root" status >"$cli_root/status.stdout" \
  2>"$cli_root/status.stderr"
for status_text in \
  'Active release: v1.0.0' \
  'Prior release: none' \
  'Service: active' \
  'Browser container: healthy' \
  'Proxy container: healthy' \
  'Chrome version: Chrome/123.0.0.0' \
  'Headed Chrome: yes' \
  'MCP initialize: ready' \
  'Playbook marker: present' \
  'Public MCP anonymous/authenticated: 401/405' \
  'MCP Content-Type headers: 1' \
  'Login HTTP: 200 with Basic auth' \
  'Login WebSocket: 101' \
  'TLS issuer: CN = Fixture Test CA' \
  'TLS expires: Jul 27 12:00:00 2027 GMT' \
  'Profile usage:' \
  'Data usage:' \
  'Last backup manifest: 20260727T120000Z.manifest'; do
  grep -Fq "$status_text" "$cli_root/status.stdout" ||
    fail "status report missing redacted field: $status_text"
done
cli_token=$(read_env_value \
  "$cli_root/etc/remote-chrome/credentials.env" MCP_TOKEN)
cli_password=$(read_env_value \
  "$cli_root/etc/remote-chrome/credentials.env" LOGIN_PASSWORD)
cli_hash=$(read_env_value \
  "$cli_root/etc/remote-chrome/compose.env" LOGIN_PASSWORD_HASH)
for secret in "$cli_token" "$cli_password" "$cli_hash"; do
  ! grep -Fq -- "$secret" "$cli_root/status.stdout" ||
    fail 'status must not print installed secrets'
  ! grep -Fq -- "$secret" "$cli_root/status.stderr" ||
    fail 'status diagnostics must not print installed secrets'
done

set +e
REMOTE_CHROME_TEST_EUID=1000 run_cli "$cli_root" credentials \
  >"$cli_root/credentials-nonroot.stdout" \
  2>"$cli_root/credentials-nonroot.stderr"
credentials_nonroot_status=$?
set -e
[[ $credentials_nonroot_status -eq 77 ]] ||
  fail 'credentials must reject non-root callers with exit 77'
[[ ! -s $cli_root/credentials-nonroot.stdout ]] ||
  fail 'non-root credentials must not print connection fields'

if [[ $EUID -ne 0 ]]; then
  set +e
  (
    unset REMOTE_CHROME_TEST_ROOT REMOTE_CHROME_CANONICAL_TEST_ROOT
    REMOTE_CHROME_TEST_EUID=0 vm_require_root
  ) >"$cli_root/test-euid-bypass.stdout" \
    2>"$cli_root/test-euid-bypass.stderr"
  test_euid_bypass_status=$?
  set -e
  [[ $test_euid_bypass_status -eq 77 ]] ||
    fail 'REMOTE_CHROME_TEST_EUID must not bypass root outside a test root'
fi

run_cli "$cli_root" credentials >"$cli_root/credentials-root.stdout"
cmp -s "$cli_root/etc/remote-chrome/credentials.env" \
  "$cli_root/credentials-root.stdout" ||
  fail 'root credentials output must exactly match installed connection fields'
run_cli "$cli_root" login >"$cli_root/login.stdout"
grep -Fxq 'Login URL: https://chrome.example.com/login/' \
  "$cli_root/login.stdout" ||
  fail 'login must print the installed URL'
grep -Fxq 'Login username: remotechrome' "$cli_root/login.stdout" ||
  fail 'login must print the installed username'
! grep -Fq -- "$cli_password" "$cli_root/login.stdout" ||
  fail 'login must never print the password'
! grep -Fq -- "$cli_token" "$cli_root/login.stdout" ||
  fail 'login must never print the token'

: >"$REMOTE_CHROME_PROTOCOL_LOG"
run_cli "$cli_root" wait-ready >"$cli_root/wait-ready.stdout" \
  2>"$cli_root/wait-ready.stderr"
[[ $(<"$REMOTE_CHROME_PROTOCOL_LOG") == \
  $'anonymous-401\ninitialize\ndelete\nget-405\nlogin-401\nlogin-200\nwebsocket-101' ]] ||
  fail 'wait-ready must require MCP, Basic login, and WebSocket readiness'
[[ ! -s $cli_root/wait-ready.stdout ]] ||
  fail 'wait-ready must remain quiet on success'
for secret in "$cli_token" "$cli_password" "$cli_hash"; do
  ! grep -Fq -- "$secret" "$cli_root/wait-ready.stderr" ||
    fail 'wait-ready must not print installed secrets'
done

set +e
run_cli "$cli_root" backup unexpected \
  >"$cli_root/backup-args.stdout" 2>"$cli_root/backup-args.stderr"
backup_args_status=$?
run_cli "$cli_root" restore \
  >"$cli_root/restore-args.stdout" 2>"$cli_root/restore-args.stderr"
restore_args_status=$?
run_cli "$cli_root" restore gs://other-bucket/remote-chrome/example.manifest \
  >"$cli_root/restore-bucket.stdout" 2>"$cli_root/restore-bucket.stderr"
restore_bucket_status=$?
set -e
[[ $backup_args_status -eq 2 && $restore_args_status -eq 2 &&
   $restore_bucket_status -eq 2 ]] ||
  fail 'backup and restore CLI arguments must enforce the Task 6 contract'

set +e
run_cli "$cli_root" update >"$cli_root/update-missing.stdout" \
  2>"$cli_root/update-missing.stderr"
update_missing_status=$?
run_cli "$cli_root" update --version master \
  >"$cli_root/update-master.stdout" 2>"$cli_root/update-master.stderr"
update_master_status=$?
set -e
[[ $update_missing_status -eq 2 ]] ||
  fail 'update without --version must exit 2'
[[ $update_master_status -eq 2 ]] ||
  fail 'master update must require --allow-unpinned'

update_archive=$(make_update_archive "$cli_root" v1.0.1)
: >"$REMOTE_CHROME_PROTOCOL_LOG"
REMOTE_CHROME_RELEASE_ARCHIVE="$update_archive" \
  run_cli "$cli_root" update --version v1.0.1 \
  >"$cli_root/update.stdout" 2>"$cli_root/update.stderr"
[[ $(<"$cli_root/etc/remote-chrome/active-version") == v1.0.1 &&
   $(<"$cli_root/etc/remote-chrome/previous-version") == v1.0.0 &&
   $(readlink "$cli_root/opt/remotechromemcp/current") == \
     releases/v1.0.1 ]] ||
  fail 'verified pinned update must activate the requested release'

# Retained release names are deliberately unrelated to activation history.
# Status must use protected state, never a lexicographic directory guess.
make_release "$cli_root" v99.0.0
: >"$REMOTE_CHROME_PROTOCOL_LOG"
run_cli "$cli_root" status >"$cli_root/status-history.stdout" \
  2>"$cli_root/status-history.stderr"
grep -Fxq 'Prior release: v1.0.0' "$cli_root/status-history.stdout" ||
  fail 'status must report the actual previous release with three retained releases'

rollback_archive=$(make_update_archive "$cli_root" v1.0.2)
set +e
REMOTE_CHROME_FAIL_AT=service-started \
REMOTE_CHROME_RELEASE_ARCHIVE="$rollback_archive" \
  run_cli "$cli_root" update --version v1.0.2 \
  >"$cli_root/update-rollback.stdout" \
  2>"$cli_root/update-rollback.stderr"
update_rollback_status=$?
set -e
[[ $update_rollback_status -ne 0 &&
   $(<"$cli_root/etc/remote-chrome/active-version") == v1.0.1 &&
   $(<"$cli_root/etc/remote-chrome/previous-version") == v1.0.0 &&
   $(readlink "$cli_root/opt/remotechromemcp/current") == \
     releases/v1.0.1 &&
   ! -e $cli_root/opt/remotechromemcp/releases/v1.0.2 ]] ||
  fail 'failed update must reuse activation rollback and remove its release'

master_archive=$(make_update_archive "$cli_root" master)
REMOTE_CHROME_RELEASE_ARCHIVE="$master_archive" \
  run_cli "$cli_root" update --version master --allow-unpinned \
  >"$cli_root/update-master-allowed.stdout" \
  2>"$cli_root/update-master-allowed.stderr"
[[ $(<"$cli_root/etc/remote-chrome/active-version") == master &&
   $(readlink "$cli_root/opt/remotechromemcp/current") == releases/master &&
   $(read_env_value "$cli_root/etc/remote-chrome/install.env" DOMAIN) == \
     chrome.example.com &&
   $(read_env_value "$cli_root/etc/remote-chrome/install.env" \
     RELEASE_VERIFICATION) == unpinned ]] ||
  fail 'explicitly allowed master must activate without corrupting config'

setup_uninstall_fixture() {
  local root=$1
  setup_activation_fixture "$root"
  touch "$REMOTE_CHROME_DATA_DIR/profile/profile-marker" \
    "$REMOTE_CHROME_DATA_DIR/backups/backup-marker" \
    "$REMOTE_CHROME_DATA_DIR/data-marker"
  printf 'chrome.example.com\n' >"$root/confirmation.tty"
}

default_uninstall_root="$test_root/uninstall-default"
setup_uninstall_fixture "$default_uninstall_root"
run_cli "$default_uninstall_root" uninstall \
  >"$default_uninstall_root/uninstall.stdout" \
  2>"$default_uninstall_root/uninstall.stderr"
[[ ! -e $default_uninstall_root/opt/remotechromemcp &&
   ! -e $default_uninstall_root/etc/systemd/system/remote-chrome.service &&
   ! -e $default_uninstall_root/usr/local/sbin/remote-chrome ]] ||
  fail 'default uninstall must remove releases, unit, and installed CLI'
for preserved in \
  "$default_uninstall_root/etc/remote-chrome/install.env" \
  "$default_uninstall_root/var/lib/remote-chrome/profile/profile-marker" \
  "$default_uninstall_root/var/lib/remote-chrome/backups/backup-marker"; do
  [[ -e $preserved ]] ||
    fail "default uninstall deleted preserved state: $preserved"
done

profile_uninstall_root="$test_root/uninstall-profile"
setup_uninstall_fixture "$profile_uninstall_root"
run_cli "$profile_uninstall_root" uninstall --delete-profile \
  >"$profile_uninstall_root/uninstall.stdout" \
  2>"$profile_uninstall_root/uninstall.stderr"
[[ ! -e $profile_uninstall_root/var/lib/remote-chrome/profile &&
   -e $profile_uninstall_root/var/lib/remote-chrome/backups/backup-marker &&
   -e $profile_uninstall_root/var/lib/remote-chrome/data-marker &&
   -e $profile_uninstall_root/etc/remote-chrome/install.env ]] ||
  fail '--delete-profile must delete only the exact managed profile'

backups_uninstall_root="$test_root/uninstall-backups"
setup_uninstall_fixture "$backups_uninstall_root"
run_cli "$backups_uninstall_root" uninstall --delete-backups \
  >"$backups_uninstall_root/uninstall.stdout" \
  2>"$backups_uninstall_root/uninstall.stderr"
[[ ! -e $backups_uninstall_root/var/lib/remote-chrome/backups &&
   -e $backups_uninstall_root/var/lib/remote-chrome/profile/profile-marker &&
   -e $backups_uninstall_root/var/lib/remote-chrome/data-marker ]] ||
  fail '--delete-backups must delete only the exact managed backups directory'

all_data_uninstall_root="$test_root/uninstall-all-data"
setup_uninstall_fixture "$all_data_uninstall_root"
REMOTE_CHROME_TTY="$all_data_uninstall_root/confirmation.tty" \
  run_cli "$all_data_uninstall_root" uninstall --delete-all-data \
  >"$all_data_uninstall_root/uninstall.stdout" \
  2>"$all_data_uninstall_root/uninstall.stderr"
[[ ! -e $all_data_uninstall_root/var/lib/remote-chrome &&
   ! -e $all_data_uninstall_root/etc/remote-chrome ]] ||
  fail '--delete-all-data must delete exact configured data and config roots'

# A production-mode confirmation source is always /dev/tty. Merely exporting
# an ordinary file must never relocate the destructive confirmation boundary.
production_confirmation_file="$test_root/production-confirmation.txt"
printf 'chrome.example.com\n' >"$production_confirmation_file"
production_confirmation_path=$(
  # shellcheck source=../vminstall/lib/management.sh
  source vminstall/lib/management.sh
  unset REMOTE_CHROME_TEST_ROOT REMOTE_CHROME_CANONICAL_TEST_ROOT
  REMOTE_CHROME_TTY="$production_confirmation_file"
  vm_management_confirmation_tty
)
[[ $production_confirmation_path == /dev/tty ]] ||
  fail 'production destructive confirmation must ignore regular-file overrides'

wrong_confirmation_root="$test_root/uninstall-wrong-confirmation"
setup_uninstall_fixture "$wrong_confirmation_root"
printf 'wrong.example.com\n' >"$wrong_confirmation_root/confirmation.tty"
set +e
REMOTE_CHROME_TTY="$wrong_confirmation_root/confirmation.tty" \
  run_cli "$wrong_confirmation_root" uninstall --delete-all-data \
  >"$wrong_confirmation_root/uninstall.stdout" \
  2>"$wrong_confirmation_root/uninstall.stderr"
wrong_confirmation_status=$?
set -e
[[ $wrong_confirmation_status -ne 0 &&
   -e $wrong_confirmation_root/opt/remotechromemcp &&
   -e $wrong_confirmation_root/var/lib/remote-chrome/profile/profile-marker ]] ||
  fail 'wrong domain confirmation must abort before uninstall mutation'

for unsafe_case in root parent symlink override; do
  unsafe_root="$test_root/uninstall-unsafe-$unsafe_case"
  setup_uninstall_fixture "$unsafe_root"
  unsafe_install="$unsafe_root/etc/remote-chrome/install.env"
  case "$unsafe_case" in
    root)
      sed -i 's#^REMOTE_CHROME_DATA_DIR=.*#REMOTE_CHROME_DATA_DIR=/#' \
        "$unsafe_install"
      ;;
    parent)
      sed -i \
        "s#^REMOTE_CHROME_DATA_DIR=.*#REMOTE_CHROME_DATA_DIR=$unsafe_root#" \
        "$unsafe_install"
      ;;
    symlink)
      mv "$unsafe_root/var/lib/remote-chrome" \
        "$unsafe_root/var/lib/remote-chrome-real"
      ln -s "$unsafe_root/var/lib/remote-chrome-real" \
        "$unsafe_root/var/lib/remote-chrome"
      ;;
    override)
      ;;
  esac
  set +e
  if [[ $unsafe_case == override ]]; then
    REMOTE_CHROME_CONFIG_ROOT="$unsafe_root/arbitrary-config" \
      run_cli "$unsafe_root" uninstall --delete-profile \
        "$unsafe_root/arbitrary-profile" \
        >"$unsafe_root/uninstall.stdout" 2>"$unsafe_root/uninstall.stderr"
  else
    run_cli "$unsafe_root" uninstall --delete-all-data --force \
      >"$unsafe_root/uninstall.stdout" 2>"$unsafe_root/uninstall.stderr"
  fi
  unsafe_status=$?
  set -e
  [[ $unsafe_status -ne 0 &&
     -e $unsafe_root/opt/remotechromemcp &&
     -e $unsafe_root/etc/systemd/system/remote-chrome.service ]] ||
    fail "$unsafe_case deletion canary must abort before uninstall mutation"
done

invalid_test_root="$test_root/not-used"
set +e
REMOTE_CHROME_TEST_ROOT=/ \
  bash vminstall/remote-chrome uninstall --delete-all-data --force \
  >"$invalid_test_root.stdout" 2>"$invalid_test_root.stderr"
invalid_test_root_status=$?
set -e
[[ $invalid_test_root_status -ne 0 ]] ||
  fail 'CLI must reject a root REMOTE_CHROME_TEST_ROOT'

# Each potentially blocking status/readiness boundary must lose to the CLI's
# own deadline, not this outer test watchdog.
for hanging_probe in SYSTEMCTL DOCKER CURL DU FIND; do
  set +e
  env \
    "REMOTE_CHROME_FAKE_${hanging_probe}_HANG=1" \
    REMOTE_CHROME_COMMAND_TIMEOUT=1 \
    REMOTE_CHROME_HEALTH_ATTEMPTS=1 \
    REMOTE_CHROME_TEST_EUID=0 \
    REMOTE_CHROME_FAKE_SYSTEMD_STATE="$cli_root/systemd-state" \
    REMOTE_CHROME_PROTOCOL_LOG="$cli_root/protocol.log" \
    REMOTE_CHROME_EXPECT_TOKEN="$cli_token" \
    REMOTE_CHROME_EXPECT_USERNAME=remotechrome \
    REMOTE_CHROME_EXPECT_PASSWORD="$cli_password" \
    /usr/bin/timeout 12 "$cli_root/usr/local/sbin/remote-chrome" status \
      >"$cli_root/hang-$hanging_probe.stdout" \
      2>"$cli_root/hang-$hanging_probe.stderr"
  hanging_status=$?
  set -e
  [[ $hanging_status -ne 124 && $hanging_status -ne 137 ]] ||
    fail "$hanging_probe probe must terminate within the CLI deadline"
done

# A Docker CLI plugin is a descendant rather than an exec replacement. Keep
# the inherited output pipe open after the monitored parent is killed; the
# inner deadline must terminate the whole process group before this outer
# watchdog fires.
forking_hang="$test_root/forking-descendant-hang"
apply_patch_fake "$forking_hang" \
  'trap "" TERM' \
  '(' \
  '  trap "" TERM' \
  '  /bin/sleep 30' \
  ') &' \
  'wait'
set +e
SECONDS=0
/usr/bin/timeout --kill-after=1 8s \
  bash -c '
    source vminstall/lib/activate.sh
    output=$(vm_run_with_timeout 1 "$1")
    status=$?
    [[ $status -eq 75 && -z $output ]]
  ' _ "$forking_hang" \
  >"$test_root/forking-timeout.stdout" \
  2>"$test_root/forking-timeout.stderr"
forking_timeout_status=$?
forking_timeout_elapsed=$SECONDS
set -e
[[ $forking_timeout_status -ne 124 &&
   $forking_timeout_status -ne 137 &&
   $forking_timeout_elapsed -lt 8 ]] ||
  fail "forking descendant must terminate inside the management deadline: status=$forking_timeout_status elapsed=$forking_timeout_elapsed"

for raw_timeout_status in 124 137; do
  set +e
  vm_run_with_timeout 1 \
    bash -c "exit $raw_timeout_status"
  normalized_timeout_status=$?
  set -e
  [[ $normalized_timeout_status -eq 75 ]] ||
    fail "timeout status $raw_timeout_status must normalize to 75"
done

for invalid_health_bounds in \
  'REMOTE_CHROME_HEALTH_ATTEMPTS=0' \
  'REMOTE_CHROME_HEALTH_ATTEMPTS=999' \
  'REMOTE_CHROME_HEALTH_DELAY=not-a-number' \
  'REMOTE_CHROME_HEALTH_DELAY=999' \
  'REMOTE_CHROME_PUBLIC_ATTEMPTS=0' \
  'REMOTE_CHROME_PUBLIC_ATTEMPTS=999' \
  'REMOTE_CHROME_PUBLIC_DELAY=not-a-number' \
  'REMOTE_CHROME_PUBLIC_DELAY=999' \
  'REMOTE_CHROME_COMMAND_TIMEOUT=0' \
  'REMOTE_CHROME_COMMAND_TIMEOUT=999' \
  'REMOTE_CHROME_SERVICE_TIMEOUT=0' \
  'REMOTE_CHROME_SERVICE_TIMEOUT=999'; do
  set +e
  env "$invalid_health_bounds" \
    REMOTE_CHROME_TEST_EUID=0 \
    "$cli_root/usr/local/sbin/remote-chrome" wait-ready \
      >"$cli_root/invalid-bound.stdout" \
      2>"$cli_root/invalid-bound.stderr"
  invalid_bound_status=$?
  set -e
  [[ $invalid_bound_status -ne 0 ]] ||
    fail "invalid readiness bound must be rejected: $invalid_health_bounds"
done

printf 'PASS: VM protected configuration, activation, rollback, handoff, and management CLI contracts\n'
