#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
original_path=$PATH

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

missing=
for function_name in \
  vm_ensure_profile_exchange_runtime vm_check_host vm_install_docker; do
  declare -F "$function_name" >/dev/null ||
    missing="${missing:+$missing }$function_name"
done
[[ -z $missing ]] ||
  fail "undefined functions: $missing"

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
  read -r fixture os_id version codename <<EOF
$matrix_row
EOF
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
     'apt-get <install> <-y> <ca-certificates> <curl> <gnupg> <openssl> <tar> <gzip> <coreutils> <python3>' ]] ||
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

python_runtime_root="$test_root/python-runtime"
mkdir "$python_runtime_root"
set_command_log_root "$python_runtime_root"
reset_fakes
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$python_runtime_root"
export REMOTE_CHROME_TEST_EUID=0
vm_init_paths
vm_ensure_profile_exchange_runtime
grep -Fxq 'apt-get <update>' "$command_log" &&
  grep -Fxq 'apt-get <install> <-y> <python3>' "$command_log" ||
  fail 'missing profile-exchange runtime must be installed explicitly'
[[ -f $python_runtime_root/usr/bin/python3 &&
   ! -L $python_runtime_root/usr/bin/python3 &&
   -x $python_runtime_root/usr/bin/python3 ]] ||
  fail 'dry-run profile-exchange runtime must be fixture-confined and executable'

: >"$command_log"
vm_ensure_profile_exchange_runtime
[[ ! -s $command_log ]] ||
  fail 'existing trusted profile-exchange runtime must not reinstall'

nonroot_runtime_root="$test_root/python-runtime-nonroot"
mkdir "$nonroot_runtime_root"
set_command_log_root "$nonroot_runtime_root"
reset_fakes
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$nonroot_runtime_root"
vm_init_paths
set +e
(REMOTE_CHROME_TEST_EUID=1000 vm_ensure_profile_exchange_runtime) \
  >"$nonroot_runtime_root/stdout" 2>"$nonroot_runtime_root/stderr"
nonroot_runtime_status=$?
set -e
[[ $nonroot_runtime_status -eq 77 ]] ||
  fail 'profile-exchange runtime installation must require root first'
[[ ! -s $command_log ]] ||
  fail 'profile-exchange runtime must not mutate before root validation'

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

PATH=$original_path
export PATH

