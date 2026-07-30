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

allocate_port() {
  node - <<'NODE'
const net = require('node:net');
const server = net.createServer();
server.listen(0, '127.0.0.1', () => {
  process.stdout.write(String(server.address().port));
  server.close();
});
NODE
}

tmp_dir="$(mktemp -d)"
project_name="remote-chrome-smoke-$(date +%s)-$$"
env_file="$tmp_dir/compose.env"
sentinel='.compose-smoke-profile-sentinel'
MCP_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
LOGIN_TOKEN=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
LOGIN_USERNAME=smokeoperator
LOGIN_PASSWORD=hiccup
http_port="$(allocate_port)"
https_port="$(allocate_port)"
while [[ "$https_port" == "$http_port" ]]; do
  https_port="$(allocate_port)"
done

cleanup() {
  docker compose --project-name "$project_name" --env-file "$env_file" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

{
  printf 'DOMAIN=localhost\n'
  printf 'ACME_EMAIL=admin@example.test\n'
  printf 'MCP_TOKEN=%s\n' "$MCP_TOKEN"
  printf 'LOGIN_TOKEN=%s\n' "$LOGIN_TOKEN"
  printf 'LOGIN_USERNAME=%s\n' "$LOGIN_USERNAME"
  printf '%s\n' \
    "LOGIN_PASSWORD_HASH='\$2a\$14\$Zkx19XLiW6VYouLHR5NmfOFU0z2GTNmpkT/5qqR7hx4IjWJPDhjvG'"
  printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
  printf 'SCREEN_GEOMETRY=1280x800x24\n'
  printf 'PROXY_BIND_ADDRESS=127.0.0.1\n'
  printf 'PROXY_HTTP_PORT=%s\n' "$http_port"
  printf 'PROXY_HTTPS_PORT=%s\n' "$https_port"
} >"$env_file"

compose=(
  docker compose
  --project-name "$project_name"
  --env-file "$env_file"
)

container_id() {
  "${compose[@]}" ps -q "$1"
}

wait_for_healthy() {
  local service="$1"
  local deadline=$((SECONDS + 120))
  local id health
  while ((SECONDS < deadline)); do
    id="$(container_id "$service")"
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
          "${compose[@]}" logs "$service" >&2
          fail "$service became unhealthy"
          ;;
      esac
    fi
    sleep 2
  done
  "${compose[@]}" logs "$service" >&2
  fail "timed out waiting 120 seconds for $service health"
}

"${compose[@]}" up -d --build
wait_for_healthy browser
wait_for_healthy proxy

"${compose[@]}" exec -T browser bash -euo pipefail -c '
  metadata="$(curl -fsS http://127.0.0.1:9222/json/version)"
  printf "%s" "$metadata" | jq -e \
    '"'"'(.Browser | startswith("Chrome/")) and
     (."User-Agent" | contains("HeadlessChrome") | not)'"'"' >/dev/null

  payload='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compose-smoke-internal","version":"1.0"}}}'"'"'
  body="$(mktemp)"
  headers="$(mktemp)"
  session_id=
  cleanup_internal() {
    if [[ -n "$session_id" ]]; then
      curl -fsS -X DELETE -H "Mcp-Session-Id: $session_id" \
        http://127.0.0.1:8931/mcp >/dev/null 2>&1 || true
    fi
    rm -f "$body" "$headers"
  }
  trap cleanup_internal EXIT

  code="$(curl -sS -o "$body" -D "$headers" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    --data "$payload" http://127.0.0.1:8931/mcp)"
  [[ "$code" == 200 ]]
  session_id="$(
    grep -i "^Mcp-Session-Id:" "$headers" |
      head -n 1 |
      cut -d: -f2- |
      tr -d "\r" |
      xargs
  )"
  [[ -n "$session_id" ]]
  curl -fsS -X DELETE -H "Mcp-Session-Id: $session_id" \
    http://127.0.0.1:8931/mcp >/dev/null
  session_id=
  grep -q "REMOTE_CHROME_PLAYBOOK_VERSION=1" "$body"
  curl -fsS http://127.0.0.1:6080/ | grep -qi "noVNC"
'

"${compose[@]}" exec -T browser \
  sh -c "printf '%s\n' compose-smoke >'/data/chrome-profile/$sentinel'"

