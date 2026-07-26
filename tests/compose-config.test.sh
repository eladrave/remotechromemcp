#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "required file is missing: $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  grep -Eq -- "$pattern" "$file" || fail "$description"
}

for file in \
  .env.example \
  compose.yaml \
  Caddyfile \
  docker/Dockerfile \
  docker/entrypoint.sh \
  docker/healthcheck.sh \
  docker/supervisord.conf; do
  require_file "$file"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
env_file="$tmp_dir/compose.env"
rendered_yaml="$tmp_dir/compose.yaml"
rendered_json="$tmp_dir/compose.json"
expected_hash='$2a$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234'

cp .env.example "$env_file"
sed -i \
  -e 's/^DOMAIN=.*/DOMAIN=chrome.example.test/' \
  -e 's/^MCP_TOKEN=.*/MCP_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/' \
  -e 's/^LOGIN_USERNAME=.*/LOGIN_USERNAME=testoperator/' \
  -e "s|^LOGIN_PASSWORD_HASH=.*|LOGIN_PASSWORD_HASH='$expected_hash'|" \
  "$env_file"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose --env-file "$env_file" config >"$rendered_yaml"
  docker compose --env-file "$env_file" config --format json >"$rendered_json"

  CONFIG_JSON="$rendered_json" EXPECTED_HASH="$expected_hash" node <<'NODE'
const fs = require('node:fs');

const config = JSON.parse(fs.readFileSync(process.env.CONFIG_JSON, 'utf8'));
const services = config.services || {};
const browser = services.browser;
const proxy = services.proxy;
if (!browser || !proxy)
  throw new Error('rendered Compose config must contain browser and proxy services');

if (browser.ports)
  throw new Error('browser must not publish host ports');
if (!Array.isArray(proxy.ports) || proxy.ports.length !== 2)
  throw new Error('proxy must be the only service publishing ports 80 and 443');
const published = proxy.ports.map(port => String(port.published)).sort();
if (published.join(',') !== '443,80')
  throw new Error(`unexpected published proxy ports: ${published.join(',')}`);

for (const service of Object.values(services)) {
  for (const port of service.ports || []) {
    if (['5900', '6080', '8931', '9222'].includes(String(port.published)))
      throw new Error(`private browser port was published: ${port.published}`);
  }
}

if (browser.init !== true || browser.restart !== 'unless-stopped' || !browser.shm_size)
  throw new Error('browser lifecycle settings are incomplete');
if (proxy.init !== true || proxy.restart !== 'unless-stopped')
  throw new Error('proxy lifecycle settings are incomplete');

const mounts = (browser.volumes || []).map(volume => `${volume.source}:${volume.target}`);
if (!mounts.includes('chrome-profile:/data/chrome-profile'))
  throw new Error('browser profile must use the chrome-profile named volume');

const proxyMounts = (proxy.volumes || []).map(volume => `${volume.source}:${volume.target}`);
if (!proxyMounts.includes('caddy-data:/data') || !proxyMounts.includes('caddy-config:/config'))
  throw new Error('proxy must persist Caddy data and configuration');

if (proxy.environment.LOGIN_PASSWORD_HASH !== process.env.EXPECTED_HASH)
  throw new Error('bcrypt hash did not survive Compose interpolation intact');
NODE
else
  if [[ "${CI:-}" == "1" ]]; then
    fail "docker compose unavailable in CI"
  fi
  printf 'SKIP: docker compose unavailable\n'
fi

# Non-Docker contract checks keep local development useful. CI additionally
# renders this definition and runs the container smoke test.
COMPOSE_FILE=compose.yaml CADDY_FILE=Caddyfile node <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');

const compose = fs.readFileSync(process.env.COMPOSE_FILE, 'utf8');
const caddy = fs.readFileSync(process.env.CADDY_FILE, 'utf8');
const browser = compose.match(/^  browser:\n([\s\S]*?)(?=^  proxy:\n)/m)?.[1];
const proxy = compose.match(/^  proxy:\n([\s\S]*?)(?=^volumes:\n)/m)?.[1];

