# Remote Chrome MCP: Coding-Agent Handoff

## Why this file exists

This repository is an in-progress production deployment for a remotely
accessible, persistent, full Chrome browser controlled through the Model Context
Protocol (MCP). The intended reader is the next coding agent responsible for
finishing the implementation.

Read this entire file before changing code. It records the product goal, the
current architecture, what has already been implemented and tested, the
problems encountered, the exact unresolved blocker, the available solution
paths, and the recommended implementation sequence.

At the time this handoff was written:

- the published baseline on `origin/master` was commit `c7703c4`;
- the Docker/VM installer, HTTPS proxy, browser profile persistence, and web
  login console were implemented;
- the main unresolved blocker was multi-call MCP session persistence when using
  Playwright MCP's Streamable HTTP transport;
- `@playwright/mcp` was pinned to `0.0.78`, which was also the version shown in
  Microsoft's upstream repository at the time;
- there was no production `v1.0.0` release/tag yet, despite documentation using
  it as an explicitly non-live example.

Do not put credentials, bearer tokens, cookies, passwords, recovery codes, or
current connection URLs containing tokens in this file, commits, test output,
issues, or pull requests.

## Product goal

The finished product must let a user install a persistent remote Chrome MCP
server in either of these supported environments:

1. A normal Linux machine or VM reached only through SSH.
2. A Docker-capable Ubuntu 22.04, Ubuntu 24.04, or Debian 12 x86_64 host.

The preferred installation experience is:

```sh
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

The guided installer must ask for everything required, including the public
domain and ACME certificate email, validate the environment, install Docker
when necessary, bind the public service to host TCP 80/443, obtain and renew a
TLS certificate through Caddy, and print a protected connection handoff.

The user must then be able to:

- connect a normal remote MCP client over HTTPS;
- authenticate either with a bearer header or, for compatibility-only clients,
  with a secret embedded in the MCP URL;
- open `https://<domain>/login/` in an ordinary web browser;
- authenticate to that page with separate Basic Auth credentials;
- see and control the same headed Chrome through noVNC;
- manually complete site passwords, CAPTCHA, MFA, security keys, or other human
  verification without needing shell access;
- return control to an MCP agent;
- keep website cookies, local storage, and login state across MCP disconnects,
  Chrome restarts, container recreation, host reboots, and software updates;
- back up and restore the persistent profile to/from GCS when configured;
- retrieve status and credentials later through the root-only management CLI.

The user explicitly does **not** want a design where an agent must enter the
container, connect to CDP directly, or run a shell command every time a website
requires login. Agents must control Chrome through the public MCP endpoint.
Humans use `/login/` for authentication handoff.

## Non-goals and boundaries

- Do not expose CDP `9222`, VNC `5900`, noVNC `6080`, or internal MCP `8931` on
  the public host. Only Caddy's TCP 80/443 ports are published.
- Do not ask users to send site passwords or MFA material through chat.
- Do not automate CAPTCHA, MFA, security-key prompts, or similar verification.
- Do not erase or replace the persistent Chrome profile during upgrades.
- Do not silently take over an existing host web server on port 80/443. The
  installer currently aborts on a listener conflict.
- Do not claim Google Cloud Run is supported by the current implementation.
  See "Cloud Run status" below.
- Do not solve the current MCP defect by teaching agents to reconnect after
  every browser operation or by putting every interaction into one unsafe
  one-shot tool call. Those are diagnostic workarounds, not the product.

## Required user-visible behavior

The following distinctions are fundamental:

### Durable browser-profile state

The Chrome profile contains cookies, local storage, history, and website
authentication. It lives under the configured host data directory and is bind
mounted at `/data/chrome-profile`. It must survive container replacement and
host restart just like a normal desktop Chrome profile survives a computer
restart.

### Ephemeral MCP protocol state

An MCP Streamable HTTP session carries a session ID, transport state, and
short-lived browser-tool state such as snapshot element references. It may
eventually expire, but it must remain usable across a normal sequence of tool
calls. A health check or unrelated client must never invalidate it.

### Visible browser process

Chrome is a current full Google Chrome Stable process running against Xvfb and
Openbox. It is not Chrome's newer headless mode. The same Chrome is exposed to
Playwright over loopback CDP and to the human over x11vnc/noVNC.

