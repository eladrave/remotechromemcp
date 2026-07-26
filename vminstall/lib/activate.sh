#!/usr/bin/env bash

vm_activation_transition() {
  local transition=$1
  if [[ -n ${REMOTE_CHROME_TRANSITION_LOG:-} ]]; then
    vm_require_management_destination "$REMOTE_CHROME_TRANSITION_LOG" ||
      return 1
    printf '%s\n' "$transition" >>"$REMOTE_CHROME_TRANSITION_LOG" ||
      return 1
  fi
  [[ ${REMOTE_CHROME_FAIL_AT:-} != "$transition" ]]
}

vm_compose_for_release() {
  local release=$1 env_file=$2
  shift 2
  docker compose \
    -f "$release/compose.yaml" \
    -f "$release/vminstall/compose.vm.yaml" \
    --env-file "$env_file" "$@"
}

vm_wait_stack_health() {
  local release=$1
  local attempts=${REMOTE_CHROME_HEALTH_ATTEMPTS:-20}
  local delay=${REMOTE_CHROME_HEALTH_DELAY:-2}
  [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]] && delay=0
  local output
  while ((attempts > 0)); do
    output=$(
      vm_compose_for_release "$release" \
        "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
        ps --format '{{.Service}} {{.Health}}' browser proxy
    ) || output=
    if grep -Fxq 'browser healthy' <<<"$output" &&
       grep -Fxq 'proxy healthy' <<<"$output"; then
      return 0
    fi
    attempts=$((attempts - 1))
    ((attempts > 0)) && sleep "$delay"
  done
  return 1
}

vm_curl_status() {
  curl --silent --show-error --dump-header "$1" --output "$2" \
    --request "$3" "${@:4}" --write-out '%{http_code}'
}

vm_verify_public_stack() {
  local verify_dir="$REMOTE_CHROME_CONFIG_ROOT/.verify.$$"
  vm_require_management_destination "$verify_dir" || return 1
  install -d -m 0700 "$verify_dir" || return 1

  local auth_headers="$verify_dir/auth.headers"
  local delete_headers="$verify_dir/delete.headers"
  local websocket_headers="$verify_dir/websocket.headers"
  local response_headers="$verify_dir/response.headers"
  local response_body="$verify_dir/response.body"
  local login_headers="$verify_dir/login.headers"
  local empty_headers="$verify_dir/empty.headers"
  local status session content_type_count basic_value
  local result=0

  {
    printf 'Authorization: Bearer %s\n' "$MCP_TOKEN"
    printf 'Content-Type: application/json\n'
    printf 'Accept: application/json, text/event-stream\n'
  } | vm_write_secret_file "$auth_headers" || result=1
  if ((result == 0)); then
    status=$(vm_curl_status "$response_headers" "$response_body" POST \
      --header "@$auth_headers" \
      --data-binary \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"remote-chrome-installer","version":"1"}}}' \
      "$MCP_URL") || result=1
    [[ $status == 200 ]] || result=1
  fi
  if ((result == 0)); then
    content_type_count=$(
      tr -d '\r' <"$response_headers" |
        awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { count++ } END { print count+0 }'
    )
    [[ $content_type_count -eq 1 ]] || result=1
    session=$(
      tr -d '\r' <"$response_headers" |
        awk 'BEGIN { IGNORECASE=1 } /^Mcp-Session-Id:/ {
          sub(/^[^:]*:[[:space:]]*/, "")
          print
          exit
        }'
    )
    [[ -n $session && $session != *$'\n'* ]] || result=1
  fi
  if ((result == 0)); then
    {
      printf 'Authorization: Bearer %s\n' "$MCP_TOKEN"
      printf 'Mcp-Session-Id: %s\n' "$session"
    } | vm_write_secret_file "$delete_headers" || result=1
  fi
  if ((result == 0)); then
    status=$(vm_curl_status "$empty_headers" "$response_body" DELETE \
      --header "@$delete_headers" "$MCP_URL") || result=1
    [[ $status == 200 || $status == 202 || $status == 204 ]] || result=1
  fi
  if ((result == 0)); then
    status=$(vm_curl_status "$empty_headers" "$response_body" GET \
      "$MCP_URL") || result=1
    [[ $status == 405 ]] || result=1
  fi
  if ((result == 0)); then
    status=$(vm_curl_status "$login_headers" "$response_body" GET \
      "$LOGIN_URL") || result=1
    [[ $status == 401 ]] || result=1
    basic_value=$(
      tr -d '\r' <"$login_headers" |
        awk 'BEGIN { IGNORECASE=1 } /^WWW-Authenticate:[[:space:]]*Basic/ {
          print "yes"
          exit
        }'
    )
    [[ $basic_value == yes ]] || result=1
  fi
  if ((result == 0)); then
    {
      printf 'Authorization: Basic %s\n' \
        "$(printf '%s:%s' "$LOGIN_USERNAME" "$LOGIN_PASSWORD" | base64)"
      printf 'Connection: Upgrade\n'
      printf 'Upgrade: websocket\n'
      printf 'Sec-WebSocket-Key: cmVtb3RlLWNocm9tZQ==\n'
      printf 'Sec-WebSocket-Version: 13\n'
    } | vm_write_secret_file "$websocket_headers" || result=1
  fi
  if ((result == 0)); then
    status=$(vm_curl_status "$empty_headers" "$response_body" GET \
      --header "@$websocket_headers" \
      "https://$DOMAIN/login/websockify") || result=1
    [[ $status == 101 ]] || result=1
  fi

  vm_require_management_destination "$verify_dir" || return 1
  rm -rf -- "$verify_dir"
  ((result == 0))
}

