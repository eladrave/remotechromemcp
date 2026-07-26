#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

docker_available=true
if ! command -v docker >/dev/null 2>&1 ||
  ! docker compose version >/dev/null 2>&1 ||
  ! docker info >/dev/null 2>&1; then
  docker_available=false
fi

if [[ "$docker_available" != true ]]; then
  if [[ "${CI:-}" == 1 ]]; then
    fail 'Docker with Compose v2 is required in CI'
  fi
  printf 'SKIP: Docker unavailable; Compose runtime smoke test not run\n'
  exit 0
fi

tmp_dir="$(mktemp -d)"
project_name="remote-chrome-smoke-$(date +%s)-$$"
env_file="$tmp_dir/compose.env"
sentinel='.compose-smoke-profile-sentinel'

cleanup() {
  docker compose --project-name "$project_name" --env-file "$env_file" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"$env_file" <<'EOF'
DOMAIN=chrome.example.test
MCP_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
LOGIN_USERNAME=smokeoperator
LOGIN_PASSWORD_HASH='$2a$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234'
PLAYWRIGHT_MCP_VERSION=0.0.78
SCREEN_GEOMETRY=1280x800x24
EOF

compose=(
  docker compose
  --project-name "$project_name"
  --env-file "$env_file"
)

container_id() {
  "${compose[@]}" ps -q browser
}

wait_for_healthy() {
  local deadline=$((SECONDS + 120))
  local id health
  while ((SECONDS < deadline)); do
    id="$(container_id)"
    if [[ -n "$id" ]]; then
      health="$(
        docker inspect --format \
          '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
          "$id" 2>/dev/null || true
      )"
      case "$health" in
        healthy)
          return 0
          ;;
        unhealthy)
          "${compose[@]}" logs browser >&2
          fail 'browser became unhealthy'
          ;;
      esac
    fi
    sleep 2
  done
  "${compose[@]}" logs browser >&2
  fail 'timed out waiting 120 seconds for browser health'
}

"${compose[@]}" up -d --build browser
wait_for_healthy

"${compose[@]}" exec -T browser bash -euo pipefail -c '
  metadata="$(curl -fsS http://127.0.0.1:9222/json/version)"
  printf "%s" "$metadata" | jq -e \
    '"'"'(.Browser | startswith("Chrome/")) and
     (."User-Agent" | contains("HeadlessChrome") | not)'"'"' >/dev/null

  payload='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compose-smoke","version":"1.0"}}}'"'"'
  body="$(mktemp)"
  trap '"'"'rm -f "$body"'"'"' EXIT
  code="$(curl -sS -o "$body" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    --data "$payload" http://127.0.0.1:8931/mcp)"
  [[ "$code" == 200 ]]
  grep -q "REMOTE_CHROME_PLAYBOOK_VERSION=1" "$body"
  curl -fsS http://127.0.0.1:6080/ | grep -qi "noVNC"
'

"${compose[@]}" exec -T browser \
  sh -c "printf '%s\n' compose-smoke >'/data/chrome-profile/$sentinel'"

"${compose[@]}" up -d --force-recreate --no-deps browser
wait_for_healthy

"${compose[@]}" exec -T browser \
  grep -qx compose-smoke "/data/chrome-profile/$sentinel"

browser_id="$(container_id)"
[[ -n "$browser_id" ]] || fail 'browser container is missing after recreation'
port_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$browser_id")"
published_ports="$(docker port "$browser_id" || true)"
for port in 5900 6080 8931 9222; do
  if [[ "$port_bindings" == *"\"${port}/tcp\""* ||
    "$published_ports" == *"${port}/tcp"* ]]; then
    fail "private port $port was published to the host"
  fi
done

printf 'PASS: Compose browser runtime and profile persistence\n'