These layers are related but not interchangeable. A durable Chrome profile does
not repair a disappearing MCP transport session. A stable MCP transport does
not, by itself, persist website cookies after Chrome restarts.

## Current architecture

The primary implementation is Docker Compose:

```text
Remote MCP client
        |
        | HTTPS POST/DELETE
        | Bearer header OR /<token>/mcp compatibility URL
        v
  Caddy container :443
        |
        | internal Docker network
        v
  Playwright MCP :8931
        |
        | CDP on 127.0.0.1:9222
        v
  full Google Chrome Stable
        |
        +-- /data/chrome-profile (persistent host bind mount on VM)
        |
        +-- Xvfb :99 -> Openbox -> x11vnc -> noVNC :6080
                                      ^
                                      |
                  Caddy /login/ + Basic Auth + WebSocket proxy
```

The `browser` container runs:

- Xvfb;
- Openbox;
- Google Chrome Stable;
- x11vnc;
- websockify/noVNC;
- `@playwright/mcp`.

Supervisor keeps these processes running. Compose uses
`restart: unless-stopped`. The VM installer also installs a systemd service
that starts the Compose project at boot.

The `proxy` container runs Caddy. It:

- binds host port 80 and redirects normal traffic to HTTPS;
- binds host port 443 and manages ACME certificates;
- proxies authenticated `/mcp`;
- rewrites the token compatibility route `/<token>/mcp` to `/mcp`;
- proxies `/login/` to noVNC with Basic Auth and WebSocket upgrade support;
- does not expose any internal service port.

## Source map

Study these files before implementing the session fix:

| Path | Purpose |
|---|---|
| `compose.yaml` | Base browser/proxy Compose stack, networks, health checks, and named volumes. |
| `vminstall/compose.vm.yaml` | VM overlay: non-root IDs and persistent host bind mounts. |
| `docker/Dockerfile` | Installs Google Chrome Stable, noVNC stack, and pinned Playwright MCP. |
| `docker/supervisord.conf` | Starts Xvfb, Chrome, VNC, noVNC, and Playwright MCP. |
| `docker/entrypoint.sh` | Validates/mounts the profile and removes only stale Chrome singleton locks. |
| `docker/healthcheck.sh` | Current internal readiness check; it still initializes and deletes an MCP session every 15 seconds. |
| `Caddyfile` | Public routes, auth, token compatibility URL, TLS, and noVNC WebSocket proxy. |
| `browser-playbook.md` | Runtime operating instructions injected into MCP initialization. |
| `lib/inject-instructions.cjs` | Patches the active Playwright MCP runtime to inject the browser playbook. |
| `skills/remote-chrome-mcp/SKILL.md` | Portable instructions for agents using a configured server. |
| `vminstall/install.sh` | Small curl-pipe bootstrap that downloads and validates a source/release archive. |
| `vminstall/installer-main.sh` | Guided VM installer entry point. |
| `vminstall/lib/config.sh` | Credentials, Compose environment, managed paths, and persistent runtime directories. |
| `vminstall/lib/activate.sh` | Activation, public HTTPS verification, rollback, and service readiness. |
| `vminstall/lib/management.sh` | `remote-chrome` status, credentials, update, restore, and uninstall commands. |
| `vminstall/lib/backup.sh` | Quiesced Chrome-profile backup and atomic restore logic. |
| `docs/vm-install.md` | Generic VM installation and operations guide. |
| `docs/gce-manual.md` | Manual GCE VM, Persistent Disk, firewall, and GCS backup guide. |
| `tests/compose-smoke.test.sh` | Full container runtime, routing, noVNC, and profile persistence smoke test. |
| `tests/run.sh` | Main non-runtime contract and shell test entry point. |

The root `README.md` still leads with the older native/systemd architecture and
is now misleading about the preferred container deployment. Updating it is a
secondary outstanding documentation task.

## Supported deployment paths

### Docker/VM path: primary

This is the target to finish. It works on a host without a physical Linux
desktop because Xvfb, Openbox, Chrome, VNC, and noVNC are inside the browser
container.

The VM installer supports:

- Ubuntu 22.04 x86_64;
- Ubuntu 24.04 x86_64;
- Debian 12 x86_64;
- interactive input through `/dev/tty` even when the script itself arrives on
  stdin through `curl | sudo sh`;
