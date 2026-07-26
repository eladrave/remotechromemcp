# Remote Chrome Guidance, Human Login, and Deployment Design

**Date:** 2026-07-26

**Status:** Approved design

## Objective

Extend Remote Chrome MCP so that:

- every MCP client receives concise, server-owned browser operating instructions;
- agents can also use a portable `SKILL.md` with detailed workflows and troubleshooting;
- a human can take over the same persistent Chrome profile through a secure web console without shell access;
- Chrome runs headed in a virtual display, including on SSH-only servers;
- native Ubuntu/systemd and Docker Compose installations provide equivalent behavior;
- the existing native deployment can migrate without losing its Chrome profile or authenticated sessions.

## Out of Scope

- Automating or bypassing CAPTCHA, MFA, security keys, consent, or anti-bot challenges.
- Storing website usernames, passwords, cookies, MCP tokens, or login-console credentials in the repository, playbook, or skill.
- Building a general multi-user browser farm or concurrent-session scheduler.
- Guaranteeing that every MCP client obeys server instructions; clients control how instructions enter agent context.
- Exposing CDP, VNC, noVNC, or Playwright's internal HTTP port directly to the public network.

## Selected Approach

Chrome will always run headed inside a virtual X display. Playwright MCP and the human noVNC console will control the same Chrome process and persistent profile.

This avoids service switching, profile-lock races, agent disconnects during human login, and the `HeadlessChrome` user-agent token. It also gives desktop and SSH-only installations the same runtime behavior.

The rejected alternatives are:

1. Switching between headless automation and headed login mode. This interrupts clients and creates profile ownership and lock transitions.
2. Keeping headless Chrome and adding instructions only. This does not provide shell-free human login and remains less compatible with sites that reject headless sessions.

## Runtime Architecture

```text
Agent
  |
  | HTTPS + MCP authentication
  v
Reverse proxy -----> Playwright MCP ---- CDP ----+
                                                  |
User                                              v
  |                                        Headed Chrome
  | HTTPS + separate Basic authentication        |
  v                                              |
noVNC ---- WebSocket ---- x11vnc ---- Xvfb <-----+
```

### Shared Runtime Contract

Both deployment modes must expose the same public and private interfaces:

- Public MCP endpoint:
  - `https://<domain>/mcp` with an `Authorization: Bearer` header.
  - `https://<domain>/<mcp-token>/mcp` for clients that cannot set headers.
- Public human-login console:
  - `https://<domain>/login/` protected by separate HTTP Basic credentials.
- Private CDP:
  - `127.0.0.1:9222` natively or an internal container interface only.
- Private Playwright MCP:
  - `127.0.0.1:8931` natively or an internal Compose network only.
- Private VNC and noVNC upstream ports:
  - loopback or an internal Compose network only.

The reverse proxy must:

- preserve Playwright MCP's upstream `Content-Type`;
- return HTTP 405 for unsupported GET streaming on `/mcp`;
- support long-lived Streamable HTTP and noVNC WebSocket connections;
- avoid logging secret-bearing MCP URL paths;
- require Basic authentication for `/login/`;
- never expose internal service ports.

## Browser Runtime

The browser runtime consists of:

- Xvfb virtual display;
- a lightweight window manager;
- full Google Chrome in headed mode;
- the existing persistent Chrome profile;
- x11vnc bound to the virtual display;
- noVNC/websockify;
- Playwright MCP connected to Chrome through CDP.

Chrome must:

- omit `--headless`;
- use the persistent `chrome-mcp-profile`;
- bind CDP privately;
- remove stale `Singleton*` locks before startup;
- restart on failure;
- retain the existing `--no-first-run` and `--no-default-browser-check` behavior.

The display resolution defaults to 1440x900 and is configurable.

Only one Chrome process may own the persistent profile. Human and agent interaction share that process rather than starting a second browser.

## Human Login and Control Flow

### Normal Agent Operation

1. The client initializes MCP and receives the server playbook.
2. The agent snapshots the current tab before navigating.
3. The agent reuses existing tabs and authenticated state.
4. The agent starts at a site's stable entry page and follows visible authentication links.
5. After navigation errors or timeouts, the agent snapshots again before retrying or declaring failure.

### Human Authentication Required

1. The agent stops interacting with Chrome.
2. The agent states what requires human action and directs the user to `https://<domain>/login/`.
3. The user authenticates to the console using the separately generated Basic credentials.
4. noVNC displays the same Chrome process and profile used by Playwright MCP.
5. The user completes login, MFA, CAPTCHA, consent, or security-key interaction.
6. The user returns to the agent and says that control can resume.
7. The agent takes a new snapshot and continues.

