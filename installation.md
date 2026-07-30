# Remote Chrome MCP Installation Guide

This guide is written for both human operators and AI coding agents. It covers
the supported managed VM installation, unattended installation for automation,
and the lower-level direct Docker Compose installation.

The recommended path is the managed VM installer. It installs Docker when
needed, builds the containers, configures HTTPS, creates persistent storage and
a boot service, validates the public endpoints, and installs the
`remote-chrome` management command.

## Choose an installation path

| Path | Best for | What it manages |
|---|---|---|
| Guided automatic VM install | A human installing over SSH | Prompts, Docker, HTTPS, persistent host directories, systemd, validation, rollback, and optional GCS backup |
| Noninteractive automatic VM install | An AI agent, cloud-init, or configuration management | The same managed deployment without prompts |
| Direct Docker Compose install | An operator who wants to manage the source checkout and Docker lifecycle directly | Containers, named volumes, HTTPS, and generated credentials; no `remote-chrome` CLI, installer rollback, or integrated GCS schedule |

The legacy native scripts are retained only as a rollback path. Do not use them
for a new installation.

Google Cloud Run is not supported by this implementation. The deployment
requires one long-lived browser process, stable local profile storage, and a
host that owns TCP 80/443. Use a persistent Linux VM or dedicated server.

## Architecture and exposure

The deployment runs one full headed Google Chrome Stable browser:

```text
MCP client
    |
    | HTTPS on TCP 443
    v
Caddy reverse proxy
    |
    +-- Playwright MCP -> Chrome over container-loopback CDP
    |
    +-- /login/ -> noVNC -> the same Chrome window
```

Only host TCP 80 and 443 are public:

| Port | Exposure | Purpose |
|---|---|---|
| 80 | Public | ACME certificate challenge and HTTPS redirect |
| 443 | Public | MCP and the protected noVNC console |
| 8931 | Docker network only | Playwright MCP |
| 6080 | Docker network only | noVNC |
| 5900 | Container only | VNC |
| 9222 | Container loopback only | Chrome DevTools Protocol |

Never publish ports 5900, 6080, 8931, or 9222.

## Requirements

### Supported managed VM hosts

- Ubuntu 22.04 x86_64
- Ubuntu 24.04 x86_64
- Debian 12 x86_64
- Root access through `sudo`
- A stable public IPv4 address
- Public inbound TCP 80 and 443
- No existing service listening on host port 80 or 443
- Either:
  - a domain whose DNS points to the VM; or
  - no domain, in which case the installer creates a hostname such as
    `203-0-113-42.sslip.io`

A practical starting size is 2 vCPU, 8 GiB RAM, and 20 GiB of storage. A larger
or separately mounted data disk is useful when the Chrome profile will grow.

### Before any installation

1. Assign the VM a stable public IPv4.
2. Allow inbound TCP 80 and 443 in both the cloud firewall and any host
   firewall.
3. Check that ports 80 and 443 are unused:

   ```bash
   sudo ss -ltnp '( sport = :80 or sport = :443 )'
   ```

   No listening process should be returned. The installer refuses to replace
   nginx, Apache, Caddy, or another existing proxy.

4. Choose a persistent data directory. The default is
   `/var/lib/remote-chrome`.
5. If the directory is on a separate disk, mount and verify that disk before
   installation. Never guess a device name and never format an unknown disk.
6. Have an email address available for ACME certificate notices.

### Using your own domain

Create a public DNS `A` record pointing to the VM's public IPv4. If an `AAAA`
record exists, it must reach this same server or be removed. Wait for DNS to
resolve correctly before installing:

```bash
getent ahosts chrome.example.com
```

### Installing without a domain

The managed installer first tries the Google Compute Engine metadata service
and then a bounded public IPv4 lookup. It validates the result and converts:

```text
203.0.113.42 -> 203-0-113-42.sslip.io
```

The generated hostname requires no DNS account. It still requires a stable
public IPv4 and public TCP 80/443 so Caddy can obtain and renew HTTPS
certificates. If the VM's address changes, reinstall or update the deployment
with a hostname for the new address.

## Path A: guided automatic VM installation

SSH to the VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

The bootstrap arrives through standard input, but all interactive questions are
read from `/dev/tty`. It asks:

1. Whether you already have a domain.
2. The domain, only when the answer is yes.
3. The ACME certificate email.
4. The persistent data directory.
5. Whether to enable GCS backup. The default is no.
6. The GCS bucket and optional systemd schedule, only when backup is enabled.

