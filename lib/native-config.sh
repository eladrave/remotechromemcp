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
