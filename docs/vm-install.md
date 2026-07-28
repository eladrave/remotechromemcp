# Install Remote Chrome MCP on a Linux VM

This is the generic path for an SSH-accessible VM or dedicated server. It
installs the Docker Compose deployment, terminates public TLS on the machine,
and keeps Chrome state in a persistent host data directory.

## Supported host

- Ubuntu 22.04, Ubuntu 24.04, or Debian 12
- x86_64/amd64 CPU
- Root access through `sudo`
- Either a domain whose public DNS points to this server or a stable public
  IPv4 for automatic `sslip.io` naming
- Inbound TCP 80 and TCP 443 reachable from the Internet
- Host ports 80 and 443 unused by another web server or proxy

The installer never formats disks and never changes firewall rules. Prepare and
mount storage yourself before selecting its data directory. If an existing
proxy or listener owns port 80 or port 443, installation stops and reports the
conflict; it does not replace or silently reconfigure that proxy.

## Guided latest install

For an interactive installation, SSH to the server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

Use this moving `master` command only when you intentionally chose the guided
latest installer. It asks through `/dev/tty` for:

- whether you have a public domain and, when you do, its hostname;
- the certificate email used for ACME notices;
- the absolute persistent data directory;
- whether to explicitly enable GCS backup, which is disabled by default;
- the GCS bucket and optional systemd calendar schedule when enabled.

If you answer no, enter `none`, or press Enter at the domain question, the
installer detects the host's public IPv4 and uses
`<public-ip-with-dashes>.sslip.io`. This requires no DNS account, but the
address must be stable and public TCP 80/443 must reach the VM. You can also
request this explicitly with `--domain none`, or omit `--domain` in
noninteractive mode.

The installer validates the supported OS and architecture, DNS, port
availability, Docker Compose, release contents, HTTPS health, and MCP
initialization before printing the handoff.

## Pinned production install

Automated production installation must select an immutable release:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/v1.0.0/vminstall/install.sh | sudo sh -s -- --version v1.0.0
```

The pinned command is not live until the matching `v1.0.0` tag and release
assets exist and pass CI. Do not present a version as installable merely because
it appears in this example.

For noninteractive automation, provide every required value and any optional
domain or backup configuration explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/v1.0.0/vminstall/install.sh |
  sudo sh -s -- \
    --version v1.0.0 \
    --non-interactive \
    --domain chrome.example.com \
    --email admin@example.com \
    --data-dir /var/lib/remote-chrome \
    --enable-gcs-backup \
    --gcs-bucket example-remote-chrome-backups \
    --backup-schedule 'daily'
```

Omit `--domain` to use an automatically generated `sslip.io` hostname. Omit all
GCS flags to leave backup disabled. A noninteractive first install without the
certificate email or data directory fails instead of guessing.

## Connection handoff

On success, the installer writes a root-readable handoff and prints the exact:

- MCP URL and bearer-token form;
- browser login URL and one-click token URL;
- login username and generated password;
- status and credential-retrieval commands.

Store these values in a password manager. Never put a token/password in chat.
Retrieve the exact MCP URL and all remote-chrome credentials later from the
server's SSH terminal:

```bash
sudo remote-chrome credentials
```

The browser login is web based. An agent or user with no shell opens the
reported `/login/` URL; routine site login never requires running a remote
`login.sh`.

The one-click URL has the form
`https://chrome.example.com/login/?token=<random-login-token>`. A valid token
is exchanged for a Secure, HttpOnly, SameSite=Strict cookie and immediately
redirected to the clean `/login/` path. The cookie lasts eight hours and also
authorizes the noVNC WebSocket. Basic Auth remains available as a fallback.
Treat the one-click URL like a password: it is reusable until credentials are
rotated and may remain in browser history or link-sharing systems.

The MCP server also publishes the read-only
`remote_chrome_request_human_intervention` tool. When a site requires a
password, MFA, CAPTCHA, security key, consent, or another human-only step, the
agent calls this tool with no arguments and gives its returned protected noVNC
URL to the requesting user. The tool never accepts usernames, passwords, codes,
or other verification data. After the user returns control, the agent takes a
fresh browser snapshot and continues in the same persistent profile.

## Operations

Inspect the installed release, service, health, backup schedule, and most recent
manifest:

```bash
sudo remote-chrome status
```

Reprint protected connection details:

```bash
sudo remote-chrome credentials
```

Update to an immutable release:

```bash
sudo remote-chrome update --version v1.0.1
```

Activation health-checks the new release and rolls back to the prior release
when activation fails. Review `sudo remote-chrome status` after every update.
An unpinned update requires an explicit opt-in flag; production automation
should remain pinned.

Create a quiesced GCS backup and inspect the uploaded manifest:

```bash
sudo remote-chrome backup
sudo remote-chrome status
```

Restore only from the exact manifest URI reported for the configured bucket:

```bash
sudo remote-chrome restore \
  gs://example-remote-chrome-backups/remote-chrome/<exact-backup>.manifest
```

Restore replaces the current browser profile after validation, so confirm the
intended recovery point first.

Uninstall services and application releases while preserving profile data and
backups by default:

```bash
sudo remote-chrome uninstall
```

Destructive profile or backup deletion requires the CLI's explicit delete
flags. Read the displayed targets and confirmation prompt before approving it.

## Troubleshooting

- DNS mismatch: update the domain record to this server's public address, wait
  for propagation, and rerun.
- Existing proxy conflict: stop and decide whether this deployment should own
  ports 80/443. The installer will not replace the existing proxy.
- Certificate failure: verify DNS, public TCP 80/TCP 443 reachability, and the
  certificate email.
- MCP client error: retrieve `sudo remote-chrome credentials` locally and use
  the exact reported URL and authentication mode. Do not expose internal MCP,
  CDP, VNC, or noVNC ports.
- Site requests authentication or human verification: open the reported
  `/login/` URL, complete it in the persistent browser, then return control to
  the agent.
