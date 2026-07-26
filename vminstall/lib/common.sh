#!/usr/bin/env bash

vm_die() {
  local code=$1
  shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

vm_log() {
  printf '[remote-chrome] %s\n' "$*"
}

vm_log_command() {
  local command_log=${COMMAND_LOG:-}
  [[ -n $command_log ]] || return 0
  {
    printf '%s' "$1"
    shift
    printf ' <%s>' "$@"
    printf '\n'
  } >>"$command_log"
}

vm_run_mutation() {
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_log_command "$@"
    return 0
  fi
  "$@"
}

vm_require_root() {
  local effective_uid=${REMOTE_CHROME_TEST_EUID:-$EUID}
  [[ $effective_uid -eq 0 ]] ||
    vm_die 77 'Run the installer as root, for example with sudo sh'
}

vm_init_paths() {
  local prefix=
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    prefix=$(realpath -m -- "$REMOTE_CHROME_TEST_ROOT")
    [[ $prefix == /tmp/* && -d $prefix && ! -L $REMOTE_CHROME_TEST_ROOT ]] ||
      vm_die 64 'REMOTE_CHROME_TEST_ROOT must be a real directory beneath /tmp'
    REMOTE_CHROME_INSTALL_ROOT=${prefix}/opt/remotechromemcp
    REMOTE_CHROME_CONFIG_ROOT=${prefix}/etc/remote-chrome
    REMOTE_CHROME_SYSTEMD_ROOT=${prefix}/etc/systemd/system
    REMOTE_CHROME_CLI_ROOT=${prefix}/usr/local/sbin
  else
    [[ ${REMOTE_CHROME_DRY_RUN:-0} != 1 ]] ||
      vm_die 64 'Dry-run requires REMOTE_CHROME_TEST_ROOT'
    REMOTE_CHROME_INSTALL_ROOT=${REMOTE_CHROME_INSTALL_ROOT:-/opt/remotechromemcp}
    REMOTE_CHROME_CONFIG_ROOT=${REMOTE_CHROME_CONFIG_ROOT:-/etc/remote-chrome}
    REMOTE_CHROME_SYSTEMD_ROOT=${REMOTE_CHROME_SYSTEMD_ROOT:-/etc/systemd/system}
    REMOTE_CHROME_CLI_ROOT=${REMOTE_CHROME_CLI_ROOT:-/usr/local/sbin}
  fi
}

vm_validate_domain() {
  [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ $1 == *.* ]]
}

vm_validate_email() {
  [[ ${1:-} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}
