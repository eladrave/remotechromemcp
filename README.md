# Remote Chrome MCP

Remote Chrome MCP runs one persistent, full Google Chrome browser on a Linux
server and exposes it to MCP clients over HTTPS.

It is designed for browser tasks that need both automation and occasional human
help:

- agents control Chrome through Playwright MCP;
- humans see and control the same browser through an authenticated noVNC page;
- cookies, local storage, and website logins survive MCP reconnects, container
  recreation, and host reboots;
- Caddy obtains and renews the public TLS certificate;
- only host TCP 80 and 443 are exposed.

The recommended deployment is the guided Docker/VM installer. The older native
systemd scripts remain in the repository as a legacy rollback path and are not
the primary installation method.

For a complete human-and-agent installation walkthrough, including guided,
noninteractive, and direct Docker Compose paths, see
[`installation.md`](installation.md).

## How it works

```text
Remote MCP client
        |
        | HTTPS POST/DELETE
        | Bearer token or /<token>/mcp compatibility URL
        v
  Caddy :443
        |
        v
  Playwright MCP :8931
        |
        | CDP on container loopback
        v
  full headed Google Chrome
        |
        +-- persistent Chrome profile
        |
        +-- Xvfb -> Openbox -> x11vnc -> noVNC
                                      ^
                                      |
                         Caddy /login/
```

Chrome is headed, not Chrome's headless mode. Playwright MCP and noVNC connect
to the same browser process and profile.

## Recommended VM installation

### Supported hosts

- Ubuntu 22.04 x86_64
- Ubuntu 24.04 x86_64
- Debian 12 x86_64
- root access through `sudo`
- either a domain you control or a stable public IPv4 for automatic
  `sslip.io` naming
- public inbound TCP 80 and 443

A practical starting size is 2 vCPU, 8 GiB RAM, and at least 20 GiB of disk.
Chrome profiles can grow, so use a larger or separately mounted data volume when
appropriate.

Before installing:

1. Give the VM a stable public IPv4 address.
2. If using your own domain, point its public DNS `A` record to that address.
   Any published `AAAA` record must also reach this host or be removed.
3. Allow inbound TCP 80 and 443 in the cloud firewall and host firewall.
4. Confirm no existing web server or proxy owns host ports 80 or 443.
5. Choose an absolute persistent data directory, such as
   `/var/lib/remote-chrome`.

The installer does not format disks, modify firewall rules, or replace an
existing proxy. It stops when DNS or port ownership is unsafe.

### Run the guided installer

SSH to the VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

Although the script arrives on standard input, prompts are read from
`/dev/tty`. The installer asks for:

- whether you already have a public domain;
- the domain, when supplied, or it automatically creates an
  `<public-ip-with-dashes>.sslip.io` hostname;
- an email address for ACME certificate notices;
- the persistent data directory;
- whether to explicitly enable GCS profile backups, which are off by default;
- the GCS bucket and optional systemd backup schedule, when enabled.

It validates the operating system, architecture, DNS, ports, Docker, Compose
configuration, public HTTPS, MCP initialization, and the browser login console.
Docker and Docker Compose are installed when necessary.

### Installing without your own domain

Answer `n`, `no`, `none`, or press Enter when asked whether you have a domain.
The installer discovers the VM's external IPv4 and generates a hostname such
as:

```text
203-0-113-42.sslip.io
```

`sslip.io` resolves the embedded address without requiring a DNS account. The
generated hostname still requires a stable public IPv4 and publicly reachable
TCP 80 and 443 so Caddy can obtain and renew its certificate. Your own domain
is preferred for a long-lived deployment because the automatic hostname
depends on a third-party DNS service and changes when the public IP changes.

In noninteractive mode, simply omit `--domain` or explicitly pass
`--domain none`. GCS backup remains disabled unless `--enable-gcs-backup` or an
explicit GCS bucket is supplied:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh |
  sudo sh -s -- \
    --non-interactive \
    --email admin@example.com \
    --data-dir /var/lib/remote-chrome
