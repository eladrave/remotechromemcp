#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
test_repo="$tmp_dir/repo"
fake_bin="$tmp_dir/bin"
mkdir -p "$test_repo/scripts" "$fake_bin"
cp scripts/bootstrap-docker.sh "$test_repo/scripts/bootstrap-docker.sh"

cat >"$fake_bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  'rand -hex 32')
    printf 'a%.0s' {1..64}
    printf '\n'
    ;;
  'rand -base64 36')
    printf 'b%.0s' {1..48}
    printf '\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  compose)
    shift
    if [[ "${1:-}" == version ]]; then
      exit 0
    fi
    if [[ " $* " == *" config "* ]]; then
      exit 71
    fi
    exit 1
    ;;
  info)
    exit 0
    ;;
  run)
    IFS= read -r supplied_password ||
      {
        printf 'password input must be newline-terminated\n' >&2
        exit 72
      }
    [[ "$supplied_password" == "$(printf 'b%.0s' {1..48})" ]] ||
      {
        printf 'unexpected password input\n' >&2
        exit 72
      }
    printf '%s\n' '$2a$14$TRf6ynPaHFGoGIzGbRPBMumKVsUbVexXBXaVlsN0t6s/6MwOe5FMe'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$fake_bin/docker" "$fake_bin/openssl"

run_until_compose_config() {
  local status
  set +e
  PATH="$fake_bin:$PATH" \
    bash "$test_repo/scripts/bootstrap-docker.sh" "$@" \
    >"$tmp_dir/bootstrap.stdout" 2>"$tmp_dir/bootstrap.stderr"
  status=$?
  set -e
  [[ "$status" == 71 ]] ||
    fail "bootstrap must reach Compose config, got status $status"
}

assert_email_line() {
  local expected="$1"
  grep -Fqx "$expected" "$test_repo/.env" ||
    fail "bootstrap wrote an unsafe or incorrect ACME email: expected $expected"
}

run_until_compose_config \
  --domain chrome.example.test \
  --email 'ops$tag@example.com'
assert_email_line "ACME_EMAIL='ops\$tag@example.com'"

if [[ -n "${STANDALONE_COMPOSE:-}" ]]; then
  [[ -x "$STANDALONE_COMPOSE" ]] ||
    fail "standalone Compose is not executable: $STANDALONE_COMPOSE"
  rendered_json="$tmp_dir/bootstrap-compose.json"
  REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome \
    "$STANDALONE_COMPOSE" \
      -f "$repo_dir/compose.yaml" \
      -f "$repo_dir/vminstall/compose.vm.yaml" \
      --env-file "$test_repo/.env" \
      config --format json >"$rendered_json"
  CONFIG_JSON="$rendered_json" node <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');

const config = JSON.parse(fs.readFileSync(process.env.CONFIG_JSON, 'utf8'));
const renderedEmail = config.services?.proxy?.environment?.ACME_EMAIL;
assert(
  renderedEmail === 'ops$tag@example.com' ||
    renderedEmail?.replace(/\$\$/g, '$') === 'ops$tag@example.com',
  'standalone Compose must preserve the bootstrap-generated ACME email'
);
NODE
  printf 'PASS: standalone Compose preserves bootstrap ACME email\n'
fi

run_until_compose_config \
  --domain chrome.example.test \
  --email person+alerts@example.test
assert_email_line "ACME_EMAIL='person+alerts@example.test'"

set +e
ACME_EMAIL=env@example.test PATH="$fake_bin:$PATH" \
  bash "$test_repo/scripts/bootstrap-docker.sh" --domain chrome.example.test \
  >"$tmp_dir/env.stdout" 2>"$tmp_dir/env.stderr"
env_status=$?
set -e
[[ "$env_status" == 71 ]] ||
  fail "environment email must reach Compose config, got status $env_status"
assert_email_line "ACME_EMAIL='env@example.test'"

set +e
ACME_EMAIL=env@example.test PATH="$fake_bin:$PATH" \
  bash "$test_repo/scripts/bootstrap-docker.sh" \
    --domain chrome.example.test --email cli@example.test \
  >"$tmp_dir/override.stdout" 2>"$tmp_dir/override.stderr"
override_status=$?
set -e
[[ "$override_status" == 71 ]] ||
  fail "CLI email override must reach Compose config, got status $override_status"
assert_email_line "ACME_EMAIL='cli@example.test'"

set +e
printf 'tty@example.test\n' |
  env PATH="$fake_bin:$PATH" \
    script -qefc \
      "bash '$test_repo/scripts/bootstrap-docker.sh' --domain chrome.example.test" \
      /dev/null >"$tmp_dir/tty.stdout" 2>"$tmp_dir/tty.stderr"
tty_status=$?
set -e
[[ "$tty_status" == 71 ]] ||
  fail "TTY-prompted email must reach Compose config, got status $tty_status"
assert_email_line "ACME_EMAIL='tty@example.test'"

assert_unsupported_email() {
  local email="$1"
  local status
  rm -f "$test_repo/.env"
  set +e
  PATH="$fake_bin:$PATH" \
    bash "$test_repo/scripts/bootstrap-docker.sh" \
      --domain chrome.example.test --email "$email" \
    >"$tmp_dir/unsupported.stdout" 2>"$tmp_dir/unsupported.stderr"
  status=$?
  set -e
  [[ "$status" == 1 ]] ||
    fail "unsupported email must be rejected before Compose, got status $status"
  grep -Fq \
    'ERROR: Certificate email contains unsupported characters' \
    "$tmp_dir/unsupported.stderr" ||
    fail 'unsupported email must report the unsupported-character boundary'
  [[ ! -e "$test_repo/.env" ]] ||
    fail 'unsupported email must be rejected before the environment file is written'
}

assert_unsupported_email "ops'quote@example.com"
assert_unsupported_email 'ops\tag@example.com'
assert_unsupported_email "ops\\'combined@example.com"

set +e
PATH="$fake_bin:$PATH" \
  bash "$test_repo/scripts/bootstrap-docker.sh" \
    --domain chrome.example.test --email invalid \
  >"$tmp_dir/invalid.stdout" 2>"$tmp_dir/invalid.stderr"
invalid_status=$?
set -e
[[ "$invalid_status" == 1 ]] ||
  fail "invalid email must be rejected before Compose, got status $invalid_status"
grep -Fq 'ERROR: Certificate email is invalid' "$tmp_dir/invalid.stderr" ||
  fail 'invalid email must report the certificate email validation error'

printf 'PASS: Docker bootstrap ACME email inputs and dotenv serialization\n'
