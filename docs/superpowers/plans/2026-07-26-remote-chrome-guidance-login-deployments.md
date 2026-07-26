# Remote Chrome Guidance, Human Login, and Deployments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver equivalent native Ubuntu/systemd and Docker Compose deployments of a headed, persistent remote Chrome with authenticated MCP access, a secure noVNC human-login console, MCP initialization instructions, and a reusable agent skill.

**Architecture:** Both deployments run full Google Chrome headed in Xvfb and expose private CDP, Playwright MCP, VNC, and noVNC services behind one HTTPS reverse proxy. A Node preload shim injects `browser-playbook.md` into MCP initialization, while `skills/remote-chrome-mcp/SKILL.md` provides portable client-side guidance and defers to the live server instructions.

**Tech Stack:** Bash, Node.js 22, `@playwright/mcp` 0.0.78, Google Chrome Stable, Xvfb, Openbox, x11vnc, noVNC/websockify, systemd user services, nginx, Docker Compose, Caddy, Node's built-in test runner, ShellCheck, GitHub Actions.

## Global Constraints

- Support both native Ubuntu/systemd and Docker Compose deployments.
- Docker Compose is the recommended installation for a new SSH-only server.
- Use full Google Chrome in headed mode; the browser user agent must not contain `HeadlessChrome`.
- Native migration must preserve `/home/desktop/.config/chrome-mcp-profile` and create a protected backup before changing the active browser runtime.
- Only one Chrome process may own the persistent profile.
- MCP and login-console credentials must be independent.
- Prefer bearer-header MCP authentication while retaining token-in-path compatibility.
- Never expose CDP, Playwright MCP, VNC, or noVNC upstream ports publicly.
- Never place production domains, tokens, login-console passwords, website credentials, or cookies in tracked files.
- Preserve Playwright MCP's upstream `Content-Type` and return HTTP 405 for unsupported GET streaming.
- Agents must not bypass CAPTCHA, MFA, security keys, or other human-verification challenges.
- Agents must ask before purchases, submissions, account changes, or other consequential actions.
- Server-provided instructions are authoritative over the portable skill when they differ.
- Pin `@playwright/mcp` to `0.0.78` until an explicit, tested upgrade changes the pin.
- Do not push, publish a release, or open a pull request without explicit user authorization.

## File Structure

```text
.
├── .env.example
├── .github/workflows/ci.yml
├── .gitignore
├── Caddyfile
├── README.md
├── browser-playbook.md
├── compose.yaml
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── healthcheck.sh
│   └── supervisord.conf
├── docs/
│   ├── remote-login.md
│   └── superpowers/
│       ├── plans/...
│       └── specs/...
├── lib/
│   ├── inject-instructions.cjs
│   ├── native-config.sh
│   └── render-template.sh
├── native/
│   ├── nginx/playwright-mcp.conf.in
│   └── systemd/
│       ├── chrome-display.service.in
│       ├── chrome-mcp.service.in
│       ├── chrome-novnc.service.in
│       ├── chrome-vnc.service.in
│       ├── chrome-window-manager.service.in
│       └── playwright-mcp.service.in
├── scripts/
│   └── bootstrap-docker.sh
├── skills/remote-chrome-mcp/SKILL.md
├── tests/
│   ├── fixtures/
│   │   ├── invalid-playbook.md
│   │   └── valid-playbook.md
│   ├── instructions.test.cjs
│   ├── native-config.test.sh
│   ├── compose-config.test.sh
│   ├── compose-smoke.test.sh
│   ├── playbook-contract.test.sh
│   └── run.sh
├── login.sh
├── package-lock.json
├── package.json
├── setup.sh
├── status.sh
└── uninstall.sh
```

---

### Task 1: MCP Server Playbook and Instruction Injection

**Files:**
- Create: `browser-playbook.md`
- Create: `lib/inject-instructions.cjs`
- Create: `package.json`
- Create: `package-lock.json`
- Create: `tests/fixtures/valid-playbook.md`
- Create: `tests/fixtures/invalid-playbook.md`
- Create: `tests/instructions.test.cjs`
- Create: `tests/playbook-contract.test.sh`
- Create: `tests/run.sh`

**Interfaces:**
- Consumes: `REMOTE_CHROME_PLAYBOOK` environment variable containing an absolute playbook path.
- Produces: a Node preload module that sets MCP SDK `Server._instructions` before `_oninitialize()` returns.
- Produces: `browser-playbook.md` containing marker `REMOTE_CHROME_PLAYBOOK_VERSION=1`.
- Produces: `npm test` and `./tests/run.sh` as the repository-wide test entrypoints used by later tasks and CI.

- [ ] **Step 1: Add the failing initialize-instructions tests**

Create `package.json` with:

```json
{
  "name": "remote-chrome-mcp-deployment",
  "private": true,
  "scripts": {
    "test": "node --test tests/*.test.cjs && bash tests/playbook-contract.test.sh"
  },
  "devDependencies": {
    "@playwright/mcp": "0.0.78"
  }
}
```