if [[ ${REMOTE_CHROME_VM_DIST_INNER:-0} == 1 ]]; then
  inner_root="$(mktemp -d /tmp/remote-chrome-vminstall-inner.XXXXXX)"
  trap 'rm -rf "$test_root" "$inner_root"' EXIT
  inner_command_log="$inner_root/commands.log"
  : >"$inner_command_log"

  REMOTE_CHROME_DRY_RUN=1
  REMOTE_CHROME_TEST_ROOT="$inner_root"
  REMOTE_CHROME_OS_RELEASE=/etc/os-release
  unset REMOTE_CHROME_TEST_ARCH
  REMOTE_CHROME_TEST_EUID=0
  COMMAND_LOG="$inner_command_log"
  vm_init_paths
  vm_load_platform ||
    fail 'inner distribution test must load real /etc/os-release'
  [[ $(uname -m) == x86_64 ]] ||
    fail "inner distribution test requires x86_64, found $(uname -m)"
  vm_validate_platform ||
    fail "unsupported inner distribution: $OS_ID $OS_VERSION"
  command -v dash >/dev/null 2>&1 ||
    fail 'inner distribution is missing dash'
  dash -n vminstall/*.sh vminstall/lib/*.sh ||
    fail 'portable installer shell files must parse with dash'

  case "$OS_ID:$OS_VERSION" in
    ubuntu:22.04) inner_codename=jammy ;;
    ubuntu:24.04) inner_codename=noble ;;
    debian:12) inner_codename=bookworm ;;
    *) fail "unsupported inner package contract: $OS_ID $OS_VERSION" ;;
  esac
  vm_install_docker
  grep -Fxq \
    'apt-get <install> <-y> <ca-certificates> <curl> <gnupg> <openssl> <tar> <gzip> <coreutils> <python3>' \
    "$inner_command_log" ||
    fail 'inner dry-run must request the complete prerequisite package set'
  grep -Fxq \
    'apt-get <install> <-y> <docker-ce> <docker-ce-cli> <containerd.io> <docker-buildx-plugin> <docker-compose-plugin>' \
    "$inner_command_log" ||
    fail 'inner dry-run must request the official Docker package set'
  grep -Fxq \
    "deb [arch=amd64 signed-by=$inner_root/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $inner_codename stable" \
    "$inner_root/etc/apt/sources.list.d/docker.list" ||
    fail 'inner dry-run must stage the real distribution package source'
  exit 0
fi

if [[ ${REMOTE_CHROME_VM_DIST_CONTRACT_CHILD:-0} != 1 ]]; then
  outer_fake_bin="$test_root/outer-fake-bin"
  outer_docker_log="$test_root/outer-docker.log"
  outer_expected_log="$test_root/outer-docker.expected"
  mkdir "$outer_fake_bin"
  : >"$outer_docker_log"
  cat >"$outer_fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL %s\n' "$#" >>"$OUTER_DOCKER_LOG"
printf 'ARG %s\n' "$@" >>"$OUTER_DOCKER_LOG"
case "${1:-}" in
  info) exit "${FAKE_DOCKER_INFO_STATUS:-0}" ;;
  run) exit "${FAKE_DOCKER_RUN_STATUS:-0}" ;;
  *) exit 64 ;;
esac
FAKE_DOCKER
  chmod +x "$outer_fake_bin/docker"

  run_outer_probe() {
    : >"$outer_docker_log"
    set +e
    env -u CI -u VM_INSTALL_TEST_IMAGE \
      PATH="$outer_fake_bin:$PATH" \
      OUTER_DOCKER_LOG="$outer_docker_log" \
      REMOTE_CHROME_VM_DIST_CONTRACT_CHILD=1 \
      "$@" \
      bash "$repo_dir/tests/vminstall-distributions.test.sh" \
      >"$test_root/outer.stdout" 2>"$test_root/outer.stderr"
    outer_status=$?
    set -e
  }

  assert_safe_docker_run() {
    local image=$1
    cat >"$outer_expected_log" <<EOF
CALL 1
ARG info
CALL 11
ARG run
ARG --rm
ARG --mount
ARG type=bind,source=$repo_dir,target=/workspace,readonly
ARG --env
ARG REMOTE_CHROME_VM_DIST_INNER=1
ARG --workdir
ARG /workspace
ARG $image
ARG bash
ARG tests/vminstall-distributions.test.sh
EOF
    cmp -s "$outer_expected_log" "$outer_docker_log" ||
      fail "unsafe or unexpected Docker arguments for $image: $(cat "$outer_docker_log")"
  }

  run_outer_probe
  [[ $outer_status -eq 0 ]] ||
    fail "unset optional image must succeed, got status $outer_status"
  [[ ! -s $outer_docker_log ]] ||
    fail 'unset optional image must not invoke Docker'

  for allowed_image in ubuntu:22.04 ubuntu:24.04 debian:12; do
    run_outer_probe CI=1 "VM_INSTALL_TEST_IMAGE=$allowed_image"
    [[ $outer_status -eq 0 ]] ||
      fail "allowlisted image $allowed_image failed with status $outer_status"
    assert_safe_docker_run "$allowed_image"
    grep -Fxq "PASS: VM distribution image $allowed_image" \
      "$test_root/outer.stdout" ||
      fail "allowlisted image $allowed_image needs a positive PASS"
  done

  for rejected_image in \
    alpine:latest \
    --privileged \
    $'ubuntu:22.04\n--privileged'; do
    run_outer_probe CI=1 "VM_INSTALL_TEST_IMAGE=$rejected_image"
    [[ $outer_status -ne 0 ]] ||
      fail "invalid image value must fail: $rejected_image"
    [[ ! -s $outer_docker_log ]] ||
      fail "invalid image value reached Docker: $rejected_image"
  done

  run_outer_probe \
    FAKE_DOCKER_INFO_STATUS=1 \
    VM_INSTALL_TEST_IMAGE=ubuntu:22.04
  [[ $outer_status -eq 0 ]] ||
    fail 'local Docker infrastructure failure must skip successfully'
  grep -Fq 'SKIP:' "$test_root/outer.stdout" ||
    fail 'local Docker infrastructure failure must print SKIP'
  cat >"$outer_expected_log" <<'EOF'
CALL 1
ARG info
EOF
  cmp -s "$outer_expected_log" "$outer_docker_log" ||
    fail 'daemon failure must not attempt docker run'

  run_outer_probe \
    CI=1 \
    FAKE_DOCKER_INFO_STATUS=1 \
    VM_INSTALL_TEST_IMAGE=ubuntu:22.04
  [[ $outer_status -ne 0 ]] ||
    fail 'CI Docker infrastructure failure must fail instead of skipping'
  ! grep -Fq 'SKIP:' "$test_root/outer.stdout" ||
    fail 'CI Docker infrastructure failure must not report a skip'
  cmp -s "$outer_expected_log" "$outer_docker_log" ||
    fail 'CI daemon failure must not attempt docker run'

  run_outer_probe \
    FAKE_DOCKER_RUN_STATUS=73 \
    VM_INSTALL_TEST_IMAGE=ubuntu:22.04
  [[ $outer_status -eq 73 ]] ||
    fail "launched container failure must propagate status 73, got $outer_status"
  ! grep -Fq 'SKIP:' "$test_root/outer.stdout" ||
    fail 'launched container failure must never become a local skip'
  ! grep -Fq 'PASS: VM distribution image' "$test_root/outer.stdout" ||
    fail 'failed container test must not print an image PASS'
fi

requested_image=${VM_INSTALL_TEST_IMAGE:-}
[[ -n $requested_image ]] || exit 0

case "$requested_image" in
  ubuntu:22.04|ubuntu:24.04|debian:12) ;;
  *) fail "unsupported VM_INSTALL_TEST_IMAGE: $requested_image" ;;
esac

docker_unavailable=
if ! command -v docker >/dev/null 2>&1; then
  docker_unavailable='Docker client is unavailable'
elif ! docker info >/dev/null 2>&1; then
  docker_unavailable='Docker daemon is unavailable'
fi

if [[ -n $docker_unavailable ]]; then
  if [[ ${CI:-} == 1 ]]; then
    fail "$docker_unavailable in CI"
  fi
  printf 'SKIP: %s; optional image %s was not run\n' \
    "$docker_unavailable" "$requested_image"
  exit 0
fi

set +e
docker run --rm \
  --mount "type=bind,source=$repo_dir,target=/workspace,readonly" \
  --env REMOTE_CHROME_VM_DIST_INNER=1 \
  --workdir /workspace \
  "$requested_image" \
  bash tests/vminstall-distributions.test.sh
container_status=$?
set -e
if [[ $container_status -ne 0 ]]; then
  printf 'FAIL: VM distribution image %s exited with status %s\n' \
    "$requested_image" "$container_status" >&2
  exit "$container_status"
fi
printf 'PASS: VM distribution image %s\n' "$requested_image"