- explicit noninteractive flags;
- DNS and port preflight;
- Docker/Compose installation;
- secure release staging;
- activation with recovery to the previous release;
- a root-only connection handoff;
- persistent profile, Caddy certificate, and Caddy configuration directories;
- optional scheduled GCS backup;
- backup/restore maintenance locking and browser quiescing.

### Native path: legacy/rollback

The repository still contains `setup.sh`, `login.sh`, native systemd templates,
and nginx templates. A previously working native Chrome/Playwright deployment
was deliberately retained on the development machine as a rollback option.

Do not remove it as part of the HTTP-session fix. The primary public endpoint
should route to the container stack, but preserving the native installation
until the container passes the complete acceptance test was an explicit user
requirement.

### Inspecting an existing VM installation

Do not infer the live deployment from listening ports or from repository state.
When given root access to an installed VM, use the management interface:

```sh
sudo remote-chrome status
sudo remote-chrome credentials
systemctl status remote-chrome.service
```

The credentials command prints secrets and must be run only in the operator's
trusted terminal. Do not paste its output into agent conversation or logs.

The development machine may also show the preserved native user services as
active. That does not prove which backend Caddy currently reaches. Inspect the
active release, Compose project, and proxy configuration before restarting or
rerouting anything. Never stop or uninstall the native services merely to make
the status output look simpler.

### Google Compute Engine VM: documented

`docs/gce-manual.md` documents:

- a static public IP;
- a dedicated service account;
- TCP 80/443 firewall access;
- a non-boot Persistent Disk for the live profile;
- a private GCS bucket for backups;
- bucket-scoped IAM;
- careful disk inspection and confirmation before formatting.

This VM path matches the product's long-running browser requirements.

### Cloud Run status

Cloud Run was discussed as a desired deployment option, but it is not delivered
by the current repository and should not be advertised as working.

The current design assumes:

- one long-lived Chrome process;
- stable WebSocket/noVNC connections;
- local profile locking and SQLite-like file semantics;
- a writable POSIX filesystem;
- a stable single instance;
- host-owned TCP 80/443 and ACME state.

Cloud Run may stop or replace instances, can scale to multiple instances, and
does not provide a normal persistent disk for Chrome's live profile. A GCS or
GCS FUSE mount is appropriate for backup/object storage, not necessarily as a
live Chrome user-data directory with locks and databases. Supporting Cloud Run
would require a separate design: externalized browser/session ownership,
single-instance constraints, durable compatible storage, and likely a
different TLS/domain topology.

Unless the user explicitly reopens that project, finish and validate the VM
deployment first. Do not delay the VM fix by attempting Cloud Run in the same
change.

## Public routes and authentication

The current Caddy contract is:

| Route | Authentication | Expected behavior |
|---|---|---|
| `POST /mcp` | `Authorization: Bearer <token>` | Proxy to internal Playwright MCP. |
| `DELETE /mcp` | Bearer header | End the specified MCP session. |
| `POST /<token>/mcp` | Token embedded in path | Compatibility route, rewritten to `/mcp`. |
| `DELETE /<token>/mcp` | Token embedded in path | Compatibility session deletion. |
| `GET /mcp` or `GET /<token>/mcp` | N/A | Return 405 because this server currently does not provide an SSE GET stream. |
| `/login/` | Separate HTTP Basic Auth | Serve noVNC and proxy its WebSocket. |
| `/healthz` over HTTP | None | Caddy container health only. |

Bearer-header authentication is preferred. The embedded-token URL exists
because some MCP clients cannot attach custom headers. A URL token can leak
through browser history or client telemetry; Caddy access logging is discarded
to reduce exposure, but the route remains a compatibility compromise.

Credentials are generated by `vminstall/lib/config.sh` and stored in root-only
managed files. Operators retrieve them on the host with:

```sh
sudo remote-chrome credentials
```

Never commit values from that command.

## Runtime browser guidance

`browser-playbook.md` is injected into the MCP initialization instructions.
`skills/remote-chrome-mcp/SKILL.md` is intended to be given to agents.

The important operational rules are:

- inspect existing tabs and take a fresh snapshot before acting;
- reuse authenticated state;
- start from stable site homepages instead of guessing deep login URLs;
- use element references only from a relevant snapshot in the same MCP
  session;
- hand passwords, MFA, CAPTCHA, security keys, and verification to the human
  through `/login/`;
