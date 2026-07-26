#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  grep -Eq -- "$pattern" "$file" || fail "$description"
}

parse_domain() {
  bash -c '
    source "$1"
    shift
    bootstrap_parse_args "$@"
    printf "%s" "$domain"
  ' _ "$repo_dir/scripts/bootstrap-docker.sh" "$@"
}

[[ "$(parse_domain --domain flag.example.test)" == flag.example.test ]] ||
  fail 'bootstrap must parse --domain DOMAIN'
[[ "$(parse_domain positional.example.test)" == positional.example.test ]] ||
  fail 'bootstrap must retain positional domain parsing'
[[ -z "$(parse_domain)" ]] ||
  fail 'bootstrap must leave the domain empty when prompt mode is needed'
if parse_domain --domain >/dev/null 2>&1; then
  fail 'bootstrap must reject --domain without a value'
fi
if parse_domain --domain=invalid.example.test >/dev/null 2>&1; then
  fail 'bootstrap must require exact --domain DOMAIN syntax'
fi
if parse_domain first.example.test second.example.test >/dev/null 2>&1; then
  fail 'bootstrap must reject extra positional arguments'
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/runtime"

cat >"$tmp_dir/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF

cat >"$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
output=
headers=
write_out=
session_id=
url=
while (($#)); do
  case "$1" in
    --request|-X)
      method="$2"
      shift 2
      ;;
    --output|-o)
      output="$2"
      shift 2
      ;;
    --dump-header|-D)
      headers="$2"
      shift 2
      ;;
    --write-out|-w)
      write_out="$2"
      shift 2
      ;;
    --header|-H)
      if [[ "$2" == Mcp-Session-Id:* ]]; then
        session_id="${2#Mcp-Session-Id: }"
      fi
      shift 2
      ;;
    --data|-d|--max-time)
      shift 2
      ;;
    --fail|--silent|--show-error|--fail-with-body)
      shift
      ;;
    http://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s %s session=%s\n' "$method" "$url" "$session_id" >>"$FAKE_CURL_LOG"
case "$url" in
  *:9222/json/version)
    printf '%s' '{"Browser":"Chrome/1","User-Agent":"Chrome/1"}'
    ;;
  *:8931/mcp)
    if [[ "$method" == POST ]]; then
      [[ -n "$headers" ]] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: cleanup-session\r\nContent-Type: application/json\r\n\r\n' >"$headers"
      [[ -n "$output" ]] && printf '%s' '{"result":{"instructions":"REMOTE_CHROME_PLAYBOOK_VERSION=1"}}' >"$output"
      [[ -n "$write_out" ]] && printf '200'
    elif [[ "$method" == DELETE ]]; then
      [[ "$session_id" == cleanup-session ]]
    else
      exit 1
    fi
    ;;
  *:6080/)
    [[ -n "$output" ]] && printf '%s' '<title>noVNC</title>' >"$output"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/curl" "$tmp_dir/bin/jq"

FAKE_CURL_LOG="$tmp_dir/curl.log" \
REMOTE_CHROME_RUNTIME_DIR="$tmp_dir/runtime" \
PATH="$tmp_dir/bin:$PATH" \
  bash docker/healthcheck.sh
grep -q '^DELETE http://127\.0\.0\.1:8931/mcp session=cleanup-session$' \
  "$tmp_dir/curl.log" ||
  fail 'recurring health check must close its initialized MCP session'

assert_contains compose.yaml \
  '\$\{PROXY_BIND_ADDRESS:-0\.0\.0\.0\}:\$\{PROXY_HTTP_PORT:-80\}:80' \
  'Compose HTTP publishing must be isolated-test overridable with production defaults'
assert_contains compose.yaml \
  '\$\{PROXY_BIND_ADDRESS:-0\.0\.0\.0\}:\$\{PROXY_HTTPS_PORT:-443\}:443' \
  'Compose HTTPS publishing must be isolated-test overridable with production defaults'
assert_contains compose.yaml 'http://127\.0\.0\.1/healthz' \
  'Compose must define a proxy readiness health check'

assert_contains tests/compose-smoke.test.sh 'PROXY_BIND_ADDRESS=127\.0\.0\.1' \
  'smoke test must isolate proxy publishing on loopback'
assert_contains tests/compose-smoke.test.sh 'PROXY_HTTP_PORT=' \
  'smoke test must allocate an isolated HTTP host port'
assert_contains tests/compose-smoke.test.sh 'PROXY_HTTPS_PORT=' \
  'smoke test must allocate an isolated HTTPS host port'
assert_contains tests/compose-smoke.test.sh 'wait_for_healthy browser' \
  'smoke test must wait for browser health'
assert_contains tests/compose-smoke.test.sh 'wait_for_healthy proxy' \
  'smoke test must wait for proxy health'
assert_contains tests/compose-smoke.test.sh 'Authorization: Bearer' \
  'smoke test must exercise bearer authentication'
assert_contains tests/compose-smoke.test.sh '/\$\{MCP_TOKEN\}/mcp|token_url' \
  'smoke test must exercise the token-path endpoint'
assert_contains tests/compose-smoke.test.sh 'content-type' \
  'smoke test must count upstream Content-Type headers'
assert_contains tests/compose-smoke.test.sh 'Mcp-Session-Id' \
  'smoke test must capture and close public MCP sessions'
assert_contains tests/compose-smoke.test.sh 'expected 405|== 405' \
  'smoke test must verify authenticated GET is 405'
assert_contains tests/compose-smoke.test.sh 'expected 401|== 401' \
  'smoke test must verify unauthenticated routes are 401'
assert_contains tests/compose-smoke.test.sh 'Upgrade: websocket' \
  'smoke test must verify the authenticated noVNC WebSocket upgrade'

assert_contains scripts/bootstrap-docker.sh 'wait_for_service_health.*browser|wait_for_healthy.*browser' \
  'bootstrap must wait for browser health'
assert_contains scripts/bootstrap-docker.sh 'wait_for_service_health.*proxy|wait_for_healthy.*proxy' \
  'bootstrap must wait for proxy health'
assert_contains scripts/bootstrap-docker.sh 'Authorization: Bearer' \
  'bootstrap must make an authenticated public MCP request'
assert_contains scripts/bootstrap-docker.sh '/login/' \
  'bootstrap must make an authenticated login-console request'

printf 'PASS: Docker fix round 1 contracts\n'
