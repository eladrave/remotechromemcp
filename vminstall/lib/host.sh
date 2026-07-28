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

vm_ensure_profile_exchange_runtime() {
  local python
  vm_require_root
  if python=$(vm_trusted_python3); then
    return 0
  fi
  vm_run_mutation apt-get update
  vm_run_mutation apt-get install -y python3
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    python="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/bin/python3"
    vm_require_confined_destination "$python" || return 1
    mkdir -p -- "${python%/*}" || return 1
    printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/python3 "$@"' \
      >"$python" || return 1
    chmod 0755 "$python" || return 1
  fi
  vm_trusted_python3 >/dev/null ||
    vm_die 69 'Python 3 runtime for atomic profile exchange is unavailable'
}

vm_check_host() {
  local required
  vm_require_root
  for required in \
    getent curl ss tar sha256sum timeout readlink apt-get; do
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

vm_validate_ipv4() {
  local candidate=${1:-} octet
  local -a octets
  [[ $candidate != *$'\n'* && $candidate != *$'\r'* &&
     $candidate != *[!0-9.]* ]] || return 1
  IFS=. read -r -a octets <<<"$candidate"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

vm_discover_public_address() {
  local external_ip
  external_ip=$(
    curl -fsS --max-time 5 \
      -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip'
  ) || external_ip=$(
    curl -fsS --max-time 5 'https://api.ipify.org'
  ) || vm_die 69 'Unable to discover this host public IP'
  [[ -n $external_ip &&
     $external_ip != *$'\n'* &&
     $external_ip != *$'\r'* ]] ||
    vm_die 69 'Public IP discovery returned an invalid response'
  printf '%s' "$external_ip"
}

vm_discover_public_ipv4() {
  local external_ip
  external_ip=$(
    curl -fsS --max-time 5 \
      -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip'
  ) || external_ip=
  if ! vm_validate_ipv4 "$external_ip"; then
    external_ip=$(
      curl -fsS --max-time 5 'https://api.ipify.org'
    ) || vm_die 69 'Unable to discover this host public IPv4 address'
  fi
  vm_validate_ipv4 "$external_ip" ||
    vm_die 69 'Public IPv4 discovery returned an invalid address'
  printf '%s' "$external_ip"
}

vm_generate_sslip_domain() {
  local external_ipv4 status
  external_ipv4=$(vm_discover_public_ipv4) || {
    status=$?
    return "$status"
  }
  printf '%s.sslip.io' "${external_ipv4//./-}"
}

vm_verify_dns() {
  [[ ${SKIP_DNS_CHECK:-0} == 1 ]] && return 0

  local resolved_output external_ip address normalized_address
  local normalized_external
  resolved_output=$(timeout 5 getent ahosts "$DOMAIN") ||
    vm_die 69 "Unable to resolve DNS for $DOMAIN"

  external_ip=$(vm_discover_public_address) || return 1

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

vm_atomic_install_file() {
  local source=$1 destination=$2 mode=$3 pending
  pending="${destination}.pending.$$"
  vm_require_confined_destination "$pending" || return 1
  vm_require_confined_destination "$destination" || return 1
  if ! vm_run_mutation install -m "$mode" "$source" "$pending"; then
    rm -f -- "$pending"
    return 1
  fi
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    cp -- "$source" "$pending" || return 1
  fi
  if ! vm_run_mutation mv -f -- "$pending" "$destination"; then
    rm -f -- "$pending"
    return 1
  fi
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    cp -- "$pending" "$destination" || return 1
    rm -f -- "$pending"
  fi
}

vm_print_gcloud_guidance() {
  cat >&2 <<'EOF'
Install the official Google Cloud CLI, then rerun the installer:
  key_tmp=$(mktemp)
  repo_tmp=$(mktemp)
  trap 'rm -f "$key_tmp" "$key_tmp.gpg" "$repo_tmp"' EXIT
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg -o "$key_tmp"
  gpg --batch --yes --dearmor -o "$key_tmp.gpg" "$key_tmp"
  sudo install -m 0644 "$key_tmp.gpg" /usr/share/keyrings/cloud.google.gpg
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' >"$repo_tmp"
  sudo install -m 0644 "$repo_tmp" /etc/apt/sources.list.d/google-cloud-sdk.list
  sudo apt-get update
  sudo apt-get install -y google-cloud-cli
The VM uses its attached service-account metadata credentials; do not run gcloud init.
EOF
}

vm_restore_gcloud_apt_state() {
  local stage=$1 keyring=$2 source_file=$3
  local key_present=$4 source_present=$5 key_mode=$6 source_mode=$7
  local status=0
  if [[ $key_present -eq 1 ]]; then
    vm_atomic_install_file "$stage/prior-keyring" "$keyring" "$key_mode" ||
      status=1
  else
    rm -f -- "$keyring" || status=1
  fi
  if [[ $source_present -eq 1 ]]; then
    vm_atomic_install_file \
      "$stage/prior-source" "$source_file" "$source_mode" || status=1
  else
    rm -f -- "$source_file" || status=1
  fi
  return "$status"
}

vm_abort_gcloud_provisioning() {
  local stage=$1 keyring=$2 source_file=$3
  local key_present=$4 source_present=$5 key_mode=$6 source_mode=$7
  if vm_restore_gcloud_apt_state \
    "$stage" "$keyring" "$source_file" \
    "$key_present" "$source_present" "$key_mode" "$source_mode"; then
    rm -rf -- "$stage"
    return 1
  fi
  printf '%s\n' \
    'ERROR: Google Cloud CLI apt rollback could not be confirmed; recovery retained:' \
    "  keyring: $keyring" \
    "  repository: $source_file" \
    "  staging: $stage" >&2
  return 70
}

vm_ensure_gcloud() {
  [[ -n ${GCS_BUCKET:-} ]] || return 0
  vm_require_root

  local command keyring_dir keyring source_dir source_file binary_dir
  local stage_dir source_line key_present=0 source_present=0
  local key_mode=0644 source_mode=0644
  command=$(vm_gcloud_path)
  if [[ -e $command || -L $command ]]; then
    vm_trusted_gcloud >/dev/null
    return
  fi

  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    keyring_dir="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/share/keyrings"
    source_dir="$REMOTE_CHROME_CANONICAL_TEST_ROOT/etc/apt/sources.list.d"
    binary_dir="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/bin"
  else
    keyring_dir=/usr/share/keyrings
    source_dir=/etc/apt/sources.list.d
    binary_dir=/usr/bin
  fi
  keyring="$keyring_dir/cloud.google.gpg"
  source_file="$source_dir/google-cloud-sdk.list"
  for destination in "$keyring_dir" "$source_dir" "$binary_dir"; do
    vm_require_confined_destination "$destination" || return 1
    [[ ! -L $destination ]] || return 1
    install -d -m 0755 "$destination" || return 1
    vm_require_confined_destination "$destination" || return 1
  done
  for destination in "$keyring" "$source_file"; do
    [[ ! -L $destination ]] || return 1
    vm_require_confined_destination "$destination" || return 1
  done

  stage_dir=$(mktemp -d) || return 1
  if [[ -e $keyring ]]; then
    [[ -f $keyring && ! -L $keyring ]] || {
      rm -rf -- "$stage_dir"
      return 1
    }
    key_present=1
    key_mode=$(stat -c '%a' -- "$keyring") || {
      rm -rf -- "$stage_dir"
      return 1
    }
    cp -p -- "$keyring" "$stage_dir/prior-keyring" || {
      rm -rf -- "$stage_dir"
      return 1
    }
  fi
  if [[ -e $source_file ]]; then
    [[ -f $source_file && ! -L $source_file ]] || {
      rm -rf -- "$stage_dir"
      return 1
    }
    source_present=1
    source_mode=$(stat -c '%a' -- "$source_file") || {
      rm -rf -- "$stage_dir"
      return 1
    }
    cp -p -- "$source_file" "$stage_dir/prior-source" || {
      rm -rf -- "$stage_dir"
      return 1
    }
  fi
  vm_run_mutation apt-get update || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  vm_run_mutation apt-get install -y ca-certificates curl gnupg || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  vm_run_mutation curl -fsSL --max-time 30 \
    https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    -o "$stage_dir/apt-key.gpg" || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    : >"$stage_dir/apt-key.gpg"
  fi
  vm_run_mutation gpg --dearmor --output "$stage_dir/cloud.google.gpg" \
    "$stage_dir/apt-key.gpg" || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    : >"$stage_dir/cloud.google.gpg"
  fi
  vm_atomic_install_file "$stage_dir/cloud.google.gpg" "$keyring" 0644 || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }

  source_line="deb [signed-by=$keyring] https://packages.cloud.google.com/apt cloud-sdk main"
  printf '%s\n' "$source_line" >"$stage_dir/google-cloud-sdk.list"
  vm_atomic_install_file \
    "$stage_dir/google-cloud-sdk.list" "$source_file" 0644 || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }

  vm_run_mutation apt-get update || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  vm_run_mutation apt-get install -y google-cloud-cli || {
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  }
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_require_confined_destination "$command" || return 1
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$command" || return 1
    chmod 0755 "$command" || return 1
  fi
  if ! vm_trusted_gcloud >/dev/null; then
    vm_abort_gcloud_provisioning "$stage_dir" "$keyring" "$source_file" \
      "$key_present" "$source_present" "$key_mode" "$source_mode"
    return $?
  fi
  rm -rf -- "$stage_dir"
}