- never clear the profile unless explicitly asked;
- require confirmation before purchases or persistent account changes;
- assume the human may have no shell access.

The playbook injection is a required runtime contract. Existing tests check for
the marker `REMOTE_CHROME_PLAYBOOK_VERSION=1`.

## Work completed and issues already solved

The published implementation contains substantially more than the old root
README suggests. Important completed work includes:

### Full headed browser in a container

- Installed current Google Chrome Stable from Google's Debian repository.
- Ran it visibly under Xvfb/Openbox rather than in headless mode.
- Bound CDP to container loopback only.
- Connected Playwright MCP to the existing Chrome through CDP.
- Added x11vnc and noVNC for human control.
- Used a dedicated unprivileged `remote-chrome` user.

This addressed the original problem where Amazon rejected a previous browser
session as unsupported before the login form loaded. In later testing, Amazon's
normal homepage and sign-in flow loaded through the full containerized Chrome.

### Persistent website authentication

- Mounted the Chrome user-data directory on durable storage.
- Removed only stale `Singleton*` lock files after an unclean stop.
- Preserved cookies and other profile state.
- Added a Compose smoke test that creates a cookie, recreates the browser
  container, and verifies the cookie still exists.
- Added VM backup/restore using a quiesced browser and validated archive.

The user manually logged into Amazon through noVNC during testing. Cookie and
profile persistence across container recreation were also tested separately.
Do not assume any particular website login is still valid now; sites may expire
sessions independently.

### noVNC login console

- Added Basic Auth separate from MCP auth.
- Fixed reverse proxying below `/login/`.
- Patched noVNC's configured WebSocket path to
  `/login/websockify`.
- Added tests requiring HTTP 200 for the authenticated UI and WebSocket 101 for
  the connection upgrade.

This fixed the earlier visible noVNC error "Failed to connect to server."

### HTTPS and port routing

- Replaced ad hoc host nginx routing for the container path with a Caddy
  container.
- Published only host TCP 80/443.
- Added automatic ACME/TLS handling and persistent Caddy state.
- Added DNS and listener preflight in the VM installer.
- Added tests that reject publication of `5900`, `6080`, `8931`, or `9222`.

### MCP authentication and compatibility

- Implemented bearer-header auth at `/mcp`.
- Implemented token-in-path compatibility at `/<token>/mcp`.
- Rewrote the compatibility route internally so Playwright sees `/mcp`.
- Ensured secret-bearing requests do not reach a Caddy access log.
- Added anonymous 401 checks.

### HTTP transport interoperability fixes

Several earlier MCPJam errors were addressed:

- An nginx-added `Content-Type: application/json` combined with Playwright's
  `text/event-stream` response and produced the invalid combined type
  `text/event-stream, application/json`. Caddy now passes the upstream content
  type without appending a duplicate header.
- Playwright MCP returns HTTP 400 for unsupported GET `/mcp`; the public proxy
  now returns 405 for non-POST/DELETE requests, signaling that GET SSE is not
  supported.
- Header parsing was made case-insensitive/portable.
- Tests assert exactly one response `Content-Type`.

These changes make initialization succeed, but they do **not** solve the
multi-call session deletion described below.

### Guided installer and management lifecycle

- Implemented the `curl | sudo sh` bootstrap.
- Added interactive and noninteractive configuration.
- Added supported distribution/architecture checks.
- Added DNS, port, Docker, archive, path, and permissions validation.
- Used immutable release/checksum behavior for future tagged releases.
- Added root-confined managed paths and symlink defenses.
- Added atomic activation and rollback behavior.
- Added a stable Compose project name.
- Added `remote-chrome status`, `credentials`, `login`, `wait-ready`, `update`,
  `backup`, `restore`, and `uninstall`.
- Preserved profile data by default on uninstall.
- Added optional scheduled GCS backups and transactional restore.
- Hardened timeout/process-tree handling and publication recovery.

### Runtime instructions and portable skill

- Injected deployment-specific browser operating instructions at initialize.
- Added a portable `SKILL.md`.
- Added contract tests for both.

## Tests that currently exist

Install Node dependencies before running JavaScript tests:

```sh
npm ci
```

Run the main contract/unit/shell suite:

```sh
bash tests/run.sh
```

