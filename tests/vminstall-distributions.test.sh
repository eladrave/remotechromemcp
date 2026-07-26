#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_root="$(mktemp -d /tmp/remote-chrome-vminstall-distributions.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
[[ -d $test_root && $test_root == /tmp/* && ! -L $test_root ]] ||
  fail 'fixture root must be a canonical directory beneath /tmp'

fake_bin="$test_root/fake-bin"
command_log="$test_root/commands.log"
all_command_log="$test_root/all-commands.log"
mkdir "$fake_bin"
: >"$command_log"
: >"$all_command_log"

cat >"$fake_bin/fake-command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

name=${0##*/}
{
  printf '%s' "$name"
  printf ' <%s>' "$@"
  printf '\n'
} >>"$COMMAND_LOG"
{
  printf '%s' "$name"
  printf ' <%s>' "$@"
  printf '\n'
} >>"$ALL_COMMAND_LOG"

case "$name" in
  dpkg)
    [[ ${1:-} == --print-architecture ]] || exit 64
    printf '%s\n' "${FAKE_DPKG_ARCH:-amd64}"
    ;;
  docker)
    if [[ ${1:-} == compose && ${2:-} == version ]]; then
      [[ ${FAKE_DOCKER_PRESENT:-0} == 1 ]]
    fi
    ;;
  getent)
    [[ ${1:-} == ahosts ]] || exit 64
    query=${2:-}
    case "$query" in
      *:*|[0-9]*)
        [[ ${FAKE_GETENT_NUMERIC_FAIL:-0} != 1 ]] || exit 2
        case "$query" in
          2001:0db8:0000:0000:0000:0000:0000:0010|2001:db8::10)
            printf '%s STREAM %s\n' 2001:db8::10 "$query"
            ;;
          *)
            printf '%s STREAM %s\n' "$query" "$query"
            ;;
        esac
        ;;
      *)
        printf '%s STREAM %s\n' \
          "${FAKE_DOMAIN_IP:-203.0.113.10}" "${query:-unknown}"
        ;;
    esac
    ;;
  curl)
    case "$*" in
      *metadata.google.internal*)
        [[ -n ${FAKE_METADATA_IP:-} ]] || exit 22
        printf '%s\n' "$FAKE_METADATA_IP"
        ;;
      *api.ipify.org*)
        printf '%s\n' "${FAKE_PUBLIC_IP:-203.0.113.10}"
        ;;
    esac
    ;;
  ss)
    printf '%s' "${FAKE_SS_OUTPUT:-}"
    ;;
  timeout)
    shift
    "$@"
    ;;
esac
FAKE
chmod +x "$fake_bin/fake-command"
for command_name in \
  getent curl ss apt-get dpkg systemctl docker gpg install mv \
  timeout mkfs fdisk parted wipefs; do
  ln -s fake-command "$fake_bin/$command_name"
done

export COMMAND_LOG="$command_log"
export ALL_COMMAND_LOG="$all_command_log"
export REMOTE_CHROME_FAKE_BIN="$fake_bin"
export PATH="$fake_bin:$PATH"

set_command_log_root() {
  local root=$1
  command_log="$root/commands.log"
  : >"$command_log"
  export COMMAND_LOG="$command_log"
}

REMOTE_CHROME_SKIP_MAIN=1
# shellcheck source=../vminstall/installer-main.sh
source vminstall/installer-main.sh

missing=()
for function_name in vm_check_host vm_install_docker; do
  declare -F "$function_name" >/dev/null || missing+=("$function_name")
