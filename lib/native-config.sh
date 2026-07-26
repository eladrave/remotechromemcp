#!/usr/bin/env bash

native_config_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
native_config_root=$(cd "$native_config_lib_dir/.." && pwd)
# shellcheck source=lib/render-template.sh
source "$native_config_lib_dir/render-template.sh"

native_config_error() {
  echo "native configuration error: $*" >&2
  return 1
}

native_config_require_safe_path() {
  local name=$1
  local value=${!name-}
  if [[ ! "$value" =~ ^/[A-Za-z0-9_./+-]+$ ]]; then
    native_config_error "$name must be an absolute path without whitespace"
    return 1
  fi
}

native_config_require_port() {
  local name=$1
  local value=${!name-}
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    native_config_error "$name must be an integer from 1 through 65535"
    return 1
  fi
  if ((${#value} > 5 || 10#$value < 1 || 10#$value > 65535)); then
    native_config_error "$name must be an integer from 1 through 65535"
    return 1
  fi
}

render_native_config() {
  if (($# != 1)); then
    native_config_error "usage: render_native_config OUTPUT_DIR"
    return 2
  fi

  local output_dir=$1
  if [[ "$output_dir" != /* || "$output_dir" == "/" || "$output_dir" == *$'\n'* || -L "$output_dir" ]]; then
    native_config_error "unsafe output directory: $output_dir"
    return 1
  fi
  if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
    native_config_error "output path is not a directory: $output_dir"
    return 1
  fi

  if [[ ! "${DOMAIN-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    native_config_error "DOMAIN is invalid"
    return 1
  fi
  if [[ ! "${MCP_TOKEN-}" =~ ^[0-9a-f]{64}$ ]]; then
    native_config_error "MCP_TOKEN must be exactly 64 lowercase hexadecimal characters"
    return 1
  fi

  local path_name
  for path_name in LOGIN_HTPASSWD_FILE PROJECT_DIR PROFILE_DIR CHROME_BIN PLAYWRIGHT_MCP_BIN; do
    native_config_require_safe_path "$path_name" || return 1
  done

  if [[ ! "${DISPLAY_NUMBER-}" =~ ^[0-9]+$ ]]; then
    native_config_error "DISPLAY_NUMBER must be a non-negative integer"
    return 1
  fi
  if [[ ! "${SCREEN_GEOMETRY-}" =~ ^[0-9]+x[0-9]+x[0-9]+$ ]]; then
    native_config_error "SCREEN_GEOMETRY must use WIDTHxHEIGHTxDEPTH format"
    return 1
  fi

  local port_name
  for port_name in MCP_INTERNAL_PORT CDP_PORT VNC_PORT NOVNC_PORT; do
    native_config_require_port "$port_name" || return 1
  done

  install -d -m 700 -- "$output_dir" || return 1
  if [[ -L "$output_dir/nginx" || -L "$output_dir/systemd" ]]; then
    native_config_error "output subdirectories must not be symbolic links"
    return 1
  fi
  install -d -m 700 -- "$output_dir/nginx" "$output_dir/systemd" || return 1

  render_template \
    "$native_config_root/native/nginx/playwright-mcp.conf.in" \
    "$output_dir/nginx/playwright-mcp.conf" \
    DOMAIN "$DOMAIN" \
    MCP_TOKEN "$MCP_TOKEN" \
    LOGIN_HTPASSWD_FILE "$LOGIN_HTPASSWD_FILE" \
    MCP_INTERNAL_PORT "$MCP_INTERNAL_PORT" \
    NOVNC_PORT "$NOVNC_PORT" || return 1

  render_template \
    "$native_config_root/native/systemd/chrome-display.service.in" \
    "$output_dir/systemd/chrome-display.service" \
    DISPLAY_NUMBER "$DISPLAY_NUMBER" \
    SCREEN_GEOMETRY "$SCREEN_GEOMETRY" || return 1

  render_template \
    "$native_config_root/native/systemd/chrome-window-manager.service.in" \
    "$output_dir/systemd/chrome-window-manager.service" \
    DISPLAY_NUMBER "$DISPLAY_NUMBER" || return 1

  render_template \
    "$native_config_root/native/systemd/chrome-mcp.service.in" \
    "$output_dir/systemd/chrome-mcp.service" \
    CHROME_BIN "$CHROME_BIN" \
    DISPLAY_NUMBER "$DISPLAY_NUMBER" \
    CDP_PORT "$CDP_PORT" \
    PROFILE_DIR "$PROFILE_DIR" || return 1

  render_template \
    "$native_config_root/native/systemd/chrome-vnc.service.in" \
    "$output_dir/systemd/chrome-vnc.service" \
    DISPLAY_NUMBER "$DISPLAY_NUMBER" \
    VNC_PORT "$VNC_PORT" || return 1

  render_template \
    "$native_config_root/native/systemd/chrome-novnc.service.in" \
    "$output_dir/systemd/chrome-novnc.service" \
    NOVNC_PORT "$NOVNC_PORT" \
    VNC_PORT "$VNC_PORT" || return 1

  render_template \
    "$native_config_root/native/systemd/playwright-mcp.service.in" \
    "$output_dir/systemd/playwright-mcp.service" \
    PLAYWRIGHT_MCP_BIN "$PLAYWRIGHT_MCP_BIN" \
    PROJECT_DIR "$PROJECT_DIR" \
    CDP_PORT "$CDP_PORT" \
    MCP_INTERNAL_PORT "$MCP_INTERNAL_PORT" || return 1
}

REMOTE_CHROME_APT_PACKAGES=(
  xvfb
  openbox
  x11vnc
  novnc
  websockify
  apache2-utils
)
REMOTE_CHROME_UNITS=(
  chrome-display.service
  chrome-window-manager.service
  chrome-mcp.service
  chrome-vnc.service
  chrome-novnc.service
  playwright-mcp.service
)

native_info() {
  printf '▶ %s\n' "$*"
}

native_success() {
  printf '✓ %s\n' "$*"
}

native_warn() {
  printf '⚠ %s\n' "$*" >&2
}

native_path_has_traversal() {
  [[ "$1" =~ (^|/)\.\.(/|$) ]]
}

native_path_is_within() {
  local child=$1
  local parent=$2
  if [[ "$parent" == "/" ]]; then
    [[ "$child" == /* ]]
  else
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
  fi
}

native_canonical_contained_path() {
  local name=$1
  local value=$2
  local parent=$3
  local allow_parent=${4:-0}
  if [[ "$value" != /* || "$value" == *$'\n'* ]] || native_path_has_traversal "$value"; then
    native_config_error "$name must be an absolute path without traversal"
    return 1
  fi
  local resolved
  resolved=$(realpath -m -- "$value") || return 1
  if ! native_path_is_within "$resolved" "$parent" ||
    [[ "$allow_parent" != 1 && "$resolved" == "$parent" ]]; then
    native_config_error "$name escapes its allowed root"
    return 1
  fi
  printf '%s\n' "$resolved"
}

native_make_temp_file() {
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    local temp_dir="$REMOTE_CHROME_ROOT/tmp"
    install -d -m 700 -- "$temp_dir"
    mktemp "$temp_dir/file.XXXXXX"
  else
    mktemp
  fi
}

native_command_log() {
  [[ -n "${REMOTE_CHROME_COMMAND_LOG-}" ]] || return 0
  printf '%s\n' "$*" >> "$REMOTE_CHROME_COMMAND_LOG"
}

native_root_path() {
  local path=$1
  if [[ "$REMOTE_CHROME_ROOT" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${REMOTE_CHROME_ROOT%/}" "$path"
  fi
}

native_privileged() {
  if [[ "$REMOTE_CHROME_ROOT" == "/" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

native_install_file() {
  local mode=$1
  local source=$2
  local destination=$3
  native_privileged install -D -m "$mode" -- "$source" "$destination"
}

native_write_user_secret() {
  local destination=$1
  local content=$2
  local temporary
  temporary=$(native_make_temp_file)
  chmod 600 "$temporary"
  printf '%s\n' "$content" > "$temporary"
  install -D -m 600 -- "$temporary" "$destination"
  rm -f -- "$temporary"
}

native_write_root_secret() {
  local destination=$1
  local content=$2
  local temporary
  temporary=$(native_make_temp_file)
  chmod 600 "$temporary"
  printf '%s\n' "$content" > "$temporary"
  native_install_file 600 "$temporary" "$destination"
  rm -f -- "$temporary"
}

native_setup_usage() {
  cat <<'EOF'
Usage: ./setup.sh [OPTIONS]

Options:
  --non-interactive       Do not prompt; missing domain or email exits 2
  --domain DOMAIN         Public HTTPS hostname
  --email EMAIL           Let's Encrypt notification email
  --skip-profile-backup   Explicitly skip the first headed profile backup
  -h, --help              Show this help

DOMAIN and CERTBOT_EMAIL environment variables take precedence over options.
EOF
}

native_initialize_paths() {
  local root_was_set=0
  [[ -n "${REMOTE_CHROME_ROOT+x}" ]] && root_was_set=1
  local requested_root=${REMOTE_CHROME_ROOT:-/}
  if [[ "$requested_root" != /* || "$requested_root" == *$'\n'* ]] ||
    native_path_has_traversal "$requested_root" ||
    [[ -L "$requested_root" || ! -d "$requested_root" ]]; then
    native_config_error "REMOTE_CHROME_ROOT must be an existing absolute, non-symlink directory without traversal"
    return 1
  fi
  REMOTE_CHROME_ROOT=$(realpath -e -- "$requested_root") || return 1

  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    if [[ "$root_was_set" != 1 || "$REMOTE_CHROME_ROOT" == "/" ]]; then
      native_config_error "dry-run mode requires an explicit sandbox root"
      return 1
    fi
    local temp_root
    temp_root=$(realpath -e -- "${TMPDIR:-/tmp}") || return 1
    if [[ "$REMOTE_CHROME_ROOT" == "$temp_root" ]] ||
      ! native_path_is_within "$REMOTE_CHROME_ROOT" "$temp_root" ||
      [[ "$(stat -c '%u' "$REMOTE_CHROME_ROOT")" != "$(id -u)" ]]; then
      native_config_error "dry-run sandbox root must be a user-owned child of $temp_root"
      return 1
    fi
  elif [[ "$REMOTE_CHROME_ROOT" != "/" ]]; then
    native_config_error "a non-root REMOTE_CHROME_ROOT is only allowed in dry-run mode"
    return 1
  fi

  local requested_home
  if [[ "$REMOTE_CHROME_ROOT" == "/" ]]; then
    requested_home="${REMOTE_CHROME_HOME:-$HOME}"
  else
    requested_home="${REMOTE_CHROME_HOME:-${REMOTE_CHROME_ROOT%/}/home}"
  fi
  if [[ "$REMOTE_CHROME_ROOT" == "/" ]]; then
    if [[ "$requested_home" != /* || "$requested_home" == "/" ]] ||
      native_path_has_traversal "$requested_home"; then
      native_config_error "REMOTE_CHROME_HOME must be a safe absolute path"
      return 1
    fi
    REMOTE_CHROME_HOME=$(realpath -m -- "$requested_home") || return 1
  else
    REMOTE_CHROME_HOME=$(native_canonical_contained_path \
      REMOTE_CHROME_HOME "$requested_home" "$REMOTE_CHROME_ROOT") || return 1
  fi

  EXPECTED_CHROME_MCP_PROFILE=$(realpath -m -- \
    "$REMOTE_CHROME_HOME/.config/chrome-mcp-profile")
  CHROME_MCP_PROFILE=$(native_canonical_contained_path CHROME_MCP_PROFILE \
    "${CHROME_MCP_PROFILE:-$EXPECTED_CHROME_MCP_PROFILE}" "$REMOTE_CHROME_HOME") || return 1
  TOKEN_FILE=$(native_canonical_contained_path TOKEN_FILE \
    "${TOKEN_FILE:-$REMOTE_CHROME_HOME/.config/mcp-bearer-token.env}" \
    "$REMOTE_CHROME_HOME") || return 1
  LOGIN_ENV_FILE=$(native_canonical_contained_path LOGIN_ENV_FILE \
    "${LOGIN_ENV_FILE:-$REMOTE_CHROME_HOME/.config/remote-chrome-login.env}" \
    "$REMOTE_CHROME_HOME") || return 1
  SYSTEMD_USER_DIR=$(native_canonical_contained_path SYSTEMD_USER_DIR \
    "${SYSTEMD_USER_DIR:-$REMOTE_CHROME_HOME/.config/systemd/user}" \
    "$REMOTE_CHROME_HOME") || return 1
  MIGRATION_MARKER=$(native_canonical_contained_path MIGRATION_MARKER \
    "${MIGRATION_MARKER:-$REMOTE_CHROME_HOME/.config/remote-chrome-headed-migration}" \
    "$REMOTE_CHROME_HOME") || return 1
  PROFILE_BACKUP_MARKER=$(native_canonical_contained_path PROFILE_BACKUP_MARKER \
    "${PROFILE_BACKUP_MARKER:-$REMOTE_CHROME_HOME/.config/remote-chrome-profile-backup-complete}" \
    "$REMOTE_CHROME_HOME") || return 1
  BACKUP_DIR=$(native_canonical_contained_path BACKUP_DIR \
    "${BACKUP_DIR:-$REMOTE_CHROME_HOME/.config/remote-chrome-backups}" \
    "$REMOTE_CHROME_HOME") || return 1
  if [[ -n "${REMOTE_CHROME_COMMAND_LOG-}" ]]; then
    if [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
      native_config_error "REMOTE_CHROME_COMMAND_LOG is only allowed in dry-run mode"
      return 1
    fi
    REMOTE_CHROME_COMMAND_LOG=$(native_canonical_contained_path \
      REMOTE_CHROME_COMMAND_LOG "$REMOTE_CHROME_COMMAND_LOG" \
      "$REMOTE_CHROME_ROOT") || return 1
  fi
  NGINX_SITE=$(native_root_path /etc/nginx/sites-available/playwright-mcp)
  NGINX_ENABLED=$(native_root_path /etc/nginx/sites-enabled/playwright-mcp)
  LOGIN_HTPASSWD_REAL=$(native_root_path /etc/nginx/.remote-chrome-login.htpasswd)
  LOGIN_HTPASSWD_FILE=/etc/nginx/.remote-chrome-login.htpasswd
}

native_require_value() {
  local name=$1
  local value=$2
  local non_interactive=$3
  local prompt=$4
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  if [[ "$non_interactive" == 1 ]]; then
    printf 'ERROR: %s is required in non-interactive mode\n' "$name" >&2
    return 2
  fi
  read -r -p "$prompt" value
  if [[ -z "$value" ]]; then
    printf 'ERROR: %s is required\n' "$name" >&2
    return 2
  fi
  printf '%s\n' "$value"
}

native_validate_setup_values() {
  if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    native_config_error "DOMAIN is invalid"
    return 2
  fi
  if [[ ! "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    native_config_error "CERTBOT_EMAIL is invalid"
    return 2
  fi
}

native_prepare_profile() {
  install -d -m 700 -- "$(dirname "$CHROME_MCP_PROFILE")"
  if [[ -d "$CHROME_MCP_PROFILE" ]]; then
    native_success "Preserving Chrome MCP profile at $CHROME_MCP_PROFILE"
    return
  fi

  local default_profile="$REMOTE_CHROME_HOME/.config/google-chrome"
  if [[ -d "$default_profile" ]]; then
    native_info "Copying the existing Chrome profile to $CHROME_MCP_PROFILE"
    cp -a -- "$default_profile" "$CHROME_MCP_PROFILE"
  else
    install -d -m 700 -- "$CHROME_MCP_PROFILE"
  fi
}

native_load_or_create_bearer_token() {
  install -d -m 700 -- "$(dirname "$TOKEN_FILE")"
  if [[ -f "$TOKEN_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TOKEN_FILE"
    if [[ ! "${BEARER_TOKEN-}" =~ ^[0-9a-f]{64}$ ]]; then
      native_config_error "existing bearer token is invalid; refusing to rotate it"
      return 1
    fi
    chmod 600 "$TOKEN_FILE"
    native_success "Preserving existing bearer token at $TOKEN_FILE"
  else
    BEARER_TOKEN=$(openssl rand -hex 32)
    native_write_user_secret "$TOKEN_FILE" "BEARER_TOKEN=$BEARER_TOKEN"
    native_success "Created bearer token at $TOKEN_FILE"
  fi
  MCP_TOKEN=$BEARER_TOKEN
}

native_load_or_create_login_credentials() {
  install -d -m 700 -- "$(dirname "$LOGIN_ENV_FILE")"
  if [[ -f "$LOGIN_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LOGIN_ENV_FILE"
    local login_password_value=${LOGIN_PASSWORD-}
    if [[ -z "${LOGIN_USERNAME-}" || ${#login_password_value} -lt 32 || -z "${LOGIN_URL-}" ]]; then
      native_config_error "existing login credential file is incomplete; refusing to rotate it"
      return 1
    fi
    LOGIN_URL="https://${DOMAIN}/login/"
    native_write_user_secret "$LOGIN_ENV_FILE" \
      "LOGIN_USERNAME=$LOGIN_USERNAME
LOGIN_PASSWORD=$LOGIN_PASSWORD
LOGIN_URL=$LOGIN_URL"
    chmod 600 "$LOGIN_ENV_FILE"
    native_success "Preserving existing login credentials at $LOGIN_ENV_FILE"
  else
    LOGIN_USERNAME="${LOGIN_USERNAME:-remote-chrome}"
    LOGIN_PASSWORD=$(openssl rand -base64 36)
    LOGIN_URL="https://${DOMAIN}/login/"
    native_write_user_secret "$LOGIN_ENV_FILE" \
      "LOGIN_USERNAME=$LOGIN_USERNAME
LOGIN_PASSWORD=$LOGIN_PASSWORD
LOGIN_URL=$LOGIN_URL"
    native_success "Created independent login-console credentials at $LOGIN_ENV_FILE"
  fi

  local htpasswd_value
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd_value=$(htpasswd -bnBC 12 "$LOGIN_USERNAME" "$LOGIN_PASSWORD")
  elif [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    htpasswd_value="${LOGIN_USERNAME}:\$2y\$12\$DRYRUNONLYNOTACREDENTIALHASH"
  else
    native_config_error "htpasswd is required after installing apache2-utils"
    return 1
  fi
  native_write_root_secret "$LOGIN_HTPASSWD_REAL" "$htpasswd_value"
}

native_install_dependencies() {
  native_info "APT packages: ${REMOTE_CHROME_APT_PACKAGES[*]}"
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    native_info "Dry run: package installation skipped"
    return
  fi

  native_privileged apt-get update
  native_privileged apt-get install -y "${REMOTE_CHROME_APT_PACKAGES[@]}"
  if ! command -v playwright-mcp >/dev/null 2>&1; then
    native_privileged npm install -g @playwright/mcp@latest
  fi
}

NATIVE_PRIOR_ACTIVE_UNITS=()
NATIVE_PRIOR_NGINX_ACTIVE=0

native_capture_runtime_state() {
  NATIVE_PRIOR_ACTIVE_UNITS=()
  NATIVE_PRIOR_NGINX_ACTIVE=0
  local unit
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    local requested=" ${REMOTE_CHROME_DRY_RUN_ACTIVE_UNITS-} "
    for unit in "${REMOTE_CHROME_UNITS[@]}"; do
      if [[ "$requested" == *" $unit "* ]]; then
        NATIVE_PRIOR_ACTIVE_UNITS+=("$unit")
      fi
    done
    [[ "${REMOTE_CHROME_DRY_RUN_NGINX_ACTIVE:-0}" == 1 ]] &&
      NATIVE_PRIOR_NGINX_ACTIVE=1
  else
    for unit in "${REMOTE_CHROME_UNITS[@]}"; do
      if systemctl --user is-active --quiet "$unit"; then
        NATIVE_PRIOR_ACTIVE_UNITS+=("$unit")
      fi
    done
    if systemctl is-active --quiet nginx; then
      NATIVE_PRIOR_NGINX_ACTIVE=1
    fi
  fi
  native_command_log "capture-active ${NATIVE_PRIOR_ACTIVE_UNITS[*]}"
  if [[ "$NATIVE_PRIOR_NGINX_ACTIVE" == 1 ]]; then
    native_command_log "capture-nginx active"
  else
    native_command_log "capture-nginx inactive"
  fi
}

native_restore_prior_runtime() {
  local failures=0
  local unit
  for unit in "${NATIVE_PRIOR_ACTIVE_UNITS[@]}"; do
    if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
      native_command_log "recovery-start $unit" || failures=$((failures + 1))
    else
      systemctl --user start "$unit" || failures=$((failures + 1))
    fi
  done
  if ((failures)); then
    native_config_error "failed to restore $failures service(s) after stop failure"
    return 1
  fi
}

native_stop_user_unit_checked() {
  local unit=$1
  systemctl --user stop "$unit" 2>/dev/null || true
  if systemctl --user is-active --quiet "$unit"; then
    native_config_error "$unit remains active after stop request"
    return 1
  fi
}

native_stop_active_browser() {
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    native_command_log "stop playwright-mcp.service"
    native_command_log "stop chrome-mcp.service"
    if [[ "${REMOTE_CHROME_DRY_RUN_STOP_RESULT:-pass}" == fail ]]; then
      native_config_error "dry-run simulated service stop failure"
      return 1
    fi
    return
  fi
  native_stop_user_unit_checked playwright-mcp.service || return 1
  native_stop_user_unit_checked chrome-mcp.service || return 1
}

native_backup_profile_once() {
  local skip_backup=$1
  if [[ -f "$PROFILE_BACKUP_MARKER" ]]; then
    local completed_archive
    completed_archive=$(cat "$PROFILE_BACKUP_MARKER")
    completed_archive=$(native_canonical_contained_path completed_archive \
      "$completed_archive" "$BACKUP_DIR") || return 1
    [[ -f "$completed_archive" ]] || {
      native_config_error "profile backup marker references a missing archive"
      return 1
    }
    native_success "Reusing protected profile backup at $completed_archive"
    return 0
  fi
  if [[ "$skip_backup" == 1 ]]; then
    native_warn "Profile backup explicitly skipped for first headed migration"
    return
  fi

  install -d -m 700 -- "$BACKUP_DIR"
  local archive profile_name
  archive=$(mktemp "$BACKUP_DIR/chrome-mcp-profile-XXXXXXXX.tar.gz")
  profile_name=$(basename "$CHROME_MCP_PROFILE")
  native_info "Backing up Chrome profile before headed migration: $archive"
  if ! tar -C "$(dirname "$CHROME_MCP_PROFILE")" \
    --exclude="$profile_name/Singleton*" \
    -czf "$archive" -- "$profile_name"; then
    rm -f -- "$archive"
    return 1
  fi
  chmod 600 "$archive"
  native_write_user_secret "$PROFILE_BACKUP_MARKER" "$archive"
}

native_backup_configuration() {
  local backup_path=$1
  install -d -m 700 -- \
    "$backup_path/systemd" "$backup_path/default.target.wants" "$backup_path/nginx"
  local unit
  for unit in "${REMOTE_CHROME_UNITS[@]}"; do
    if [[ -e "$SYSTEMD_USER_DIR/$unit" || -L "$SYSTEMD_USER_DIR/$unit" ]]; then
      cp -a -- "$SYSTEMD_USER_DIR/$unit" "$backup_path/systemd/$unit"
    fi
    if [[ -e "$SYSTEMD_USER_DIR/default.target.wants/$unit" ||
      -L "$SYSTEMD_USER_DIR/default.target.wants/$unit" ]]; then
      cp -a -- "$SYSTEMD_USER_DIR/default.target.wants/$unit" \
        "$backup_path/default.target.wants/$unit"
    fi
  done
  if [[ -e "$NGINX_SITE" || -L "$NGINX_SITE" ]]; then
    cp -a -- "$NGINX_SITE" "$backup_path/nginx/site"
  fi
  if [[ -e "$NGINX_ENABLED" || -L "$NGINX_ENABLED" ]]; then
    cp -a -- "$NGINX_ENABLED" "$backup_path/nginx/enabled"
  fi
}

native_restore_configuration() {
  local backup_path=$1
  native_warn "Activation failed; restoring the previous service and proxy configuration"
  local failures=0
  local unit
  local reverse_units=(
    playwright-mcp.service
    chrome-novnc.service
    chrome-vnc.service
    chrome-mcp.service
    chrome-window-manager.service
    chrome-display.service
  )
  for unit in "${reverse_units[@]}"; do
    if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
      native_command_log "rollback-stop $unit" || failures=$((failures + 1))
    else
      native_stop_user_unit_checked "$unit" || failures=$((failures + 1))
    fi
  done

  for unit in "${REMOTE_CHROME_UNITS[@]}"; do
    rm -f -- "$SYSTEMD_USER_DIR/$unit" || failures=$((failures + 1))
    rm -f -- "$SYSTEMD_USER_DIR/default.target.wants/$unit" ||
      failures=$((failures + 1))
    if [[ -e "$backup_path/systemd/$unit" || -L "$backup_path/systemd/$unit" ]]; then
      cp -a -- "$backup_path/systemd/$unit" "$SYSTEMD_USER_DIR/$unit" ||
        failures=$((failures + 1))
    fi
    if [[ -e "$backup_path/default.target.wants/$unit" ||
      -L "$backup_path/default.target.wants/$unit" ]]; then
      install -d -m 700 -- "$SYSTEMD_USER_DIR/default.target.wants"
      cp -a -- "$backup_path/default.target.wants/$unit" \
        "$SYSTEMD_USER_DIR/default.target.wants/$unit" ||
        failures=$((failures + 1))
    fi
  done

  native_privileged rm -f -- "$NGINX_SITE" "$NGINX_ENABLED" ||
    failures=$((failures + 1))
  if [[ -e "$backup_path/nginx/site" || -L "$backup_path/nginx/site" ]]; then
    native_privileged cp -a -- "$backup_path/nginx/site" "$NGINX_SITE" ||
      failures=$((failures + 1))
  fi
  if [[ -e "$backup_path/nginx/enabled" || -L "$backup_path/nginx/enabled" ]]; then
    native_privileged cp -a -- "$backup_path/nginx/enabled" "$NGINX_ENABLED" ||
      failures=$((failures + 1))
  fi

  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    native_command_log "rollback-daemon-reload" || failures=$((failures + 1))
  else
    systemctl --user daemon-reload || failures=$((failures + 1))
  fi
  local restore_unit
  for restore_unit in "${NATIVE_PRIOR_ACTIVE_UNITS[@]}"; do
    if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
      native_command_log "rollback-start $restore_unit" ||
        failures=$((failures + 1))
    else
      systemctl --user start "$restore_unit" || failures=$((failures + 1))
    fi
  done
  if [[ "$NATIVE_PRIOR_NGINX_ACTIVE" == 1 ]]; then
    if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
      native_command_log "rollback-nginx-reload" || failures=$((failures + 1))
    else
      native_privileged nginx -t || failures=$((failures + 1))
      native_privileged systemctl reload nginx || failures=$((failures + 1))
    fi
  elif [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
    native_privileged systemctl stop nginx || failures=$((failures + 1))
  fi
  if ((failures)); then
    native_config_error "rollback incomplete: $failures operation(s) failed"
    return 1
  fi
}

native_render_staged_configuration() {
  local render_dir=$1
  PROJECT_DIR="${PROJECT_DIR:-$native_config_root}"
  PROFILE_DIR="$CHROME_MCP_PROFILE"
  CHROME_BIN="${CHROME_BIN:-/usr/bin/google-chrome}"
  PLAYWRIGHT_MCP_BIN="${PLAYWRIGHT_MCP_BIN:-$(command -v playwright-mcp || true)}"
  DISPLAY_NUMBER="${DISPLAY_NUMBER:-99}"
  SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1440x900x24}"
  MCP_INTERNAL_PORT="${MCP_INTERNAL_PORT:-8931}"
  CDP_PORT="${CDP_PORT:-9222}"
  VNC_PORT="${VNC_PORT:-5900}"
  NOVNC_PORT="${NOVNC_PORT:-6080}"
  if [[ -z "$PLAYWRIGHT_MCP_BIN" ]]; then
    native_config_error "playwright-mcp executable was not found"
    return 1
  fi
  render_native_config "$render_dir"
}

native_validate_staged_nginx() {
  local render_dir=$1
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    native_info "Dry run: staged nginx validation passed"
    return
  fi

  local validation_conf="$render_dir/nginx-validation.conf"
  chmod 755 "$render_dir" "$render_dir/nginx"
  {
    printf 'events {}\nhttp {\n'
    printf '  include /etc/nginx/mime.types;\n'
    printf '  include %s;\n' "$render_dir/nginx/playwright-mcp.conf"
    printf '}\n'
  } > "$validation_conf"
  chmod 644 "$validation_conf" "$render_dir/nginx/playwright-mcp.conf"
  native_privileged nginx -t -c "$validation_conf"
}

native_install_staged_configuration() {
  local render_dir=$1
  install -d -m 700 -- "$SYSTEMD_USER_DIR"
  local unit
  for unit in "${REMOTE_CHROME_UNITS[@]}"; do
    install -m 644 -- "$render_dir/systemd/$unit" "$SYSTEMD_USER_DIR/$unit"
  done

  native_install_file 644 "$render_dir/nginx/playwright-mcp.conf" "$NGINX_SITE"
  native_privileged install -d -m 755 -- "$(dirname "$NGINX_ENABLED")"
  native_privileged ln -sfn -- "$NGINX_SITE" "$NGINX_ENABLED"
}

native_initialize_payload() {
  printf '%s' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"native-health","version":"1.0"}}}'
}

native_health_checks_once() {
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    native_info "Dry run: CDP, headed user agent, noVNC, MCP initialize, and public checks passed"
    return
  fi

  local cdp_version mcp_response public_response
  cdp_version=$(curl --fail --silent --show-error --max-time 10 \
    "http://127.0.0.1:${CDP_PORT}/json/version") || return 1
  printf '%s' "$cdp_version" | grep -q '"Browser"' || return 1
  printf '%s' "$cdp_version" | grep -q '"User-Agent"' || return 1
  if printf '%s' "$cdp_version" | grep -q 'HeadlessChrome'; then
    native_config_error "Chrome reports a headless user agent"
    return 1
  fi

  curl --fail --silent --show-error --max-time 10 \
    "http://127.0.0.1:${NOVNC_PORT}/" >/dev/null || return 1
  mcp_response=$(curl --fail --silent --show-error --max-time 15 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "http://127.0.0.1:${MCP_INTERNAL_PORT}/mcp" \
    -d "$(native_initialize_payload)") || return 1
  printf '%s' "$mcp_response" | grep -q 'REMOTE_CHROME_PLAYBOOK_VERSION=1' || return 1

  public_response=$(curl --fail --silent --show-error --max-time 15 \
    -X POST \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "https://${DOMAIN}/mcp" \
    -d "$(native_initialize_payload)") || return 1
  printf '%s' "$public_response" | grep -q 'REMOTE_CHROME_PLAYBOOK_VERSION=1'
}

native_wait_for_health_checks() {
  local attempts=${REMOTE_CHROME_HEALTHCHECK_ATTEMPTS:-15}
  local delay=${REMOTE_CHROME_HEALTHCHECK_DELAY:-2}
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if native_health_checks_once; then
      return
    fi
    if ((attempt < attempts)); then
      sleep "$delay"
    fi
  done
  native_config_error "health checks did not pass after $attempts attempts"
  return 1
}

native_activate_configuration() {
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    if [[ "${REMOTE_CHROME_DRY_RUN_ACTIVATION_RESULT:-pass}" == fail ]]; then
      native_warn "Dry run: simulated activation failure"
      return 1
    fi
    native_info "Dry run: would daemon-reload and start services in dependency order"
    native_wait_for_health_checks
    return
  fi

  systemctl --user daemon-reload || return 1
  systemctl --user enable "${REMOTE_CHROME_UNITS[@]}" || return 1
  local unit
  for unit in chrome-display.service chrome-window-manager.service chrome-mcp.service \
    chrome-vnc.service chrome-novnc.service playwright-mcp.service; do
    systemctl --user start "$unit" || return 1
  done
  native_privileged nginx -t || return 1
  if [[ "$NATIVE_PRIOR_NGINX_ACTIVE" == 1 ]]; then
    native_privileged systemctl reload nginx || return 1
  else
    native_privileged systemctl start nginx || return 1
  fi
  native_wait_for_health_checks
}

native_write_migration_marker() {
  local temporary
  temporary=$(native_make_temp_file)
  printf 'REMOTE_CHROME_HEADED_MIGRATION=1\n' > "$temporary"
  install -D -m 600 -- "$temporary" "$MIGRATION_MARKER"
  rm -f -- "$temporary"
}

native_validate_profile_deletion_target() {
  local candidate=$1
  local expected=$2
  local remote_home=$3
  local remote_root=$4
  if [[ "$candidate" != /* || "$candidate" == "/" || "$candidate" == "$remote_home" ||
    "$candidate" == *$'\n'* ]] || native_path_has_traversal "$candidate" ||
    [[ -L "$candidate" ]]; then
    native_config_error "refusing unsafe profile deletion target: $candidate"
    return 1
  fi
  local resolved_candidate resolved_expected resolved_home resolved_root
  resolved_candidate=$(realpath -m -- "$candidate") || return 1
  resolved_expected=$(realpath -m -- "$expected") || return 1
  resolved_home=$(realpath -m -- "$remote_home") || return 1
  resolved_root=$(realpath -m -- "$remote_root") || return 1
  if [[ "$resolved_candidate" != "$resolved_expected" ]] ||
    ! native_path_is_within "$resolved_candidate" "$resolved_home" ||
    ! native_path_is_within "$resolved_candidate" "$resolved_root"; then
    native_config_error "profile deletion target is not the expected managed profile"
    return 1
  fi
}

native_setup_main() {
  local non_interactive=0
  local cli_domain=
  local cli_email=
  local skip_profile_backup=0

  while (($#)); do
    case "$1" in
      --non-interactive)
        non_interactive=1
        ;;
      --domain)
        (($# >= 2)) || { native_setup_usage >&2; return 2; }
        cli_domain=$2
        shift
        ;;
      --email)
        (($# >= 2)) || { native_setup_usage >&2; return 2; }
        cli_email=$2
        shift
        ;;
      --skip-profile-backup)
        skip_profile_backup=1
        ;;
      -h|--help)
        native_setup_usage
        return
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        native_setup_usage >&2
        return 2
        ;;
    esac
    shift
  done

  native_initialize_paths || return
  DOMAIN=$(native_require_value DOMAIN "${DOMAIN:-$cli_domain}" "$non_interactive" \
    "Domain for the HTTPS MCP and login endpoints: ") || return
  CERTBOT_EMAIL=$(native_require_value CERTBOT_EMAIL \
    "${CERTBOT_EMAIL:-${EMAIL:-$cli_email}}" "$non_interactive" \
    "Email for certificate renewal notices: ") || return
  native_validate_setup_values || return

  native_info "Native headed Remote Chrome setup for $DOMAIN"
  native_install_dependencies || return
  native_prepare_profile || return
  native_load_or_create_bearer_token || return
  native_load_or_create_login_credentials || return

  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
    command -v nginx >/dev/null 2>&1 || {
      native_config_error "nginx is required"
      return 1
    }
    command -v certbot >/dev/null 2>&1 || {
      native_config_error "certbot is required"
      return 1
    }
    if [[ ! -e "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
      native_info "Requesting a Let's Encrypt certificate for $DOMAIN"
      native_privileged certbot certonly --nginx -d "$DOMAIN" --non-interactive \
        --agree-tos -m "$CERTBOT_EMAIL" --no-eff-email || return
    fi
  fi

  native_capture_runtime_state || return
  if ! native_stop_active_browser; then
    native_restore_prior_runtime || native_warn "runtime recovery after stop failure was incomplete"
    return 1
  fi
  if ! native_backup_profile_once "$skip_profile_backup"; then
    native_restore_prior_runtime ||
      native_warn "runtime recovery after backup failure was incomplete"
    return 1
  fi

  install -d -m 700 -- "$BACKUP_DIR"
  local config_backup render_dir
  config_backup=$(mktemp -d "$BACKUP_DIR/config-XXXXXXXX")
  if ! native_backup_configuration "$config_backup"; then
    native_restore_prior_runtime ||
      native_warn "runtime recovery after configuration backup failure was incomplete"
    return 1
  fi
  if [[ "${REMOTE_CHROME_DRY_RUN:-0}" == 1 ]]; then
    install -d -m 700 -- "$REMOTE_CHROME_ROOT/tmp"
    render_dir=$(mktemp -d "$REMOTE_CHROME_ROOT/tmp/remote-chrome-render.XXXXXX")
  else
    render_dir=$(mktemp -d "${TMPDIR:-/tmp}/remote-chrome-render.XXXXXX")
  fi
  if ! native_render_staged_configuration "$render_dir"; then
    native_restore_configuration "$config_backup" ||
      native_warn "rollback failed after render failure"
    rm -rf -- "$render_dir"
    return 1
  fi
  if ! native_validate_staged_nginx "$render_dir"; then
    native_restore_configuration "$config_backup" ||
      native_warn "rollback failed after nginx validation failure"
    rm -rf -- "$render_dir"
    return 1
  fi
  if ! native_install_staged_configuration "$render_dir" ||
    ! native_activate_configuration; then
    native_restore_configuration "$config_backup" ||
      native_warn "rollback failed after activation failure"
    rm -rf -- "$render_dir"
    return 1
  fi
  rm -rf -- "$render_dir"
  native_write_migration_marker

  native_success "Native headed migration activated"
  printf 'MCP endpoint: https://%s/mcp\n' "$DOMAIN"
  printf 'Login console: %s\n' "$LOGIN_URL"
  printf 'Login username: %s\n' "$LOGIN_USERNAME"
  printf 'Credentials remain in %s (mode 600); the password was not printed.\n' "$LOGIN_ENV_FILE"
}
