#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for file in vminstall/compose.vm.yaml compose.yaml Caddyfile; do
  [[ -f "$file" ]] || fail "required file missing: $file"
done

grep -Fq 'ACME_EMAIL' Caddyfile ||
  fail 'Caddyfile must configure the ACME email'
grep -Fq 'REMOTE_CHROME_DATA_DIR' vminstall/compose.vm.yaml ||
  fail 'VM override must consume REMOTE_CHROME_DATA_DIR'
grep -Fq '/data/chrome-profile' vminstall/compose.vm.yaml ||
  fail 'VM override must replace the Chrome profile mount'
grep -Fq '/data' vminstall/compose.vm.yaml ||
  fail 'VM override must replace Caddy data storage'
grep -Fq '/config' vminstall/compose.vm.yaml ||
  fail 'VM override must replace Caddy config storage'

if command -v docker >/dev/null 2>&1 &&
   docker compose version >/dev/null 2>&1; then
  env_file="$(mktemp)"
  trap 'rm -f "$env_file"' EXIT
  hash='$2a$14$TRf6ynPaHFGoGIzGbRPBMumKVsUbVexXBXaVlsN0t6s/6MwOe5FMe'
  {
    printf 'DOMAIN=chrome.example.com\n'
    printf 'ACME_EMAIL=admin@example.com\n'
    printf 'MCP_TOKEN=%s\n' "$(printf 'a%.0s' {1..64})"
    printf 'LOGIN_USERNAME=remotechrome\n'
    printf "LOGIN_PASSWORD_HASH='%s'\n" "$hash"
    printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
    printf 'SCREEN_GEOMETRY=1440x900x24\n'
    printf 'REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome\n'
  } >"$env_file"
  docker compose -f compose.yaml -f vminstall/compose.vm.yaml \
    --env-file "$env_file" config >/dev/null
else
  printf 'SKIP: Docker Compose unavailable; rendered overlay checked in CI\n'
fi