This suite covers instruction injection, native rendering, Compose contracts,
VM installer parsing and confinement, supported distributions, management,
backup/restore, documentation contracts, and shell syntax.

Run the full Docker runtime smoke test separately:

```sh
bash tests/compose-smoke.test.sh
```

That smoke test:

- builds the browser image;
- waits for browser and proxy health;
- verifies full non-headless Chrome metadata;
- initializes and deletes one internal MCP session;
- verifies noVNC;
- writes a profile sentinel;
- creates a browser cookie;
- recreates the browser container;
- verifies the sentinel and cookie survive;
- tests bearer-header and embedded-token initialization over HTTPS;
- checks unauthenticated MCP is 401;
- checks unsupported GET is 405;
- checks exactly one Content-Type header;
- checks the authenticated noVNC page;
- checks the noVNC WebSocket upgrade;
- checks that private service ports are not published.

The critical gap is that this test initializes a session and immediately
deletes it. It does not make two or more MCP tool calls in the same session.
Consequently it passed while the core multi-step defect remained undetected.

## The outstanding blocker: HTTP MCP sessions disappear

### Reproduced behavior

Testing through the public HTTPS MCP endpoint with the current embedded token
produced:

```text
POST initialize with no session ID
  -> HTTP 200
  -> response includes Mcp-Session-Id

POST first browser tool call with that same session ID
  -> HTTP 200
  -> browser action succeeds

POST second request with the same session ID
  -> HTTP 404
  -> "Session not found"
```

This happened immediately and reproducibly; it did not require waiting for the
15-second Docker health-check interval.

The browser itself remained open because Chrome and its profile are shared and
persistent. The failed layer was the MCP HTTP transport/session. This means
cookies may persist while element references and the logical tool sequence
break.

### Correction to an earlier diagnosis

The health check was initially blamed for replacing or killing the real client
session. That conclusion was too quick and is not supported by the later test.

`docker/healthcheck.sh` creates a separate session, captures its own
`Mcp-Session-Id`, validates the playbook marker, and deletes that same session.
A correct stateful MCP server must isolate session IDs, so this should not
invalidate another client's session.

The current health check is still undesirable because it mutates the stateful
MCP lifecycle every 15 seconds and can obscure debugging. It should be
simplified. However, the immediate first-call/second-call failure points to the
Playwright MCP HTTP implementation, not to the health-check timing.

### Expected MCP behavior

Under Streamable HTTP:

1. The client sends `initialize`.
2. If the server returns `Mcp-Session-Id`, the client includes that ID on all
   subsequent related requests.
3. The server retains the logical session.
4. The server may expire a session and return 404.
5. A client receiving a legitimate 404 should initialize a new session.

Reinitialization is recovery from expiration. It is not intended to happen
after every browser action. Even if a client reconnects automatically, old
snapshot references and other in-memory tool state cannot be assumed valid.

Relevant specifications and examples:

- MCP Streamable HTTP transport:
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- MCP TypeScript SDK stateful HTTP server documentation:
  <https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/server.md>

### Upstream Playwright MCP evidence

The observed behavior matches these Microsoft Playwright MCP reports:

- <https://github.com/microsoft/playwright-mcp/issues/1140>
  describes HTTP/container mode succeeding on the first tool call and returning
  404 `Session not found` on the second because the HTTP transport's close
  handler immediately removes the session from its map.
- <https://github.com/microsoft/playwright-mcp/issues/1045>
  describes browser state disappearing between calls from ChatGPT/Claude HTTP
  integrations while local/stdio operation remains usable.

Both issues were shown as closed when investigated, but no linked released fix
was established. Do not interpret "closed" as proof that the package used here
is fixed. The repository and this project both showed version `0.0.78` at the
time, and the deployed behavior is the deciding evidence.

### A separate client configuration issue

During testing, a previously configured Codex remote connector still referenced
an older embedded token URL and returned 404. A custom protocol client using the
current protected URL successfully initialized and reproduced the multi-call
failure.

Do not confuse a stale configured token URL with the session bug:

- stale URL/token: initialization itself fails, commonly 401 or 404;
- HTTP session bug: initialization and the first tool call succeed, then the
  same session returns 404.

## Solution options

### Option A: patch Playwright MCP's built-in HTTP session lifecycle

