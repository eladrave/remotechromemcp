#!/usr/bin/env bash

vm_management_usage() {
  printf '%s\n' \
    'Usage: remote-chrome COMMAND [OPTIONS]' \
    'Commands:' \
    '  status' \
    '  credentials' \
    '  login' \
    '  wait-ready' \
    '  update --version REF [--allow-unpinned]' \
    '  backup' \
    '  restore GCS_MANIFEST' \
    '  uninstall [--delete-profile] [--delete-backups]' \
    '            [--delete-all-data] [--force]'
}

vm_management_require_no_args() {
  (($# == 0)) || {
    vm_management_usage >&2
    return 2
  }
}

vm_management_load_installed_state() {
  local install_env="$REMOTE_CHROME_CONFIG_ROOT/install.env"
  local credentials="$REMOTE_CHROME_CONFIG_ROOT/credentials.env"
  [[ -f $install_env && ! -L $install_env &&
     -f $credentials && ! -L $credentials ]] || return 1

  DOMAIN=$(vm_read_env_value "$install_env" DOMAIN) || return 1
  ACME_EMAIL=$(vm_read_env_value "$install_env" ACME_EMAIL) || return 1
  REMOTE_CHROME_DATA_DIR=$(
    vm_read_env_value "$install_env" REMOTE_CHROME_DATA_DIR
  ) || return 1
  GCS_BUCKET=$(vm_read_env_value "$install_env" GCS_BUCKET) || return 1
  BACKUP_SCHEDULE=$(
    vm_read_env_value "$install_env" BACKUP_SCHEDULE
  ) || return 1
  MCP_URL=$(vm_read_env_value "$credentials" MCP_URL) || return 1
  MCP_TOKEN=$(vm_read_env_value "$credentials" MCP_TOKEN) || return 1
  MCP_COMPATIBILITY_URL=$(
    vm_read_env_value "$credentials" MCP_COMPATIBILITY_URL
  ) || return 1
  LOGIN_URL=$(vm_read_env_value "$credentials" LOGIN_URL) || return 1
  LOGIN_TOKEN=$(vm_read_env_value "$credentials" LOGIN_TOKEN) || return 1
  LOGIN_TOKEN_URL=$(
    vm_read_env_value "$credentials" LOGIN_TOKEN_URL
  ) || return 1
  LOGIN_USERNAME=$(
    vm_read_env_value "$credentials" LOGIN_USERNAME
  ) || return 1
  LOGIN_PASSWORD=$(
    vm_read_env_value "$credentials" LOGIN_PASSWORD
  ) || return 1

  vm_validate_domain "$DOMAIN" &&
    vm_validate_email "$ACME_EMAIL" &&
    vm_validate_config_value "$REMOTE_CHROME_DATA_DIR" &&
    { [[ -z $GCS_BUCKET ]] || vm_validate_gcs_bucket "$GCS_BUCKET"; } &&
    [[ $LOGIN_TOKEN =~ ^[0-9a-f]{64}$ &&
       $LOGIN_TOKEN != "$MCP_TOKEN" &&
       $LOGIN_TOKEN_URL == "https://$DOMAIN/login/?token=$LOGIN_TOKEN" &&
       $MCP_URL == "https://$DOMAIN/mcp" &&
       $LOGIN_URL == "https://$DOMAIN/login/" ]]
}

vm_management_release_path() {
  local current="$REMOTE_CHROME_INSTALL_ROOT/current"
  local target
  [[ -L $current ]] || return 1
  target=$(readlink "$current") || return 1
  [[ $target == releases/* && $target != *$'\n'* ]] || return 1
  printf '%s/%s' "$REMOTE_CHROME_INSTALL_ROOT" "$target"
}

vm_management_container_state() {
  local release=$1 output
  output=$(
    vm_compose_for_release "$release" \
      "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
      ps --format '{{.Service}} {{.Health}}' browser proxy
  ) || return 1
  grep -Fxq 'browser healthy' <<<"$output" || return 1
  grep -Fxq 'proxy healthy' <<<"$output" || return 1
}

vm_management_browser_state() {
  local release=$1 output container
  container=$(
    vm_compose_for_release "$release" \
      "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
      ps -q browser
  ) || return 1
  [[ $container =~ ^[0-9a-f]{64}$ ]] || return 1
  output=$(
    vm_run_bounded docker exec "$container" sh -c \
      'chrome_version=$(curl -fsS --max-time 5 http://127.0.0.1:9222/json/version); printf "%s\n" "$chrome_version"; grep -Fx "REMOTE_CHROME_PLAYBOOK_VERSION=1" /opt/remote-chrome/browser-playbook.md'
  ) || return 1
  VM_MANAGEMENT_CHROME_VERSION=$(
    grep -Eo 'Chrome/[0-9][^[:space:]"]*' <<<"$output" | head -n 1
  ) || return 1
  [[ -n $VM_MANAGEMENT_CHROME_VERSION &&
     $output != *HeadlessChrome* ]] || return 1
  grep -Fxq 'REMOTE_CHROME_PLAYBOOK_VERSION=1' <<<"$output"
}

vm_management_ready() {
  local release
  vm_management_load_installed_state || {
    printf 'ERROR: installed configuration is not ready\n' >&2
    return 1
  }
  release=$(vm_management_release_path) || {
    printf 'ERROR: active release is not ready\n' >&2
    return 1
  }
  vm_wait_stack_health "$release" || {
    printf 'ERROR: browser or proxy container health did not become ready\n' >&2
    return 1
  }
  vm_management_browser_state "$release" || {
    printf 'ERROR: Chrome or browser playbook verification failed\n' >&2
    return 1
  }
  vm_wait_public_stack
}

vm_management_prior_release() {
  local active=$1 state="$REMOTE_CHROME_CONFIG_ROOT/previous-version"
  local prior=
  if [[ ! -e $state && ! -L $state ]]; then
    printf 'none'
    return 0
  fi
  [[ -f $state && ! -L $state &&
     $(awk 'END { print NR }' "$state") == 1 ]] || return 1
  IFS= read -r prior <"$state" || return 1
  vm_validate_release_ref "$prior" || return 1
  [[ $prior != "$active" ]] || return 1
  printf '%s' "$prior"
}

vm_management_usage_text() {
  local path=$1
  vm_run_bounded du -sh -- "$path" 2>/dev/null | awk '{ print $1 }'
}

vm_management_status() {
  vm_management_require_no_args "$@" || return $?
  vm_management_load_installed_state ||
    vm_die 69 'Installed Remote Chrome state is unavailable'
  local active release prior service profile_usage data_usage manifest
  active=$(
    vm_read_env_value "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
      SELECTED_VERSION
  ) || return 1
  if [[ -f $REMOTE_CHROME_CONFIG_ROOT/active-version &&
        ! -L $REMOTE_CHROME_CONFIG_ROOT/active-version ]]; then
    IFS= read -r active <"$REMOTE_CHROME_CONFIG_ROOT/active-version" ||
      return 1
  fi
  vm_validate_release_ref "$active" || return 1
  release=$(vm_management_release_path) || return 1
  prior=$(vm_management_prior_release "$active") || return 1
  if vm_run_bounded systemctl is-active --quiet remote-chrome.service; then
    service=active
  else
    service=inactive
  fi
  [[ $service == active ]] || return 1
  vm_management_container_state "$release" || return 1
  vm_management_browser_state "$release" || return 1
  vm_verify_public_stack || return 1

  profile_usage=$(
    vm_management_usage_text "$REMOTE_CHROME_DATA_DIR/profile"
  ) || profile_usage=unavailable
  data_usage=$(
    vm_management_usage_text "$REMOTE_CHROME_DATA_DIR"
  ) || data_usage=unavailable
  manifest=$(
    vm_run_bounded find "$REMOTE_CHROME_DATA_DIR/backups" \
      -mindepth 1 -maxdepth 1 \
      -type f -name '*.manifest' -printf '%f\n' 2>/dev/null |
      LC_ALL=C sort | tail -n 1
  )
  [[ -n $manifest ]] || manifest=none

  printf '%s\n' \
    "Active release: $active" \
    "Prior release: $prior" \
    "Service: $service" \
    'Browser container: healthy' \
    'Proxy container: healthy' \
    "Chrome version: $VM_MANAGEMENT_CHROME_VERSION" \
    'Headed Chrome: yes' \
    'MCP initialize: ready' \
    'Playbook marker: present' \
    'Public MCP anonymous/authenticated: 401/405' \
    'MCP Content-Type headers: 1' \
    'Login HTTP: 200 with Basic auth' \
    'Login WebSocket: 101' \
    "TLS issuer: $CERTIFICATE_ISSUER" \
    "TLS expires: $CERTIFICATE_EXPIRES" \
    "Profile usage: $profile_usage" \
    "Data usage: $data_usage" \
    "Last backup manifest: $manifest"
}

vm_management_credentials() {
  vm_management_require_no_args "$@" || return $?
  vm_require_root
  local credentials="$REMOTE_CHROME_CONFIG_ROOT/credentials.env"
  [[ -f $credentials && ! -L $credentials ]] ||
    vm_die 69 'Installed credentials are unavailable'
  cat -- "$credentials"
}

vm_management_login() {
  vm_management_require_no_args "$@" || return $?
  vm_management_load_installed_state ||
    vm_die 69 'Installed login details are unavailable'
  printf 'Login URL: %s\nLogin username: %s\n' \
    "$LOGIN_URL" "$LOGIN_USERNAME"
}

vm_management_wait_ready() {
  vm_management_require_no_args "$@" || return $?
  vm_management_ready
}

vm_management_download_release() {
  local ref=$1 download_dir archive_name archive_url
  download_dir=$(mktemp -d) || return 1
  archive_name="remotechromemcp-$ref.tar.gz"
  if [[ $ref == master ]]; then
    archive_url=https://github.com/eladrave/remotechromemcp/archive/refs/heads/master.tar.gz
  else
    archive_url="https://github.com/eladrave/remotechromemcp/releases/download/$ref/$archive_name"
  fi
  if ! vm_run_with_timeout 310 curl -fsSL --connect-timeout 10 --max-time 300 \
    "$archive_url" -o "$download_dir/$archive_name"; then
    rm -rf -- "$download_dir"
    return 1
  fi
  if [[ $ref != master ]] &&
     ! vm_run_with_timeout 40 curl -fsSL --connect-timeout 10 --max-time 30 \
       "$archive_url.sha256" -o "$download_dir/$archive_name.sha256"; then
    rm -rf -- "$download_dir"
    return 1
  fi
  printf '%s/%s' "$download_dir" "$archive_name"
}

vm_management_update_locked() {
  vm_require_root
  local ref= allow_unpinned=0 archive= download_dir=
  while (($#)); do
    case "$1" in
      --version)
        (($# >= 2)) || {
          vm_management_usage >&2
          return 2
        }
        [[ -z $ref ]] || {
          vm_management_usage >&2
          return 2
        }
        ref=$2
        shift 2
        ;;
      --allow-unpinned)
        allow_unpinned=1
        shift
        ;;
      *)
        vm_management_usage >&2
        return 2
        ;;
    esac
  done
  [[ -n $ref ]] || {
    vm_management_usage >&2
    return 2
  }
  vm_validate_release_ref "$ref" || {
    vm_management_usage >&2
    return 2
  }
  [[ $ref != master || $allow_unpinned -eq 1 ]] || {
    printf 'ERROR: master requires --allow-unpinned\n' >&2
    return 2
  }

  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  SELECTED_VERSION=$ref
  ROTATE_CREDENTIALS=0
  if [[ -n ${REMOTE_CHROME_RELEASE_ARCHIVE:-} ]]; then
    archive=$REMOTE_CHROME_RELEASE_ARCHIVE
  else
    archive=$(vm_management_download_release "$ref") || return 1
    download_dir=${archive%/*}
  fi
  if ! vm_stage_release "$archive"; then
    [[ -z $download_dir ]] || rm -rf -- "$download_dir"
    return 1
  fi
  local status=0
  vm_activate_release || status=$?
  if ((status != 0)); then
    [[ -z $download_dir ]] || rm -rf -- "$download_dir"
    return "$status"
  fi
  [[ -z $download_dir ]] || rm -rf -- "$download_dir"
}

vm_management_validate_data_root() {
  local data_root=$1 canonical
  [[ $data_root == /* && $data_root != / && ! -L $data_root ]] ||
    return 1
  canonical=$(realpath -sm -- "$data_root") || return 1
  [[ $data_root == "$canonical" ]] || return 1
  case "$data_root" in
    /etc|/usr|/var|/var/lib|/opt|/home|/root) return 1 ;;
  esac
  local protected
  for protected in \
    "$REMOTE_CHROME_TRUSTED_INSTALL_ROOT" \
    "$REMOTE_CHROME_TRUSTED_CONFIG_ROOT" \
    "$REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT" \
    "$REMOTE_CHROME_TRUSTED_CLI_ROOT"; do
    case "$protected" in
      "$data_root"|"$data_root"/*) return 1 ;;
    esac
  done
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} &&
        $data_root == "$REMOTE_CHROME_CANONICAL_TEST_ROOT" ]]; then
    return 1
  fi
  vm_require_management_destination "$data_root"
}

vm_management_validate_delete_target() {
  local target=$1 expected=$2
  [[ $target == "$expected" && $target == /* && $target != / &&
     ! -L $target ]] || return 1
  [[ $(realpath -sm -- "$target") == "$expected" ]] || return 1
  vm_require_management_destination "$target"
}

vm_management_confirmation_tty() {
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    printf '%s' "$REMOTE_CHROME_TTY"
  else
    printf '/dev/tty'
  fi
}

vm_management_uninstall_locked() {
  vm_require_root
  local delete_profile=0 delete_backups=0 delete_all=0 force=0
  while (($#)); do
    case "$1" in
      --delete-profile) delete_profile=1 ;;
      --delete-backups) delete_backups=1 ;;
      --delete-all-data) delete_all=1 ;;
      --force) force=1 ;;
      *)
        vm_management_usage >&2
        return 2
        ;;
    esac
    shift
  done
  ((delete_all == 0 || (delete_profile == 0 && delete_backups == 0))) || {
    vm_management_usage >&2
    return 2
  }
  ((force == 0 || delete_all == 1)) || {
    vm_management_usage >&2
    return 2
  }

  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  [[ $REMOTE_CHROME_INSTALL_ROOT == "$REMOTE_CHROME_TRUSTED_INSTALL_ROOT" &&
     $REMOTE_CHROME_CONFIG_ROOT == "$REMOTE_CHROME_TRUSTED_CONFIG_ROOT" &&
     $REMOTE_CHROME_SYSTEMD_ROOT == "$REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT" &&
     $REMOTE_CHROME_CLI_ROOT == "$REMOTE_CHROME_TRUSTED_CLI_ROOT" ]] ||
    vm_die 64 'Installed management roots are untrusted'
  local data_root=$REMOTE_CHROME_DATA_DIR
  local profile="$data_root/profile" backups="$data_root/backups"
  local unit="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service"
  local backup_unit="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service"
  local backup_timer="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"
  local cli="$REMOTE_CHROME_CLI_ROOT/remote-chrome"
  vm_management_validate_data_root "$data_root" ||
    vm_die 64 'Configured data root is unsafe'
  vm_management_validate_delete_target \
    "$REMOTE_CHROME_INSTALL_ROOT" "$REMOTE_CHROME_TRUSTED_INSTALL_ROOT" ||
    vm_die 64 'Install root is unsafe'
  vm_management_validate_delete_target \
    "$unit" "$REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT/remote-chrome.service" ||
    vm_die 64 'Service unit path is unsafe'
  vm_management_validate_delete_target \
    "$backup_unit" \
    "$REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT/remote-chrome-backup.service" ||
    vm_die 64 'Backup service unit path is unsafe'
  vm_management_validate_delete_target \
    "$backup_timer" \
    "$REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT/remote-chrome-backup.timer" ||
    vm_die 64 'Backup timer unit path is unsafe'
  vm_management_validate_delete_target \
    "$cli" "$REMOTE_CHROME_TRUSTED_CLI_ROOT/remote-chrome" ||
    vm_die 64 'Management CLI path is unsafe'
  if ((delete_profile == 1)); then
    vm_management_validate_delete_target "$profile" "$data_root/profile" ||
      vm_die 64 'Managed profile path is unsafe'
  fi
  if ((delete_backups == 1)); then
    vm_management_validate_delete_target "$backups" "$data_root/backups" ||
      vm_die 64 'Managed backups path is unsafe'
  fi
  if ((delete_all == 1)); then
    vm_management_validate_delete_target "$data_root" "$data_root" ||
      vm_die 64 'Managed data path is unsafe'
    vm_management_validate_delete_target \
      "$REMOTE_CHROME_CONFIG_ROOT" "$REMOTE_CHROME_TRUSTED_CONFIG_ROOT" ||
      vm_die 64 'Managed configuration path is unsafe'
    if ((force == 0)); then
      local tty confirmation=
      tty=$(vm_management_confirmation_tty) || return 1
      if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
        vm_require_management_destination "$tty" ||
          vm_die 64 'Confirmation TTY is unsafe'
      else
        [[ $tty == /dev/tty && -c $tty ]] ||
          vm_die 64 'Confirmation requires the real /dev/tty'
      fi
      if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
        printf 'Type %s to delete all Remote Chrome data: ' "$DOMAIN" \
          >>"$tty" || return 1
        IFS= read -r confirmation <"$tty" || return 1
      else
        local tty_fd
        exec {tty_fd}<>"$tty" || return 1
        [[ -t $tty_fd ]] || {
          exec {tty_fd}>&-
          vm_die 64 'Confirmation requires an interactive /dev/tty'
        }
        printf 'Type %s to delete all Remote Chrome data: ' "$DOMAIN" \
          >&"$tty_fd" || return 1
        IFS= read -r confirmation <&"$tty_fd" || return 1
        exec {tty_fd}>&-
      fi
      [[ $confirmation == "$DOMAIN" ]] ||
        vm_die 64 'Domain confirmation did not match'
    fi
  fi

  vm_run_bounded systemctl stop remote-chrome.service
  vm_run_bounded systemctl disable remote-chrome.service
  vm_run_bounded systemctl disable --now remote-chrome-backup.timer ||
    true
  rm -f -- "$unit" "$backup_unit" "$backup_timer"
  vm_run_bounded systemctl daemon-reload
  rm -f -- "$cli"
  rm -rf -- "$REMOTE_CHROME_INSTALL_ROOT"
  ((delete_profile == 0)) || rm -rf -- "$profile"
  ((delete_backups == 0)) || rm -rf -- "$backups"
  if ((delete_all == 1)); then
    rm -rf -- "$data_root"
    rm -rf -- "$REMOTE_CHROME_CONFIG_ROOT"
  fi
}

vm_management_backup() {
  vm_management_require_no_args "$@" || return $?
  vm_require_root
  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  vm_backup_profile "gs://$GCS_BUCKET/remote-chrome"
}

vm_management_restore() {
  (($# == 1)) || {
    vm_management_usage >&2
    return 2
  }
  vm_require_root
  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  [[ $1 == "gs://$GCS_BUCKET/"*.manifest ]] || {
    printf 'ERROR: restore requires an exact manifest URI in the configured bucket\n' >&2
    return 2
  }
  vm_restore_profile "$1"
}

vm_management_update() {
  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  vm_with_maintenance_lock vm_management_update_locked "$@"
}

vm_management_uninstall() {
  vm_management_load_installed_state ||
    vm_die 69 'Installed configuration is unavailable'
  vm_with_maintenance_lock vm_management_uninstall_locked "$@"
}

vm_management_dispatch() {
  local command=${1:-}
  if (($#)); then
    shift
  fi
  case "$command" in
    status) vm_management_status "$@" ;;
    credentials) vm_management_credentials "$@" ;;
    login) vm_management_login "$@" ;;
    wait-ready) vm_management_wait_ready "$@" ;;
    update) vm_management_update "$@" ;;
    backup) vm_management_backup "$@" ;;
    restore) vm_management_restore "$@" ;;
    uninstall) vm_management_uninstall "$@" ;;
    *)
      vm_management_usage >&2
      return 2
      ;;
  esac
}
