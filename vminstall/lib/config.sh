#!/usr/bin/env bash

vm_require_management_destination() {
  local destination=$1 canonical_root canonical_destination
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]] || return 1
    canonical_root=$(realpath -e -- "$REMOTE_CHROME_TEST_ROOT") || return 1
    [[ $canonical_root == "$REMOTE_CHROME_CANONICAL_TEST_ROOT" ]] || return 1
    canonical_destination=$(realpath -m -- "$destination") || return 1
    case "$canonical_destination" in
      "$canonical_root"|"$canonical_root"/*) ;;
      *)
        printf 'ERROR: management destination escapes test root: %s\n' \
          "$destination" >&2
        return 1
        ;;
    esac
  fi
  vm_require_confined_destination "$destination"
}

vm_validate_config_value() {
  [[ ${1:-} != *$'\n'* && ${1:-} != *$'\r'* ]]
}

vm_single_quote_dotenv() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\\\'}
  printf "'%s'" "$value"
}

vm_read_env_value() {
  local file=$1 key=$2
  [[ -f $file && ! -L $file ]] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      if (value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
        gsub(/\\\047/, "\047", value)
        gsub(/\\\\/, "\\", value)
      }
      print value
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

vm_write_secret_file() {
  local destination=$1
  local temporary="${destination}.tmp.$$"
  vm_require_management_destination "$destination" || return 1
  vm_require_management_destination "$temporary" || return 1
  umask 077
  install -d -m 0700 "$(dirname "$destination")" || return 1
  if ! : >"$temporary" ||
     ! chmod 0600 "$temporary" ||
     ! cat >"$temporary" ||
     ! chown root:root "$temporary" ||
     ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

vm_render_systemd_service() {
  local destination="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate"
  local temporary="${destination}.tmp.$$"
  local template
  template="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/remote-chrome.service.in"
  vm_require_management_destination "$destination" || return 1
  vm_require_management_destination "$temporary" || return 1
  [[ -f $template && ! -L $template ]] || return 1
  install -d -m 0755 "$REMOTE_CHROME_SYSTEMD_ROOT" || return 1
  if ! install -m 0644 "$template" "$temporary" ||
     ! chown root:root "$temporary" ||
     ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

vm_generate_credentials() {
  local installed_credentials="$REMOTE_CHROME_CONFIG_ROOT/credentials.env"
  local installed_compose="$REMOTE_CHROME_CONFIG_ROOT/compose.env"
  local rotate=${ROTATE_CREDENTIALS:-0}

  MCP_TOKEN=
  LOGIN_USERNAME=remotechrome
  LOGIN_PASSWORD=
  LOGIN_PASSWORD_HASH=

  if [[ $rotate -eq 0 && -f $installed_credentials ]]; then
    MCP_TOKEN=$(vm_read_env_value "$installed_credentials" MCP_TOKEN) ||
      return 1
    LOGIN_USERNAME=$(
      vm_read_env_value "$installed_credentials" LOGIN_USERNAME
    ) || return 1
    LOGIN_PASSWORD=$(
      vm_read_env_value "$installed_credentials" LOGIN_PASSWORD
    ) || return 1
    if [[ -f $installed_compose ]]; then
      LOGIN_PASSWORD_HASH=$(
        vm_read_env_value "$installed_compose" LOGIN_PASSWORD_HASH
      ) || return 1
    fi
  fi

  if [[ -z $MCP_TOKEN || $rotate -eq 1 ]]; then
    MCP_TOKEN=$(openssl rand -hex 32) || return 1
  fi
  [[ $MCP_TOKEN =~ ^[0-9a-f]{64}$ ]] || return 1

  if [[ -z $LOGIN_PASSWORD || $rotate -eq 1 ]]; then
    LOGIN_PASSWORD=$(openssl rand -base64 48) || return 1
    [[ ${#LOGIN_PASSWORD} -ge 64 ]] || return 1
    LOGIN_PASSWORD_HASH=
  fi
  if [[ -z $LOGIN_PASSWORD_HASH ]]; then
    LOGIN_PASSWORD_HASH=$(
      printf '%s\n' "$LOGIN_PASSWORD" |
        docker run --rm -i caddy:2-alpine caddy hash-password
    ) || return 1
  fi
  [[ $LOGIN_PASSWORD_HASH =~ ^\$2[aby]\$[0-9][0-9]\$.{53}$ ]] ||
    return 1

  MCP_URL="https://$DOMAIN/mcp"
  MCP_COMPATIBILITY_URL="https://$DOMAIN/$MCP_TOKEN/mcp"
  LOGIN_URL="https://$DOMAIN/login/"
  local destination="$REMOTE_CHROME_CONFIG_ROOT/credentials.env.candidate"
  {
    printf 'MCP_URL=%s\n' "$MCP_URL"
    printf 'MCP_TOKEN=%s\n' "$MCP_TOKEN"
    printf 'MCP_COMPATIBILITY_URL=%s\n' "$MCP_COMPATIBILITY_URL"
    printf 'LOGIN_URL=%s\n' "$LOGIN_URL"
    printf 'LOGIN_USERNAME=%s\n' "$LOGIN_USERNAME"
    printf 'LOGIN_PASSWORD=%s\n' "$LOGIN_PASSWORD"
  } | vm_write_secret_file "$destination"
}

vm_render_compose_env() {
  local destination="$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate"
  {
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'ACME_EMAIL=%s\n' "$(vm_single_quote_dotenv "$ACME_EMAIL")"
    printf 'MCP_TOKEN=%s\n' "$MCP_TOKEN"
    printf 'LOGIN_USERNAME=%s\n' "$LOGIN_USERNAME"
    printf 'LOGIN_PASSWORD_HASH=%s\n' \
      "$(vm_single_quote_dotenv "$LOGIN_PASSWORD_HASH")"
    printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
    printf 'SCREEN_GEOMETRY=1440x900x24\n'
    printf 'REMOTE_CHROME_DATA_DIR=%s\n' \
      "$(vm_single_quote_dotenv "$REMOTE_CHROME_DATA_DIR")"
    printf 'PROXY_BIND_ADDRESS=0.0.0.0\n'
    printf 'PROXY_HTTP_PORT=80\n'
    printf 'PROXY_HTTPS_PORT=443\n'
  } | vm_write_secret_file "$destination"
}

vm_render_install_env() {
  local destination="$REMOTE_CHROME_CONFIG_ROOT/install.env.candidate"
  {
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'ACME_EMAIL=%s\n' "$(vm_single_quote_dotenv "$ACME_EMAIL")"
    printf 'REMOTE_CHROME_DATA_DIR=%s\n' \
      "$(vm_single_quote_dotenv "$REMOTE_CHROME_DATA_DIR")"
    printf 'GCS_BUCKET=%s\n' "$(vm_single_quote_dotenv "${GCS_BUCKET:-}")"
    printf 'BACKUP_SCHEDULE=%s\n' \
      "$(vm_single_quote_dotenv "${BACKUP_SCHEDULE:-}")"
    printf 'SELECTED_VERSION=%s\n' "$SELECTED_VERSION"
  } | vm_write_secret_file "$destination"
}

vm_preserve_installed_configuration() {
  local installed="$REMOTE_CHROME_CONFIG_ROOT/install.env"
  [[ -f $installed && ! -L $installed ]] || return 0
  DOMAIN=$(vm_read_env_value "$installed" DOMAIN) || return 1
  ACME_EMAIL=$(vm_read_env_value "$installed" ACME_EMAIL) || return 1
  REMOTE_CHROME_DATA_DIR=$(
    vm_read_env_value "$installed" REMOTE_CHROME_DATA_DIR
  ) || return 1
  GCS_BUCKET=$(vm_read_env_value "$installed" GCS_BUCKET) || return 1
  BACKUP_SCHEDULE=$(
    vm_read_env_value "$installed" BACKUP_SCHEDULE
  ) || return 1
}

vm_prepare_config() {
  local supplied
  for supplied in \
    "${DOMAIN:-}" "${ACME_EMAIL:-}" "${REMOTE_CHROME_DATA_DIR:-}" \
    "${GCS_BUCKET:-}" "${BACKUP_SCHEDULE:-}" "${SELECTED_VERSION:-}"; do
    vm_validate_config_value "$supplied" || return 1
  done
  vm_validate_release_ref "${SELECTED_VERSION:-}" || return 1
  vm_preserve_installed_configuration || return 1
  vm_validate_domain "$DOMAIN" || return 1
  vm_validate_email "$ACME_EMAIL" || return 1

  local canonical_data_dir
  canonical_data_dir=$(vm_canonicalize_data_dir "$REMOTE_CHROME_DATA_DIR") ||
    return 1
  vm_validate_data_dir "$canonical_data_dir" || return 1
  REMOTE_CHROME_DATA_DIR=$canonical_data_dir
  vm_require_management_destination "$REMOTE_CHROME_CONFIG_ROOT" || return 1
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    vm_require_management_destination "$REMOTE_CHROME_DATA_DIR" || return 1
  fi

  install -d -m 0700 "$REMOTE_CHROME_CONFIG_ROOT" || return 1
  local subdirectory
  for subdirectory in profile caddy-data caddy-config backups restore-staging; do
    vm_require_management_destination \
      "$REMOTE_CHROME_DATA_DIR/$subdirectory" || return 1
    install -d -m 0700 "$REMOTE_CHROME_DATA_DIR/$subdirectory" || return 1
  done

  vm_generate_credentials || return 1
  vm_render_install_env || return 1
  vm_render_compose_env || return 1
  vm_render_systemd_service || return 1
}
