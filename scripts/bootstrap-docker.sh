#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail 'Docker is required'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable'
command -v openssl >/dev/null 2>&1 || fail 'openssl is required'

domain="${1:-}"
if [[ -z "$domain" ]]; then
  read -r -p 'Public domain (for example chrome.example.com): ' domain
fi
[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
  fail 'Domain must be a hostname without a scheme, path, or port'

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
  printf 'MCP_TOKEN=%s\n' "$mcp_token"
  printf 'LOGIN_USERNAME=%s\n' "$login_username"
  printf "LOGIN_PASSWORD_HASH='%s'\n" "$login_password_hash"
  printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
  printf 'SCREEN_GEOMETRY=%s\n' "${SCREEN_GEOMETRY:-1440x900x24}"
} >"$env_file"
chmod 600 "$env_file"

docker compose --env-file "$env_file" config >/dev/null
docker compose --env-file "$env_file" up -d --build

browser_id="$(docker compose --env-file "$env_file" ps -q browser)"
[[ -n "$browser_id" ]] || fail 'Browser container was not created'

deadline=$((SECONDS + 120))
while ((SECONDS < deadline)); do
  health="$(
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "$browser_id" 2>/dev/null || true
  )"
  case "$health" in
    healthy)
      break
      ;;
    unhealthy)
      docker compose --env-file "$env_file" logs browser >&2
      fail 'Browser container became unhealthy'
      ;;
  esac
  sleep 2
done

health="$(
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
    "$browser_id" 2>/dev/null || true
)"
if [[ "$health" != healthy ]]; then
  docker compose --env-file "$env_file" logs browser >&2
  fail 'Timed out waiting 120 seconds for browser health'
fi

printf '\nRemote Chrome is healthy.\n'
printf 'MCP credentials are stored in %s (mode 600).\n' "$env_file"
printf 'Preferred MCP endpoint: https://%s/mcp\n' "$domain"
printf 'Authorization: Bearer <MCP_TOKEN from .env>\n'
printf 'Compatibility endpoint: https://%s/<MCP_TOKEN from .env>/mcp\n' "$domain"
printf 'Login URL: https://%s/login/\n' "$domain"
printf 'Login username: %s\n' "$login_username"
printf 'Login password (shown once): %s\n' "$login_password"