Modify the installed `@playwright/mcp` HTTP runtime so a session remains in the
session map across ordinary request/connection completion. Refresh an idle
deadline after each valid request, delete on explicit MCP `DELETE`, and clean up
after a bounded idle timeout.

Advantages:

- smallest architectural change;
- preserves existing Caddy routes and client configuration;
- preserves Playwright MCP's current tool surface and instruction injection;
- likely the fastest route to an urgent working deployment.

Risks:

- the package is compiled third-party code and internal paths may change;
- retaining a transport object is useful only if that object can handle a later
  request after its close callback;
- a brittle search/replace can silently patch the wrong code;
- a short arbitrary delay such as five seconds is inadequate for agents that
  think or wait between actions;
- unbounded session retention would leak memory/resources.

Requirements if choosing this option:

- inspect the exact installed package source during the image build;
- make the patch deterministic and fail the build if the expected source
  signature is absent;
- use an explicit configurable idle timeout, initially around 30 minutes, not a
  five-second grace period;
- refresh the timeout on every request;
- preserve explicit `DELETE` semantics;
- ensure session cleanup closes associated transport/browser resources;
- add a build-time assertion that the patched behavior is present;
- add the full public multi-call regression test before declaring success.

Do not assume the issue author's proposed delayed `sessions.delete()` snippet
is sufficient. Test the actual reused transport.

### Option B: add a Streamable HTTP gateway backed by Playwright MCP stdio

Run Playwright MCP in its stable stdio mode and place a small first-party
Streamable HTTP server in front of it. The gateway owns external MCP session
IDs and maps each live external session to a managed backend stdio connection.

Advantages:

- avoids the known Playwright HTTP wrapper entirely;
- uses the transport mode reported to work for multi-step operations;
- gives this project explicit control over session TTL, cleanup, limits, and
  observability;
- can be tested independently of upstream HTTP internals.

Risks:

- more code and a larger maintenance/security surface;
- must correctly implement MCP initialization, notifications, request IDs,
  errors, cancellation, and cleanup;
- must decide whether to use one backend process per external session or safely
  multiplex a backend;
- multiple stdio children attaching to the same CDP browser need concurrency
  testing;
- instruction injection environment variables must reach backend children;
- resource limits are required to prevent unlimited child processes.

Recommended gateway shape if Option A fails:

- use the official MCP TypeScript SDK for the public Streamable HTTP side;
- keep a `Map<externalSessionId, SessionRecord>`;
- give each external session a backend Playwright MCP stdio child initially,
  because it provides the clearest isolation;
- start each child with the same CDP endpoint and inherited playbook injection
  environment;
- serialize requests per session;
- impose maximum session count and a sliding idle timeout;
- on explicit `DELETE` or timeout, close transport and terminate the child;
- reject unknown session IDs with the spec-compliant 404;
- add graceful shutdown handling;
- expose only the gateway's internal port to Caddy;
- do not let Caddy manage MCP application sessions.

If multiple backend children cannot safely share the same Chrome default
context, evaluate a single serialized backend process as a deliberate
single-user limitation. Document the limitation rather than creating undefined
concurrency.

### Option C: move to a verified upstream/v-next release

If Microsoft publishes a newer Playwright MCP release with documented
Streamable HTTP session fixes:

- inspect its changelog/source;
- update the pinned version and lockfile;
- rebuild from scratch;
- run the same multi-call acceptance test.

Advantages:

- least project-specific code;
- follows upstream maintenance.

Risks:

- no fixed release was verified at handoff time;
- issue closure or a `latest` label is not evidence;
- a newer version may change tools, internal instruction injection, or browser
  attachment behavior.

Do not unpin to `latest` in production. Pin an exact tested version.

### Option D: client reconnects or one-shot browser scripts

Possible emergency workarounds include:

- reinitialize after every 404;
- avoid snapshot references and use stable selectors;
- perform a complete workflow inside one `browser_run_code_unsafe` call.

These are not recommended product solutions. They are incompatible with normal
multi-step agent behavior, can lose reference state, reduce safety and
inspectability, and require special client behavior. Keep them only as
diagnostic tools.

## Recommended decision

Use a time-boxed Option A implementation first, with the regression test written
before the patch. It directly targets the reproduced defect and is the smallest
change.

The decision gate is objective:

- if the same public session performs multiple ordinary Playwright MCP calls
  before and after a wait spanning at least two health-check intervals, Option
  A is acceptable;
