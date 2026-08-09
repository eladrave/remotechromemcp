# Playwright MCP `undefined.once` lifecycle resolution

**Resolved implementation date:** 2026-08-09
**Affected baseline:** `@playwright/mcp@0.0.78`
**Fixed pin:** `@playwright/mcp@0.0.79` with exact local bundle verification

This document records the root cause and permanent implementation for the
long-running Remote Chrome failure:

```text
TypeError: Cannot read properties of undefined (reading 'once')
```

It contains no credentials, session identifiers, browser contents, or profile
data.

## Proven state transition

The failure was reproduced in an isolated container using a synthetic profile:

1. Start one Playwright MCP process attached to the supervised Chrome CDP
   endpoint.
2. Open a Streamable HTTP session and call `browser_snapshot` successfully.
3. Keep that MCP process running while restarting only Chrome.
4. Wait for Supervisor to start replacement Chrome and confirm that the MCP PID
   did not change.
5. Initialize a new MCP session and call `browser_snapshot`.

The 0.0.78 process retained a resolved shared-browser promise after the CDP
browser disconnected. That cached browser was disconnected and exposed zero
contexts. The new backend then evaluated `browser.contexts()[0]`, passed
`undefined` to `BrowserBackend`, and dereferenced `.once()` while registering
the context close listener.

The captured sanitized stack followed this path:

```text
BrowserBackend constructor
factory.create
initializeServer
tools/call browser_snapshot
```

At construction time, the captured state was:

```text
context present: false
browser contexts: 0
browser connected: false
```

This explains why a fresh MCP process attached to the same Chrome succeeded:
the Chrome profile and browser were healthy, but the old MCP process retained a
stale resolved browser object.

## Permanent implementation

The image now pins `@playwright/mcp@0.0.79` and its exact
`playwright-core@1.63.0-alpha-2026-08-05` dependency. Version 0.0.79 includes
upstream shared-browser promise invalidation on disconnect, balanced client
counting after failed creation, and idempotent backend disposal.

The repository retains two deterministic, fail-closed patches:

- `docker/patch-playwright-mcp-http.cjs` preserves Streamable HTTP sessions
  across normal requests, refreshes a bounded idle timeout, retires a session
  before deletion, rejects new work for that session, and waits for all active
  requests before explicit `DELETE` cleanup.
- `docker/patch-playwright-mcp-lifecycle.cjs` validates that a browser context
  exists, reconnects once when a shared CDP browser has no context, latches an
  early disconnect until the server attaches its callback, pairs disconnect
  listeners with disposal, drains active tools before releasing the last
  browser owner, and turns an otherwise unattributed unhandled rejection into
  a fixed, data-free fatal classification before the MCP process exits.

Both scripts require exact package versions, source hashes, block hashes, and a
single source signature. The Docker build applies and checks the HTTP patch
before applying and checking the lifecycle patch. Read-only copies of both
verifiers remain in the image so operators can verify the exact final bundle:

```bash
node /opt/remote-chrome/verify-playwright-mcp-http-patch.cjs --check \
  --mcp-package-json /usr/local/lib/node_modules/@playwright/mcp/package.json
node /opt/remote-chrome/verify-playwright-mcp-lifecycle-patch.cjs --check \
  --mcp-package-json /usr/local/lib/node_modules/@playwright/mcp/package.json
```

The non-root container does not expose Supervisor's RPC control interface. A
same-UID browser or MCP compromise therefore does not gain a ready-made full
process-control API. Targeted recovery signals only the uniquely identified MCP
process; Supervisor's existing `autorestart` policy starts its replacement. The
recurring container health check remains non-mutating and does not create MCP
application sessions.

No automatic restart policy was added to the functional canary. A targeted MCP
restart interrupts live MCP sessions, so the hourly checker remains alert-only.
Normal cleanup drains active requests for up to
`REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS` (five minutes by default). If an
unsafe tool never settles, the MCP process emits a fixed data-free timeout
classification and exits; Supervisor replaces only MCP while Chrome and its
persistent profile remain running.

## Regression coverage

`tests/mcp-browser-lifecycle-regression.cjs` uses the real browser and real MCP
transport. With a shortened test-only idle timeout it verifies:

- five overlapping sessions can use browser tools;
- deleting one session does not affect the others;
- expiring one idle session does not affect active sessions;
- deleting the sole remaining session waits for its active one-second browser
  tool to finish, then retires it without affecting a later session;
- repeated seeded create, use, and delete operations remain healthy;
- Chrome can restart while the MCP PID stays unchanged; and
- a fresh session after replacement Chrome starts can call two browser tools,
  delete its session, and observe the required post-delete `404`.

The deterministic patch tests additionally force the early-disconnect window,
force both session-log and browser-context initialization failures, run a
controlled active-tool/disposal race, call disposal twice, and create and
dispose 100 backends while asserting that every context/browser disconnect
listener and owner is released exactly once.

The full Compose smoke test also verifies the public bearer route, the embedded
compatibility route, noVNC, WebSocket upgrade, private-port isolation, and
profile/cookie persistence across container recreation.

## Operator recovery boundary

If the functional checker detects a browser-tool failure, first confirm that no
active workflow is using MCP. A narrow recovery is:

```bash
docker exec remote-chrome-browser-1 sh -ceu '
  mcp_pids="$(pgrep -f "^node /usr/local/bin/playwright-mcp --cdp-endpoint " || true)"
  mcp_count="$(printf "%s\n" "$mcp_pids" | awk "NF { count++ } END { print count + 0 }")"
  test "$mcp_count" -eq 1
  kill -TERM "$mcp_pids"
'
```

Confirm that Chrome's Supervisor PID did not change, then rerun the functional
checker. Do not restart the whole container or remove the persistent profile as
the first response.