"${compose[@]}" exec -T \
  --env NODE_PATH=/usr/local/lib/node_modules/@playwright/mcp/node_modules \
  browser node <<'NODE'
const http = require('node:http');
const { chromium } = require('playwright-core');

(async () => {
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html' });
    response.end('<!doctype html><title>Profile persistence probe</title>');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(18080, '127.0.0.1', resolve);
  });
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const [context] = browser.contexts();
  if (!context) throw new Error('persistent Chrome context is missing');
  const page = await context.newPage();
  await page.goto('http://127.0.0.1:18080/');
  await page.evaluate(() => {
    document.cookie =
      'remote_chrome_persistence_probe=survives-recreation; ' +
      'Max-Age=3600; Path=/; SameSite=Lax';
  });
  const cookies = await context.cookies('http://127.0.0.1:18080/');
  const probe = cookies.find(
    cookie => cookie.name === 'remote_chrome_persistence_probe',
  );
  if (!probe || probe.value !== 'survives-recreation') {
    throw new Error('persistent Chrome cookie was not created');
  }
  await page.close();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  // Chrome's network service commits durable cookies asynchronously. The
  // production container stays running, so allow that normal commit window
  // before simulating a later restart.
  await new Promise(resolve => setTimeout(resolve, 35000));
  process.exit(0);
})().catch(error => {
  console.error(error);
  process.exit(1);
});
NODE

"${compose[@]}" up -d --force-recreate --no-deps browser
wait_for_healthy browser
wait_for_healthy proxy

"${compose[@]}" exec -T browser \
  grep -qx compose-smoke "/data/chrome-profile/$sentinel"

"${compose[@]}" exec -T \
  --env NODE_PATH=/usr/local/lib/node_modules/@playwright/mcp/node_modules \
  browser node <<'NODE'
const { chromium } = require('playwright-core');

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const [context] = browser.contexts();
  if (!context) throw new Error('persistent Chrome context is missing');
  const cookies = await context.cookies('http://127.0.0.1:18080/');
  const probe = cookies.find(
    cookie => cookie.name === 'remote_chrome_persistence_probe',
  );
  if (!probe || probe.value !== 'survives-recreation') {
    throw new Error('persistent Chrome cookie did not survive recreation');
  }
  process.exit(0);
})().catch(error => {
  console.error(error);
  process.exit(1);
});
NODE

curl_https=(
  curl
  --insecure
  --silent
  --show-error
  --resolve "localhost:${https_port}:127.0.0.1"
)
base_url="https://localhost:${https_port}"
initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compose-smoke-public","version":"1.0"}}}'

unauth_mcp_code="$(
  "${curl_https[@]}" --output /dev/null --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data "$initialize_payload" \
    "$base_url/mcp"
)"
[[ "$unauth_mcp_code" == 401 ]] ||
  fail "unauthenticated /mcp expected 401, got $unauth_mcp_code"