- if the retained transport is closed/unusable or the patch becomes invasive,
  stop patching and implement Option B;
- do not keep adding Caddy/nginx/client workarounds because the failure is
  behind the proxy after successful initialization.

Option C is preferable to maintaining a patch only when an exact upstream
version passes the same test. Option D is not an acceptance path.

## Required implementation sequence for the next agent

### Phase 1: reproduce with a committed regression client

1. Start from the latest remote default branch and keep the existing native
   rollback installation intact.
2. Add a small Node test client that understands both JSON and SSE-framed MCP
   responses.
3. Make the test operate through public HTTPS, not by invoking Docker or CDP
   directly.
4. Initialize once and retain the returned `Mcp-Session-Id`.
5. Send `notifications/initialized` if required by the negotiated protocol.
6. Call `tools/list`.
7. Call at least two normal browser tools using the same session.
8. Prefer a deterministic local fixture served inside the browser container so
   the test does not depend on Amazon or the public internet.
9. Create a page containing a button/input, snapshot it, use a reference from
   that snapshot in a later tool call, and verify the page changed.
10. Wait at least 35 seconds, spanning two 15-second health-check intervals.
11. Call another browser tool with the same session and verify state.
12. Explicitly delete the session and verify subsequent use gets 404.
13. Run the test for both bearer-header and embedded-token public routes where
    practical, but one complete lifecycle may be sufficient if route rewriting
    is separately covered.

The test must fail on the current baseline for the known reason before the fix
is applied. Capture status codes and sanitized error text, never secrets.

### Phase 2: simplify the health check

Change `docker/healthcheck.sh` so the recurring 15-second probe does not create
and delete an MCP application session.

Suitable recurring checks include:

- supervisor-managed processes are running;
- CDP `/json/version` responds with full `Chrome/` and not `HeadlessChrome`;
- internal TCP port 8931 accepts a connection;
- noVNC static content responds.

Keep one full protocol lifecycle test in activation/installer verification, but
make that test exercise multiple calls rather than initialize/delete only.

Do not weaken public activation verification. Separate liveness from protocol
conformance.

### Phase 3: implement Option A as a bounded experiment

1. Locate the exact session-map implementation inside the installed
   `@playwright/mcp@0.0.78` image.
2. Add a source patch script under `docker/` rather than an opaque inline
   `sed`.
3. Make the patch verify exact preconditions and fail closed.
4. Implement explicit deletion plus sliding idle cleanup.
5. Add unit/contract tests for patch application and mismatch failure.
6. Rebuild without using a stale Docker layer.
7. Run the regression from Phase 1.
8. Test two separate client sessions to ensure one client's deletion does not
   remove the other.

If the second request still fails because the underlying transport object
cannot be reused, revert the experimental patch and proceed to Option B.

### Phase 4: gateway fallback

If needed, implement the gateway as a separate process with a clear module and
tests. Change Supervisor so it starts Playwright MCP backend process(es) and the
gateway. Route Caddy to the gateway.

Test:

- initialize and multiple sequential calls;
- notifications;
- invalid/missing session IDs;
- explicit deletion;
- idle expiration;
- backend child crash;
- gateway/container graceful shutdown;
- two isolated sessions;
- maximum-session rejection;
- playbook instruction injection;
- persistence of the shared Chrome profile across gateway/backend restart.

### Phase 5: end-to-end acceptance

Run:

```sh
npm ci
bash tests/run.sh
bash tests/compose-smoke.test.sh
```

Then run a clean VM-style install or update using the master installer and
validate:

- host 443 routes to the container proxy;
- valid TLS certificate;
- public anonymous 401;
- bearer-header initialization;
- embedded-token initialization;
- one Content-Type header;
- stable multi-call session;
- noVNC page and WebSocket;
- human login handoff;
- browser/container restart with profile retained;
- host reboot with Compose returning automatically;
- `sudo remote-chrome status`;
- `sudo remote-chrome credentials`;
- rollback still preserves profile data.

Finally test at least:

- the deterministic protocol client;
- MCPJam;
- the real target Codex/ChatGPT-compatible MCP client.

Do not claim completion based only on `curl initialize`.

### Phase 6: documentation and release

After the transport fix passes:

