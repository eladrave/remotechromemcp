#!/usr/bin/env bash
set -euo pipefail

credentials_file=/etc/remote-chrome/credentials.env
lock_file=/run/lock/remote-chrome-functional-healthcheck.lock

usage() {
  cat <<'EOF'
Usage: remote-chrome-functional-healthcheck [options]

Options:
  --credentials-file PATH  Root-only env file containing MCP_URL and MCP_TOKEN.
  --lock-file PATH         Non-secret lock file used to prevent overlapping runs.
  -h, --help               Show this help text.
EOF
}

fail() {
  printf 'remote-chrome functional healthcheck failed: %s\n' "$1" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --credentials-file)
      (($# >= 2)) || fail 'missing value for --credentials-file'
      credentials_file=$2
      shift 2
      ;;
    --lock-file)
      (($# >= 2)) || fail 'missing value for --lock-file'
      lock_file=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for command_name in awk curl flock jq mktemp stat; do
  command -v "$command_name" >/dev/null ||
    fail "required command is unavailable: $command_name"
done

[[ $EUID -eq 0 ]] || fail 'must run as root'
[[ $credentials_file == /* && $lock_file == /* ]] ||
  fail 'credential and lock paths must be absolute'
[[ -f $credentials_file && ! -L $credentials_file ]] ||
  fail 'credential file is missing or is not a regular file'
[[ $(stat -c '%u' -- "$credentials_file") == 0 ]] ||
  fail 'credential file must be owned by root'
credential_mode=$(stat -c '%a' -- "$credentials_file")
(((8#$credential_mode & 077) == 0)) ||
  fail 'credential file must not be readable by group or other users'

read_env_value() {
  local key=$1
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      value = substr($0, length(wanted) + 2)
      if (value ~ /^\047.*\047$/ || value ~ /^".*"$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$credentials_file"
}

mcp_url=$(read_env_value MCP_URL)
mcp_token=$(read_env_value MCP_TOKEN)
[[ $mcp_url =~ ^https://[^[:space:]]+/mcp$ ]] ||
  fail 'MCP_URL is missing or invalid'
[[ $mcp_token =~ ^[0-9a-f]{64}$ ]] ||
  fail 'MCP_TOKEN is missing or invalid'

install -d -m 0755 -- "${lock_file%/*}"
exec 9>"$lock_file"
flock --nonblock 9 || {
  printf 'remote-chrome functional healthcheck skipped: another run is active\n'
  exit 0
}

umask 077
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/remote-chrome-functional-health.XXXXXX")
session_id=

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n $session_id && -f $work_dir/session.headers ]]; then
    curl --fail --silent --show-error --max-time 10 \
      --request DELETE \
      --header "@$work_dir/session.headers" \
      "$mcp_url" >/dev/null 2>&1 || true
  fi
  if [[ -d $work_dir && ! -L $work_dir ]]; then
    find "$work_dir" -mindepth 1 -maxdepth 1 -type f -delete
    rmdir "$work_dir"
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

printf 'Authorization: Bearer %s\n' "$mcp_token" >"$work_dir/auth.headers"

normalize_response() {
  local source=$1 destination=$2
  if jq -e . "$source" >"$destination" 2>/dev/null; then
    return 0
  fi
  awk '/^data:[[:space:]]*/ {
    sub(/^data:[[:space:]]*/, "")
    print
  }' "$source" |
    jq -s -e 'map(select(type == "object" and .jsonrpc == "2.0")) | last' \
      >"$destination" 2>/dev/null
}

initialize_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"remote-chrome-functional-healthcheck","version":"1"}}}'
initialize_code=$(
  curl --silent --show-error --max-time 25 \
    --request POST \
    --header "@$work_dir/auth.headers" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data-binary "$initialize_payload" \
    --dump-header "$work_dir/initialize.headers" \
    --output "$work_dir/initialize.body" \
    --write-out '%{http_code}' \
    "$mcp_url"
) || fail 'initialize request failed'
[[ $initialize_code == 200 ]] || fail "initialize returned HTTP $initialize_code"
session_id=$(
  awk 'BEGIN { IGNORECASE=1 } /^Mcp-Session-Id:/ {
    sub(/^[^:]*:[[:space:]]*/, "")
    sub(/\r$/, "")
    print
    exit
  }' "$work_dir/initialize.headers"
)
[[ -n $session_id && $session_id != *$'\n'* ]] ||
  fail 'initialize returned no valid MCP session ID'
{
  printf 'Authorization: Bearer %s\n' "$mcp_token"
  printf 'Mcp-Session-Id: %s\n' "$session_id"
} >"$work_dir/session.headers"
normalize_response "$work_dir/initialize.body" "$work_dir/initialize.json" ||
  fail 'initialize returned an invalid MCP response'
jq -e '.result.protocolVersion and (.error == null)' \
  "$work_dir/initialize.json" >/dev/null ||
  fail 'initialize returned an MCP error'

initialized_code=$(
  curl --silent --show-error --max-time 10 \
    --request POST \
    --header "@$work_dir/session.headers" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data-binary \
      '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    --output "$work_dir/initialized.body" \
    --write-out '%{http_code}' \
    "$mcp_url"
) || fail 'initialized notification failed'
[[ $initialized_code == 200 || $initialized_code == 202 ||
   $initialized_code == 204 ]] ||
  fail "initialized notification returned HTTP $initialized_code"

tools_code=$(
  curl --silent --show-error --max-time 20 \
    --request POST \
    --header "@$work_dir/session.headers" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data-binary \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    --output "$work_dir/tools.body" \
    --write-out '%{http_code}' \
    "$mcp_url"
) || fail 'tools/list request failed'
[[ $tools_code == 200 ]] || fail "tools/list returned HTTP $tools_code"
normalize_response "$work_dir/tools.body" "$work_dir/tools.json" ||
  fail 'tools/list returned an invalid MCP response'
jq -e '.error == null and any(.result.tools[]?; .name == "browser_snapshot")' \
  "$work_dir/tools.json" >/dev/null ||
  fail 'tools/list omitted browser_snapshot or returned an MCP error'

snapshot_code=$(
  curl --silent --show-error --max-time 30 \
    --request POST \
    --header "@$work_dir/session.headers" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --data-binary \
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' \
    --output "$work_dir/snapshot.body" \
    --write-out '%{http_code}' \
    "$mcp_url"
) || fail 'browser_snapshot request failed'
[[ $snapshot_code == 200 ]] ||
  fail "browser_snapshot returned HTTP $snapshot_code"
normalize_response "$work_dir/snapshot.body" "$work_dir/snapshot.json" ||
  fail 'browser_snapshot returned an invalid MCP response'
jq -e '
  .error == null and
  (.result.isError // false | not) and
  (.result.content | type == "array") and
  ([.result.content[]? | select(.type == "text") | .text] | join("") |
    startswith("### Error") | not)
' "$work_dir/snapshot.json" >/dev/null ||
  fail 'browser_snapshot returned a tool error'

delete_code=$(
  curl --silent --show-error --max-time 10 \
    --request DELETE \
    --header "@$work_dir/session.headers" \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$mcp_url"
) || fail 'session DELETE request failed'
[[ $delete_code == 200 || $delete_code == 202 || $delete_code == 204 ]] ||
  fail "session DELETE returned HTTP $delete_code"
session_id=

printf 'remote-chrome functional healthcheck passed: initialize, tools/list, browser_snapshot, DELETE\n'