vm_snapshot_activation_state() {
  local snapshot=$1
  vm_require_management_destination "$snapshot" || return 1
  install -d -m 0700 "$snapshot" || return 1
  local source name
  for source in \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service"; do
    name=${source##*/}
    if [[ -e $source || -L $source ]]; then
      [[ -f $source && ! -L $source ]] || return 1
      cp -a -- "$source" "$snapshot/$name" || return 1
      : >"$snapshot/$name.present"
    fi
  done
}

vm_restore_activation_state() {
  local snapshot=$1
  local destination name
  for destination in \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service"; do
    name=${destination##*/}
    vm_require_management_destination "$destination" || return 1
    if [[ -f $snapshot/$name.present ]]; then
      cp -a -- "$snapshot/$name" "$destination.tmp.$$" || return 1
      mv -fT -- "$destination.tmp.$$" "$destination" || return 1
    else
      rm -f -- "$destination"
    fi
  done
}

vm_switch_current() {
  local target=$1
  local temporary="$REMOTE_CHROME_INSTALL_ROOT/.current.tmp.$$"
  vm_require_management_destination "$temporary" || return 1
  vm_require_management_destination "$REMOTE_CHROME_INSTALL_ROOT/current" ||
    return 1
  rm -f -- "$temporary"
  ln -s -- "$target" "$temporary" || return 1
  mv -fT -- "$temporary" "$REMOTE_CHROME_INSTALL_ROOT/current"
}

vm_install_candidate_config() {
  local name
  for name in install.env compose.env credentials.env; do
    [[ -f $REMOTE_CHROME_CONFIG_ROOT/$name.candidate ]] || return 1
    vm_write_secret_file "$REMOTE_CHROME_CONFIG_ROOT/$name" \
      <"$REMOTE_CHROME_CONFIG_ROOT/$name.candidate" || return 1
  done
  local service_candidate="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate"
  local service_destination="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service"
  local service_temporary="${service_destination}.tmp.$$"
  [[ -f $service_candidate ]] || return 1
  vm_require_management_destination "$service_destination" || return 1
  vm_require_management_destination "$service_temporary" || return 1
  install -m 0644 "$service_candidate" "$service_temporary" || return 1
  chown root:root "$service_temporary" || return 1
  mv -fT -- "$service_temporary" "$service_destination" || return 1
}

vm_cleanup_candidate_config() {
  local candidate
  for candidate in \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/credentials.env.candidate" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate"; do
    vm_require_management_destination "$candidate" || return 1
    rm -f -- "$candidate"
  done
}

vm_rollback_release() {
  local previous_target=$1 snapshot=$2 candidate_release=$3
  local rollback_failed=0
  vm_compose_for_release "$candidate_release" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env" down || rollback_failed=1

  if [[ -n $previous_target ]]; then
    vm_switch_current "$previous_target" || rollback_failed=1
  else
    vm_require_management_destination "$REMOTE_CHROME_INSTALL_ROOT/current" ||
      rollback_failed=1
    rm -f -- "$REMOTE_CHROME_INSTALL_ROOT/current" || rollback_failed=1
  fi
  vm_restore_activation_state "$snapshot" || rollback_failed=1
  systemctl daemon-reload || rollback_failed=1

  if [[ -n $previous_target ]]; then
    systemctl start remote-chrome.service || rollback_failed=1
    if ! REMOTE_CHROME_ROLLBACK=1 \
      vm_wait_stack_health "$REMOTE_CHROME_INSTALL_ROOT/$previous_target"; then
      printf 'ERROR: rollback health verification failed\n' >&2
      return 70
    fi
  fi
  ((rollback_failed == 0)) || return 1
}

vm_activate_release() {
  local current="$REMOTE_CHROME_INSTALL_ROOT/current"
  local previous_target=
  local snapshot="$REMOTE_CHROME_CONFIG_ROOT/.rollback.$$"
  local candidate_release="$REMOTE_CHROME_INSTALL_ROOT/releases/$SELECTED_VERSION"
  local switched=0 result=1

  [[ -n ${STAGED_RELEASE_DIR:-} ]] || return 1
  vm_verify_release "$STAGED_RELEASE_DIR" || return 1
  if [[ -L $current ]]; then
    previous_target=$(readlink "$current") || return 1
    [[ $previous_target == releases/* && $previous_target != *$'\n'* ]] ||
      return 1
  elif [[ -e $current ]]; then
    return 1
  fi

  vm_snapshot_activation_state "$snapshot" || return 1
  vm_require_management_destination "$candidate_release" || return 1
  [[ ! -e $candidate_release && ! -L $candidate_release ]] || return 1
  if ! mv -T -- "$STAGED_RELEASE_DIR" "$candidate_release" ||
     ! vm_activation_transition release-installed ||
     ! vm_prepare_config ||
     ! vm_activation_transition candidate-config-written ||
     ! vm_compose_for_release "$candidate_release" \
       "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" config ||
     ! vm_activation_transition compose-config-validated; then
    vm_cleanup_candidate_config || true
    rm -rf -- "$snapshot"
    return 1
  fi

  if vm_switch_current "releases/$SELECTED_VERSION"; then
    switched=1
  fi
  if ((switched == 1)) &&
     vm_activation_transition current-switched &&
     vm_install_candidate_config &&
     vm_activation_transition config-installed &&
     systemctl daemon-reload &&
     vm_activation_transition service-reloaded &&
     systemctl enable --now remote-chrome.service &&
     vm_activation_transition service-started &&
     vm_wait_stack_health "$candidate_release" &&
     vm_activation_transition health-verified &&
     vm_verify_public_stack &&
     vm_activation_transition public-verified &&
     printf '%s\n' "$SELECTED_VERSION" |
       vm_write_secret_file "$REMOTE_CHROME_CONFIG_ROOT/active-version" &&
     vm_activation_transition active-recorded; then
    result=0
  fi

  if ((result != 0)); then
    if ((switched == 1)); then
      if vm_rollback_release \
        "$previous_target" "$snapshot" "$candidate_release"; then
        :
      else
        local rollback_status=$?
        vm_cleanup_candidate_config || true
        rm -rf -- "$snapshot"
        [[ $rollback_status -eq 70 ]] && return 70
        return 1
      fi
    fi
    vm_cleanup_candidate_config || true
    rm -rf -- "$snapshot"
    return 1
  fi

  vm_cleanup_candidate_config || return 1
  rm -rf -- "$snapshot"
  return 0
}

vm_display_installed_path() {
  local path=$1
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} &&
     $path == "$REMOTE_CHROME_CANONICAL_TEST_ROOT"/* ]]; then
    printf '/%s' "${path#"$REMOTE_CHROME_CANONICAL_TEST_ROOT"/}"
  else
    printf '%s' "$path"
  fi
}

vm_print_connection_handoff() {
  local credentials="$REMOTE_CHROME_CONFIG_ROOT/credentials.env"
  local tty=${REMOTE_CHROME_TTY:-/dev/tty}
  [[ -f $credentials && ! -L $credentials ]] || return 1
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    vm_require_management_destination "$tty" || return 1
  fi
  [[ -w $tty ]] || return 1

  local mcp_url mcp_token compatibility_url login_url username password
  local data_dir profile
  mcp_url=$(vm_read_env_value "$credentials" MCP_URL) || return 1
  mcp_token=$(vm_read_env_value "$credentials" MCP_TOKEN) || return 1
  compatibility_url=$(
    vm_read_env_value "$credentials" MCP_COMPATIBILITY_URL
  ) || return 1
  login_url=$(vm_read_env_value "$credentials" LOGIN_URL) || return 1
  username=$(vm_read_env_value "$credentials" LOGIN_USERNAME) || return 1
  password=$(vm_read_env_value "$credentials" LOGIN_PASSWORD) || return 1
  data_dir=$(
    vm_read_env_value "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
      REMOTE_CHROME_DATA_DIR
  ) || return 1
  profile=$(vm_display_installed_path "$data_dir/profile")

  {
    printf '%s\n' \
      'Remote Chrome is ready.' \
      "Preferred MCP URL: $mcp_url" \
      "Authorization: Bearer $mcp_token" \
      "Compatibility MCP URL: $compatibility_url" \
      "Login URL: $login_url" \
      "Login username: $username" \
      "Login password: $password" \
      'Certificate: HTTPS managed by Caddy (ACME)' \
      'Credentials file: /etc/remote-chrome/credentials.env' \
      "Profile: $profile" \
      'Status: sudo remote-chrome status' \
      'Credentials: sudo remote-chrome credentials' \
      'Backup: sudo remote-chrome backup' \
      'Restore: sudo remote-chrome restore'
    printf '\nJSON client configuration:\n'
    printf '{\n  "url": "%s",\n  "headers": {\n' "$mcp_url"
    printf '    "Authorization": "Bearer %s"\n  }\n}\n' "$mcp_token"
    printf '\nTOML client configuration:\n'
    printf 'url = "%s"\n' "$mcp_url"
    printf 'authorization = "Bearer %s"\n' "$mcp_token"
  } >>"$tty"
}