Agents must not interact while the user has control. This is a coordination rule rather than a technical lock in the first version.

### Desktop and SSH-Only Behavior

- On a desktop installation, `login.sh` opens the HTTPS login console in the local default browser and also prints its URL.
- On an SSH-only installation, `login.sh` prints the URL and instructions; the user opens it from another machine.
- No service restart is required for either flow.
- The installer prints the login-console username and generated password once and instructs the user to store them in a password manager.

## MCP Server Instructions

### Source

`browser-playbook.md` is the single source of server-owned operating instructions.

It contains:

- a versioned marker for diagnostics;
- snapshot-first and existing-tab rules;
- navigation timeout recovery;
- stable-entry-page and visible-login-link guidance;
- persistent profile expectations;
- MCP session and element-reference constraints;
- human-control escalation without assuming shell access;
- credential, CAPTCHA, MFA, purchase, and destructive-action safety;
- concise domain-specific rules, initially including Amazon.

It must not contain installation-specific secrets or login-console credentials.

### Injection

Playwright MCP does not currently expose a public configuration option for MCP initialization instructions. A small Node preload shim will:

1. read `browser-playbook.md` for every MCP initialization;
2. set the MCP SDK server's initialization instructions before the normal initialize handler returns;
3. use a minimal embedded safety playbook if the file is missing or invalid;
4. emit a clear warning when falling back.

Native systemd and the container entrypoint load the same shim through `NODE_OPTIONS=--require=<shim>`.

The implementation relies on the MCP SDK server's instructions behavior used by Playwright's bundled SDK. Because this is an integration seam rather than a Playwright CLI option, automated initialization tests must guard it during Playwright upgrades.

## Portable Agent Skill

The repository will include:

```text
skills/remote-chrome-mcp/
  SKILL.md
```

The skill will explain:

- when to use a remote persistent browser;
- how to connect without embedding real tokens in the skill;
- that server-provided instructions are authoritative and may be newer;
- snapshot-first browser control;
- navigation timeout recovery;
- reuse of tabs and persistent authentication;
- why guessed deep authentication URLs are unsafe;
- MCP session and snapshot reference lifetime;
- human-login escalation through `/login/`;
- SSH-only and container deployments;
- handling CAPTCHA, MFA, security keys, purchases, and other sensitive actions;
- troubleshooting transport, browser, login-console, and page-level failures;
- example recovery scenarios.

The skill must use placeholders for domain and authentication settings. It must not include the current production endpoint or token.

## Native Ubuntu/Systemd Deployment

The native installer will:

- continue supporting Ubuntu hosts with or without a desktop session;
- install or verify Xvfb, a lightweight window manager, x11vnc, noVNC/websockify, and Basic-auth tooling;
- generate separate login-console credentials;
- create user services with explicit dependencies:
  - virtual display;
  - window manager;
  - Chrome;
  - x11vnc/noVNC;
  - Playwright MCP;
- update nginx with MCP and login-console routes;
- validate generated configuration before activation;
- back up the active nginx and systemd configuration before migration;
- preserve the existing Chrome profile;
- restart only after validation succeeds.

The installer remains idempotent and supports environment-variable overrides.

`login.sh` changes from stopping Chrome to opening or printing the persistent login-console URL.

`status.sh` checks every layer and reports failures separately.

`uninstall.sh` removes generated services and proxy configuration but must require an explicit choice before deleting the persistent Chrome profile.

## Docker Compose Deployment

Docker Compose is the recommended installation for a new SSH-only server.

The Compose deployment contains:

### Browser Runtime

A purpose-built image that includes:

- full Google Chrome;
- Node.js and a version-pinned Playwright MCP;
- Xvfb;
- lightweight window manager;
- x11vnc;
- noVNC/websockify;
- the instruction preload shim and browser playbook;
- a process supervisor or deterministic entrypoint with child-process health handling.

The service uses:

- `init: true`;
- `restart: unless-stopped`;
- enlarged shared memory;
- a named persistent profile volume;
- internal-only CDP, MCP, VNC, and noVNC ports;
- health checks for Chrome CDP, MCP initialization, and noVNC.

### Reverse Proxy

A Caddy service provides:

- automatic HTTPS;
- MCP bearer-header and token-path authentication;
- HTTP 405 for unsupported MCP GET;
- Basic authentication for `/login/`;
- noVNC WebSocket proxying;
- sanitized or disabled logs for secret-bearing routes;
- persistent certificate data.