initialize_and_close() {
  local url="$1"
  shift
  local headers body code content_type_count session_id
  local tools_body handoff_body novnc_alias_body rejected_body
  headers="$(mktemp "$tmp_dir/public-headers.XXXXXX")"
  body="$(mktemp "$tmp_dir/public-body.XXXXXX")"
  tools_body="$(mktemp "$tmp_dir/public-tools.XXXXXX")"
  handoff_body="$(mktemp "$tmp_dir/public-handoff.XXXXXX")"
  novnc_alias_body="$(mktemp "$tmp_dir/public-novnc-alias.XXXXXX")"
  rejected_body="$(mktemp "$tmp_dir/public-handoff-rejected.XXXXXX")"

  code="$(
    "${curl_https[@]}" \
      --output "$body" \
      --dump-header "$headers" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --data "$initialize_payload" \
      "$@" \
      "$url"
  )"
  [[ "$code" == 200 ]] || fail "public initialize expected 200, got $code"
  session_id="$(
    awk 'tolower($0) ~ /^mcp-session-id:/ {
        sub(/^[^:]+:[[:space:]]*/, "")
        sub(/\r$/, "")
        print
        exit
      }' "$headers"
  )"
  [[ -n "$session_id" ]] || fail 'public initialize returned no Mcp-Session-Id'

  code="$(
    "${curl_https[@]}" \
      --output "$tools_body" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --header "Mcp-Session-Id: $session_id" \
      --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      "$@" \
      "$url"
  )"
  [[ "$code" == 200 ]] || fail "public tools/list expected 200, got $code"
  grep -Fq 'remote_chrome_request_human_intervention' "$tools_body" ||
    fail 'public tools/list omitted the human-intervention handoff tool'
  grep -Fq 'get_novnc_link' "$tools_body" ||
    fail 'public tools/list omitted the noVNC-link alias'

  code="$(
    "${curl_https[@]}" \
      --output "$handoff_body" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --header "Mcp-Session-Id: $session_id" \
      --data '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remote_chrome_request_human_intervention","arguments":{}}}' \
      "$@" \
      "$url"
  )"
  [[ "$code" == 200 ]] ||
    fail "public human-intervention tool expected 200, got $code"
  grep -Fq "https://localhost/login/?token=$LOGIN_TOKEN" "$handoff_body" ||
    fail 'human-intervention tool did not return the configured protected URL'
  grep -Fq 'password-equivalent secret' "$handoff_body" ||
    fail 'human-intervention tool omitted its secret-handling warning'

  code="$(
    "${curl_https[@]}" \
      --output "$novnc_alias_body" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --header "Mcp-Session-Id: $session_id" \
      --data '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_novnc_link","arguments":{}}}' \
      "$@" \
      "$url"
  )"
  [[ "$code" == 200 ]] ||
    fail "public get_novnc_link tool expected 200, got $code"
  grep -Fq "https://localhost/login/?token=$LOGIN_TOKEN" \
    "$novnc_alias_body" ||
    fail 'get_novnc_link did not return the configured protected URL'
  grep -Fq 'Human intervention is required' "$novnc_alias_body" ||
    fail 'get_novnc_link omitted the user-intervention instruction'

  code="$(
    "${curl_https[@]}" \
      --output "$rejected_body" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --header "Mcp-Session-Id: $session_id" \
      --data '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"remote_chrome_request_human_intervention","arguments":{"password":"must-not-be-echoed"}}}' \
      "$@" \
      "$url"
  )"
  [[ "$code" == 200 ]] ||
    fail "public rejected handoff arguments expected HTTP 200, got $code"
  grep -Fq '"isError":true' "$rejected_body" ||
    fail 'human-intervention tool must reject nonempty arguments'
  if grep -Fq 'must-not-be-echoed' "$rejected_body"; then
    fail 'human-intervention tool echoed rejected credential data'
  fi

  "${curl_https[@]}" --fail \
    --request DELETE \
    --header "Mcp-Session-Id: $session_id" \
    "$@" \
    "$url" >/dev/null
  grep -q 'REMOTE_CHROME_PLAYBOOK_VERSION=1' "$body" ||
    fail 'public initialize response is missing playbook instructions'
  content_type_count="$(
    awk 'BEGIN { count=0 }
      tolower($0) ~ /^content-type:/ { count += 1 }
      END { print count }' "$headers"
  )"
  [[ "$content_type_count" == 1 ]] ||
    fail "public initialize expected exactly one content-type, got $content_type_count"
}

initialize_and_close "$base_url/mcp" \
  --header "Authorization: Bearer $MCP_TOKEN"
token_url="$base_url/${MCP_TOKEN}/mcp"
initialize_and_close "$token_url"
node tests/mcp-session-regression.cjs \
  --endpoint "$token_url" \
  --wait-seconds 35 \
  --timeout-seconds 60 \
  --insecure

get_code="$(
  "${curl_https[@]}" --output /dev/null --write-out '%{http_code}' \
    --request GET \
    --header "Authorization: Bearer $MCP_TOKEN" \
    "$base_url/mcp"
)"
[[ "$get_code" == 405 ]] ||
  fail "authenticated GET expected 405, got $get_code"

login_unauth_code="$(
  "${curl_https[@]}" --output /dev/null --write-out '%{http_code}' \
    "$base_url/login/"
)"
[[ "$login_unauth_code" == 401 ]] ||
  fail "unauthenticated /login/ expected 401, got $login_unauth_code"

invalid_login_token_code="$(
  "${curl_https[@]}" --output /dev/null --write-out '%{http_code}' \
    "$base_url/login/?token=invalid"
)"
[[ "$invalid_login_token_code" == 401 ]] ||
  fail "invalid one-click login token expected 401, got $invalid_login_token_code"