done
((${#missing[@]} == 0)) ||
  fail "undefined functions: ${missing[*]}"

assert_no_mutations() {
  ! grep -Eq '^(apt-get|install|gpg|mv|systemctl) ' "$command_log" ||
    fail "host mutation occurred before validation: $(cat "$command_log")"
}

reset_fakes() {
  : >"$command_log"
  export FAKE_DPKG_ARCH=amd64
  export FAKE_DOCKER_PRESENT=0
  export FAKE_DOMAIN_IP=203.0.113.10
  export FAKE_METADATA_IP=
  export FAKE_PUBLIC_IP=203.0.113.10
  export FAKE_SS_OUTPUT=
  export FAKE_GETENT_NUMERIC_FAIL=0
}

run_main_expect_failure() {
  local expected_status=$1
  shift
  set +e
  (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_TEST_EUID=0
    REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-ubuntu-24.04
    REMOTE_CHROME_TEST_ARCH=x86_64
    vm_installer_main "$@"
  ) >"$test_root/main.stdout" 2>"$test_root/main.stderr"
  local status=$?
  set -e
  [[ $status -eq $expected_status ]] ||
    fail "installer exit status: expected $expected_status, got $status"
}

for matrix_row in \
  'ubuntu-22.04 ubuntu 22.04 jammy' \
  'ubuntu-24.04 ubuntu 24.04 noble' \
  'debian-12 debian 12 bookworm'; do
  read -r fixture os_id version codename <<<"$matrix_row"
  fixture_root="$test_root/matrix-$fixture"
  mkdir "$fixture_root"
  set_command_log_root "$fixture_root"
  reset_fakes
  REMOTE_CHROME_DRY_RUN=1
  REMOTE_CHROME_TEST_ROOT="$fixture_root"
  REMOTE_CHROME_OS_RELEASE="tests/fixtures/os-release-$fixture"
  REMOTE_CHROME_TEST_ARCH=x86_64
  vm_init_paths
  vm_load_platform
  vm_validate_platform || fail "$fixture must be supported"
  vm_install_docker

  grep -Fxq 'dpkg <--print-architecture>' "$command_log" ||
    fail "$fixture must verify the dpkg architecture"
  grep -Fq "https://download.docker.com/linux/$os_id/gpg" "$command_log" ||
    fail "$fixture must use the official Docker $os_id key"
  docker_list="$fixture_root/etc/apt/sources.list.d/docker.list"
  [[ -f $docker_list ]] || fail "$fixture must stage docker.list below the fixture root"
  grep -Fxq \
    "deb [arch=amd64 signed-by=$fixture_root/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$os_id $codename stable" \
    "$docker_list" ||
    fail "$fixture must use Docker codename $codename"
  grep -Fxq \
    'apt-get <install> <-y> <docker-ce> <docker-ce-cli> <containerd.io> <docker-buildx-plugin> <docker-compose-plugin>' \
    "$command_log" ||
    fail "$fixture must install the official Docker packages"
  [[ $(sed -n '3p' "$command_log") == 'apt-get <update>' ]] ||
    fail "$fixture must update apt before installing prerequisites"
  [[ $(sed -n '4p' "$command_log") == \
     'apt-get <install> <-y> <ca-certificates> <curl> <gnupg> <openssl> <tar> <gzip> <coreutils>' ]] ||
    fail "$fixture must install the complete prerequisite package set"
  [[ $(sed -n '12p' "$command_log") == 'apt-get <update>' ]] ||
    fail "$fixture must update apt after installing the Docker repository"
  [[ $(sed -n '14p' "$command_log") == \
     'systemctl <enable> <--now> <docker>' ]] ||
    fail "$fixture must enable and start Docker after package installation"
  [[ $(sed -n '15p' "$command_log") == \
     'docker <compose> <version>' ]] ||
    fail "$fixture must verify the Compose plugin last"
done

arch_root="$test_root/unsupported-arch"
mkdir "$arch_root"
set_command_log_root "$arch_root"
reset_fakes
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$arch_root"
REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-ubuntu-24.04
REMOTE_CHROME_TEST_ARCH=x86_64
FAKE_DPKG_ARCH=arm64
export FAKE_DPKG_ARCH
vm_init_paths
vm_load_platform
set +e
(vm_install_docker) >"$test_root/arch.stdout" 2>"$test_root/arch.stderr"
arch_status=$?
set -e
[[ $arch_status -ne 0 ]] || fail 'Docker installation must reject non-amd64 dpkg architecture'
assert_no_mutations

descendant_root="$test_root/descendant-root"
descendant_escape="$test_root/descendant-escape"
mkdir "$descendant_root" "$descendant_escape"
set_command_log_root "$descendant_root"
reset_fakes
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$descendant_root"
REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-ubuntu-24.04
REMOTE_CHROME_TEST_ARCH=x86_64
vm_init_paths
vm_load_platform
ln -s ../descendant-escape "$descendant_root/etc"
set +e
(vm_install_docker) \
  >"$test_root/descendant.stdout" 2>"$test_root/descendant.stderr"
descendant_status=$?
set -e
[[ $descendant_status -ne 0 ]] ||
  fail 'dry-run Docker writes must reject a descendant symlink escape'
[[ -z $(find "$descendant_escape" -mindepth 1 -print -quit) ]] ||
  fail 'dry-run Docker writes must not follow a descendant symlink outside the fixture root'

log_canary_root="$test_root/log-canary-root"
log_canary_escape="$test_root/log-canary-escape"
mkdir "$log_canary_root" "$log_canary_escape"
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$log_canary_root"
vm_init_paths

absolute_command_log="$test_root/absolute-command.log"
command_log="$absolute_command_log"
export COMMAND_LOG="$command_log"
external_commands_before="$(wc -l <"$all_command_log")"
set +e
vm_run_mutation apt-get update \
  >"$test_root/absolute-command.stdout" \
  2>"$test_root/absolute-command.stderr"
absolute_command_status=$?
set -e
[[ $absolute_command_status -ne 0 ]] ||
  fail 'dry-run mutation must reject an absolute command log outside the canonical test root'
[[ ! -e "$absolute_command_log" ]] ||
  fail 'rejected absolute command log must not be written'
[[ $(wc -l <"$all_command_log") -eq $external_commands_before ]] ||
  fail 'invalid absolute command log must fail before external mutation'

ln -s ../log-canary-escape "$log_canary_root/logs"
command_log="$log_canary_root/logs/commands.log"
export COMMAND_LOG="$command_log"
set +e
vm_run_mutation apt-get update \
  >"$test_root/symlink-command.stdout" \
  2>"$test_root/symlink-command.stderr"
symlink_command_status=$?
set -e
[[ $symlink_command_status -ne 0 ]] ||
  fail 'dry-run mutation must reject a descendant-symlink command log escape'
[[ ! -e "$log_canary_escape/commands.log" ]] ||
  fail 'rejected descendant-symlink command log must not be written'
[[ $(wc -l <"$all_command_log") -eq $external_commands_before ]] ||
  fail 'invalid descendant-symlink command log must fail before external mutation'

normal_command_log="$test_root/normal-command.log"
(
  unset REMOTE_CHROME_TEST_ROOT REMOTE_CHROME_CANONICAL_TEST_ROOT
  REMOTE_CHROME_DRY_RUN=0
  COMMAND_LOG="$normal_command_log"
  export REMOTE_CHROME_DRY_RUN COMMAND_LOG
  vm_log_command normal-non-test command
)
grep -Fxq 'normal-non-test <command>' "$normal_command_log" ||
  fail 'normal non-test command logging behavior must be preserved'

set_command_log_root "$test_root"
reset_fakes
FAKE_DOCKER_PRESENT=1
export FAKE_DOCKER_PRESENT
vm_install_docker
grep -Fxq 'docker <compose> <version>' "$command_log" ||
  fail 'existing Docker Compose must be verified'
[[ $(wc -l <"$command_log") -eq 1 ]] ||
  fail 'existing Docker Compose must skip package installation'

reset_fakes
unset REMOTE_CHROME_TEST_ROOT
run_main_expect_failure 64 \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --non-interactive \
  --skip-dns-check
assert_no_mutations

reset_fakes
escape_target="$test_root/escape"
mkdir "$escape_target"
ln -s "$escape_target" "$test_root/root-link"
for unsafe_root in "$test_root/../escape-root" "$test_root/root-link" /etc; do
  set +e
  (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_TEST_ROOT="$unsafe_root"
    vm_init_paths
  ) >"$test_root/root.stdout" 2>"$test_root/root.stderr"
  root_status=$?
  set -e
  [[ $root_status -eq 64 ]] ||
    fail "unsafe fixture root must fail: $unsafe_root"
  assert_no_mutations
done

REMOTE_CHROME_INSTALL_ROOT=/etc/remote-chrome-override
REMOTE_CHROME_CONFIG_ROOT=/var/remote-chrome-override
REMOTE_CHROME_TEST_ROOT="$test_root"
vm_init_paths
[[ $REMOTE_CHROME_INSTALL_ROOT == "$test_root/opt/remotechromemcp" &&
   $REMOTE_CHROME_CONFIG_ROOT == "$test_root/etc/remote-chrome" ]] ||
  fail 'absolute path overrides must remain confined to the canonical fixture root'
assert_no_mutations

reset_fakes
export REMOTE_CHROME_TEST_ROOT="$test_root"
run_main_expect_failure 2 \
  --domain 'https://chrome.example.com' \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --non-interactive
assert_no_mutations

reset_fakes
export REMOTE_CHROME_TEST_ROOT="$test_root"
run_main_expect_failure 2 \
  --domain chrome.example.com \
  --email invalid \
  --data-dir "$test_root/data" \
  --non-interactive
assert_no_mutations

reset_fakes
export REMOTE_CHROME_TEST_ROOT="$test_root"
FAKE_DOMAIN_IP=198.51.100.40
FAKE_PUBLIC_IP=203.0.113.10
export FAKE_DOMAIN_IP FAKE_PUBLIC_IP
run_main_expect_failure 69 \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --non-interactive
assert_no_mutations
grep -Fq '198.51.100.40' "$test_root/main.stderr" ||
  fail 'DNS mismatch must report the resolved address'
grep -Fq '203.0.113.10' "$test_root/main.stderr" ||
  fail 'DNS mismatch must report the public address'
grep -Fq 'curl <-fsS> <--max-time> <5>' "$command_log" ||
  fail 'public IP discovery must use a bounded five-second timeout'

reset_fakes
DOMAIN=chrome.example.com
SKIP_DNS_CHECK=0
FAKE_DOMAIN_IP=2001:0db8:0000:0000:0000:0000:0000:0010
FAKE_METADATA_IP='[2001:DB8::10]'
FAKE_PUBLIC_IP=198.51.100.99
export FAKE_DOMAIN_IP FAKE_METADATA_IP FAKE_PUBLIC_IP
vm_verify_dns ||
  fail 'expanded and compressed forms of the same IPv6 address must compare equal'
grep -Fq 'metadata.google.internal' "$command_log" ||
  fail 'DNS verification must try GCE metadata discovery'
! grep -Fq 'api.ipify.org' "$command_log" ||
  fail 'successful metadata discovery must skip the public fallback'
grep -Fxq \
  'timeout <5> <getent> <ahosts> <2001:0db8:0000:0000:0000:0000:0000:0010>' \
  "$command_log" ||
  fail 'DNS IPv6 values must use the bounded trusted numeric-address parser'
grep -Fxq 'timeout <5> <getent> <ahosts> <2001:DB8::10>' "$command_log" ||
  fail 'public IPv6 values must use the bounded trusted numeric-address parser'

reset_fakes
DOMAIN=chrome.example.com
SKIP_DNS_CHECK=0
FAKE_DOMAIN_IP=2001:db8::10
FAKE_METADATA_IP=2001:db8::10
FAKE_GETENT_NUMERIC_FAIL=1
export FAKE_DOMAIN_IP FAKE_METADATA_IP FAKE_GETENT_NUMERIC_FAIL
set +e
(vm_verify_dns) >"$test_root/parser-failure.stdout" \
  2>"$test_root/parser-failure.stderr"
parser_failure_status=$?
set -e
[[ $parser_failure_status -ne 0 ]] ||
  fail 'DNS verification must reject an address the numeric parser cannot validate'
grep -Fq 'timeout <5> <getent> <ahosts>' "$command_log" ||
  fail 'numeric-address parser failures must remain bounded to five seconds'

reset_fakes
export REMOTE_CHROME_TEST_ROOT="$test_root"
FAKE_DOMAIN_IP=198.51.100.40
FAKE_PUBLIC_IP=203.0.113.10
FAKE_SS_OUTPUT='LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FAKE_DOMAIN_IP FAKE_PUBLIC_IP FAKE_SS_OUTPUT
run_main_expect_failure 69 \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --non-interactive \
  --skip-dns-check
assert_no_mutations
grep -Fq 'nginx' "$test_root/main.stderr" ||
  fail 'port conflict must report the owning process'

for port in 80 443; do
  reset_fakes
  FAKE_SS_OUTPUT="LISTEN 0 511 [::]:$port [::]:* users:((\"listener-$port\",pid=456,fd=7))"
  export FAKE_SS_OUTPUT
  set +e
  vm_check_public_ports >"$test_root/port.stdout" 2>"$test_root/port.stderr"
  port_status=$?
  set -e
  [[ $port_status -ne 0 ]] || fail "listener on port $port must fail preflight"
  grep -Fq "listener-$port" "$test_root/port.stderr" ||
    fail "port $port owner must be reported"
done

sleep 30 &
fixture_listener_pid=$!
reset_fakes
FAKE_SS_OUTPUT="LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"fixture\",pid=$fixture_listener_pid,fd=3))"
export FAKE_SS_OUTPUT
set +e
vm_check_public_ports >/dev/null 2>"$test_root/listener.stderr"
listener_status=$?
set -e
[[ $listener_status -ne 0 ]] ||
  fail 'fixture listener must trigger a port conflict'
kill -0 "$fixture_listener_pid" 2>/dev/null ||
  fail 'port preflight must report listeners without terminating them'
kill "$fixture_listener_pid"
wait "$fixture_listener_pid" 2>/dev/null || true

reset_fakes
SKIP_DNS_CHECK=1
vm_verify_dns
[[ ! -s $command_log ]] ||
  fail 'skip DNS must not run network discovery commands'

if grep -Eq '^(mkfs|fdisk|parted|wipefs)([ <]|$)' "$all_command_log"; then
  fail 'generic installer must never invoke destructive disk tools'
fi

disk_tool_source_matches="$test_root/disk-tool-source.matches"
if grep -En \
  '(^|[^[:alnum:]_])(mkfs(\.[[:alnum:]_-]+)?|fdisk|parted|wipefs)([^[:alnum:]_]|$)' \
  vminstall/install.sh vminstall/installer-main.sh vminstall/lib/*.sh \
  >"$disk_tool_source_matches"; then
  fail "generic installer source contains a forbidden disk-tool invocation: $(cat "$disk_tool_source_matches")"
fi

printf 'PASS: VM host, distribution, Docker, and network preflight contracts\n'
