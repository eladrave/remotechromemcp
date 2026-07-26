#!/usr/bin/env bash

vm_load_platform() {
  local source=${REMOTE_CHROME_OS_RELEASE:-/etc/os-release}
  local key value
  [[ -r $source ]] || return 1
  OS_ID=
  OS_VERSION=
  while IFS='=' read -r key value; do
    case "$key" in
      ID) OS_ID=${value//\"/} ;;
      VERSION_ID) OS_VERSION=${value//\"/} ;;
    esac
  done <"$source"
  PLATFORM_ID=$OS_ID
  PLATFORM_VERSION_ID=$OS_VERSION
  PLATFORM_ARCH=${REMOTE_CHROME_TEST_ARCH:-$(uname -m)}
}

vm_validate_platform() {
  local arch=${PLATFORM_ARCH:-${REMOTE_CHROME_TEST_ARCH:-$(uname -m)}}
  [[ $arch == x86_64 || $arch == amd64 ]] || return 1
  [[ $OS_ID == ubuntu && ( $OS_VERSION == 22.04 || $OS_VERSION == 24.04 ) ||
     $OS_ID == debian && $OS_VERSION == 12 ]]
}

vm_check_host() {
  local required
  vm_require_root
  for required in getent curl ss tar sha256sum timeout; do
    command -v "$required" >/dev/null 2>&1 ||
      vm_die 69 "Required host command is unavailable: $required"
  done
}

vm_normalize_address() {
  local address=${1#[} parsed canonical _
  address=${address%]}
  address=${address#::ffff:}
  case "$address" in
    ''|*[!0-9A-Fa-f:.]*) return 1 ;;
  esac
  parsed=$(timeout 5 getent ahosts "$address") || return 1
  read -r canonical _ <<<"$parsed"
  [[ -n $canonical ]] || return 1
  canonical=${canonical#::ffff:}
  printf '%s' "${canonical,,}"
}

vm_verify_dns() {
  [[ ${SKIP_DNS_CHECK:-0} == 1 ]] && return 0

  local resolved_output external_ip address normalized_address
  local normalized_external
  resolved_output=$(timeout 5 getent ahosts "$DOMAIN") ||
    vm_die 69 "Unable to resolve DNS for $DOMAIN"

  external_ip=$(
    curl -fsS --max-time 5 \
      -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip'
  ) || external_ip=$(
    curl -fsS --max-time 5 'https://api.ipify.org'
  ) || vm_die 69 'Unable to discover this host public IP'

  normalized_external=$(vm_normalize_address "$external_ip") ||
    vm_die 69 "Public IP discovery returned an invalid numeric address: $external_ip"
  while read -r address _; do
    normalized_address=$(vm_normalize_address "$address") || continue
    [[ $normalized_address == "$normalized_external" ]] &&
      return 0
  done <<<"$resolved_output"

  printf 'ERROR: DNS for %s resolves to %s, but this host public IP is %s\n' \
    "$DOMAIN" "$(awk '{print $1}' <<<"$resolved_output" | paste -sd, -)" \
    "$external_ip" >&2
  return 69
}

vm_check_public_ports() {
  local listeners line conflict=0
  listeners=$(ss -H -ltnp) || vm_die 69 'Unable to inspect TCP listeners'
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line =~ :80([[:space:]]|$) || $line =~ :443([[:space:]]|$) ]]; then
      printf 'ERROR: public HTTP port is already in use: %s\n' "$line" >&2
      conflict=1
    fi
  done <<<"$listeners"
  ((conflict == 0))
}
