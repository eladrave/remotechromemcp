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

vm_validate_integer_bound() {
  local value=$1 minimum=$2 maximum=$3
  [[ $value =~ ^[0-9]+$ ]] &&
    ((value >= minimum && value <= maximum))
}

vm_command_timeout() {
  local value=${REMOTE_CHROME_COMMAND_TIMEOUT:-15}
  vm_validate_integer_bound "$value" 1 120 || {
    printf 'ERROR: REMOTE_CHROME_COMMAND_TIMEOUT must be between 1 and 120\n' >&2
    return 64
  }
  printf '%s' "$value"
}

vm_run_with_timeout() {
  local seconds=$1
  shift
  vm_validate_integer_bound "$seconds" 1 600 || return 64
  local status=0
  /usr/bin/timeout --kill-after=2 "${seconds}s" "$@" ||
    status=$?
  [[ $status -ne 124 && $status -ne 137 ]] || return 75
  return "$status"
}

vm_run_bounded() {
  local seconds
  seconds=$(vm_command_timeout) || return $?
  vm_run_with_timeout "$seconds" "$@"
}

vm_service_timeout() {
  local value=${REMOTE_CHROME_SERVICE_TIMEOUT:-300}
  vm_validate_integer_bound "$value" 30 600 || {
    printf 'ERROR: REMOTE_CHROME_SERVICE_TIMEOUT must be between 30 and 600\n' >&2
    return 64
  }
  printf '%s' "$value"
}

vm_run_service_control() {
  local seconds
  seconds=$(vm_service_timeout) || return $?
  vm_run_with_timeout "$seconds" systemctl "$@"
}

vm_compose_for_release() {
  local release=$1 env_file=$2
  shift 2
  vm_run_bounded docker compose \
    --project-name remote-chrome \
    -f "$release/compose.yaml" \
    -f "$release/vminstall/compose.vm.yaml" \
    --env-file "$env_file" "$@"
}

vm_wait_stack_health() {
  local release=$1
  local attempts=${REMOTE_CHROME_HEALTH_ATTEMPTS:-20}
  local delay=${REMOTE_CHROME_HEALTH_DELAY:-2}
  vm_validate_integer_bound "$attempts" 1 60 || {
    printf 'ERROR: REMOTE_CHROME_HEALTH_ATTEMPTS must be between 1 and 60\n' >&2
    return 64
  }
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    vm_validate_integer_bound "$delay" 0 30 || {
      printf 'ERROR: REMOTE_CHROME_HEALTH_DELAY must be between 0 and 30\n' >&2
      return 64
    }
    delay=0
  else
    vm_validate_integer_bound "$delay" 1 30 || {
      printf 'ERROR: REMOTE_CHROME_HEALTH_DELAY must be between 1 and 30\n' >&2
      return 64
    }
  fi
  vm_command_timeout >/dev/null || return $?
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
  vm_run_bounded curl --silent --show-error --dump-header "$1" --output "$2" \
    --connect-timeout 5 --max-time 10 \
    --request "$3" "${@:4}" --write-out '%{http_code}'
}

vm_capture_certificate_metadata() {
  local metadata issuer expires
  metadata=$(
    vm_run_with_timeout 5 openssl s_client \
      -connect "$DOMAIN:443" \
      -servername "$DOMAIN" \
      -verify_return_error </dev/null 2>/dev/null |
      vm_run_with_timeout 5 openssl x509 -noout -issuer -enddate
  ) || return 1
  issuer=$(
    awk 'index($0, "issuer=") == 1 {
      print substr($0, length("issuer=") + 1)
      found=1
      exit
    } END { if (!found) exit 1 }' <<<"$metadata"
  ) || return 1
  expires=$(
    awk 'index($0, "notAfter=") == 1 {
      print substr($0, length("notAfter=") + 1)
      found=1
      exit
    } END { if (!found) exit 1 }' <<<"$metadata"
  ) || return 1
  [[ -n $issuer && -n $expires &&
     $issuer != *$'\n'* && $issuer != *$'\r'* &&
     $expires != *$'\n'* && $expires != *$'\r'* ]] || return 1

  CERTIFICATE_STATUS=ready
  CERTIFICATE_ISSUER=$issuer
  CERTIFICATE_EXPIRES=$expires
  {
    printf 'CERTIFICATE_STATUS=%s\n' "$CERTIFICATE_STATUS"
    printf 'CERTIFICATE_ISSUER=%s\n' "$CERTIFICATE_ISSUER"
    printf 'CERTIFICATE_EXPIRES=%s\n' "$CERTIFICATE_EXPIRES"
  } | vm_write_secret_file "$REMOTE_CHROME_CONFIG_ROOT/certificate.env"
}

