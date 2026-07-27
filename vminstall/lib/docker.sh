#!/usr/bin/env bash

vm_docker_codename() {
  case "$OS_ID:$OS_VERSION" in
    ubuntu:22.04) printf 'jammy' ;;
    ubuntu:24.04) printf 'noble' ;;
    debian:12) printf 'bookworm' ;;
    *) return 1 ;;
  esac
}

vm_install_docker() {
  if docker compose version >/dev/null 2>&1; then
    vm_log 'Docker Compose plugin is already installed'
    return 0
  fi

  local dpkg_arch codename keyring_dir keyring source_dir source_file
  dpkg_arch=$(dpkg --print-architecture) ||
    vm_die 69 'Unable to determine dpkg architecture'
  [[ $dpkg_arch == amd64 ]] ||
    vm_die 65 "Docker packages require amd64, found $dpkg_arch"
  codename=$(vm_docker_codename) ||
    vm_die 65 "Unsupported Docker platform: $OS_ID $OS_VERSION"

  keyring_dir=${REMOTE_CHROME_TEST_ROOT:+$REMOTE_CHROME_TEST_ROOT}/etc/apt/keyrings
  keyring=$keyring_dir/docker.gpg
  source_dir=${REMOTE_CHROME_TEST_ROOT:+$REMOTE_CHROME_TEST_ROOT}/etc/apt/sources.list.d
  source_file=$source_dir/docker.list

  vm_run_mutation apt-get update
  vm_run_mutation apt-get install -y \
    ca-certificates curl gnupg openssl tar gzip coreutils python3
  vm_run_mutation install -m 0755 -d "$keyring_dir"

  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_require_confined_destination "$keyring_dir" || return 1
    vm_require_confined_destination "$source_dir" || return 1
    mkdir -p -- "$keyring_dir" "$source_dir"
    vm_run_mutation curl -fsSL --max-time 30 \
      "https://download.docker.com/linux/$OS_ID/gpg" \
      -o "$keyring.tmp.$$"
    vm_run_mutation gpg --dearmor --output "$keyring.new.$$" "$keyring.tmp.$$"
    vm_require_confined_destination "$keyring.new.$$" || return 1
    : >"$keyring.new.$$"
    vm_run_mutation install -m 0644 "$keyring.new.$$" "$keyring.pending.$$"
    vm_require_confined_destination "$keyring.pending.$$" || return 1
    : >"$keyring.pending.$$"
    vm_run_mutation mv -f "$keyring.pending.$$" "$keyring"
    vm_require_confined_destination "$keyring" || return 1
    cp -- "$keyring.pending.$$" "$keyring"
    vm_require_confined_destination "$keyring.tmp.$$" || return 1
    vm_require_confined_destination "$keyring.new.$$" || return 1
    vm_require_confined_destination "$keyring.pending.$$" || return 1
    rm -f -- "$keyring.tmp.$$" "$keyring.new.$$" "$keyring.pending.$$"
  else
    local temp_dir
    temp_dir=$(mktemp -d)
    curl -fsSL --max-time 30 \
      "https://download.docker.com/linux/$OS_ID/gpg" \
      -o "$temp_dir/docker.asc"
    gpg --dearmor --output "$temp_dir/docker.gpg" "$temp_dir/docker.asc"
    install -m 0644 "$temp_dir/docker.gpg" "$keyring.pending.$$"
    mv -f -- "$keyring.pending.$$" "$keyring"
    rm -rf -- "$temp_dir"
  fi

  local source_line
  source_line="deb [arch=amd64 signed-by=$keyring] https://download.docker.com/linux/$OS_ID $codename stable"
  if [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_require_confined_destination "$source_file.pending.$$" || return 1
    printf '%s\n' "$source_line" >"$source_file.pending.$$"
    vm_run_mutation install -m 0644 "$source_file.pending.$$" "$source_file.new.$$"
    vm_require_confined_destination "$source_file.new.$$" || return 1
    cp -- "$source_file.pending.$$" "$source_file.new.$$"
    vm_run_mutation mv -f "$source_file.new.$$" "$source_file"
    vm_require_confined_destination "$source_file" || return 1
    cp -- "$source_file.new.$$" "$source_file"
    vm_require_confined_destination "$source_file.new.$$" || return 1
    rm -f -- "$source_file.new.$$"
    vm_require_confined_destination "$source_file.pending.$$" || return 1
    rm -f -- "$source_file.pending.$$"
  else
    local source_temp
    source_temp=$(mktemp)
    printf '%s\n' "$source_line" >"$source_temp"
    install -m 0644 "$source_temp" "$source_file.pending.$$"
    mv -f -- "$source_file.pending.$$" "$source_file"
    rm -f -- "$source_temp"
  fi

  vm_run_mutation apt-get update
  vm_run_mutation apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin
  vm_run_mutation systemctl enable --now docker
  vm_run_mutation docker compose version
}