At the domain question, answer `n`, `no`, `none`, or press Enter to select an
automatic `sslip.io` hostname. If you answer yes at first but enter `none`,
`auto`, or a blank domain, automatic naming is also selected.

At the GCS question, press Enter or answer no to keep backup disabled. No GCS
tools or schedule are configured by default.

### What the managed installer does

The installer:

1. Validates root access, x86_64 architecture, and the supported distribution.
2. Validates the domain or generates an `sslip.io` hostname.
3. Confirms that the hostname resolves to this host's public address.
4. Refuses to continue if host port 80 or 443 already has a listener.
5. Installs Docker Engine and Docker Compose v2 when necessary.
6. Downloads and validates the selected source or release archive.
7. Creates root-confined configuration and persistent runtime directories.
8. Generates independent MCP, one-click noVNC, and Basic Auth credentials.
9. Builds and activates the Docker Compose deployment.
10. Installs and enables `remote-chrome.service` for host reboots.
11. Optionally installs a GCS backup timer when explicitly enabled.
12. Verifies HTTPS, authenticated MCP initialization, the browser, noVNC, and
    the noVNC WebSocket.
13. Attempts to recover the previous release if activation fails.
14. Prints a protected connection handoff.

The installer does not modify cloud firewall rules, format disks, or replace an
existing web server.

## Path B: noninteractive automatic installation

This is the preferred path for an AI agent or other automation. It provides the
same managed deployment without prompts.

### Without a domain and without GCS backup

Omit `--domain`; the external IPv4 is detected automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh |
  sudo sh -s -- \
    --non-interactive \
    --email admin@example.com \
    --data-dir /var/lib/remote-chrome
```

The equivalent explicit form is:

```text
--domain none
```

### With your own domain

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh |
  sudo sh -s -- \
    --non-interactive \
    --domain chrome.example.com \
    --email admin@example.com \
    --data-dir /var/lib/remote-chrome
```

### With explicitly enabled GCS backup

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh |
  sudo sh -s -- \
    --non-interactive \
    --domain chrome.example.com \
    --email admin@example.com \
    --data-dir /var/lib/remote-chrome \
    --enable-gcs-backup \
    --gcs-bucket example-remote-chrome-backups \
    --backup-schedule daily