vm_verify_public_stack() {
  local verify_dir="$REMOTE_CHROME_CONFIG_ROOT/.verify.$$"
  vm_require_management_destination "$verify_dir" || return 1
  install -d -m 0700 "$verify_dir" || return 1

  local auth_headers="$verify_dir/auth.headers"
  local basic_headers="$verify_dir/basic.headers"
  local delete_headers="$verify_dir/delete.headers"
  local websocket_headers="$verify_dir/websocket.headers"
  local response_headers="$verify_dir/response.headers"
  local response_body="$verify_dir/response.body"
  local login_headers="$verify_dir/login.headers"
  local empty_headers="$verify_dir/empty.headers"
  local anonymous_headers="$verify_dir/anonymous.headers"
  local status session content_type_count basic_value websocket_curl_status
  local result=0

  {
    printf 'Authorization: Bearer %s\n' "$MCP_TOKEN"
    printf 'Content-Type: application/json\n'
    printf 'Accept: application/json, text/event-stream\n'
  } | vm_write_secret_file "$auth_headers" || result=1
  {
    printf 'Authorization: Basic %s\n' \
      "$(printf '%s:%s' "$LOGIN_USERNAME" "$LOGIN_PASSWORD" | base64 -w0)"
  } | vm_write_secret_file "$basic_headers" || result=1
  if ((result == 0)); then
    status=$(vm_curl_status "$anonymous_headers" "$response_body" POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --data-binary \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"remote-chrome-anonymous-check","version":"1"}}}' \
      "$MCP_URL") || result=1
    [[ $status == 401 ]] || result=1
  fi
  if ((result == 0)); then
    status=$(vm_curl_status "$response_headers" "$response_body" POST \
      --header "@$auth_headers" \
      --data-binary \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"remote-chrome-installer","version":"1"}}}' \
      "$MCP_URL") || result=1
    [[ $status == 200 ]] || result=1
    grep -Fq 'REMOTE_CHROME_PLAYBOOK_VERSION=1' "$response_body" ||
      result=1
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
      --header "@$auth_headers" "$MCP_URL") || result=1
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
    status=$(vm_curl_status "$login_headers" "$response_body" GET \
      --header "@$basic_headers" "$LOGIN_URL") || result=1
    [[ $status == 200 ]] || result=1
    grep -qi 'noVNC' "$response_body" || result=1
  fi
  if ((result == 0)); then
    {
      printf 'Authorization: Basic %s\n' \
        "$(printf '%s:%s' "$LOGIN_USERNAME" "$LOGIN_PASSWORD" | base64 -w0)"
      printf 'Connection: Upgrade\n'
      printf 'Upgrade: websocket\n'
      printf 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\n'
      printf 'Sec-WebSocket-Version: 13\n'
    } | vm_write_secret_file "$websocket_headers" || result=1
  fi
  if ((result == 0)); then
    websocket_curl_status=0
    status=$(vm_curl_status "$empty_headers" "$response_body" GET \
      --http1.1 \
      --max-time 3 \
      --header "@$websocket_headers" \
      "https://$DOMAIN/login/websockify") || websocket_curl_status=$?
    [[ $websocket_curl_status == 0 ||
       $websocket_curl_status == 28 ]] || result=1
    tr -d '\r' <"$empty_headers" |
      grep -Eq '^HTTP/[^ ]+ 101([[:space:]]|$)' || result=1
  fi
  if ((result == 0)); then
    vm_capture_certificate_metadata || result=1
  fi

  vm_require_management_destination "$verify_dir" || return 1
  rm -rf -- "$verify_dir"
  ((result == 0))
}