```

The `master` URL is a moving, unpinned installer. Use an immutable release tag
for production automation after that release and its checksum assets actually
exist. Do not substitute an example version that has not been published.

### Verify the installation

The installer creates a boot-enabled `remote-chrome.service` and installs the
root-only management command:

```bash
sudo remote-chrome status
sudo remote-chrome credentials
```

`status` verifies the containers, headed Chrome, MCP initialization, public
authentication, TLS, noVNC, and the noVNC WebSocket.

For ongoing production monitoring, install the optional hourly functional
healthcheck. Unlike the container's lightweight liveness probe, it performs a
real read-only `browser_snapshot` through a temporary MCP session:

```bash
sudo scripts/install-functional-healthcheck.sh
```

See [`docs/functional-healthcheck.md`](docs/functional-healthcheck.md) for the
security model, systemd units, verification commands, and failure handling.

`credentials` prints password-equivalent secrets. Run it only in a trusted SSH
terminal and store the output in a password manager. Do not paste it into chat,
issues, logs, or shell transcripts.

The handoff includes:

- the preferred MCP endpoint;
- the MCP bearer token;
- the token-in-URL compatibility endpoint;
- the `/login/` page;
- the one-click noVNC URL;
- the fallback noVNC username and password.

## Connect an MCP client

Bearer-header authentication is preferred:

```text
URL: https://chrome.example.com/mcp
Authorization: Bearer <MCP_TOKEN>
```

For clients that cannot send custom headers, use the exact compatibility URL
reported by `sudo remote-chrome credentials`:

```text
https://chrome.example.com/<MCP_TOKEN>/mcp
```

For a TOML-based MCP client:

```toml
[mcp_servers.remote_chrome]
url = "https://chrome.example.com/mcp"
headers = { Authorization = "Bearer <MCP_TOKEN>" }
tool_timeout_sec = 120
```

For a JSON-based MCP client:

```json
{
  "mcpServers": {
    "remote_chrome": {
      "url": "https://chrome.example.com/mcp",
      "headers": {
        "Authorization": "Bearer <MCP_TOKEN>"
      }
    }
  }
}
```

Use only one authentication form at a time. A token embedded in a URL may be
retained by client telemetry or configuration history, so prefer the bearer
header whenever the client supports it.

## Human login and verification

When a site asks for a password, MFA, CAPTCHA, security key, consent, or another
human-only step, the agent should call the canonical tool:

```text
remote_chrome_request_human_intervention
```

API applications may call the equivalent alias:

```text
get_novnc_link
```

Both read-only MCP tools accept no arguments and return the same protected
one-click noVNC URL. The workflow is:

1. The agent stops browser interaction and calls the handoff tool.
2. The user opens the returned URL in a trusted browser.
3. The user completes the human-only step in the visible Chrome window.
4. The user tells the agent that control is returned.
5. The agent takes a fresh snapshot and continues.

Never send a site username, password, MFA code, recovery code, security-key
data, or CAPTCHA answer to the MCP tool or agent. Enter it directly in the
noVNC browser. The one-click URL itself is a reusable password-equivalent secret
until server credentials are rotated.

Basic Auth at `https://chrome.example.com/login/` remains available as a
fallback. Both access methods control the same Chrome used by MCP.

## Persistent browser state

The VM installer bind-mounts the Chrome profile from:

```text
<data-directory>/profile
```

Website cookies and local storage survive:

- MCP client disconnects and new MCP protocol sessions;
- Chrome and container restarts;
- container recreation during an update;
- host reboots.

MCP session IDs and snapshot element references are intentionally temporary.
Take a fresh snapshot after reconnecting or after a human handoff.

A website can still expire or revoke its own login. In that case, use the
human-intervention tool again; do not clear or replace the rest of the profile.

Protect the profile directory as sensitive data. It contains authenticated
browser state. Never run `docker compose down --volumes` against a direct
Compose installation unless profile deletion is intentional.

## Operations

### VM installer deployment

```bash
# Full health and deployment status
sudo remote-chrome status

# Protected MCP and noVNC handoff
sudo remote-chrome credentials

# Public login URL and username, without printing the password
sudo remote-chrome login

# Wait until the service is ready
sudo remote-chrome wait-ready

# Update from the moving master branch
sudo remote-chrome update --version master --allow-unpinned

# Create a configured, quiesced GCS profile backup
sudo remote-chrome backup

# Restore an exact validated backup manifest
sudo remote-chrome restore \
  gs://example-backups/remote-chrome/<exact-backup>.manifest

# Remove the application while preserving profile data by default
sudo remote-chrome uninstall
```

Use a published immutable release instead of `master` when one is available.
Activation health-checks the replacement and attempts to recover the previous
release if activation fails.

Restore replaces the live profile after validation. Confirm the exact manifest
before running it. Destructive uninstall options require explicit flags and
confirmation.

### Logs

```bash
sudo journalctl -u remote-chrome.service -f
```

For container-level inspection, first use `sudo remote-chrome status`. The
management interface is the canonical view of an installed VM deployment.

## Direct Docker Compose installation

Use this path on a machine that already has Docker Engine and Docker Compose v2.
It uses Docker named volumes instead of the VM installer's host bind mounts and
management CLI.

```bash
git clone https://github.com/eladrave/remotechromemcp.git
cd remotechromemcp
./scripts/bootstrap-docker.sh \
  --domain chrome.example.com \
  --email admin@example.com
```