1. Update `README.md` so Docker/VM is the primary architecture.
2. Document the session lifetime and client expectations.
3. Document that the health check is non-mutating.
4. Keep the native path clearly labeled legacy/rollback.
5. State accurately that GCE VM is supported and Cloud Run is not yet
   supported.
6. Create an immutable release only after tests pass.
7. Tag the exact commit, run `scripts/package-release.sh`, publish archive and
   checksum assets, and then replace the documentation's hypothetical release
   example with a real version.

## Acceptance criteria

The work is finished only when all of these are true:

- A fresh supported VM can install from the documented curl command.
- Caddy owns public TCP 80/443 and internal ports remain private.
- Public TLS is valid.
- Both documented MCP authentication modes initialize.
- A standard Streamable HTTP client can make a multi-step browser workflow
  using one `Mcp-Session-Id`.
- The session remains usable after at least 35 seconds and across recurring
  health checks.
- Deleting one session does not affect another.
- Explicit deletion and idle expiration release resources.
- The human can connect through `/login/` and control the same Chrome.
- noVNC WebSocket proxying works.
- Chrome uses the persistent profile.
- Cookies survive browser container recreation and host reboot.
- Software update/rollback does not erase profile data.
- The user never needs container shell access for routine site login.
- Agents operate through MCP rather than direct Docker/CDP control.
- The complete automated suite passes from a clean checkout.
- At least one real external MCP client completes a multi-call interaction.

## Known caveats and follow-up work

- `README.md` is outdated relative to the Docker/VM implementation.
- There is no verified tagged production release yet.
- Cloud Run is not implemented.
- The current health check mutates MCP sessions.
- The current smoke test is insufficient for multi-call session behavior.
- The current Playwright MCP package is pinned to a version exhibiting the HTTP
  session failure in this deployment.
- Caddy's compatibility token URL is less secure than bearer headers and should
  remain explicitly labeled compatibility-only.
- Chrome uses `--no-sandbox` inside the container. Keep the container
  unprivileged, avoid extra capabilities, and do not mount the Docker socket.
- The VM overlay runs services as UID/GID 10001 and depends on installer-managed
  ownership. Preserve reinstall/upgrade ownership handling.
- Website sessions can expire or be revoked by the website even when profile
  persistence is correct. Do not promise indefinite Amazon authentication.

## Security and repository hygiene

- Treat `/etc/remote-chrome/credentials.env`, Compose environment files, Chrome
  profile data, Caddy ACME data, and backup manifests as sensitive.
- Never paste real values into tests.
- Use fixed synthetic credentials in isolated tests.
- Do not log the token compatibility path.
- Do not publish internal service ports.
- Keep release and archive validation fail-closed.
- Preserve symlink/path/ownership defenses in the VM installer.
- Preserve backup maintenance locks and quiesced profile capture.
- Avoid destructive profile operations. Uninstall preserves data by default.
- Do not remove the known-good native installation during development unless
  the user explicitly authorizes it after container acceptance.
- Before any public deployment change, resolve exact targets and preserve a
  rollback path.

## Useful diagnostic classification

When testing, classify errors before changing code:

| Symptom | Likely layer |
|---|---|
| DNS/TLS connection failure | DNS, firewall, Caddy, certificate |
| HTTP 401 on initialize | wrong/missing bearer token or stale URL |
| HTTP 404 before initialize succeeds | wrong path/stale embedded token |
| Duplicate/combined Content-Type | proxy header mutation |
| GET `/mcp` 400/405 during SSE fallback | unsupported GET SSE transport |
| Initialize 200, first tool 200, second tool 404 | Playwright MCP HTTP session lifecycle |
| MCP works but noVNC page is 401 | expected Basic Auth or wrong login credentials |
| noVNC UI loads but shows failed connection | WebSocket path/proxy upgrade |
| Browser shows login after restart | site session expiry or profile persistence problem |
| Browser state persists but refs fail | MCP session/reference lifetime, not cookies |
| Amazon says unsupported client before login | browser build/fingerprint/automation environment |

## Final handoff instruction

The highest-priority task is not adding more installation features. It is
making one public MCP session survive a normal multi-step browser workflow.

Write the failing test first, simplify the health check, try the bounded
Playwright HTTP patch, and move to a stdio-backed gateway if the transport
cannot be reused. Preserve the current profile and rollback deployment
throughout. Only after a real external MCP client passes should the work be
tagged and described as ready.
