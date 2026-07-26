# Portable VM Installer, GCE Setup, and GCS Backups Design

## Goal

Provide a guided installation path for Remote Chrome MCP on an SSH-accessible
Linux VM while preserving the same headed Chrome, persistent profile, MCP
authentication, and browser-based human-login behavior as the native and
Docker deployments.

The primary quick-install command is:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

The installer must guide an interactive user through every required decision
and finish by printing and securely storing all MCP and login-console
connection details.

## Supported Platforms

The first release supports:

- Ubuntu 22.04 LTS on x86_64;
- Ubuntu 24.04 LTS on x86_64;
- Debian 12 on x86_64;
- a root shell or a user with working `sudo`;
- Docker Engine with Docker Compose v2;
- public TCP ports 80 and 443.

The first release does not support:

- Linux distributions outside the three listed versions;
- ARM or other non-x86_64 machines;
- Cloud Run;
- a live Chrome profile stored on Cloud Storage FUSE or Cloud Run NFS;
- silently replacing an existing reverse proxy or firewall policy.

Cloud Run is excluded because Cloud Storage FUSE is not POSIX compliant and
does not provide file locking, while Cloud Run mounts NFS without locking.
Chrome profiles contain SQLite databases and require conventional local
filesystem semantics. The supported Google Cloud deployment is therefore a
Compute Engine VM with Persistent Disk. See Google's documentation for
[Cloud Storage FUSE limitations](https://docs.cloud.google.com/storage/docs/cloud-storage-fuse/overview)
and [Cloud Run NFS limitations](https://docs.cloud.google.com/run/docs/configuring/services/nfs-volume-mounts).

## Installation Modes

### Interactive Quick Install

The unpinned convenience command installs the current `master` version:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh
```

Because the shell script itself arrives on standard input, all interactive
questions read from `/dev/tty`. If `/dev/tty` is unavailable, the installer
must exit with a concise list of required noninteractive arguments instead of
hanging.

The wizard asks for:

1. the public domain;
2. the ACME certificate-notice email;
3. confirmation that DNS points to the VM;
4. the persistent data directory;
5. whether GCS archive backups are required;
6. the GCS bucket name when backups are enabled;
7. whether an optional scheduled backup should be installed.

### Pinned Production Install

Production installations should pin both the fetched installer and the
downloaded release:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/v1.0.0/vminstall/install.sh \
  | sudo sh -s -- --version v1.0.0
```

Pinned releases download a release archive plus its SHA-256 manifest and
refuse activation when verification fails. The `master` path is labeled
`latest/unpinned` in installer output and cannot claim immutable supply-chain
verification.

### Noninteractive Install

Automation uses the same installer:

```bash
curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/v1.0.0/vminstall/install.sh \
  | sudo sh -s -- \
      --non-interactive \
      --version v1.0.0 \
      --domain chrome.example.com \
      --email admin@example.com \
      --data-dir /var/lib/remote-chrome
```

Noninteractive mode exits with status 2 when required values are absent.

## Installer Workflow

The installer performs these phases in order:

1. Detect and validate the operating system, release, architecture, root
   access, disk space, and memory.
2. Ask for the domain and certificate email before making host changes.
3. Validate the domain, resolve its A/AAAA records, determine the server's
   public address, and compare the results. A mismatch fails by default and
   requires an explicit `--skip-dns-check`.
4. Check whether TCP ports 80 or 443 are already occupied. A conflict stops
   installation and reports the owning process without changing it.
5. Install required host packages and Docker Engine/Compose from Docker's
   official apt repository. The installer does not pipe Docker's convenience
   installer into a shell.
6. Download and verify the selected repository release into a staging
   directory.
7. Create the application, configuration, data, profile, certificate, and
   backup directories with explicit ownership and permissions.
8. Generate independent MCP bearer and human-console credentials.
9. Render the environment and Compose configuration.
10. Validate Compose, install the systemd wrapper, and start the stack.
11. Wait for browser health, Caddy readiness, TLS issuance, authenticated MCP
    initialize, noVNC Basic authentication, and a noVNC WebSocket upgrade.
12. Atomically activate the version only after all checks succeed.
13. Print and save the complete connection handoff.

Every phase is idempotent. Rerunning the installer preserves credentials,
profiles, certificates, and backup configuration unless an explicit rotation
or reset flag is supplied.

## Filesystem Layout

The default installation uses:

```text
/opt/remotechromemcp/
├── releases/
│   └── v1.0.0/
└── current -> releases/v1.0.0

/etc/remote-chrome/
├── install.env
├── compose.env
└── credentials.env

/var/lib/remote-chrome/
├── profile/
├── caddy-data/
├── caddy-config/
├── backups/
└── restore-staging/

/etc/systemd/system/remote-chrome.service
/usr/local/sbin/remote-chrome
```

`/etc/remote-chrome` files are root-owned and mode 600. The profile and Caddy
directories are owned by the container runtime UID/GID selected by the image.
The active release symlink permits atomic upgrade and rollback without moving
profile data.

The Compose deployment uses bind mounts from the configured data directory
instead of hiding VM installations inside Docker-managed named volumes.

## Domain, HTTPS, and Network Routing

Before installation, the wizard and the installation skill must ask:

1. Which domain will serve Remote Chrome?
2. Which email should receive certificate notices?
3. Does the domain already resolve to this VM?

The host publishes exactly:

```text
0.0.0.0:80  -> Caddy container port 80
0.0.0.0:443 -> Caddy container port 443
```

No host mapping is created for CDP 9222, Playwright MCP 8931, VNC 5900, or
noVNC 6080.

Caddy:

- obtains and renews the public certificate automatically;
- persists ACME state under the configured data directory;
- redirects HTTP to HTTPS;
- routes bearer-authenticated `https://chrome.example.com/mcp`;
- retains token-path compatibility;
- returns 401 for missing authentication and 405 for unsupported MCP methods;
- preserves Playwright MCP's upstream `Content-Type`;
- routes `https://chrome.example.com/login/` through independent Basic
  authentication;
- preserves noVNC WebSocket upgrades.

The installer must not report success until the public HTTPS endpoint passes
authenticated MCP and login-console health checks.

The generic installer diagnoses host firewall and provider-firewall failures
but does not silently modify them. The GCE guide creates explicit TCP 80/443
firewall rules. SSH port 22 is never changed by the installer.

## Connection Handoff

Successful installation prints:

- the preferred MCP URL;
- the bearer token;
- the token-in-URL compatibility endpoint;
- the login-console URL;
- the login username and password;
- certificate readiness and expiry information;
- configuration, release, profile, and backup locations;
- ready-to-copy MCP client examples;
- status, credentials, update, backup, restore, and uninstall commands.

The same details are stored in `/etc/remote-chrome/credentials.env` with root
ownership and mode 600. Secrets are not written to ordinary logs.

The installed management command exposes:

```bash
sudo remote-chrome status
sudo remote-chrome credentials
sudo remote-chrome login
sudo remote-chrome update
sudo remote-chrome backup
sudo remote-chrome restore
sudo remote-chrome uninstall
```

`credentials` is the only routine command that prints secret values, and it
requires root access.

## Service and Upgrade Model

`remote-chrome.service` is a system service that:

- starts after Docker and the network are ready;
- runs `docker compose up -d`;
- uses the root-only Compose environment;
- waits for browser and proxy health;
- stops the Compose project cleanly during shutdown;
- restarts after host reboot.

An update downloads and verifies a new release into a separate directory,
renders and validates configuration, records the prior active release, and
activates the new release. If browser, MCP, Caddy, TLS, or noVNC health fails,
the command restores the previous release and confirms its health before
returning failure.

Uninstall removes the system service and application releases but preserves
configuration, profiles, certificates, and backups by default. Deleting any
of those data classes requires a separate explicit flag and a canonical-path
safety check.

## Generic VM Storage

The default data directory is `/var/lib/remote-chrome`. Users may select a
mounted local or block-storage path with `--data-dir`.

The installer:

- requires an absolute canonical path;
- rejects `/`, `/home`, `/root`, `/etc`, `/var`, and unresolved symlinks;
- never formats block devices;
- creates only the Remote Chrome subdirectories beneath the selected path;
- reports available space before building the image;
- refuses to share one profile directory between multiple installations.

Disk partitioning, filesystem creation, and mounting remain explicit
provider-specific steps.

## Manual Google Compute Engine Setup

The GCE guide uses manual `gcloud` commands rather than Terraform.

It covers:

1. enabling Compute Engine and Cloud Storage APIs;
2. creating a restricted service account;
3. reserving a static external IPv4 address;
4. creating an Ubuntu 24.04 x86_64 VM;
5. creating and attaching a separate balanced Persistent Disk;
6. creating TCP 80/443 firewall rules with a dedicated network tag;
7. granting the VM service account access only to the selected backup bucket;
8. connecting by SSH;
9. resolving the data disk through `/dev/disk/by-id`;
10. refusing to format a disk that already contains a filesystem;
11. formatting an empty approved disk as ext4;
12. mounting it at `/var/lib/remote-chrome` by filesystem UUID in
    `/etc/fstab`;
13. running the generic interactive installer;
14. verifying reboot persistence, TLS, MCP, noVNC, and backup/restore.

The recommended starting VM is an x86_64 machine with at least 2 vCPU and
8 GiB memory. The guide describes this as a baseline, not an enforced product
limit.

The same installer remains valid on other providers when the user supplies an
x86_64 Ubuntu/Debian VM, public 80/443 access, DNS, and persistent local or
block storage.

## GCS Backup and Restore

GCS is backup storage only. It is never mounted as Chrome's live profile.

### Backup

`sudo remote-chrome backup`:

1. acquires an exclusive maintenance lock;
2. verifies bucket configuration and credentials;
3. records current service health;
4. stops the browser cleanly so SQLite files are quiescent;
5. creates a compressed archive in local staging;
6. writes a SHA-256 checksum and metadata manifest;
7. uploads archive, checksum, and manifest with `gcloud storage cp`;
8. restarts the stack in a guaranteed cleanup path;
9. verifies public MCP and login-console health;
10. reports the immutable GCS object names.

An upload failure must not leave the browser stopped.

When requested by the wizard, a systemd timer runs the same locked backup
command on the approved schedule. The timer is never enabled silently.

### Restore

`sudo remote-chrome restore gs://remote-chrome-backups/example`:

1. requires explicit confirmation or `--force`;
2. acquires the maintenance lock;
3. downloads archive, checksum, and manifest into staging;
4. validates the checksum and rejects absolute paths, traversal, links, and
   unexpected ownership metadata;
5. stops the stack;
6. moves the current profile to a timestamped rollback directory;
7. extracts the restored profile with fixed ownership;
8. starts and health-checks the stack;
9. restores the rollback profile if activation fails.

The restore command never overlays an active profile in place.

GCE Persistent Disk snapshot schedules remain the recommended first recovery
layer. GCS archives provide portable, off-machine recovery.

## Agent Guidance

The installation guidance added to the portable skill must:

- ask for domain, certificate email, DNS readiness, data directory, and GCS
  preference before running installation;
- select native installation only when the user explicitly prefers it;
- recommend Docker Compose for a new SSH-only VM;
- use the interactive quick-install command when the user wants a guided
  install;
- use pinned release and noninteractive flags for automation;
- never guess a domain, email, disk, mount path, public IP, or bucket;
- never format a disk without explicit user approval;
- never expose internal browser-control ports;
- never replace an existing reverse proxy without explicit migration
  approval;
- never include credentials in the skill or server instructions.

After installation, the agent must hand the user the protected connection
details and teach them `sudo remote-chrome credentials`.

## Error Handling and Recovery

The installer uses staged changes and traps:

- package or download failure leaves the current installation active;
- checksum failure prevents extraction;
- invalid DNS, occupied ports, or failed TLS prevents activation;
- Compose failure captures redacted logs;
- activation failure restores the previous release and environment;
- an interrupted first install leaves a resumable staging directory and no
  enabled system service;
- backup/upload failure restarts the prior healthy stack;
- restore failure returns to the prior profile.

Every destructive path canonicalizes and validates its exact target before
mutation.

## Test Strategy

### Installer Contracts

- Ubuntu 22.04, Ubuntu 24.04, and Debian 12 detection;
- rejection of unsupported OS versions and non-x86_64 architectures;
- `/dev/tty` interactive flow and no-TTY failure;
- noninteractive required-argument validation;
- domain, email, DNS, public-IP, path, and occupied-port validation;
- official Docker repository configuration;
- staged release download and checksum failure;
- idempotent reinstall without credential rotation;
- failed-upgrade rollback;
- root-only secret permissions;
- unsafe data and deletion path rejection.

### Runtime Contracts

- only host ports 80 and 443 are published;
- public TLS becomes ready;
- bearer and token-path MCP initialize;
- one upstream MCP `Content-Type`;
- unsupported GET returns 405;
- noVNC rejects anonymous access, accepts Basic auth, and upgrades WebSockets;
- headed Chrome does not contain `HeadlessChrome`;
- profile state survives container and host restart;
- `remote-chrome credentials` returns the same installed credentials.

### Backup and Restore Contracts

- the browser is quiesced before archiving;
- failed upload always restarts the stack;
- archive checksum and path validation;
- unsafe archives are rejected;
- successful GCS round trip;
- failed restored-profile health triggers rollback;
- concurrent backup/restore commands are rejected by the lock.

Tests use fake provider and GCS commands unless a dedicated integration
environment is explicitly enabled. They never format a real disk, alter a
real firewall, upload personal profiles, or expose production credentials.

### CI and Manual Verification

CI runs:

- the repository suite and ShellCheck;
- installer contract matrices for all three supported distributions;
- Docker full-stack smoke tests;
- secret and production-endpoint scanning.

The GCE manual checklist verifies:

- static IP and DNS;
- firewall behavior;
- Persistent Disk mount after reboot;
- public TLS;
- MCPJam readiness;
- browser-based human login;
- GCS backup;
- destructive restore test with a harmless synthetic profile;
- upgrade and rollback.

## Acceptance Criteria

The VM-installer feature is complete when:

1. The documented `curl | sudo sh` command completes a guided installation
   on each supported distribution.
2. The wizard asks for domain and certificate email before host changes.
3. Host 80/443 traffic reaches Caddy and no internal browser port is public.
4. Caddy obtains TLS and both MCP authentication modes work.
5. The installer displays and securely stores every required connection
   detail.
6. The installation survives a host reboot with profile and certificate state
   intact.
7. A pinned update either becomes healthy or rolls back cleanly.
8. The same installer works on a generic VM and the documented GCE VM.
9. GCS backup never archives a running Chrome profile.
10. Restore validates input and rolls back on failed browser health.
11. Automated checks cover supported platforms, installer safety, proxy
    routing, secrets, upgrade, backup, and restore.
