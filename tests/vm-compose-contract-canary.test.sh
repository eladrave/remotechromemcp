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
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
  [[ "${FAKE_COMPOSE_AVAILABLE:-true}" == true ]]
  exit
fi
if [[ "${1:-}" == compose ]]; then
  cat "$FAKE_RENDERED_JSON"
  exit 0
fi
exit 1
EOF
chmod +x "$tmp_dir/bin/docker"

write_valid_config() {
  local email="$1"
  local output="$2"
  OUTPUT="$output" REPO_DIR="$repo_dir" EMAIL="$email" node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const config = {
  services: {
    browser: {
      expose: ['6080', '8931'],
      user: '10001:10001',
      volumes: [
        {
          type: 'bind',
          source: '/var/lib/remote-chrome/profile',
          target: '/data/chrome-profile',
        },
      ],
    },
    proxy: {
      user: '10001:10001',
      cap_drop: ['ALL'],
      cap_add: ['NET_BIND_SERVICE'],
      environment: {
        ACME_EMAIL: process.env.EMAIL,
      },
      ports: [
        { host_ip: '0.0.0.0', published: '80', target: 80 },
        { host_ip: '0.0.0.0', published: '443', target: 443 },
      ],
      volumes: [
        {
          type: 'bind',
          source: '/var/lib/remote-chrome/caddy-data',
          target: '/data',
        },
        {
          type: 'bind',
          source: '/var/lib/remote-chrome/caddy-config',
          target: '/config',
        },
        {
          type: 'bind',
          source: path.join(process.env.REPO_DIR, 'Caddyfile'),
          target: '/etc/caddy/Caddyfile',
          read_only: true,
        },
      ],
    },
  },
};

fs.writeFileSync(process.env.OUTPUT, JSON.stringify(config));
NODE
}

canonical_json="$tmp_dir/canonical.json"
write_valid_config 'ops$$tag@example.com' "$canonical_json"
FAKE_RENDERED_JSON="$canonical_json" PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/canonical.stdout" 2>"$tmp_dir/canonical.stderr" ||
  fail 'VM Compose contract must accept canonical doubled-dollar ACME email'

wrong_email_json="$tmp_dir/wrong-email.json"
write_valid_config 'wrong@example.com' "$wrong_email_json"
set +e
FAKE_RENDERED_JSON="$wrong_email_json" PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/wrong-email.stdout" 2>"$tmp_dir/wrong-email.stderr"
wrong_email_status=$?
set -e
[[ "$wrong_email_status" != 0 ]] ||
  fail 'VM Compose contract must reject a wrong rendered ACME email'

bad_render_json="$tmp_dir/bad-render.json"
printf '%s\n' '{"services":{"browser":{},"proxy":{}}}' >"$bad_render_json"
set +e
FAKE_RENDERED_JSON="$bad_render_json" PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/bad-render.stdout" 2>"$tmp_dir/bad-render.stderr"
bad_render_status=$?
set -e
[[ "$bad_render_status" != 0 ]] ||
  fail 'VM Compose contract must reject incorrect rendered semantics'

set +e
CI=1 FAKE_COMPOSE_AVAILABLE=false FAKE_RENDERED_JSON="$bad_render_json" \
  PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/ci.stdout" 2>"$tmp_dir/ci.stderr"
ci_status=$?
set -e
[[ "$ci_status" != 0 ]] ||
  fail 'VM Compose contract must fail in CI when Compose is unavailable'
grep -Fq 'Docker Compose unavailable in CI' "$tmp_dir/ci.stderr" ||
  fail 'CI Compose failure must explain the missing dependency'

FAKE_COMPOSE_AVAILABLE=false FAKE_RENDERED_JSON="$bad_render_json" \
  PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh >"$tmp_dir/local.stdout"
grep -Fq \
  'SKIP: Docker Compose unavailable; rendered overlay checked in CI' \
  "$tmp_dir/local.stdout" ||
  fail 'local Compose absence must retain the explicit skip'

printf 'PASS: VM Compose contract mutation canaries\n'