vm_wait_public_stack() {
  local attempts=${REMOTE_CHROME_PUBLIC_ATTEMPTS:-}
  local delay=${REMOTE_CHROME_PUBLIC_DELAY:-2}
  if [[ -z $attempts ]]; then
    if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
      attempts=1
    else
      attempts=20
    fi
  fi
  vm_validate_integer_bound "$attempts" 1 60 || {
    printf 'ERROR: REMOTE_CHROME_PUBLIC_ATTEMPTS must be between 1 and 60\n' >&2
    return 64
  }
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    vm_validate_integer_bound "$delay" 0 30 || {
      printf 'ERROR: REMOTE_CHROME_PUBLIC_DELAY must be between 0 and 30\n' >&2
      return 64
    }
    delay=0
  else
    vm_validate_integer_bound "$delay" 1 30 || {
      printf 'ERROR: REMOTE_CHROME_PUBLIC_DELAY must be between 1 and 30\n' >&2
      return 64
    }
  fi
  while ((attempts > 0)); do
    if vm_verify_public_stack; then
      return 0
    fi
    attempts=$((attempts - 1))
    ((attempts > 0)) && sleep "$delay"
  done
  printf 'ERROR: public TLS, MCP, login, or WebSocket verification did not become ready\n' >&2
  return 1
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
    "$REMOTE_CHROME_CONFIG_ROOT/certificate.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
    "$REMOTE_CHROME_CONFIG_ROOT/previous-version" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"; do
    name=${source##*/}
    if [[ -e $source || -L $source ]]; then
      [[ -f $source && ! -L $source ]] || return 1
      cp -a -- "$source" "$snapshot/$name" || return 1
      : >"$snapshot/$name.present"
    fi
  done
  if [[ -e $REMOTE_CHROME_CLI_ROOT/remote-chrome ||
        -L $REMOTE_CHROME_CLI_ROOT/remote-chrome ]]; then
    [[ -f $REMOTE_CHROME_CLI_ROOT/remote-chrome &&
       ! -L $REMOTE_CHROME_CLI_ROOT/remote-chrome ]] || return 1
    cp -a -- "$REMOTE_CHROME_CLI_ROOT/remote-chrome" \
      "$snapshot/remote-chrome.cli" || return 1
    : >"$snapshot/remote-chrome.cli.present"
  fi
  if vm_run_bounded systemctl is-enabled --quiet remote-chrome.service; then
    : >"$snapshot/service.enabled"
  fi
  if vm_run_bounded systemctl is-active --quiet remote-chrome.service; then
    : >"$snapshot/service.active"
  fi
  if vm_run_bounded systemctl is-enabled --quiet remote-chrome-backup.timer; then
    : >"$snapshot/backup-timer.enabled"
  fi
  if vm_run_bounded systemctl is-active --quiet remote-chrome-backup.timer; then
    : >"$snapshot/backup-timer.active"
  fi
}

vm_restore_managed_file() {
  local snapshot_file=$1 destination=$2 mode=$3
  vm_require_management_destination "$destination" || return 1
  if [[ -f $snapshot_file ]]; then
    vm_write_managed_file "$destination" "$mode" <"$snapshot_file"
  else
    rm -f -- "$destination"
  fi
}

vm_restore_activation_state() {
  local snapshot=$1
  local destination name mode
  for destination in \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/credentials.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/certificate.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/active-version" \
    "$REMOTE_CHROME_CONFIG_ROOT/previous-version" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"; do
    name=${destination##*/}
    mode=0600
    [[ $destination == "$REMOTE_CHROME_SYSTEMD_ROOT/"*.service ||
       $destination == "$REMOTE_CHROME_SYSTEMD_ROOT/"*.timer ]] &&
      mode=0644
    if [[ -f $snapshot/$name.present ]]; then
      vm_restore_managed_file "$snapshot/$name" "$destination" "$mode" ||
        return 1
    else
      vm_restore_managed_file /nonexistent "$destination" "$mode" || return 1
    fi
  done
  if [[ -f $snapshot/remote-chrome.cli.present ]]; then
    vm_restore_managed_file "$snapshot/remote-chrome.cli" \
      "$REMOTE_CHROME_CLI_ROOT/remote-chrome" 0755 || return 1
  else
    vm_restore_managed_file /nonexistent \
      "$REMOTE_CHROME_CLI_ROOT/remote-chrome" 0755 || return 1
  fi
}

vm_switch_current() {
  local target=$1
  local temporary
  vm_require_management_destination "$REMOTE_CHROME_INSTALL_ROOT" || return 1
  install -d -m 0755 "$REMOTE_CHROME_INSTALL_ROOT" || return 1
  vm_require_management_destination "$REMOTE_CHROME_INSTALL_ROOT" || return 1
  temporary=$(
    mktemp -p "$REMOTE_CHROME_INSTALL_ROOT" '.current.XXXXXXXXXX'
  ) || return 1
  vm_require_management_destination "$temporary" || return 1
  rm -f -- "$temporary" || return 1
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
  [[ -f $service_candidate ]] || return 1
  vm_write_managed_file "$service_destination" 0644 <"$service_candidate" ||
    return 1
  local backup_name backup_candidate backup_destination
  if [[ -n ${BACKUP_SCHEDULE:-} ]]; then
    for backup_name in remote-chrome-backup.service remote-chrome-backup.timer; do
      backup_candidate="$REMOTE_CHROME_SYSTEMD_ROOT/$backup_name.candidate"
      backup_destination="$REMOTE_CHROME_SYSTEMD_ROOT/$backup_name"
      [[ -f $backup_candidate && ! -L $backup_candidate ]] || return 1
      vm_write_managed_file "$backup_destination" 0644 <"$backup_candidate" ||
        return 1
    done
  fi

  local cli_candidate="$REMOTE_CHROME_INSTALL_ROOT/releases/$SELECTED_VERSION/vminstall/remote-chrome"
  local cli_destination="$REMOTE_CHROME_CLI_ROOT/remote-chrome"
  [[ -f $cli_candidate && ! -L $cli_candidate && -x $cli_candidate ]] ||
    return 1
  vm_write_managed_file "$cli_destination" 0755 <"$cli_candidate"
}

vm_cleanup_candidate_config() {
  local candidate
  for candidate in \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/credentials.env.candidate" \
    "$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome.service.candidate" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service.candidate" \
    "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer.candidate"; do
    vm_require_management_destination "$candidate" || return 1
    rm -f -- "$candidate"
  done
}

vm_validate_candidate_compose() {
  local candidate_release=$1
  local diagnostic="$REMOTE_CHROME_CONFIG_ROOT/activation-diagnostic.log"
  local raw status=0
  vm_require_management_destination "$REMOTE_CHROME_CONFIG_ROOT" || return 1
  raw=$(mktemp -p "$REMOTE_CHROME_CONFIG_ROOT" \
    '.compose-validation.XXXXXXXXXX') || return 1
  vm_require_management_destination "$raw" || return 1
  chmod 0600 "$raw" || {
    rm -f -- "$raw"
    return 1
  }
  chown root:root "$raw" || {
    rm -f -- "$raw"
    return 1
  }
  if ! vm_compose_for_release "$candidate_release" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate" \
    config --quiet >"$raw" 2>&1; then
    status=1
  fi
  if ((status == 0)); then
    printf 'Compose candidate validation passed; raw output suppressed.\n'
  else
    printf 'Compose candidate validation failed; raw output suppressed.\n'
  fi | vm_write_secret_file "$diagnostic" || status=1
  rm -f -- "$raw"
  ((status == 0))
}

vm_stop_candidate_release() {
  local candidate_release=$1 env_file
  local diagnostic="$REMOTE_CHROME_CONFIG_ROOT/candidate-shutdown.log"
  VM_CANDIDATE_STOP_CONFIRMED=0
  : | vm_write_secret_file "$diagnostic" || return 1
  env_file="$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate"
  [[ -f $env_file && ! -L $env_file ]] ||
    env_file="$REMOTE_CHROME_CONFIG_ROOT/compose.env"
  if [[ -f $env_file && ! -L $env_file ]] &&
     vm_compose_for_release "$candidate_release" "$env_file" down \
       >>"$diagnostic" 2>&1; then
    VM_CANDIDATE_STOP_CONFIRMED=1
    return 0
  fi
  printf '%s\n' \
    'ERROR: candidate shutdown was not confirmed; recovery retained:' \
    "  release: $candidate_release" \
    "  compose environment: $env_file" \
    "  shutdown diagnostic: $diagnostic" >&2
  return 1
}

vm_remove_candidate_release() {
  local candidate_release=$1
  [[ $candidate_release == \
    "$REMOTE_CHROME_INSTALL_ROOT/releases/$SELECTED_VERSION" ]] || return 1
  [[ -d $candidate_release && ! -L $candidate_release ]] || return 1
  vm_require_management_destination "$candidate_release" || return 1
  rm -rf -- "$candidate_release"
}

vm_activate_backup_timer() {
  if [[ -n ${BACKUP_SCHEDULE:-} ]]; then
    vm_run_bounded systemctl enable --now remote-chrome-backup.timer
  else
    local timer="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"
    local timer_present=0 timer_enabled=0 timer_active=0
    [[ ! -e $timer ]] || timer_present=1
    if vm_run_bounded systemctl is-enabled --quiet \
      remote-chrome-backup.timer; then
      timer_enabled=1
    fi
    if vm_run_bounded systemctl is-active --quiet \
      remote-chrome-backup.timer; then
      timer_active=1
    fi
    if ((timer_present || timer_enabled || timer_active)); then
      vm_run_bounded systemctl disable --now remote-chrome-backup.timer ||
        return 1
    fi
    rm -f -- \
      "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service" \
      "$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer" || return 1
    vm_run_bounded systemctl daemon-reload
  fi
}

vm_rollback_release() {
  local previous_target=$1 snapshot=$2 candidate_release=$3
  local rollback_failed=0 prior_health_failed=0
  vm_stop_candidate_release "$candidate_release" || rollback_failed=1
  vm_run_service_control stop remote-chrome.service || rollback_failed=1
  vm_run_bounded systemctl disable remote-chrome.service || rollback_failed=1
  vm_run_bounded systemctl disable --now remote-chrome-backup.timer \
    >/dev/null 2>&1 || true

  if [[ -n $previous_target ]]; then
    vm_switch_current "$previous_target" || rollback_failed=1
  else
    rm -f -- "$REMOTE_CHROME_INSTALL_ROOT/current" || rollback_failed=1
  fi
  vm_restore_activation_state "$snapshot" || rollback_failed=1
  vm_run_bounded systemctl daemon-reload || rollback_failed=1

  if [[ -f $snapshot/service.enabled ]]; then
    vm_run_bounded systemctl enable remote-chrome.service ||
      rollback_failed=1
  fi
  if [[ -f $snapshot/service.active ]]; then
    vm_run_service_control start remote-chrome.service || rollback_failed=1
    if [[ -z $previous_target ]] || ! REMOTE_CHROME_ROLLBACK=1 \
      vm_wait_stack_health "$REMOTE_CHROME_INSTALL_ROOT/$previous_target"; then
      prior_health_failed=1
    fi
  fi
  if [[ -f $snapshot/backup-timer.enabled ]]; then
    vm_run_bounded systemctl enable remote-chrome-backup.timer ||
      rollback_failed=1
  fi
  if [[ -f $snapshot/backup-timer.active ]]; then
    vm_run_bounded systemctl start remote-chrome-backup.timer ||
      rollback_failed=1
  fi
  if ((prior_health_failed == 1)); then
    printf 'ERROR: rollback health verification failed\n' >&2
    return 70
  fi
  ((rollback_failed == 0)) || return 1
}

vm_activate_release() {
  local current="$REMOTE_CHROME_INSTALL_ROOT/current"
  local previous_target=
  local snapshot="$REMOTE_CHROME_CONFIG_ROOT/.rollback.$$"
  local candidate_release="$REMOTE_CHROME_INSTALL_ROOT/releases/$SELECTED_VERSION"
  local switched=0 installed_candidate=0 result=1 rollback_status=0
  local previous_version=
  VM_CANDIDATE_STOP_CONFIRMED=0

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
  if ! mv -T -- "$STAGED_RELEASE_DIR" "$candidate_release"; then
    rm -rf -- "$snapshot"
    return 1
  fi
  installed_candidate=1
  if ! vm_activation_transition release-installed ||
     ! vm_prepare_config ||
     ! vm_activation_transition candidate-config-written ||
     ! vm_validate_candidate_compose "$candidate_release" ||
     ! vm_activation_transition compose-config-validated; then
    if vm_stop_candidate_release "$candidate_release"; then
      vm_cleanup_candidate_config || true
      ((installed_candidate == 0)) ||
        vm_remove_candidate_release "$candidate_release" || true
    fi
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
     vm_run_bounded systemctl daemon-reload &&
     vm_activation_transition service-reloaded &&
     vm_run_service_control enable --now remote-chrome.service &&
     vm_activation_transition service-started &&
     vm_activation_transition health-verified &&
     vm_activation_transition public-verified &&
     { if [[ -n $previous_target ]]; then
         previous_version=${previous_target#releases/}
         vm_validate_release_ref "$previous_version" &&
           printf '%s\n' "$previous_version" |
             vm_write_secret_file \
               "$REMOTE_CHROME_CONFIG_ROOT/previous-version"
       else
         rm -f -- "$REMOTE_CHROME_CONFIG_ROOT/previous-version"
       fi; } &&
     printf '%s\n' "$SELECTED_VERSION" |
       vm_write_secret_file "$REMOTE_CHROME_CONFIG_ROOT/active-version" &&
     vm_activation_transition active-recorded &&
     vm_activate_backup_timer &&
     vm_activation_transition backup-timer-configured; then
    result=0
  fi

  if ((result != 0)); then
    if ((switched == 1)); then
      vm_rollback_release \
        "$previous_target" "$snapshot" "$candidate_release" ||
        rollback_status=$?
    else
      vm_stop_candidate_release "$candidate_release" || true
    fi
    if [[ ${VM_CANDIDATE_STOP_CONFIRMED:-0} == 1 ]]; then
      vm_cleanup_candidate_config || true
      ((installed_candidate == 0)) ||
        vm_remove_candidate_release "$candidate_release" || true
    fi
    rm -rf -- "$snapshot"
    [[ $rollback_status -eq 70 ]] && return 70
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
  local data_dir profile certificate_status certificate_issuer
  local certificate_expires certificate_state
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
  certificate_state="$REMOTE_CHROME_CONFIG_ROOT/certificate.env"
  [[ -f $certificate_state && ! -L $certificate_state ]] || return 1
  certificate_status=$(
    vm_read_env_value "$certificate_state" CERTIFICATE_STATUS
  ) || return 1
  certificate_issuer=$(
    vm_read_env_value "$certificate_state" CERTIFICATE_ISSUER
  ) || return 1
  certificate_expires=$(
    vm_read_env_value "$certificate_state" CERTIFICATE_EXPIRES
  ) || return 1
  [[ $certificate_status == ready ]] || return 1

  {
    printf '%s\n' \
      'Remote Chrome is ready.' \
      "Preferred MCP URL: $mcp_url" \
      "Authorization: Bearer $mcp_token" \
      "Compatibility MCP URL: $compatibility_url" \
      "Login URL: $login_url" \
      "Login username: $username" \
      "Login password: $password" \
      'Certificate: ready (public HTTPS verified during activation)' \
      "Certificate issuer: $certificate_issuer" \
      "Certificate expires: $certificate_expires" \
      'Credentials file: /etc/remote-chrome/credentials.env' \
      "Profile: $profile" \
      'Status: sudo remote-chrome status' \
      'Credentials: sudo remote-chrome credentials' \
      'Backup: sudo remote-chrome backup' \
      'Restore: sudo remote-chrome restore'
    printf '\nJSON client configuration:\n'
    printf '{\n  "mcpServers": {\n    "remote_chrome": {\n'
    printf '      "url": "%s",\n      "headers": {\n' "$mcp_url"
    printf '        "Authorization": "Bearer %s"\n' "$mcp_token"
    printf '      }\n    }\n  }\n}\n'
    printf '\nTOML client configuration:\n'
    printf '[mcp_servers.remote_chrome]\n'
    printf 'url = "%s"\n' "$mcp_url"
    printf 'headers = { Authorization = "Bearer %s" }\n' "$mcp_token"
  } >>"$tty"
}
