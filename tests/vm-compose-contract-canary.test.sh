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
  printf '%s\n' '{"services":{"browser":{},"proxy":{}}}'
  exit 0
fi
exit 1
EOF
chmod +x "$tmp_dir/bin/docker"

set +e
PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/bad-render.stdout" 2>"$tmp_dir/bad-render.stderr"
bad_render_status=$?
set -e
[[ "$bad_render_status" != 0 ]] ||
  fail 'VM Compose contract must reject incorrect rendered semantics'

set +e
CI=1 FAKE_COMPOSE_AVAILABLE=false PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh \
  >"$tmp_dir/ci.stdout" 2>"$tmp_dir/ci.stderr"
ci_status=$?
set -e
[[ "$ci_status" != 0 ]] ||
  fail 'VM Compose contract must fail in CI when Compose is unavailable'
grep -Fq 'Docker Compose unavailable in CI' "$tmp_dir/ci.stderr" ||
  fail 'CI Compose failure must explain the missing dependency'

FAKE_COMPOSE_AVAILABLE=false PATH="$tmp_dir/bin:$PATH" \
  bash tests/vm-compose-contract.test.sh >"$tmp_dir/local.stdout"
grep -Fq \
  'SKIP: Docker Compose unavailable; rendered overlay checked in CI' \
  "$tmp_dir/local.stdout" ||
  fail 'local Compose absence must retain the explicit skip'

printf 'PASS: VM Compose contract mutation canaries\n'
