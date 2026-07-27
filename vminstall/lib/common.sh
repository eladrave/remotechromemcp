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
  vm_require_confined_destination "$command_log" || return 1
  {
    printf '%s' "$1"
    shift
    printf ' <%s>' "$@"
    printf '\n'
  } >>"$command_log"
}

vm_run_mutation() {
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_log_command "$@" || return 1
    return 0
  fi
  "$@"
}

vm_require_root() {
  local effective_uid=$EUID
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} &&
        -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    effective_uid=${REMOTE_CHROME_TEST_EUID:-$EUID}
  fi
  [[ $effective_uid -eq 0 ]] ||
    vm_die 77 'Run the installer as root, for example with sudo sh'
}

vm_trusted_python3() {
  local command=/usr/bin/python3 resolved prefix=/usr/bin
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    prefix="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/bin"
    command="$prefix/python3"
  fi
  [[ -e $command && -x $command ]] || return 69
  resolved=$(/usr/bin/readlink -f -- "$command") || return 69
  [[ $resolved == "$prefix/python3" ||
     $resolved == "$prefix/python3."* ]] || return 69
  [[ -f $resolved && ! -L $resolved && -x $resolved ]] || return 69
  printf '%s' "$resolved"
}

vm_init_paths() {
  local prefix=
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    prefix=$(realpath -m -- "$REMOTE_CHROME_TEST_ROOT")
    [[ $prefix == /tmp/* && -d $prefix && ! -L $REMOTE_CHROME_TEST_ROOT ]] ||
      vm_die 64 'REMOTE_CHROME_TEST_ROOT must be a real directory beneath /tmp'
    REMOTE_CHROME_CANONICAL_TEST_ROOT=$prefix
    REMOTE_CHROME_INSTALL_ROOT=${prefix}/opt/remotechromemcp
    REMOTE_CHROME_CONFIG_ROOT=${prefix}/etc/remote-chrome
    REMOTE_CHROME_SYSTEMD_ROOT=${prefix}/etc/systemd/system
    REMOTE_CHROME_CLI_ROOT=${prefix}/usr/local/sbin
  else
    [[ ${REMOTE_CHROME_DRY_RUN:-0} != 1 ]] ||
      vm_die 64 'Dry-run requires REMOTE_CHROME_TEST_ROOT'
    REMOTE_CHROME_INSTALL_ROOT=/opt/remotechromemcp
    REMOTE_CHROME_CONFIG_ROOT=/etc/remote-chrome
    REMOTE_CHROME_SYSTEMD_ROOT=/etc/systemd/system
    REMOTE_CHROME_CLI_ROOT=/usr/local/sbin
  fi
}

vm_require_confined_destination() {
  [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]] || return 0
  [[ -n ${REMOTE_CHROME_TEST_ROOT:-} &&
     -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]] || {
    printf 'ERROR: dry-run destination has no test root: %s\n' "$1" >&2
    return 1
  }

  local current_root destination
  current_root=$(realpath -e -- "$REMOTE_CHROME_TEST_ROOT") || return 1
  [[ $current_root == "$REMOTE_CHROME_CANONICAL_TEST_ROOT" ]] || return 1
  destination=$(realpath -m -- "$1") || return 1
  case "$destination" in
    "$REMOTE_CHROME_CANONICAL_TEST_ROOT"|"$REMOTE_CHROME_CANONICAL_TEST_ROOT"/*)
      return 0
      ;;
    *)
      printf 'ERROR: dry-run destination escapes test root: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

vm_validate_domain() {
  [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ $1 == *.* ]]
}

vm_validate_email() {
  [[ ${1:-} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

vm_validate_gcs_bucket() {
  local bucket=${1:-}
  ((${#bucket} >= 3 && ${#bucket} <= 63)) &&
    [[ $bucket =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] &&
    [[ $bucket != *..* ]]
}

vm_gcloud_path() {
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    printf '%s/usr/bin/gcloud' "$REMOTE_CHROME_CANONICAL_TEST_ROOT"
  else
    printf '/usr/bin/gcloud'
  fi
}

vm_trusted_gcloud() {
  local command resolved package_target prefix=
  command=$(vm_gcloud_path)
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    prefix=$REMOTE_CHROME_CANONICAL_TEST_ROOT
  fi
  package_target="$prefix/usr/lib/google-cloud-sdk/bin/gcloud"
  [[ -e $command && -x $command ]] || return 69
  resolved=$(/usr/bin/readlink -f -- "$command") || return 69
  if [[ -L $command ]]; then
    [[ $resolved == "$package_target" ]] || return 69
  else
    [[ $resolved == "$command" && -f $command ]] || return 69
  fi
  [[ -f $resolved && ! -L $resolved && -x $resolved ]] || return 69
  if [[ -z ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    local mode
    [[ $(stat -c '%u' -- "$resolved") == 0 ]] || return 69
    mode=$(stat -c '%a' -- "$resolved") || return 69
    (( (8#$mode & 0022) == 0 )) || return 69
  fi
  printf '%s' "$command"
}