login_token_headers="$tmp_dir/login-token.headers"
login_token_cookies="$tmp_dir/login-token.cookies"
login_token_code="$(
  "${curl_https[@]}" \
    --output /dev/null \
    --dump-header "$login_token_headers" \
    --cookie-jar "$login_token_cookies" \
    --write-out '%{http_code}' \
    "$base_url/login/?token=$LOGIN_TOKEN"
)"
[[ "$login_token_code" == 303 ]] ||
  fail "valid one-click login token expected 303, got $login_token_code"
tr -d '\r' <"$login_token_headers" |
  grep -Eiq '^Location:[[:space:]]*/login/[[:space:]]*$' ||
  fail 'one-click login must redirect to a clean /login/ URL'
tr -d '\r' <"$login_token_headers" |
  grep -Eiq '^Cache-Control:[[:space:]]*no-store[[:space:]]*$' ||
  fail 'one-click login response must disable caching'
tr -d '\r' <"$login_token_headers" |
  grep -Eiq '^Referrer-Policy:[[:space:]]*no-referrer[[:space:]]*$' ||
  fail 'one-click login response must suppress referrer disclosure'
tr -d '\r' <"$login_token_headers" |
  grep -Eiq '^Set-Cookie: remote_chrome_login=.*HttpOnly; Secure; SameSite=Strict' ||
  fail 'one-click login cookie must be HttpOnly, Secure, and SameSite=Strict'

login_token_body="$tmp_dir/login-token.html"
login_token_session_code="$(
  "${curl_https[@]}" \
    --output "$login_token_body" \
    --cookie "$login_token_cookies" \
    --write-out '%{http_code}' \
    "$base_url/login/"
)"
[[ "$login_token_session_code" == 200 ]] ||
  fail "one-click login cookie expected 200, got $login_token_session_code"
grep -qi 'noVNC' "$login_token_body" ||
  fail 'one-click login cookie did not serve noVNC'

login_body="$tmp_dir/login.html"
login_code="$(
  "${curl_https[@]}" --location \
    --output "$login_body" --write-out '%{http_code}' \
    --user "$LOGIN_USERNAME:$LOGIN_PASSWORD" \
    "$base_url/login/"
)"
[[ "$login_code" == 200 ]] ||
  fail "authenticated /login/ expected 200, got $login_code"
grep -qi 'noVNC' "$login_body" ||
  fail 'authenticated /login/ did not serve noVNC'

login_ui="$tmp_dir/ui.js"
"${curl_https[@]}" --fail \
  --cookie "$login_token_cookies" \
  --output "$login_ui" \
  "$base_url/login/app/ui.js"
websocket_path="$(
  sed -n \
    "s/.*UI\\.initSetting('path', '\\([^']*\\)').*/\\1/p" \
    "$login_ui" |
    head -n 1
)"
[[ -n "$websocket_path" ]] ||
  fail 'authenticated noVNC UI did not define a WebSocket path'
[[ "$websocket_path" == /* ]] || websocket_path="/$websocket_path"

websocket_headers="$tmp_dir/websocket.headers"
websocket_curl_status=0
"${curl_https[@]}" --http1.1 --max-time 3 \
  --output /dev/null \
  --dump-header "$websocket_headers" \
  --cookie "$login_token_cookies" \
  --header 'Connection: Upgrade' \
  --header 'Upgrade: websocket' \
  --header 'Sec-WebSocket-Version: 13' \
  --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$base_url$websocket_path" ||
  websocket_curl_status=$?
grep -Eq '^HTTP/[^ ]+ 101([[:space:]]|$)' "$websocket_headers" ||
  fail 'authenticated noVNC WebSocket expected 101'
[[ "$websocket_curl_status" == 0 ||
   "$websocket_curl_status" == 23 ||
   "$websocket_curl_status" == 28 ]] ||
  fail "authenticated WebSocket curl failed with $websocket_curl_status"

for id in $("${compose[@]}" ps -q); do
  published_ports="$(
    docker inspect --format \
      '{{range $port, $bindings := .NetworkSettings.Ports}}{{if $bindings}}{{$port}} {{end}}{{end}}' \
      "$id"
  )"
  for port in 5900 6080 8931 9222; do
    if [[ "$published_ports" == *"${port}/tcp"* ]]; then
      fail "private port $port was published to the host"
    fi
  done
done

printf 'PASS: Compose full-stack runtime, routing, and profile persistence\n'