assert(browser, 'browser service block is missing');
assert(proxy, 'proxy service block is missing');
assert(!/^\s{4}ports:/m.test(browser), 'browser must not publish ports');
assert.match(browser, /^\s{4}expose:\n(?:\s{6}.+\n)*\s{6}- "?(6080|8931)"?/m);
assert.match(browser, /^\s{4}init: true$/m);
assert.match(browser, /^\s{4}restart: unless-stopped$/m);
assert.match(browser, /^\s{4}shm_size:/m);
assert.match(browser, /chrome-profile:\/data\/chrome-profile/);
assert.match(proxy, /^\s{4}ports:\n\s{6}- "80:80"\n\s{6}- "443:443"/m);
assert.doesNotMatch(proxy, /"(5900|6080|8931|9222):/);
assert.match(proxy, /condition: service_healthy/);
assert.match(proxy, /caddy-data:\/data/);
assert.match(proxy, /caddy-config:\/config/);
assert.match(compose, /^  chrome-profile:\s*$/m);
assert.match(compose, /^  caddy-data:\s*$/m);
assert.match(compose, /^  caddy-config:\s*$/m);

assert.match(caddy, /\{\$DOMAIN\}/);
assert.match(caddy, /header Authorization "Bearer \{\$MCP_TOKEN\}"/);
assert.match(caddy, /\/\{\$MCP_TOKEN\}\/mcp/);
assert.match(caddy, /method POST DELETE/);
assert.match(caddy, /respond 405/);
assert.match(caddy, /\/login\/\*/);
assert.match(caddy, /basic_auth/);
assert.match(caddy, /\{\$LOGIN_USERNAME\} \{\$LOGIN_PASSWORD_HASH\}/);
assert.match(caddy, /reverse_proxy browser:8931/);
assert.match(caddy, /reverse_proxy browser:6080/);
assert.match(caddy, /header_up Upgrade/);
assert.doesNotMatch(caddy, /Content-Type/i);
assert.doesNotMatch(caddy, /log_append.*MCP_TOKEN/i);
NODE

assert_contains docker/Dockerfile '^FROM node:22-bookworm-slim$' \
  'Dockerfile must use node:22-bookworm-slim'
assert_contains docker/Dockerfile 'google-chrome-stable' \
  'Dockerfile must install full Google Chrome'
assert_contains docker/Dockerfile 'npm install -g "@playwright/mcp=\$\{PLAYWRIGHT_MCP_VERSION\}"' \
  'Dockerfile must install the pinned Playwright MCP version'
assert_contains docker/Dockerfile '^USER remote-chrome$' \
  'browser runtime must run as a non-root user'

assert_contains docker/supervisord.conf '--remote-debugging-address=127\.0\.0\.1' \
  'Chrome CDP must bind to container loopback'
assert_contains docker/supervisord.conf '--host 0\.0\.0\.0' \
  'Playwright MCP must bind to the private container interface'
assert_contains docker/supervisord.conf '--port 8931' \
  'Playwright MCP must use its private container port'
assert_contains docker/supervisord.conf 'websockify.*0\.0\.0\.0:6080' \
  'noVNC must bind to the private container interface'
assert_contains docker/supervisord.conf 'NODE_OPTIONS=.*inject-instructions\.cjs' \
  'Playwright MCP must preload the instruction shim'
assert_contains docker/supervisord.conf 'NODE_PATH=.*@playwright/mcp/node_modules' \
  'instruction preload must resolve globally installed Playwright dependencies'
SUPERVISOR_FILE=docker/supervisord.conf node <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');

const config = fs.readFileSync(process.env.SUPERVISOR_FILE, 'utf8');
const programs = ['xvfb', 'openbox', 'chrome', 'x11vnc', 'novnc', 'playwright-mcp'];
const positions = programs.map(name => config.indexOf(`[program:${name}]`));
assert(positions.every(position => position >= 0), 'a supervised browser process is missing');
for (let index = 1; index < positions.length; index += 1) {
  assert(
    positions[index - 1] < positions[index],
    `supervisor process order is wrong for ${programs[index - 1]} and ${programs[index]}`
  );
}
NODE

assert_contains docker/entrypoint.sh 'Singleton\*' \
  'entrypoint must remove only Chrome Singleton locks'
assert_contains docker/entrypoint.sh 'SCREEN_GEOMETRY is required' \
  'entrypoint must validate its required runtime environment'
assert_contains docker/entrypoint.sh 'exec .*supervisord' \
  'entrypoint must exec supervisord'

assert_contains docker/healthcheck.sh '127\.0\.0\.1:9222/json/version' \
  'health check must inspect Chrome CDP'
assert_contains docker/healthcheck.sh 'HeadlessChrome' \
  'health check must reject headless Chrome'
assert_contains docker/healthcheck.sh '127\.0\.0\.1:8931/mcp' \
  'health check must initialize MCP'
assert_contains docker/healthcheck.sh 'REMOTE_CHROME_PLAYBOOK_VERSION=1' \
  'health check must verify injected MCP instructions'
assert_contains docker/healthcheck.sh '127\.0\.0\.1:6080' \
  'health check must inspect noVNC'

printf 'PASS: Compose deployment contract\n'