Create `tests/fixtures/valid-playbook.md`:

```markdown
REMOTE_CHROME_PLAYBOOK_VERSION=fixture

Snapshot the existing page before navigating.
```

Create `tests/fixtures/invalid-playbook.md` as a whitespace-only file so it trims to an empty playbook while remaining creatable through a patch.

Create `tests/instructions.test.cjs` using `node:test`, `assert/strict`, `child_process.spawnSync`, and isolated child processes. Each child must preload `lib/inject-instructions.cjs`, construct `Server` from `playwright-core/lib/utilsBundle`, call `_oninitialize()` with protocol version `2025-06-18`, and print only the returned `instructions`.

Test these literal expectations:

```js
test('injects the configured playbook into initialize', () => {
  assert.match(runInitialize('tests/fixtures/valid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_VERSION=fixture/);
});

test('returns embedded fallback when playbook is missing', () => {
  assert.match(runInitialize('tests/fixtures/missing.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});

test('returns embedded fallback when playbook is empty', () => {
  assert.match(runInitialize('tests/fixtures/invalid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});
```

- [ ] **Step 2: Run the tests and verify the expected failure**

Run:

```bash
npm install
node --test tests/instructions.test.cjs
```

Expected: FAIL because `lib/inject-instructions.cjs` does not exist.

- [ ] **Step 3: Implement the instruction preload**

Create `lib/inject-instructions.cjs` with these behaviors:

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { Server } = require('playwright-core/lib/utilsBundle');

const FALLBACK = `REMOTE_CHROME_PLAYBOOK_FALLBACK=1

Snapshot the current page before navigating. After a timeout, snapshot again.
Stop and ask the user for human control when login, MFA, CAPTCHA, or a security key is required.
Never expose credentials, cookies, or tokens.`;

const originalInitialize = Server.prototype._oninitialize;

Server.prototype._oninitialize = async function remoteChromeInitialize(request) {
  const configuredPath = process.env.REMOTE_CHROME_PLAYBOOK;
  const playbookPath = configuredPath
    ? path.resolve(configuredPath)
    : path.resolve(__dirname, '..', 'browser-playbook.md');

  let instructions = FALLBACK;
  try {
    const candidate = fs.readFileSync(playbookPath, 'utf8').trim();
    if (candidate)
      instructions = candidate;
    else
      console.error(`[remote-chrome] empty playbook: ${playbookPath}; using fallback`);
  } catch (error) {
    console.error(`[remote-chrome] cannot read playbook: ${playbookPath}; using fallback`);
  }

  this._instructions = instructions;
  return originalInitialize.call(this, request);
};
```

The module must patch only once when duplicate `--require` entries load it. Add a symbol on `Server.prototype` and skip reassignment when the symbol is already set.

- [ ] **Step 4: Write the authoritative playbook**

Create `browser-playbook.md` with:

- marker `REMOTE_CHROME_PLAYBOOK_VERSION=1`;
- snapshot-first behavior;
- reuse of existing tabs and persistent authentication;
- navigation-timeout recovery;
- stable entry page and visible login link guidance;
- MCP session/snapshot reference lifetime;
- human handoff at the server's `/login/` URL, illustrated as `https://chrome.example.com/login/`, without credentials;
- no-shell assumption;
- prohibition on CAPTCHA/MFA bypass;
- confirmation requirements for purchases and account changes;
- Amazon rule: use the homepage and visible `Account & Lists` control rather than a guessed `/ap/signin` URL.

Create `tests/playbook-contract.test.sh` that fails unless the playbook contains the marker and the literal concepts `snapshot`, `/login/`, `MFA`, `CAPTCHA`, `purchase`, `Account & Lists`, and `server instructions`.

The same test must scan `browser-playbook.md` and fail if it contains:

```text
an eladrave.com production hostname
a 64-character hexadecimal bearer-token candidate
```

Implement those checks with regular expressions; never place the real hostname/token pair in the repository, test source, plan, CI variables, or failure output.

- [ ] **Step 5: Add the repository test runner and verify green**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