### Bootstrap

A bootstrap script:

1. checks Docker and Compose;
2. asks for the domain;
3. generates independent MCP and login-console secrets;
4. writes a protected local environment file;
5. validates the rendered Compose configuration;
6. starts the deployment;
7. runs end-to-end health checks;
8. prints MCP configuration examples and login-console credentials once.

## Authentication and Security

- MCP and login-console credentials are independent.
- MCP bearer-header authentication is preferred; token-in-path remains for client compatibility.
- The login console uses Basic authentication at a non-secret `/login/` path.
- Login-console credentials are never returned through MCP instructions.
- Reverse-proxy logs must not record the MCP path token.
- CDP remains private because it grants complete control over browser sessions and cookies.
- VNC and noVNC upstream ports remain private.
- Profile and secret files use restrictive permissions.
- Container volumes containing browser state are treated as secrets.
- Agents must ask before purchases, submissions, account changes, or other consequential actions.
- Agents must not bypass human-verification challenges.

## Failure Handling

### Component Isolation

- A Chrome crash restarts Chrome against the same persistent profile after stale-lock cleanup.
- A Playwright MCP crash restarts MCP without restarting Chrome.
- A noVNC failure does not take down MCP or Chrome.
- A reverse-proxy failure does not alter browser state.

### Playbook Failure

If `browser-playbook.md` cannot be read:

- initialization still succeeds;
- a minimal embedded safety playbook is returned;
- a warning is logged;
- `status.sh` reports degraded guidance.

### Upgrade and Rollback

- Playwright MCP and container base versions are pinned.
- Upgrades must pass initialize-instructions and browser integration tests before activation.
- Native configuration is backed up and validated before replacement.
- Docker retains the previous image reference for rollback.
- Existing profiles are backed up before the first headed-display migration.

## Validation

### Static and Generation Checks

- Shell syntax and ShellCheck.
- Generated systemd and proxy configuration validation.
- `docker compose config`.
- Dockerfile build.
- No checked-in secrets.
- The skill and playbook contain required sections and no production endpoint or token.

### MCP Checks

- Initialize succeeds through both authentication methods.
- Initialize includes the playbook version marker and instructions.
- MCPJam reports the server ready and lists browser tools.
- Public responses contain exactly one valid `Content-Type`.
- Unsupported GET returns HTTP 405.
- Missing-playbook fallback instructions are returned.

### Browser Checks

- Chrome reports a full headed Chrome user agent without `HeadlessChrome`.
- CDP is reachable only from the expected private interface.
- Browser navigation and snapshot work through public MCP.
- Profile state survives Chrome and container restarts.
- The existing native profile remains usable after migration.

### Human Console Checks

- Anonymous `/login/` access is rejected.
- Valid Basic authentication serves noVNC.
- noVNC WebSocket upgrade succeeds.
- The console controls the same Chrome tab seen by Playwright MCP.
- VNC and websockify ports are not publicly reachable.

### Skill Scenario Checks

The skill is tested against scenarios covering:

- navigation timeout followed by successful snapshot;
- stale or already-authenticated tabs;
- invalid guessed deep-login URLs;
- MFA, CAPTCHA, and security-key escalation;
- human handoff without shell access;
- element references reused across different MCP sessions;
- sensitive actions requiring confirmation;
- native and container deployments.

Tests must not submit real credentials, make purchases, change real accounts, or attempt to bypass challenges.

## Documentation

The README will clearly separate:

- Docker Compose quick start for new remote servers;
- native/systemd installation and migration;
- MCP client configuration;
- login-console usage;
- credential storage and rotation;
- profile backup and restore;
- health checks and troubleshooting;
- skill installation and use;
- upgrade and rollback procedures.

## Acceptance Criteria

The feature is complete when:

1. Native and Compose deployments expose equivalent MCP and login-console behavior.
2. A new MCP connection receives versioned server instructions.
3. A supplied agent skill teaches the same workflow without containing secrets.
4. A user with only a web browser can complete human authentication in the shared Chrome profile.
5. No shell or service restart is required for routine human login.
6. Chrome is headed and does not identify as `HeadlessChrome`.
7. Browser profile state survives restarts and migration.
8. Internal browser-control ports are not publicly exposed.
9. Automated checks cover transport, instructions, browser, profile persistence, authentication, and noVNC.
10. Existing production MCP behavior remains compatible with MCPJam and other Streamable HTTP clients.