```

Supplying `--gcs-bucket` remains a backwards-compatible explicit opt-in, but
new automation should include `--enable-gcs-backup` so its intent is obvious.
Enabling backup without a bucket fails.

### Installer flag reference

| Flag | Meaning |
|---|---|
| `--non-interactive` | Never read prompts; fail when required values are absent |
| `--domain HOSTNAME` | Use an existing DNS hostname |
| `--domain none` or `--domain auto` | Detect the public IPv4 and use `sslip.io` |
| `--email ADDRESS` | Required ACME certificate email for a first noninteractive install |
| `--data-dir PATH` | Required absolute persistent directory for a first noninteractive install |
| `--enable-gcs-backup` | Explicitly opt in to GCS profile backup |
| `--gcs-bucket BUCKET` | GCS bucket name; also implies backup opt-in for compatibility |
| `--backup-schedule CALENDAR` | systemd `OnCalendar` value, such as `daily` |
| `--disable-gcs-backup` | Disable a previously configured backup |
| `--disable-backup-schedule` | Remove the timer while retaining bucket configuration |
| `--skip-dns-check` | Diagnostic override only; HTTPS still requires a working hostname |
| `--rotate-credentials` | Generate replacement MCP and login credentials |
| `--version REF` | Select a source or immutable release reference |

The `master` installer is intentionally moving and unpinned. This repository
does not yet advertise a verified production release. Do not invent a version
tag from an example. Use `master` only when accepting that update behavior.

## AI agent execution contract

An AI agent with SSH and `sudo` access can complete a noninteractive managed
installation. It should follow this sequence:

1. Read `AGENTS.md` and this file completely.
2. Confirm the exact target host and that it is a supported x86_64 OS.
3. Determine whether the user supplied a domain. If not, use automatic
   `sslip.io` naming rather than blocking.
4. Confirm the intended persistent data directory. Do not format or repurpose
   a disk.
5. Check port 80/443 listeners and stop if either is already owned.
6. Confirm cloud and host firewalls allow TCP 80/443. Opening a cloud firewall
   is provider-specific and must remain within the user's authorization.
7. Leave GCS disabled unless the user explicitly requests it and supplies the
   bucket and authentication context.
8. Run the noninteractive command.
9. Run `sudo remote-chrome status`.
10. Report the hostname, health result, and credential-retrieval command.

An agent must not:

- print `sudo remote-chrome credentials` into chat, build logs, issues, or
  transcripts;
- expose MCP, CDP, VNC, or noVNC internal ports;
- request site passwords or MFA codes through chat;
- delete or replace an existing Chrome profile;
- take over an existing port 80/443 listener;
- claim success from container startup alone when `remote-chrome status`
  fails.

The human retrieves the protected handoff in their own trusted terminal:

```bash
sudo remote-chrome credentials
```

## Path C: direct Docker Compose installation

Use this path when Docker lifecycle and source updates will be managed directly.
It is not equivalent to the managed VM installation.

Direct Compose:

- uses Docker named volumes for the profile and Caddy state;
- does not install the `remote-chrome` CLI;
- does not create `remote-chrome.service`;
- does not provide managed activation rollback;
- does not configure GCS backup or restore;
- requires the operator to preserve the checkout and `.env`.

### 1. Install Docker Engine and Compose v2

Skip this step when both commands already work:

```bash
docker info
docker compose version
```

On a supported Ubuntu or Debian x86_64 host, these commands mirror the Docker
repository setup used by the managed installer:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git gnupg openssl

. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:22.04) docker_codename=jammy ;;
  ubuntu:24.04) docker_codename=noble ;;
  debian:12) docker_codename=bookworm ;;
  *) printf 'Unsupported OS: %s %s\n' "$ID" "$VERSION_ID" >&2; exit 1 ;;
esac

docker_key_stage="$(mktemp -d)"
curl -fsSL --max-time 30 \
  "https://download.docker.com/linux/$ID/gpg" \
  -o "$docker_key_stage/docker.asc"
gpg --dearmor \
  --output "$docker_key_stage/docker.gpg" \
  "$docker_key_stage/docker.asc"

sudo install -m 0755 -d /etc/apt/keyrings
sudo install -m 0644 \
  "$docker_key_stage/docker.gpg" \
  /etc/apt/keyrings/docker.gpg
rm -rf -- "$docker_key_stage"

printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
  "$ID" "$docker_codename" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker info
sudo docker compose version
```

Use `sudo docker ...` below unless the current account is already authorized to
use the Docker daemon.

### 2. Prepare the hostname and firewall

The direct bootstrap requires a hostname. Use your own DNS domain, or manually
derive the same `sslip.io` form from a stable public IPv4:

```text
PUBLIC_IPV4: 203.0.113.42
DOMAIN:      203-0-113-42.sslip.io
```

Confirm the hostname resolves to the VM and that public TCP 80/443 reach it.

### 3. Clone the public repository

```bash
git clone https://github.com/eladrave/remotechromemcp.git
cd remotechromemcp
```

### 4. Run the direct bootstrap

With your own domain:

```bash
sudo ./scripts/bootstrap-docker.sh \
  --domain chrome.example.com \
  --email admin@example.com
```

With a manually selected `sslip.io` hostname:

```bash
sudo ./scripts/bootstrap-docker.sh \
  --domain 203-0-113-42.sslip.io \
  --email admin@example.com
```

The script:

1. Generates separate MCP, one-click login, and Basic Auth credentials.
2. Writes `.env` with mode `600`; `.env` is ignored by Git.
3. Builds the browser image.
4. Starts the browser and proxy.
5. Waits for healthy containers.
6. Verifies authenticated MCP initialization.
7. Verifies one-click and Basic Auth noVNC access.
8. Prints the connection handoff.

The Basic Auth password is shown only once. Store it immediately in a password
manager. Do not commit `.env` or copy its values into chat.

### 5. Fully manual Compose configuration

This subsection replaces `scripts/bootstrap-docker.sh`. Prefer the bootstrap
unless a manual credential and Compose lifecycle is specifically required.

From the repository root:

