#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

bootstrap_parse_args() {
  domain=
  acme_email="${ACME_EMAIL:-}"
  while (($#)); do
    case "$1" in
      --domain)
        if (($# < 2)) || [[ -z "${2:-}" || "$2" == -* ]]; then
          printf 'ERROR: usage: %s [--domain DOMAIN|DOMAIN] [--email EMAIL]\n' \
            "$(basename "${BASH_SOURCE[0]}")" >&2
          return 64
        fi
        domain="$2"
        shift 2
        ;;
      --email)
        if (($# < 2)) || [[ -z "${2:-}" || "$2" == -* ]]; then
          printf 'ERROR: usage: %s [--domain DOMAIN|DOMAIN] [--email EMAIL]\n' \
            "$(basename "${BASH_SOURCE[0]}")" >&2
          return 64
        fi
        acme_email="$2"
        shift 2
        ;;
      --*)
        printf 'ERROR: usage: %s [--domain DOMAIN|DOMAIN] [--email EMAIL]\n' \
          "$(basename "${BASH_SOURCE[0]}")" >&2
        return 64
        ;;
      *)
        if [[ -n "$domain" ]]; then
          printf 'ERROR: usage: %s [--domain DOMAIN|DOMAIN] [--email EMAIL]\n' \
            "$(basename "${BASH_SOURCE[0]}")" >&2
          return 64
        fi
        domain="$1"
        shift
        ;;
    esac
  done
}

wait_for_service_health() {
  local service="$1"
  local deadline="$2"
  local container_id health

  while ((SECONDS < deadline)); do
    container_id="$("${compose[@]}" ps -q "$service")"
    if [[ -n "$container_id" ]]; then
      health="$(
        docker inspect --format \
          '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
          "$container_id" 2>/dev/null || true
      )"
      case "$health" in
        healthy)
          return 0
          ;;
        unhealthy)
          "${compose[@]}" logs "$service" >&2
          fail "$service container became unhealthy"
          ;;
      esac
    fi
    sleep 2
  done

  "${compose[@]}" logs "$service" >&2
  fail "Timed out waiting 120 seconds for $service health"
}

extract_mcp_session_id() {
  awk 'tolower($0) ~ /^mcp-session-id:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }' "$1"
}

