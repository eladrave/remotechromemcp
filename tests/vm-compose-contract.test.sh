#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for file in vminstall/compose.vm.yaml compose.yaml Caddyfile docker/Dockerfile; do
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
grep -Fq 'groupadd --gid 10001 remote-chrome' docker/Dockerfile ||
  fail 'browser image must create the fixed remote-chrome GID 10001'
grep -Fq 'useradd --uid 10001 --gid remote-chrome' docker/Dockerfile ||
  fail 'browser image must create the fixed remote-chrome UID 10001'

if command -v docker >/dev/null 2>&1 &&
   docker compose version >/dev/null 2>&1; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  env_file="$tmp_dir/compose.env"
  rendered_json="$tmp_dir/compose.json"
  hash='$2a$14$TRf6ynPaHFGoGIzGbRPBMumKVsUbVexXBXaVlsN0t6s/6MwOe5FMe'
  acme_email='ops$tag@example.com'
  {
    printf 'DOMAIN=chrome.example.com\n'
    printf "ACME_EMAIL='%s'\n" "$acme_email"
    printf 'MCP_TOKEN=%s\n' "$(printf 'a%.0s' {1..64})"
    printf 'LOGIN_TOKEN=%s\n' "$(printf 'b%.0s' {1..64})"
    printf 'LOGIN_USERNAME=remotechrome\n'
    printf "LOGIN_PASSWORD_HASH='%s'\n" "$hash"
    printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
    printf 'SCREEN_GEOMETRY=1440x900x24\n'
    printf 'REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome\n'
  } >"$env_file"
  docker compose -f compose.yaml -f vminstall/compose.vm.yaml \
    --env-file "$env_file" config --format json >"$rendered_json"

  CONFIG_JSON="$rendered_json" \
    REPO_DIR="$repo_dir" \
    EXPECTED_ACME_EMAIL="$acme_email" \
    node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const config = JSON.parse(fs.readFileSync(process.env.CONFIG_JSON, 'utf8'));
const services = config.services || {};
const browser = services.browser;
const proxy = services.proxy;

assert(browser, 'rendered VM Compose config must contain the browser service');
assert(proxy, 'rendered VM Compose config must contain the proxy service');
assert.equal(
  browser.user,
  '10001:10001',
  'browser runtime identity must match fresh bind-directory ownership'
);
assert.equal(
  proxy.user,
  '10001:10001',
  'proxy runtime identity must match fresh Caddy bind-directory ownership'
);
assert.deepEqual(
  [...(proxy.cap_drop || [])].sort(),
  ['ALL'],
  'non-root proxy must drop all ambient capabilities'
);
assert.deepEqual(
  [...(proxy.cap_add || [])].sort(),
  ['NET_BIND_SERVICE'],
  'non-root proxy must regain only low-port bind capability'
);

function assertMount(service, target, source, readOnly = false) {
  const matches = (service.volumes || []).filter(volume => volume.target === target);
  assert.equal(matches.length, 1, `expected exactly one mount at ${target}`);
  assert.equal(matches[0].type, 'bind', `${target} must be a bind mount`);
  assert.equal(matches[0].source, source, `${target} has the wrong bind source`);
  if (readOnly)
    assert.equal(matches[0].read_only, true, `${target} must remain read-only`);
}

assertMount(
  browser,
  '/data/chrome-profile',
  '/var/lib/remote-chrome/profile'
);
assertMount(proxy, '/data', '/var/lib/remote-chrome/caddy-data');
assertMount(proxy, '/config', '/var/lib/remote-chrome/caddy-config');
assertMount(
  proxy,
  '/etc/caddy/Caddyfile',
  path.join(process.env.REPO_DIR, 'Caddyfile'),
  true
);

assert(
  !browser.ports || browser.ports.length === 0,
  'browser must not publish host ports'
);
assert.deepEqual(
  [...(browser.expose || [])].map(String).sort(),
  ['6080', '8931'],
  'browser must expose only ports 6080 and 8931'
);

assert.equal(proxy.ports?.length, 2, 'proxy must publish exactly two ports');
const proxyPorts = proxy.ports.map(port => ({
  hostIp: port.host_ip,
  published: String(port.published),
  target: String(port.target),
}));
assert.deepEqual(
  proxyPorts.sort((left, right) => left.published.localeCompare(right.published)),
  [
    { hostIp: '0.0.0.0', published: '443', target: '443' },
    { hostIp: '0.0.0.0', published: '80', target: '80' },
  ],
  'proxy must publish only 0.0.0.0:80:80 and 0.0.0.0:443:443'
);

const renderedAcmeEmail = proxy.environment?.ACME_EMAIL;
const decodedAcmeEmail = renderedAcmeEmail?.replace(/\$\$/g, '$');
assert(
  renderedAcmeEmail === process.env.EXPECTED_ACME_EMAIL ||
    decodedAcmeEmail === process.env.EXPECTED_ACME_EMAIL,
  'proxy ACME_EMAIL must preserve the expected literal or Compose-canonical value'
);
NODE

  printf 'PASS: rendered VM Compose semantics\n'
else
  if [[ -v CI ]]; then
    fail 'Docker Compose unavailable in CI'
  fi
  printf 'SKIP: Docker Compose unavailable; rendered overlay checked in CI\n'
fi