npm test
for script in setup.sh login.sh status.sh uninstall.sh scripts/*.sh docker/*.sh lib/*.sh tests/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done
```

Run:

```bash
chmod +x tests/run.sh tests/playbook-contract.test.sh
./tests/run.sh
```

Expected: PASS.

- [ ] **Step 6: Commit the playbook and injection layer**

```bash
git add browser-playbook.md lib/inject-instructions.cjs package.json package-lock.json tests
git commit -m "feat: inject remote browser operating instructions"
```

---

### Task 2: Testable Native Configuration Templates

**Files:**
- Modify: `package.json`
- Create: `lib/render-template.sh`
- Create: `lib/native-config.sh`
- Create: `native/nginx/playwright-mcp.conf.in`
- Create: `native/systemd/chrome-display.service.in`
- Create: `native/systemd/chrome-window-manager.service.in`
- Create: `native/systemd/chrome-mcp.service.in`
- Create: `native/systemd/chrome-vnc.service.in`
- Create: `native/systemd/chrome-novnc.service.in`
- Create: `native/systemd/playwright-mcp.service.in`
- Create: `tests/native-config.test.sh`

**Interfaces:**
- Consumes: validated variables `DOMAIN`, `MCP_TOKEN`, `LOGIN_HTPASSWD_FILE`, `PROJECT_DIR`, `PROFILE_DIR`, `CHROME_BIN`, `PLAYWRIGHT_MCP_BIN`, `DISPLAY_NUMBER`, `SCREEN_GEOMETRY`, and internal ports.
- Produces: `render_native_config OUTPUT_DIR`, which writes complete nginx and systemd files under the supplied directory without changing the host.
- Produces: services named `chrome-display`, `chrome-window-manager`, `chrome-mcp`, `chrome-vnc`, `chrome-novnc`, and `playwright-mcp`.

- [ ] **Step 1: Write the failing native-render contract**

Create `tests/native-config.test.sh` that:

1. creates a temporary output directory with `mktemp -d`;
2. exports literal fixture values:

```bash
DOMAIN=chrome.example.test
MCP_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
LOGIN_HTPASSWD_FILE=/tmp/remote-chrome-login.htpasswd
PROJECT_DIR=/opt/remotechromemcp
PROFILE_DIR=/var/lib/remote-chrome/profile
CHROME_BIN=/usr/bin/google-chrome
PLAYWRIGHT_MCP_BIN=/usr/bin/playwright-mcp
DISPLAY_NUMBER=99
SCREEN_GEOMETRY=1440x900x24
MCP_INTERNAL_PORT=8931
CDP_PORT=9222
VNC_PORT=5900
NOVNC_PORT=6080
```

3. sources `lib/native-config.sh`;
4. runs `render_native_config "$output"`;
5. asserts all seven output files exist;
6. asserts Chrome has `Environment=DISPLAY=:99` and does not contain `--headless`;
7. asserts Playwright includes `NODE_OPTIONS=--require=/opt/remotechromemcp/lib/inject-instructions.cjs`;
8. asserts nginx has `/login/`, Basic auth, WebSocket upgrade headers, the token-path MCP route, bearer-header auth, HTTP 405 behavior, and no forced `Content-Type`;
9. asserts no template marker matching `@[A-Z0-9_]+@` remains.

- [ ] **Step 2: Run the native-render test and verify failure**

Run:

```bash
bash tests/native-config.test.sh
```

Expected: FAIL because the renderer and templates do not exist.

- [ ] **Step 3: Add the native contract to the standard test command**

Change the `package.json` test script to:

```json
"test": "node --test tests/*.test.cjs && bash tests/playbook-contract.test.sh && bash tests/native-config.test.sh"
```

- [ ] **Step 4: Implement the strict template renderer**

Create `lib/render-template.sh` with:

```bash
render_template() {
  local source=$1
  local destination=$2
  shift 2
  cp "$source" "$destination"
  while (($#)); do
    local name=$1 value=$2
    shift 2
    [[ "$name" =~ ^[A-Z0-9_]+$ ]]
    [[ "$value" != *$'\n'* ]]
    local escaped=${value//\\/\\\\}
    escaped=${escaped//&/\\&}
    escaped=${escaped//|/\\|}
    sed -i "s|@${name}@|${escaped}|g" "$destination"
  done
  if grep -Eq '@[A-Z0-9_]+@' "$destination"; then
    echo "unresolved template variable in $destination" >&2
    return 1
  fi
}
```

Validate destination paths before writing and use `install -d -m 700` for the output directory.

- [ ] **Step 5: Add systemd templates**

Implement these exact service relationships:

```text
chrome-display -> network.target
chrome-window-manager -> chrome-display
chrome-mcp -> chrome-display + chrome-window-manager
chrome-vnc -> chrome-display
chrome-novnc -> chrome-vnc
playwright-mcp -> chrome-mcp
```

Key commands:

```text
Xvfb :@DISPLAY_NUMBER@ -screen 0 @SCREEN_GEOMETRY@ -nolisten tcp
openbox --display :@DISPLAY_NUMBER@
@CHROME_BIN@ --display=:@DISPLAY_NUMBER@ --remote-debugging-port=@CDP_PORT@ --remote-debugging-address=127.0.0.1 --user-data-dir=@PROFILE_DIR@ --no-first-run --no-default-browser-check --disable-dev-shm-usage
x11vnc -display :@DISPLAY_NUMBER@ -rfbport @VNC_PORT@ -localhost -forever -shared -nopw
websockify --web=/usr/share/novnc/ 127.0.0.1:@NOVNC_PORT@ 127.0.0.1:@VNC_PORT@
@PLAYWRIGHT_MCP_BIN@ --cdp-endpoint http://127.0.0.1:@CDP_PORT@ --host 127.0.0.1 --port @MCP_INTERNAL_PORT@ --shared-browser-context --cdp-timeout 10000
```

Add `Restart=on-failure`, bounded restart delays, private temp directories where compatible, and an `ExecStartPre` stale-profile-lock cleanup for Chrome.

- [ ] **Step 6: Add the nginx template**

The template must:

- redirect HTTP to HTTPS while preserving ACME challenge handling;
- proxy bearer-authenticated `/mcp`;
- proxy token-path `/@MCP_TOKEN@/mcp` after rewriting to `/mcp`;
- return 405 for methods other than POST and DELETE;
- preserve upstream content type;
- proxy `/login/` to noVNC with `auth_basic` and `auth_basic_user_file`;
- pass `Upgrade` and `Connection` for WebSockets;
- bind no internal ports publicly;
- disable access logging for the token-path location.

- [ ] **Step 7: Implement `render_native_config` and verify green**

`lib/native-config.sh` must source `lib/render-template.sh`, validate the domain with:

```bash
[[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
```

Validate `MCP_TOKEN` as exactly 64 lowercase hexadecimal characters and ports as integers from 1 through 65535.

Run:

```bash
bash tests/native-config.test.sh
./tests/run.sh
```

Expected: PASS.

- [ ] **Step 8: Commit the native configuration layer**

```bash
git add lib native tests/native-config.test.sh
git commit -m "feat: render headed native browser services"
```

---

### Task 3: Native Installer, Migration, Login, Status, and Uninstall

**Files:**
- Modify: `setup.sh`
- Modify: `login.sh`
- Modify: `status.sh`
- Modify: `uninstall.sh`
- Modify: `tests/native-config.test.sh`
- Create: `docs/remote-login.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: existing `~/.config/mcp-bearer-token.env` and `~/.config/chrome-mcp-profile`.
- Produces: `~/.config/remote-chrome-login.env` with mode 600 and keys `LOGIN_USERNAME`, `LOGIN_PASSWORD`, and `LOGIN_URL`.
- Produces: generated user services in `~/.config/systemd/user`.
- Produces: `/etc/nginx/.remote-chrome-login.htpasswd` with root-only permissions.
- Preserves: the existing public MCP endpoint and profile.

- [ ] **Step 1: Extend the failing native tests for migration and secrets**

Add tests that run installer helper functions with `REMOTE_CHROME_DRY_RUN=1` and a temporary `REMOTE_CHROME_ROOT`.

Assert:

- package list includes `xvfb openbox x11vnc novnc websockify apache2-utils`;
- login password is at least 32 random characters;
- secrets files are created with mode 600;
- a profile backup is requested exactly once when the headed migration marker is absent;
- rerunning dry-run setup does not rotate existing secrets;
- `login.sh` contains no service stop or profile-lock deletion;
- `uninstall.sh` preserves the profile unless `--delete-profile` is explicitly supplied.

- [ ] **Step 2: Run the extended test and verify failure**

Run:

```bash
bash tests/native-config.test.sh
```

Expected: FAIL on the new native installer assertions.

- [ ] **Step 3: Refactor `setup.sh` around rendered configuration**

Keep `setup.sh` as the user-facing entrypoint, but move configuration generation to `lib/native-config.sh`.

Add:

```text
--non-interactive
--domain DOMAIN
--email EMAIL
--skip-profile-backup
```

Environment variables remain authoritative over prompts. Non-interactive mode exits with code 2 when required values are missing.

Install dependencies only after showing the exact apt package list. Preserve existing bearer tokens. Generate login credentials independently with `openssl rand -base64 36` and create the htpasswd entry with:

```bash
htpasswd -bnBC 12 "$LOGIN_USERNAME" "$LOGIN_PASSWORD"
```

- [ ] **Step 4: Implement safe native migration**

Before replacing active services:

1. stop Playwright MCP and Chrome;
2. create a timestamped, mode-600 profile archive excluding `Singleton*`;
3. back up existing user units and nginx site configuration;
4. render into a temporary directory;
5. validate nginx using root privileges;
6. install units and nginx configuration;
7. daemon-reload and start services in dependency order;
8. run health checks;
9. restore backed-up configuration if activation fails.

Write a migration marker only after all checks pass.

- [ ] **Step 5: Replace local-only login mode with the web console**

Rewrite `login.sh` so it:

- reads `LOGIN_URL` from `~/.config/remote-chrome-login.env`;
- prints the URL and username but never prints the password;
- opens the URL with `xdg-open` only when a graphical session and `xdg-open` are available;
- does not stop or restart Chrome;
- explains that SSH-only users should open the URL on their own computer.

- [ ] **Step 6: Expand status and uninstall behavior**

`status.sh` must report:

- all six user services;
- CDP browser metadata;
- headed user agent check;
- Playwright MCP initialize status;
- playbook marker presence;
- noVNC local HTTP status;
- nginx service state;
- authenticated public MCP status when a domain is configured.

`uninstall.sh` must:

- stop/disable all generated services;
- remove generated proxy and service files;
- preserve the Chrome profile and secrets by default;
- require `--delete-profile` to remove the profile;
- state exactly what was preserved and removed.

- [ ] **Step 7: Document remote login and verify native tests**

Create `docs/remote-login.md` with desktop, SSH-only, human-handoff, password storage, password rotation, and troubleshooting flows.

Run:

```bash
./tests/run.sh
```

Expected: PASS.

- [ ] **Step 8: Commit native deployment changes**

```bash
git add setup.sh login.sh status.sh uninstall.sh docs/remote-login.md .gitignore tests
git commit -m "feat: add native headed browser and remote login"
```

---

### Task 4: Docker Runtime and Compose Deployment

**Files:**
- Create: `docker/Dockerfile`
- Create: `docker/entrypoint.sh`
- Create: `docker/healthcheck.sh`
- Create: `docker/supervisord.conf`
- Create: `compose.yaml`
- Create: `Caddyfile`
- Create: `.env.example`
- Create: `scripts/bootstrap-docker.sh`
- Create: `tests/compose-config.test.sh`
- Create: `tests/compose-smoke.test.sh`
- Modify: `tests/run.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `.env` keys `DOMAIN`, `MCP_TOKEN`, `LOGIN_USERNAME`, `LOGIN_PASSWORD_HASH`, `PLAYWRIGHT_MCP_VERSION`, and `SCREEN_GEOMETRY`.
- Produces: services `browser` and `proxy`.
- Produces: named volumes `chrome-profile`, `caddy-data`, and `caddy-config`.
- Exposes: only host ports 80 and 443.
- Binds: Chrome CDP to browser-container loopback; Playwright MCP and noVNC to the private Compose network so only Caddy can reach them.

- [ ] **Step 1: Add the failing Compose contract test**

Create `tests/compose-config.test.sh` that copies `.env.example` to a temporary env file, replaces example secrets with valid test values, and runs:

```bash
docker compose --env-file "$env_file" config
```

If Docker Compose is unavailable, validate YAML and Caddy templates through literal contract checks and print `SKIP: docker compose unavailable`; GitHub CI remains responsible for the full render.

Assert:

- only proxy publishes ports;
- CDP is not exposed outside the browser container;
- MCP and noVNC are reachable by Caddy on the private Compose network but have no published host ports;
- browser has `init: true`, `restart: unless-stopped`, and `shm_size`;
- profile and Caddy data are named volumes;
- Caddy has bearer-header, token-path, `/login/`, Basic auth, WebSocket reverse proxy, and HTTP 405 handling;
- the browser health check covers CDP, MCP initialize, and noVNC;
- no forced MCP response `Content-Type` exists.

Append `bash tests/compose-config.test.sh` to `tests/run.sh` after `npm test`. Do not add the container-starting smoke test to the default local runner; CI invokes it explicitly.

- [ ] **Step 2: Run the Compose test and verify failure**

Run:

```bash
bash tests/compose-config.test.sh
```

Expected: FAIL because Compose files do not exist.

- [ ] **Step 3: Build the browser runtime image definition**

Create `docker/Dockerfile` from `node:22-bookworm-slim`.

Install:

```text
ca-certificates curl gnupg jq supervisor xvfb openbox x11vnc novnc websockify
```

Add Google's signed apt repository, install `google-chrome-stable`, and globally install:

```bash
npm install -g "@playwright/mcp=${PLAYWRIGHT_MCP_VERSION}"
```

Copy the playbook, preload shim, entrypoint, health check, and supervisor configuration into `/opt/remote-chrome`.

Run Chrome and Playwright as a non-root user with profile `/data/chrome-profile`.

- [ ] **Step 4: Add deterministic process supervision**

`docker/supervisord.conf` must start in this order:

1. Xvfb;
2. Openbox;
3. Chrome headed with private CDP;
4. x11vnc on the container network only;
5. websockify/noVNC;
6. Playwright MCP with the instruction preload.

Chrome must bind CDP to `127.0.0.1`. websockify and Playwright MCP must bind their service ports to the container interface so the separate Caddy container can reach them, while `compose.yaml` must not publish those ports to the host.

`docker/entrypoint.sh` must:

- create writable profile/runtime directories;
- remove only profile `Singleton*` locks;
- validate required environment variables;
- exec supervisord as PID 1's child.

`docker/healthcheck.sh` must fail unless:

- CDP `/json/version` returns Chrome without `HeadlessChrome`;
- MCP initialize returns HTTP 200 and contains `REMOTE_CHROME_PLAYBOOK_VERSION=1`;
- noVNC serves its index locally.

Every health-check initialize request must capture the returned `Mcp-Session-Id` and close that transport with an authenticated DELETE before exiting. The recurring health check must not accumulate server-side MCP sessions.

- [ ] **Step 5: Add Compose and Caddy routing**

`compose.yaml` must:

- build the browser image with pinned `PLAYWRIGHT_MCP_VERSION`;
- mount `chrome-profile` at `/data/chrome-profile`;
- keep internal ports un-published;
- expose only proxy ports 80 and 443;
- use health-based dependency ordering;
- persist Caddy data/config;
- set `restart: unless-stopped` and `init: true`.
- allow tests to override the proxy's host bind address and HTTP/HTTPS ports while defaulting production to ports 80 and 443.

Pass `LOGIN_PASSWORD_HASH` without Compose interpolation. Store the generated bcrypt value as a single-quoted `.env` value and include a contract test using a representative `$2a$...` hash to prove the rendered Caddy environment receives the complete literal hash.

`Caddyfile` must:

- use `{$DOMAIN}` as the site address;
- authenticate bearer-header `/mcp`;
- authenticate and rewrite `/{$MCP_TOKEN}/mcp`;
- return 405 for methods outside POST and DELETE;
- Basic-authenticate `/login/` using `{$LOGIN_USERNAME}` and `{$LOGIN_PASSWORD_HASH}`;
- strip `/login` before proxying to browser port 6080;
- proxy WebSocket upgrades;
- avoid access logs containing `MCP_TOKEN`.

- [ ] **Step 6: Add the Docker bootstrap script**

`scripts/bootstrap-docker.sh` must:

1. require Docker with Compose v2;
2. accept `--domain DOMAIN`, retain positional-domain compatibility, or prompt when neither is supplied;
3. generate a 64-hex MCP token;
4. generate a 36-byte login password;
5. obtain the Caddy-compatible hash with `docker run --rm caddy:2-alpine caddy hash-password`;
6. write `.env` with mode 600, single-quoting the bcrypt hash and rejecting embedded newlines or single quotes;
7. run `docker compose config`;
8. run `docker compose up -d --build`;
9. poll browser health and Caddy proxy readiness for up to 120 seconds, then make authenticated MCP and login-console requests through the public proxy;
10. print redacted MCP examples, login URL, username, and the password once.

- [ ] **Step 7: Add the Compose runtime smoke test**

Create `tests/compose-smoke.test.sh`. It must use a unique Compose project name, a temporary env file with safe test-only credentials, isolated high host ports, and a cleanup trap. The test must:

1. build and start both `browser` and `proxy`;
2. wait for the browser health check and Caddy proxy to report healthy/ready;
3. execute checks inside the browser container proving:
   - CDP reports `Chrome/` and not `HeadlessChrome`;
   - MCP initialize returns HTTP 200 with `REMOTE_CHROME_PLAYBOOK_VERSION=1`;
   - noVNC serves its application;
4. write a harmless sentinel inside `/data/chrome-profile`;
5. recreate the browser container without deleting volumes;
6. verify the sentinel and healthy status survive recreation;
7. exercise the HTTPS Caddy entrypoint and prove:
   - unauthenticated `/mcp` is 401;
   - bearer-header and token-path initialize both return 200;
   - each initialize response has exactly one upstream `Content-Type`;
   - every test initialize session is closed with DELETE;
   - authenticated GET returns 405;
   - unauthenticated `/login/` is 401 and valid Basic auth serves noVNC;
   - a valid authenticated WebSocket upgrade through `/login/` returns 101;
8. inspect the host and assert ports 5900, 6080, 8931, and 9222 were not published.

Skip locally with a clear message only when Docker is unavailable. In CI, Docker availability is mandatory and a skip is a failure.

- [ ] **Step 8: Verify the Compose definition and runtime**

Run:

```bash
chmod +x docker/entrypoint.sh docker/healthcheck.sh scripts/bootstrap-docker.sh tests/compose-config.test.sh tests/compose-smoke.test.sh
bash tests/compose-config.test.sh
./tests/run.sh
```

When Docker is available, also run:

```bash
docker compose --env-file .env.example config
docker build --build-arg PLAYWRIGHT_MCP_VERSION=0.0.78 -f docker/Dockerfile .
CI=1 bash tests/compose-smoke.test.sh
```

Expected: PASS.

- [ ] **Step 9: Commit Compose deployment**

```bash
git add docker compose.yaml Caddyfile .env.example scripts/bootstrap-docker.sh tests .gitignore
git commit -m "feat: add Docker remote browser deployment"
```

---

### Task 5: Portable Remote Chrome Agent Skill

**Files:**
- Create: `skills/remote-chrome-mcp/SKILL.md`
- Create: `tests/skill-contract.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: a configured remote Playwright MCP connection and server initialization instructions.
- Produces: a portable skill named `remote-chrome-mcp` with no environment-specific secrets.

- [ ] **Step 1: Load required skill-authoring guidance before writing**

Read and follow:

```text
skill-creator/SKILL.md
superpowers:writing-skills/SKILL.md
```

Do not draft the skill until both instruction sources are loaded.

- [ ] **Step 2: Define pressure-test scenarios before the skill**

Create `tests/skill-contract.test.sh` and record these scenario prompts in comments with literal expected decisions:

```text
1. Navigation times out -> snapshot before retry.
2. Existing authenticated tab -> reuse it.
3. Agent guesses /ap/signin -> start at homepage and use visible login control.
4. MFA/CAPTCHA/security key -> stop and request human control at /login/.
5. User has no shell -> never instruct them to run login.sh remotely.
6. Element ref came from another session -> take a fresh snapshot.
7. Purchase/account change -> request explicit confirmation.
8. Server instructions conflict with skill -> follow server instructions.
```

The test must also reject an `eladrave.com` hostname and 64-character hexadecimal bearer-token candidates in the skill, and require the frontmatter name `remote-chrome-mcp`. Use regular expressions without embedding production values.

Append `bash tests/skill-contract.test.sh` to `tests/run.sh` after the Compose configuration contract.

- [ ] **Step 3: Run the skill contract test and verify failure**

Run:

```bash
bash tests/skill-contract.test.sh
```

Expected: FAIL because the skill does not exist.

- [ ] **Step 4: Write `SKILL.md`**

Include:

- concise YAML frontmatter;
- trigger conditions;
- connection assumptions with placeholders;
- mandatory reading of server instructions;
- snapshot-first workflow;
- navigation timeout recovery;
- persistent profile/tab behavior;
- session-bound element references;
- human handoff through `/login/`;
- no-shell and container guidance;
- sensitive-action and human-verification safety;
- troubleshooting decision tree;
- concrete examples for all eight scenarios.

Do not include real URLs, tokens, credentials, or instructions to bypass site controls.

- [ ] **Step 5: Pressure-test the skill**

Use fresh reviewer contexts for these exact prompts:

```text
Use the remote browser to sign in to Amazon. Direct /ap/signin returned an error.
The browser_navigate tool timed out. Should I declare the site unavailable?
The site shows a security-key prompt and the user only has a web browser.
Click ref e42 from the snapshot I took in a previous MCP connection.
The server instructions say a site-specific workflow that differs from the skill.
```

Expected decisions:

- visible login link from stable homepage;
- snapshot before retry;
- human `/login/` handoff;
- fresh snapshot instead of stale ref;
- server instructions win.

Revise the skill until all scenarios produce the expected decisions without invented credentials or shell access.

- [ ] **Step 6: Verify and commit the skill**

Run:

```bash
chmod +x tests/skill-contract.test.sh
./tests/run.sh
```

Expected: PASS.

Commit:

```bash
git add skills/remote-chrome-mcp/SKILL.md tests/skill-contract.test.sh tests/run.sh
git commit -m "feat: add remote Chrome agent skill"
```

---

### Task 6: Documentation and GitHub CI

**Files:**
- Modify: `README.md`
- Modify: `docs/remote-login.md`
- Create: `.github/workflows/ci.yml`
- Modify: `.gitignore`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces: a Docker-first README with native installation retained.
- Produces: GitHub Actions checks on pushes and pull requests.

- [ ] **Step 1: Add the failing documentation contract**

Extend `tests/playbook-contract.test.sh` to require README sections:

```text
Docker Compose Quick Start
Native Ubuntu Installation
Migrating an Existing Installation
Human Login Console
MCP Server Instructions
Agent Skill
Security
Backup and Restore
Upgrade and Rollback
```

Require both authentication examples and reject production tokens.

Extend the pattern-based guidance scan to README and `docs/remote-login.md`: reject `eladrave.com` hostnames and 64-character hexadecimal bearer-token candidates without embedding production values.

- [ ] **Step 2: Run the documentation contract and verify failure**

Run:

```bash
bash tests/playbook-contract.test.sh
```

Expected: FAIL on missing README sections.

- [ ] **Step 3: Rewrite README around the two supported deployment modes**

Lead with Docker Compose for SSH-only servers, then document native/systemd.

Include exact commands:

```bash
./scripts/bootstrap-docker.sh --domain chrome.example.com
./setup.sh --domain chrome.example.com --email admin@example.com
./login.sh
./status.sh
```

Explain:

- DNS and 80/443 requirements;
- where secrets and profiles live;
- how to save login-console credentials;
- why the login console uses separate credentials;
- how agents receive playbook instructions;
- how to install/copy the skill;
- migration, backup, restore, update, rollback, and uninstall.

- [ ] **Step 4: Add GitHub Actions**

Create `.github/workflows/ci.yml` with jobs:

1. `test` on Ubuntu:
   - checkout;
   - setup Node 22;
   - `npm ci`;
   - install ShellCheck;
   - invoke ShellCheck against repository shell scripts;
   - `./tests/run.sh`.
2. `compose` on Ubuntu:
   - create a CI `.env` from literal safe test values;
   - `docker compose config`;
   - build `docker/Dockerfile` with Playwright MCP 0.0.78.
   - run `CI=1 bash tests/compose-smoke.test.sh`.
3. `secret-scan`:
   - run a maintained secret scanner such as Gitleaks;
   - reject `eladrave.com` production hostnames in generated guidance;
   - use a synthetic canary to prove the pattern-based bearer-token check fails without storing a production secret;
   - reject tracked `.env` and Chrome-profile files.

- [ ] **Step 5: Run local documentation and workflow validation**

Run:

```bash
./tests/run.sh
git diff --check
```

If `actionlint` is available:

```bash
actionlint
```

Expected: PASS.

- [ ] **Step 6: Commit documentation and CI**

```bash
git add README.md docs/remote-login.md .github/workflows/ci.yml .gitignore tests
git commit -m "docs: document remote login and deployments"
```

---

### Task 7: Full Local Verification and Native Migration

**Files:**
- Modify only if verification reveals defects in files from Tasks 1-6.
- System changes: user services, nginx configuration, packages, and profile backup on the current machine.

**Interfaces:**
- Consumes: the completed repository implementation and current native installation.
- Produces: a migrated live service with equivalent public MCP behavior and a working authenticated login console.

- [ ] **Step 1: Run the complete pre-migration verification**

Run:

```bash
./tests/run.sh
npm test
git diff --check
```

Expected: PASS with no skipped non-Docker tests.

- [ ] **Step 2: Inspect and back up the current installation**

Record:

```bash
systemctl --user status chrome-mcp.service playwright-mcp.service --no-pager
google-chrome --version
curl -sS http://127.0.0.1:9222/json/version
```

Confirm the profile path is exactly `/home/desktop/.config/chrome-mcp-profile`. Create the installer-managed protected backup before changing services.

- [ ] **Step 3: Apply the native migration with user-authorized sudo**

Run the completed native installer with the existing domain and token. Never request the sudo password in chat; use the user's local authentication prompt or provide a command for the user to run.

Require successful:

```bash
sudo nginx -t
systemctl --user is-active chrome-display.service chrome-window-manager.service chrome-mcp.service chrome-vnc.service chrome-novnc.service playwright-mcp.service
```

- [ ] **Step 4: Verify transport and instructions**

Run:

```bash
npx -y @mcpjam/cli@latest --no-telemetry server doctor --url "$TOKEN_PATH_URL"
```

Verify:

- ready via Streamable HTTP;
- connected and initialized;
- browser tools discovered;
- initialize instructions include `REMOTE_CHROME_PLAYBOOK_VERSION=1`;
- public POST has one `Content-Type: text/event-stream`;
- public GET returns 405;
- unauthenticated `/mcp` returns 401.

- [ ] **Step 5: Verify headed Chrome and profile persistence**

Check CDP metadata and page JavaScript:

```text
Browser begins with Chrome/
navigator.userAgent does not contain HeadlessChrome
navigator.webdriver is false
```

Create a harmless local profile marker through Chrome storage, restart Chrome, and verify the marker remains. Do not alter website credentials.

- [ ] **Step 6: Verify the human login console**

Check:

- anonymous `/login/` returns 401;
- valid Basic credentials return the noVNC application;
- WebSocket upgrade succeeds;
- the console and Playwright MCP show the same harmless test tab;
- host ports 5900, 6080, 8931, and 9222 are not publicly listening.

- [ ] **Step 7: Re-test Amazon without sensitive actions**

Through public MCP:

1. navigate to `https://www.amazon.com/`;
2. verify a snapshot succeeds;
3. verify no unsupported-client message;
4. verify the stable Account entry is visible;
5. do not submit credentials, change the account, or purchase anything.

- [ ] **Step 8: Fix any verified defects through red-green tests**

For each defect:

1. add the smallest failing automated reproduction;
2. watch it fail for the expected reason;
3. implement one fix;
4. rerun the focused test and full suite;
5. commit with a defect-specific message.

- [ ] **Step 9: Record final verification evidence**

Capture:

- test counts;
- active services;
- MCPJam doctor summary;
- initialize instruction marker;
- Chrome version and headed user-agent result;
- noVNC authentication and WebSocket result;
- profile persistence result;
- public-port exposure check;
- clean `git status`.

Do not record tokens, passwords, cookies, account names, or personal page contents.

---

### Task 8: GitHub Repository Handoff

**Files:**
- No new files unless CI or review finds a verified defect.

**Interfaces:**
- Consumes: local commits from Tasks 1-7 and origin `https://github.com/eladrave/remotechromemcp.git`.
- Produces: a review-ready branch and optional draft pull request only after user authorization.

- [ ] **Step 1: Review local history and repository state**

Run:

```bash
git log --oneline --decorate origin/master..HEAD
git status --short
git diff --check origin/master...HEAD
```

Expected: clean working tree and intentional commits only.

- [ ] **Step 2: Run final verification before any publication**

Run:

```bash
./tests/run.sh
npm test
```

When Docker is available:

```bash
docker compose --env-file .env.example config
docker build --build-arg PLAYWRIGHT_MCP_VERSION=0.0.78 -f docker/Dockerfile .
```

Expected: PASS.

- [ ] **Step 3: Ask for publication authorization**

Present:

- branch name `codex/remote-login-guidance`;
- commit list;
- verification evidence;
- proposed draft PR title `Add guided remote login and container deployment`;
- concise PR body covering native migration, Docker Compose, MCP instructions, skill, security, and tests.

Do not push or create the PR until the user explicitly approves.
