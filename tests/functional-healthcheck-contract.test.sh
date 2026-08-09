#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checker=$repo_dir/scripts/remote-chrome-functional-healthcheck.sh
installer=$repo_dir/scripts/install-functional-healthcheck.sh
doc=$repo_dir/docs/functional-healthcheck.md

fail() {
  printf 'functional healthcheck contract failed: %s\n' "$1" >&2
  exit 1
}

for file in "$checker" "$installer" "$doc"; do
  [[ -f $file && ! -L $file ]] || fail "missing regular file: $file"
done
bash -n "$checker" "$installer"

grep -Fq 'notifications/initialized' "$checker" ||
  fail 'checker must complete MCP initialization'
grep -Fq '"method":"tools/list"' "$checker" ||
  fail 'checker must discover tools'
grep -Fq '"name":"browser_snapshot"' "$checker" ||
  fail 'checker must execute a real browser snapshot'
grep -Fq -- '--request DELETE' "$checker" ||
  fail 'checker must explicitly delete its temporary MCP session'
# The literal runtime variable is the contract.
# shellcheck disable=SC2016
grep -Fq -- '--header "@$work_dir/session.headers"' "$checker" ||
  fail 'checker must keep the bearer token out of curl arguments'
grep -Fq "((8#\$credential_mode & 077) == 0)" "$checker" ||
  fail 'checker must correctly accept a root-only credential mode'
if grep -Eq 'systemctl[[:space:]]+restart|docker[[:space:]].*restart' "$checker"; then
  fail 'checker must remain alert-only'
fi

test_root=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -d $test_root && ! -L $test_root ]]; then
    find "$test_root" -depth -type f -delete
    find "$test_root" -depth -type d -empty -delete
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

"$installer" --test-root "$test_root" >/dev/null
service=$test_root/etc/systemd/system/remote-chrome-functional-healthcheck.service
timer=$test_root/etc/systemd/system/remote-chrome-functional-healthcheck.timer
installed_checker=$test_root/usr/local/libexec/remote-chrome-functional-healthcheck

[[ -x $installed_checker ]] || fail 'installer did not install the checker'
grep -Fq 'OnCalendar=hourly' "$timer" ||
  fail 'timer must run hourly by default'
grep -Fq 'Persistent=yes' "$timer" ||
  fail 'timer must catch up after downtime'
grep -Fq 'ProtectSystem=strict' "$service" ||
  fail 'service must use systemd filesystem hardening'
grep -Fq '/etc/remote-chrome/credentials.env' "$service" ||
  fail 'service must reference the managed credential file'

printf 'functional healthcheck contract passed\n'