```bash
umask 077

MCP_TOKEN="$(openssl rand -hex 32)"
LOGIN_TOKEN="$(openssl rand -hex 32)"
LOGIN_USERNAME=remotechrome
LOGIN_PASSWORD="$(openssl rand -base64 36 | tr '+/' '-_')"
LOGIN_PASSWORD_HASH="$(
  printf '%s\n' "$LOGIN_PASSWORD" |
    sudo docker run --rm -i caddy:2-alpine \
      caddy hash-password --algorithm bcrypt
)"

{
  printf 'DOMAIN=%s\n' 'chrome.example.com'
  printf "ACME_EMAIL='%s'\n" 'admin@example.com'
  printf 'MCP_TOKEN=%s\n' "$MCP_TOKEN"
  printf 'LOGIN_TOKEN=%s\n' "$LOGIN_TOKEN"
  printf 'LOGIN_USERNAME=%s\n' "$LOGIN_USERNAME"
  printf "LOGIN_PASSWORD_HASH='%s'\n" "$LOGIN_PASSWORD_HASH"
  printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
  printf 'SCREEN_GEOMETRY=1440x900x24\n'
  printf 'REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS=1800000\n'
} >.env
chmod 600 .env

printf 'Store this noVNC Basic Auth password now: %s\n' "$LOGIN_PASSWORD"
unset LOGIN_PASSWORD

sudo docker compose --env-file .env config >/dev/null
sudo docker compose --env-file .env up -d --build
sudo docker compose --env-file .env ps
```

Replace the example domain and email before running the block. Do not enable
shell tracing with `set -x`; it would expose generated credentials.

### Direct Compose lifecycle

Run from the checkout containing `.env`:

```bash
# Status
sudo docker compose --env-file .env ps

# Logs
sudo docker compose --env-file .env logs -f

# Rebuild and update containers
git pull --ff-only
sudo docker compose --env-file .env up -d --build

# Stop containers while preserving named volumes
sudo docker compose --env-file .env down

# Start again
sudo docker compose --env-file .env up -d
```

Never add `--volumes` to `docker compose down` unless permanent browser-profile
deletion is explicitly intended.

## Verify a managed installation

Run:

```bash
sudo remote-chrome status
systemctl is-enabled remote-chrome.service
systemctl is-active remote-chrome.service
```

`remote-chrome status` checks the active release, containers, full headed
Chrome, MCP initialization, HTTPS authentication, noVNC page, and noVNC
WebSocket.

Retrieve the protected connection details only in a trusted terminal:

```bash
sudo remote-chrome credentials
```

The handoff contains:

- `https://<host>/mcp`
- the MCP bearer token
- `https://<host>/<token>/mcp` for clients that cannot send headers
- `https://<host>/login/`
- a one-click noVNC URL
- the Basic Auth username and password

Prefer the bearer-header MCP endpoint. URLs containing tokens can be retained
in client configuration, history, or telemetry.

## Connect an MCP client

Preferred configuration:

```text
URL: https://chrome.example.com/mcp
Authorization: Bearer <MCP_TOKEN>
```

Example TOML:

```toml
[mcp_servers.remote_chrome]
url = "https://chrome.example.com/mcp"
headers = { Authorization = "Bearer <MCP_TOKEN>" }
tool_timeout_sec = 120
```

Example JSON:

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

When a client cannot send custom headers, use the exact compatibility URL from
`sudo remote-chrome credentials`. Use one authentication form at a time.

## Human login and persistent website state

When a website asks for a password, CAPTCHA, MFA, security key, consent, or
another human-only step:

1. The agent stops browser actions.
2. The agent calls `remote_chrome_request_human_intervention` with no
   arguments. An API application may call the equivalent `get_novnc_link`
   alias.
3. The agent gives the returned protected noVNC URL to the requesting user.
4. The user enters credentials or completes verification directly in noVNC.
5. The user returns control.
6. The agent takes a fresh browser snapshot before continuing.

Never send site credentials or MFA material through MCP or chat.

Both handoff tools are read-only, accept no input, and return the same
token-embedded `https://<host>/login/?token=<token>` URL plus instructions for
the user. The canonical tool name is preferred for agents; `get_novnc_link`
exists for simple API integrations.

The managed deployment stores browser state in:

```text
<data-directory>/profile
```

The direct Compose deployment stores it in the `chrome-profile` named volume.
Cookies and local storage survive MCP reconnects, container recreation, and
host reboot. A website can still expire its own session independently.

## Managed operations