The bootstrap script:

- generates independent MCP, one-click login, and Basic Auth credentials;
- writes the ignored `.env` file with mode `600`;
- builds and starts the Compose stack;
- waits for both services to become healthy;
- verifies public MCP and both noVNC authentication methods;
- prints the connection handoff.

The generated Basic Auth password is shown once. Save it immediately.

Later operations:

```bash
docker compose --env-file .env ps
docker compose --env-file .env logs -f
docker compose --env-file .env up -d --build
docker compose --env-file .env down
```

The final command stops and removes containers and networks but preserves named
volumes. Do not add `--volumes` unless permanent browser-state deletion is
intended.

## Public and private ports

Only Caddy publishes host ports:

| Port | Exposure | Purpose |
|---|---|---|
| TCP 80 | Public | ACME challenge and HTTPS redirect |
| TCP 443 | Public | MCP and noVNC over HTTPS |
| TCP 8931 | Container network only | Playwright MCP |
| TCP 6080 | Container network only | noVNC |
| TCP 5900 | Container only | VNC |
| TCP 9222 | Container loopback only | Chrome DevTools Protocol |

Never publish TCP 5900, 6080, 8931, or 9222 to the public host.

## Security model

- MCP and noVNC use separate random credentials.
- The preferred MCP endpoint requires a bearer header.
- The compatibility MCP URL and one-click noVNC URL contain secrets.
- The one-click login exchanges its token for an eight-hour Secure, HttpOnly,
  SameSite=Strict cookie and redirects to a clean `/login/` URL.
- Caddy discards access logs so secret-bearing paths are not written there.
- Chrome, VNC, noVNC, and MCP run as an unprivileged container user.
- The VM installer stores credentials in root-only managed files.
- CDP and VNC are never public.
- The persistent profile must be protected like a credential store.

Rotate credentials if a token URL is exposed. Do not commit `.env`, credential
files, cookies, profile data, backup archives, or URLs containing live tokens.

## Backup and recovery

The VM installer can configure a private GCS bucket and systemd backup timer.
Backups stop browser writes, archive the profile, upload the archive plus
checksum and manifest, and restart the browser. Restore validates the manifest,
checksum, archive paths, and installation identity before replacing the
profile; failed activation attempts roll back to the prior profile.

For a Google Compute Engine walkthrough with a static address, dedicated service
account, persistent disk, firewall rules, and bucket-scoped IAM, see
[docs/gce-manual.md](docs/gce-manual.md).

## Troubleshooting

### The installer reports a DNS mismatch

Confirm the public `A` record points to the VM. Remove or correct an `AAAA`
record that points elsewhere, wait for DNS propagation, and rerun.

### Ports 80 or 443 are already in use

The installer intentionally refuses to take them over. Decide which proxy owns
the host before retrying; do not expose the internal browser ports as a
workaround.

### MCP initialization fails

Run:

```bash
sudo remote-chrome status
sudo remote-chrome credentials
```

Use the exact endpoint and authentication mode from the protected credentials
output. A stale token URL fails during initialization, while an expired MCP
session requires a new initialization.

### The noVNC page opens but does not connect

Check `sudo remote-chrome status`. It validates both the page and WebSocket
upgrade. Do not expose port 6080 directly.

### A website is signed out

Sites can expire their own sessions. Ask the agent to call
`remote_chrome_request_human_intervention`, complete login in noVNC, return
control, and take a fresh snapshot.

### Profile state disappears

Confirm the same configured data directory or Docker named volume is mounted.
Do not run two Chrome processes against the same profile and do not delete the
profile volume during updates.

## Validation

Install Node dependencies before running repository tests:

```bash
npm ci
bash tests/run.sh
```

Run the full Docker runtime test separately:

```bash
bash tests/compose-smoke.test.sh
```

The runtime test builds the image and verifies headed Chrome, public
authentication, multi-call MCP sessions, the human-intervention tool, noVNC,
WebSocket proxying, profile persistence across container recreation, and that
private ports are not published.

## Additional documentation

- [Complete human and AI-agent installation guide](installation.md)
- [Generic VM installation and operations](docs/vm-install.md)
- [Google Compute Engine manual setup](docs/gce-manual.md)
- [Remote login and profile persistence](docs/remote-login.md)
- [Agent operating skill](skills/remote-chrome-mcp/SKILL.md)

## Current boundaries

- Google Cloud Run is not supported by this implementation.
- The deployment is designed for one persistent browser host, not horizontal
  auto-scaling.
- A third-party website can always expire or revoke its own session.
- The native `setup.sh`, `login.sh`, `status.sh`, and `uninstall.sh` path is
  retained for legacy rollback only.