bootstrap_main() {
  bootstrap_parse_args "$@" || return $?
  cd "$repo_dir"

  command -v docker >/dev/null 2>&1 || fail 'Docker is required'
  docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required'
  docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable'
  command -v openssl >/dev/null 2>&1 || fail 'openssl is required'

  if [[ -z "$domain" ]]; then
    read -r -p 'Public domain (for example chrome.example.com): ' domain
  fi
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
    fail 'Domain must be a hostname without a scheme, path, or port'

  if [[ -z "$acme_email" ]]; then
    read -r -p 'Certificate email: ' acme_email </dev/tty
  fi
  [[ $acme_email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    fail 'Certificate email is invalid'

  login_username="${LOGIN_USERNAME:-remotechrome}"
  [[ "$login_username" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail 'LOGIN_USERNAME contains unsupported characters'

  mcp_token="$(openssl rand -hex 32)"
  [[ ${#mcp_token} -eq 64 ]] || fail 'Failed to generate a 64-hex MCP token'

  login_password="$(openssl rand -base64 36 | tr '+/' '-_')"
  [[ ${#login_password} -eq 48 ]] ||
    fail 'Failed to generate a login password from 36 random bytes'

  login_password_hash="$(
    printf '%s' "$login_password" |
      docker run --rm -i caddy:2-alpine \
        caddy hash-password --algorithm bcrypt
  )"
  [[ -n "$login_password_hash" ]] || fail 'Caddy returned an empty password hash'
  if [[ "$login_password_hash" == *$'\n'* || "$login_password_hash" == *"'"* ]]; then
    fail 'Caddy password hash contains a newline or single quote'
  fi

  env_file="$repo_dir/.env"
  umask 077
  install -m 600 /dev/null "$env_file"
  {
    printf 'DOMAIN=%s\n' "$domain"
    printf 'ACME_EMAIL=%s\n' "$acme_email"
    printf 'MCP_TOKEN=%s\n' "$mcp_token"
    printf 'LOGIN_USERNAME=%s\n' "$login_username"
    printf "LOGIN_PASSWORD_HASH='%s'\n" "$login_password_hash"
    printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
    printf 'SCREEN_GEOMETRY=%s\n' "${SCREEN_GEOMETRY:-1440x900x24}"
  } >"$env_file"
  chmod 600 "$env_file"

  compose=(docker compose --env-file "$env_file")
  "${compose[@]}" config >/dev/null
  "${compose[@]}" up -d --build

  deadline=$((SECONDS + 120))
  wait_for_service_health browser "$deadline"
  wait_for_service_health proxy "$deadline"

  verification_dir="$(mktemp -d)"
  mcp_headers="$verification_dir/mcp.headers"
  mcp_body="$verification_dir/mcp.body"
  login_body="$verification_dir/login.html"
  mcp_session_id=
  cleanup_verification() {
    if [[ -n "$mcp_session_id" ]]; then
      curl --fail --silent --show-error --max-time 10 \
        --resolve "${domain}:443:127.0.0.1" \
        --request DELETE \
        --header "Authorization: Bearer $mcp_token" \
        --header "Mcp-Session-Id: $mcp_session_id" \
        "https://${domain}/mcp" >/dev/null 2>&1 || true
    fi
    rm -rf "$verification_dir"
  }
  trap cleanup_verification EXIT

  initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"docker-bootstrap","version":"1.0"}}}'
  mcp_code="$(
    curl --silent --show-error --max-time 15 \
      --resolve "${domain}:443:127.0.0.1" \
      --output "$mcp_body" \
      --dump-header "$mcp_headers" \
      --write-out '%{http_code}' \
      --request POST \
      --header "Authorization: Bearer $mcp_token" \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --data "$initialize_payload" \
      "https://${domain}/mcp"
  )"
  [[ "$mcp_code" == 200 ]] || fail "Authenticated public MCP returned HTTP $mcp_code"
  mcp_session_id="$(extract_mcp_session_id "$mcp_headers")"
  [[ -n "$mcp_session_id" ]] || fail 'Authenticated public MCP returned no session ID'
  curl --fail --silent --show-error --max-time 10 \
    --resolve "${domain}:443:127.0.0.1" \
    --request DELETE \
    --header "Authorization: Bearer $mcp_token" \
    --header "Mcp-Session-Id: $mcp_session_id" \
    "https://${domain}/mcp" >/dev/null
  mcp_session_id=
  grep -q 'REMOTE_CHROME_PLAYBOOK_VERSION=1' "$mcp_body" ||
    fail 'Authenticated public MCP response is missing the playbook marker'

  curl --fail --silent --show-error --max-time 15 \
    --resolve "${domain}:443:127.0.0.1" \
    --user "$login_username:$login_password" \
    --output "$login_body" \
    "https://${domain}/login/"
  grep -qi 'noVNC' "$login_body" ||
    fail 'Authenticated login-console response did not serve noVNC'

  trap - EXIT
  cleanup_verification

  printf '\nRemote Chrome is healthy.\n'
  printf 'MCP credentials are stored in %s (mode 600).\n' "$env_file"
  printf 'Preferred MCP endpoint: https://%s/mcp\n' "$domain"
  printf 'Authorization: Bearer <MCP_TOKEN from .env>\n'
  printf 'Compatibility endpoint: https://%s/<MCP_TOKEN from .env>/mcp\n' "$domain"
  printf 'Login URL: https://%s/login/\n' "$domain"
  printf 'Login username: %s\n' "$login_username"
  printf 'Login password (shown once): %s\n' "$login_password"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bootstrap_main "$@"
fi