```bash
# Full status
sudo remote-chrome status

# Protected connection handoff
sudo remote-chrome credentials

# Public login URL and username without printing the password
sudo remote-chrome login

# Wait for readiness
sudo remote-chrome wait-ready

# Update from master, explicitly accepting an unpinned source
sudo remote-chrome update --version master --allow-unpinned

# Create a configured GCS backup
sudo remote-chrome backup

# Restore an exact validated manifest
sudo remote-chrome restore \
  gs://example-remote-chrome-backups/remote-chrome/<exact-backup>.manifest

# Uninstall services while preserving profile data by default
sudo remote-chrome uninstall
```

Restore replaces the live browser profile after validating the manifest,
checksum, archive, and installation identity. Confirm the exact recovery point
before restoring.

Destructive uninstall options require explicit delete flags and confirmation.
Read the displayed paths before approving deletion.

## GCS backup notes

GCS backup is disabled by default.

On Google Compute Engine, use a dedicated VM service account with only the
required bucket permissions. For the full static-IP, persistent-disk, firewall,
service-account, and bucket walkthrough, see
[`docs/gce-manual.md`](docs/gce-manual.md).

A VM outside GCP can also use GCS when `gcloud` has suitable credentials and
network access. The current installer does not automatically onboard external
identity. Configure root's noninteractive Google authentication before relying
on the systemd backup timer. Prefer short-lived external workload federation
over a long-lived downloaded service-account key.

## Troubleshooting

| Symptom | Action |
|---|---|
| Installer cannot detect a public IPv4 | Confirm outbound HTTPS and, on GCE, metadata access; rerun with an explicit domain if available |
| Generated `sslip.io` hostname does not resolve | Confirm the detected public IPv4 and retry DNS; use your own domain if the third-party DNS service is unavailable |
| DNS mismatch | Correct the `A` record and any `AAAA` record, wait for propagation, and rerun |
| Port 80 or 443 conflict | Stop and decide which proxy should own the host; do not publish internal ports |
| Certificate failure | Check hostname resolution, inbound TCP 80/443, NAT, and the ACME email |
| `remote-chrome status` fails | Inspect `sudo journalctl -u remote-chrome.service -f`; do not expose private ports as a workaround |
| MCP returns 401 | Retrieve the current protected handoff locally and use the correct bearer token or compatibility URL |
| MCP initialization returns 404 | Check for a stale or malformed token-in-path URL |
| A later MCP session is unknown | Initialize a new MCP protocol session and take a fresh browser snapshot; do not clear the Chrome profile |
| noVNC page returns 401 | Use the one-click URL or current Basic Auth credentials |
| noVNC loads but cannot connect | Run `sudo remote-chrome status`; it verifies the WebSocket proxy |
| Website is logged out | Repeat the human `/login/` handoff; do not erase the rest of the profile |
| State disappears after direct Compose recreation | Confirm the same project and named volume are used and that `down --volumes` was never run |

## Security checklist

- Store MCP and login credentials in a password manager.
- Treat the compatibility MCP URL and one-click noVNC URL as passwords.
- Never commit `.env`, credentials, cookies, profiles, ACME state, or backup
  archives.
- Do not paste `sudo remote-chrome credentials` output into chat or logs.
- Keep only TCP 80 and 443 public.
- Protect the persistent Chrome profile like a credential store.
- Rotate credentials after suspected disclosure.
- Require explicit confirmation before purchases, submissions, transfers, or
  account changes.
- Do not automate CAPTCHA, MFA, or security-key challenges.

## Installation completion checklist

An installation is complete only when:

- the selected hostname resolves to the correct public IPv4;
- public TCP 80 and 443 reach Caddy;
- HTTPS has a valid certificate;
- anonymous MCP requests are rejected;
- authenticated MCP initialization succeeds;
- multiple MCP tool calls work in one session;
- the protected noVNC page and WebSocket work;
- the browser is full headed Chrome;
- only TCP 80 and 443 are published;
- the human can complete login in the same browser controlled by MCP;
- browser cookies survive a container restart;
- the managed service returns after a host reboot;
- the operator has safely stored the protected handoff.

## Related documentation

- [`README.md`](README.md) — architecture, usage, and operations overview
- [`docs/vm-install.md`](docs/vm-install.md) — concise managed VM reference
- [`docs/gce-manual.md`](docs/gce-manual.md) — Google Compute Engine setup
- [`docs/remote-login.md`](docs/remote-login.md) — human login and persistence
- [`skills/remote-chrome-mcp/SKILL.md`](skills/remote-chrome-mcp/SKILL.md) —
  operating instructions for an MCP agent
- [`AGENTS.md`](AGENTS.md) — implementation handoff and safety boundaries
