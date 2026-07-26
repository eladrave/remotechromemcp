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
  elif [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_die 64 'Dry-run requires REMOTE_CHROME_TEST_ROOT'
  fi

  REMOTE_CHROME_INSTALL_ROOT=${REMOTE_CHROME_INSTALL_ROOT:-${prefix}/opt/remotechromemcp}
  REMOTE_CHROME_CONFIG_ROOT=${REMOTE_CHROME_CONFIG_ROOT:-${prefix}/etc/remote-chrome}
  REMOTE_CHROME_SYSTEMD_ROOT=${REMOTE_CHROME_SYSTEMD_ROOT:-${prefix}/etc/systemd/system}
  REMOTE_CHROME_CLI_ROOT=${REMOTE_CHROME_CLI_ROOT:-${prefix}/usr/local/sbin}
}

vm_validate_domain() {
  [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ $1 == *.* ]]
}

vm_validate_email() {
  [[ ${1:-} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

vm_load_platform() {
  local release_file=${REMOTE_CHROME_OS_RELEASE:-/etc/os-release}
  local ID=
  local VERSION_ID=

  [[ -r $release_file ]] ||
    vm_die 65 "Cannot read platform metadata: $release_file"
  # os-release is a shell-compatible assignment file provided by the OS.
  # shellcheck disable=SC1090
  source "$release_file"

  PLATFORM_ID=${ID:-}
  PLATFORM_VERSION_ID=${VERSION_ID:-}
  PLATFORM_ARCH=${REMOTE_CHROME_TEST_ARCH:-$(uname -m)}
}

vm_validate_platform() {
  case "$PLATFORM_ARCH" in
    x86_64|amd64) ;;
    *) return 1 ;;
  esac

  case "$PLATFORM_ID:$PLATFORM_VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04|debian:12) return 0 ;;
    *) return 1 ;;
  esac
}
