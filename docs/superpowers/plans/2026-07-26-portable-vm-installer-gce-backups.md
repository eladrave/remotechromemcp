# Portable VM Installer, GCE Setup, and GCS Backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a guided `curl | sudo sh` installer for supported SSH-accessible Linux VMs, a safe installed management CLI, manual GCE/Persistent Disk instructions, and quiesced GCS backup/restore.

**Architecture:** A small POSIX bootstrap runs correctly when piped to `sudo sh`, downloads a selected repository release, and hands control to a testable Bash installer. VM installations reuse the existing browser/Caddy Compose stack through a bind-mount override, store releases/configuration/data separately, and expose lifecycle operations through a root-only `remote-chrome` command.

**Tech Stack:** POSIX shell, Bash, Docker Engine, Docker Compose v2, Caddy 2, systemd, Google Chrome Stable, `@playwright/mcp` 0.0.78, curl, OpenSSL, tar, SHA-256, Google Cloud CLI, GitHub Releases, ShellCheck, GitHub Actions.

## Global Constraints

- Support only Ubuntu 22.04, Ubuntu 24.04, and Debian 12 on x86_64 in the first release.
- The exact interactive command `curl -fsSL https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh | sudo sh` must work.
- `vminstall/install.sh` must be valid POSIX shell because the documented command invokes `sh`, not Bash.
- Interactive prompts must read from `/dev/tty`; no-TTY mode must fail with required noninteractive flags rather than hang.
- Ask for the public domain and ACME email before making host changes.
- Docker packages must come from Docker's official apt repository; do not invoke Docker's convenience installer.
- Host mappings `0.0.0.0:80:80` and `0.0.0.0:443:443` route only to Caddy; do not publish CDP 9222, MCP 8931, VNC 5900, or noVNC 6080.
- Preserve Playwright MCP's upstream `Content-Type` and both bearer-header and token-path authentication.
- Store releases under `/opt/remotechromemcp`, root-only configuration under `/etc/remote-chrome`, and persistent data under `/var/lib/remote-chrome` by default.
- VM Compose uses bind mounts for profile and Caddy state; the existing ordinary Compose named-volume workflow must remain usable.
- Rerunning installation preserves credentials, profile, certificates, and backup configuration unless an explicit rotation/reset flag is supplied.
- GCS is backup storage only and must never be mounted as Chrome's live profile.
- Stop Chrome cleanly before archiving or restoring its profile.
- Never format a block device in the generic installer.
- Never silently alter SSH, a host firewall, a provider firewall, or an existing reverse proxy.
- Every mutation test must use a canonical `mktemp -d` root; `REMOTE_CHROME_DRY_RUN=1` without a safe explicit `REMOTE_CHROME_TEST_ROOT` must fail before any write, delete, package, service, or sudo command.
- Never place real domains, tokens, passwords, cookies, or personal profile data in tracked files or test output.
- Pin `@playwright/mcp` to `0.0.78`.
- Do not push, publish a release, or create a pull request without explicit user authorization.

## Cross-Plan Execution Order

This plan depends on completed Docker Task 4 from
`docs/superpowers/plans/2026-07-26-remote-chrome-guidance-login-deployments.md`.

Execute the original plan's Task 5 first so
`skills/remote-chrome-mcp/SKILL.md` exists. Then execute Tasks 1-7 below.
After this plan is complete, resume the original plan at Task 6 so its README,
GitHub Actions, full native verification, and GitHub handoff include the VM
installer.

## File Structure

```text
.
├── .env.example
├── Caddyfile
├── compose.yaml
├── docs/
│   ├── gce-manual.md
│   ├── vm-install.md
│   └── superpowers/
│       ├── plans/2026-07-26-portable-vm-installer-gce-backups.md
│       └── specs/2026-07-26-portable-vm-installer-gce-backups-design.md
├── scripts/
│   └── package-release.sh
├── skills/remote-chrome-mcp/SKILL.md
├── tests/
│   ├── fixtures/
│   │   ├── os-release-debian-12
│   │   ├── os-release-ubuntu-22.04
│   │   └── os-release-ubuntu-24.04
│   ├── vm-compose-contract.test.sh
│   ├── vminstall-backup.test.sh
│   ├── vminstall-bootstrap.test.sh
│   ├── vminstall-contract.test.sh
│   ├── vminstall-distributions.test.sh
│   ├── vminstall-gce-docs.test.sh
│   └── vminstall-management.test.sh
└── vminstall/
    ├── compose.vm.yaml
    ├── install.sh
    ├── installer-main.sh
    ├── lib/
    │   ├── activate.sh
    │   ├── backup.sh
    │   ├── common.sh
    │   ├── config.sh
    │   ├── docker.sh
    │   ├── host.sh
    │   ├── management.sh
    │   ├── release.sh
    │   └── wizard.sh
    ├── remote-chrome
    ├── remote-chrome-backup.service.in
    ├── remote-chrome-backup.timer.in
    └── remote-chrome.service.in
```

---

### Task 1: VM Compose Overlay and ACME Configuration

**Files:**
- Create: `vminstall/compose.vm.yaml`
- Create: `tests/vm-compose-contract.test.sh`
- Modify: `compose.yaml`
- Modify: `Caddyfile`
- Modify: `.env.example`
- Modify: `scripts/bootstrap-docker.sh`
- Modify: `tests/compose-config.test.sh`
- Modify: `tests/compose-smoke.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: existing services `browser` and `proxy` from `compose.yaml`.
- Consumes: `REMOTE_CHROME_DATA_DIR`, `ACME_EMAIL`, `DOMAIN`, and existing authentication variables.
- Produces: the command `docker compose -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env config`.
- Produces: bind mounts at `${REMOTE_CHROME_DATA_DIR}/profile`, `caddy-data`, and `caddy-config`.

- [ ] **Step 1: Add the failing VM Compose contract**

Create `tests/vm-compose-contract.test.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for file in vminstall/compose.vm.yaml compose.yaml Caddyfile; do
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

if command -v docker >/dev/null 2>&1 &&
   docker compose version >/dev/null 2>&1; then
  env_file="$(mktemp)"
  trap 'rm -f "$env_file"' EXIT
  hash='$2a$14$TRf6ynPaHFGoGIzGbRPBMumKVsUbVexXBXaVlsN0t6s/6MwOe5FMe'
  {
    printf 'DOMAIN=chrome.example.com\n'
    printf 'ACME_EMAIL=admin@example.com\n'
    printf 'MCP_TOKEN=%s\n' "$(printf 'a%.0s' {1..64})"
    printf 'LOGIN_USERNAME=remotechrome\n'
    printf "LOGIN_PASSWORD_HASH='%s'\n" "$hash"
    printf 'PLAYWRIGHT_MCP_VERSION=0.0.78\n'
    printf 'SCREEN_GEOMETRY=1440x900x24\n'
    printf 'REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome\n'
  } >"$env_file"
  docker compose -f compose.yaml -f vminstall/compose.vm.yaml \
    --env-file "$env_file" config >/dev/null
else
  printf 'SKIP: Docker Compose unavailable; rendered overlay checked in CI\n'
fi
```

Append `bash tests/vm-compose-contract.test.sh` to `tests/run.sh` after the
existing Docker contract.

- [ ] **Step 2: Verify the contract fails for the missing overlay**

Run:

```bash
bash tests/vm-compose-contract.test.sh
```

Expected: FAIL with `required file missing: vminstall/compose.vm.yaml`.

- [ ] **Step 3: Add the VM bind-mount overlay**

Create `vminstall/compose.vm.yaml`:

```yaml
services:
  browser:
    volumes:
      - type: bind
        source: ${REMOTE_CHROME_DATA_DIR:?set REMOTE_CHROME_DATA_DIR}/profile
        target: /data/chrome-profile
  proxy:
    volumes:
      - type: bind
        source: ${REMOTE_CHROME_DATA_DIR:?set REMOTE_CHROME_DATA_DIR}/caddy-data
        target: /data
      - type: bind
        source: ${REMOTE_CHROME_DATA_DIR:?set REMOTE_CHROME_DATA_DIR}/caddy-config
        target: /config
```

Keep the existing `Caddyfile` bind mount from `compose.yaml`; Compose merges
service volumes by container target, replacing only `/data/chrome-profile`,
`/data`, and `/config`.

- [ ] **Step 4: Add ACME email plumbing**

Add `ACME_EMAIL` to `.env.example`:

```dotenv
ACME_EMAIL=admin@example.com
```

Pass it into the `proxy` environment in `compose.yaml`:

```yaml
ACME_EMAIL: ${ACME_EMAIL:?set ACME_EMAIL}
```

Add a Caddy global block before the existing site:

```caddyfile
{
	email {$ACME_EMAIL}
}
```

Do not change MCP response headers or authentication routes.

Update every existing Compose environment writer in
`scripts/bootstrap-docker.sh`, `tests/compose-config.test.sh`, and
`tests/compose-smoke.test.sh` to include `ACME_EMAIL`. The existing Docker
bootstrap accepts `--email EMAIL` and `ACME_EMAIL`; when neither is supplied,
it prompts through `/dev/tty`. Validate with the same email expression used
by the VM installer:

```bash
[[ $acme_email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
  fail 'Certificate email is invalid'
```

Write the value into `.env`:

```bash
printf 'ACME_EMAIL=%s\n' "$acme_email"
```

- [ ] **Step 5: Verify the focused and repository contracts**

Run:

```bash
chmod +x tests/vm-compose-contract.test.sh
bash tests/vm-compose-contract.test.sh
./tests/run.sh
```

Expected: PASS; Docker-dependent rendering may print one explicit local SKIP.

- [ ] **Step 6: Commit the VM Compose boundary**

```bash
git add .env.example Caddyfile compose.yaml vminstall/compose.vm.yaml \
  scripts/bootstrap-docker.sh tests/compose-config.test.sh \
  tests/compose-smoke.test.sh tests/vm-compose-contract.test.sh tests/run.sh
git commit -m "feat: add VM storage overlay and ACME email"
```

---

### Task 2: POSIX Bootstrap and Guided Installer Foundation

**Files:**
- Create: `vminstall/install.sh`
- Create: `vminstall/installer-main.sh`
- Create: `vminstall/lib/common.sh`
- Create: `vminstall/lib/wizard.sh`
- Create: `tests/vminstall-bootstrap.test.sh`
- Create: `tests/vminstall-contract.test.sh`
- Create: `tests/fixtures/os-release-ubuntu-22.04`
- Create: `tests/fixtures/os-release-ubuntu-24.04`
- Create: `tests/fixtures/os-release-debian-12`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces POSIX entrypoint: `vminstall/install.sh [--version REF] [installer options]`.
- Produces Bash entrypoint: `vminstall/installer-main.sh`.
- Produces Bash functions: `vm_die`, `vm_log`, `vm_require_root`, `vm_parse_args`, `vm_prompt`, `vm_validate_domain`, `vm_validate_email`, `vm_validate_data_dir`, `vm_load_platform`, `vm_validate_platform`.
- Consumes test overrides: `REMOTE_CHROME_TEST_ROOT`, `REMOTE_CHROME_OS_RELEASE`, `REMOTE_CHROME_TTY`, `REMOTE_CHROME_FAKE_BIN`, and `REMOTE_CHROME_SKIP_MAIN`.

- [ ] **Step 1: Add POSIX bootstrap RED tests**

Create `tests/vminstall-bootstrap.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

dash -n vminstall/install.sh 2>/dev/null ||
  fail 'vminstall/install.sh must parse under dash'

help_output="$(dash vminstall/install.sh --help)"
grep -Fq -- '--version' <<<"$help_output" ||
  fail 'bootstrap help must document --version'
grep -Fq -- '--domain' <<<"$help_output" ||
  fail 'bootstrap must pass installer arguments through'

if dash vminstall/install.sh --version >/tmp/vminstall-missing-version.out 2>&1; then
  fail 'missing --version value must fail'
fi
grep -Fq 'requires a value' /tmp/vminstall-missing-version.out ||
  fail 'missing version failure must be actionable'
```

Create `vminstall/install.sh` initially with a Bash-only array so `dash -n`
fails for the expected reason. Remove the invalid file after observing RED;
do not retain it as implementation reference.

- [ ] **Step 2: Record the POSIX bootstrap failure**

Run:

```bash
bash tests/vminstall-bootstrap.test.sh
```

Expected: FAIL with `vminstall/install.sh must parse under dash`.

- [ ] **Step 3: Implement the POSIX bootstrap**

Create a POSIX-only `vminstall/install.sh` with this control flow:

```sh
#!/bin/sh
set -eu

default_ref=master
selected_ref=$default_ref
tmp_dir=$(mktemp -d)
args_file=$tmp_dir/installer.args
umask 077
: >"$args_file"

cleanup() {
  if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    rm -rf -- "$tmp_dir"
  fi
}
trap cleanup 0 HUP INT TERM

bootstrap_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

bootstrap_usage() {
  printf '%s\n' \
    'Usage: install.sh [--version REF] [installer options]' \
    'Installer options include --domain, --email, --data-dir, and --non-interactive.'
}

bootstrap_append_arg() {
  case "$1" in
    *'
'*) bootstrap_fail 'arguments may not contain newlines' ;;
  esac
  printf '%s\n' "$1" >>"$args_file"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      bootstrap_usage
      exit 0
      ;;
    --version)
      [ "$#" -ge 2 ] || bootstrap_fail '--version requires a value'
      selected_ref=$2
      bootstrap_append_arg "$1"
      bootstrap_append_arg "$2"
      shift 2
      ;;
    *)
      bootstrap_append_arg "$1"
      shift
      ;;
  esac
done
```

After extracting the release, reconstruct positional arguments without
`eval`:

```sh
set --
while IFS= read -r bootstrap_arg || [ -n "$bootstrap_arg" ]; do
  set -- "$@" "$bootstrap_arg"
done <"$args_file"

bash "$extracted_dir/vminstall/installer-main.sh" "$@"
```

Tests must include spaces and shell metacharacters and prove they are passed
literally. The bootstrap rejects newline-containing arguments because newline
is the argument-file delimiter.

For `master`, download:

```text
https://github.com/eladrave/remotechromemcp/archive/refs/heads/master.tar.gz
```

For `v1.0.0`, download release assets:

```text
https://github.com/eladrave/remotechromemcp/releases/download/v1.0.0/remotechromemcp-v1.0.0.tar.gz
https://github.com/eladrave/remotechromemcp/releases/download/v1.0.0/remotechromemcp-v1.0.0.tar.gz.sha256
```

Verify pinned SHA-256 with `sha256sum -c`; label `master` as unpinned. Invoke
the extracted Bash installer using `/dev/tty` only for prompts.

- [ ] **Step 4: Add wizard and platform RED contracts**

Create fixtures with exact contents:

`tests/fixtures/os-release-ubuntu-22.04`:

```dotenv
ID=ubuntu
VERSION_ID="22.04"
```

`tests/fixtures/os-release-ubuntu-24.04`:

```dotenv
ID=ubuntu
VERSION_ID="24.04"
```

`tests/fixtures/os-release-debian-12`:

```dotenv
ID=debian
VERSION_ID="12"
```

Create `tests/vminstall-contract.test.sh` that sources
`vminstall/installer-main.sh` with `REMOTE_CHROME_SKIP_MAIN=1` and asserts:

```bash
vm_validate_domain chrome.example.com
! vm_validate_domain https://chrome.example.com
! vm_validate_domain chrome.example.com/path
vm_validate_email admin@example.com
! vm_validate_email admin

for fixture in tests/fixtures/os-release-*; do
  REMOTE_CHROME_OS_RELEASE="$fixture" vm_load_platform
  vm_validate_platform
done

REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-debian-12 vm_load_platform
REMOTE_CHROME_TEST_ARCH=aarch64
! vm_validate_platform
```

Add a no-TTY test that invokes noninteractive mode without `--domain`,
`--email`, or `--data-dir` and expects exit 2 plus all three flag names.

- [ ] **Step 5: Verify the wizard contracts fail**

Run:

```bash
bash tests/vminstall-contract.test.sh
```

Expected: FAIL because `vminstall/installer-main.sh` and its functions do not
exist.

- [ ] **Step 6: Implement common validation and wizard collection**

Create `vminstall/lib/common.sh` with:

```bash
vm_die() {
  local code=$1
  shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

vm_log() {
  printf '[remote-chrome] %s\n' "$*"
}

vm_require_root() {
  local effective_uid=${REMOTE_CHROME_TEST_EUID:-$EUID}
  [[ $effective_uid -eq 0 ]] ||
    vm_die 77 'Run the installer as root, for example with sudo sh'
}

vm_init_paths() {
  local prefix=
  if [[ -n ${REMOTE_CHROME_TEST_ROOT:-} ]]; then
    prefix=$(realpath -m -- "$REMOTE_CHROME_TEST_ROOT")
    [[ $prefix == /tmp/* && -d $prefix && ! -L $REMOTE_CHROME_TEST_ROOT ]] ||
      vm_die 64 'REMOTE_CHROME_TEST_ROOT must be a real directory beneath /tmp'
  elif [[ ${REMOTE_CHROME_DRY_RUN:-0} == 1 ]]; then
    vm_die 64 'Dry-run requires REMOTE_CHROME_TEST_ROOT'
  fi

  REMOTE_CHROME_INSTALL_ROOT=${REMOTE_CHROME_INSTALL_ROOT:-${prefix}/opt/remotechromemcp}
  REMOTE_CHROME_CONFIG_ROOT=${REMOTE_CHROME_CONFIG_ROOT:-${prefix}/etc/remote-chrome}
  REMOTE_CHROME_SYSTEMD_ROOT=${REMOTE_CHROME_SYSTEMD_ROOT:-${prefix}/etc/systemd/system}
  REMOTE_CHROME_CLI_ROOT=${REMOTE_CHROME_CLI_ROOT:-${prefix}/usr/local/sbin}
}

vm_validate_domain() {
  [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ $1 == *.* ]]
}

vm_validate_email() {
  [[ ${1:-} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}
```

Create `vminstall/lib/wizard.sh` with:

```bash
vm_prompt() {
  local prompt=$1
  local value
  [[ -r ${REMOTE_CHROME_TTY:-/dev/tty} ]] ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --domain, --email, and --data-dir"
  read -r -p "$prompt" value <"${REMOTE_CHROME_TTY:-/dev/tty}"
  printf '%s' "$value"
}

vm_validate_data_dir() {
  local candidate=$1
  [[ $candidate == /* ]] || return 1
  case "$candidate" in
    /|/home|/root|/etc|/var) return 1 ;;
  esac
  [[ "$candidate" != *$'\n'* ]]
}
```

Implement `vm_parse_args` without `eval`:

```bash
vm_installer_usage() {
  printf '%s\n' \
    'Usage: installer-main.sh [options]' \
    '  --version REF' \
    '  --domain DOMAIN' \
    '  --email EMAIL' \
    '  --data-dir ABSOLUTE_PATH' \
    '  --gcs-bucket BUCKET' \
    '  --backup-schedule SYSTEMD_CALENDAR' \
    '  --non-interactive --skip-dns-check --rotate-credentials'
}

vm_parse_args() {
  SELECTED_VERSION=master
  DOMAIN=
  ACME_EMAIL=
  REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome
  GCS_BUCKET=
  BACKUP_SCHEDULE=
  NON_INTERACTIVE=0
  SKIP_DNS_CHECK=0
  ROTATE_CREDENTIALS=0

  while (($#)); do
    case "$1" in
      --version|--domain|--email|--data-dir|--gcs-bucket|--backup-schedule)
        (($# >= 2)) || vm_die 2 "$1 requires a value"
        case "$1" in
          --version) SELECTED_VERSION=$2 ;;
          --domain) DOMAIN=$2 ;;
          --email) ACME_EMAIL=$2 ;;
          --data-dir) REMOTE_CHROME_DATA_DIR=$2 ;;
          --gcs-bucket) GCS_BUCKET=$2 ;;
          --backup-schedule) BACKUP_SCHEDULE=$2 ;;
        esac
        shift 2
        ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --rotate-credentials) ROTATE_CREDENTIALS=1; shift ;;
      --help|-h) vm_installer_usage; return 64 ;;
      *) vm_die 2 "Unknown installer argument: $1" ;;
    esac
  done
}
```

Create `vminstall/installer-main.sh`, source the two libraries relative to its
resolved release directory, and guard execution:

```bash
if [[ ${REMOTE_CHROME_SKIP_MAIN:-0} != 1 ]]; then
  vm_installer_main "$@"
fi
```

- [ ] **Step 7: Verify bootstrap/wizard GREEN and commit**

Run:

```bash
chmod +x vminstall/install.sh vminstall/installer-main.sh \
  tests/vminstall-bootstrap.test.sh tests/vminstall-contract.test.sh
bash tests/vminstall-bootstrap.test.sh
bash tests/vminstall-contract.test.sh
./tests/run.sh
```

Expected: PASS.

Commit:

```bash
git add vminstall tests/vminstall-bootstrap.test.sh \
  tests/vminstall-contract.test.sh tests/fixtures tests/run.sh
git commit -m "feat: add portable VM installer bootstrap"
```

---

### Task 3: Host Preflight, Docker Installation, and Release Staging

**Files:**
- Create: `vminstall/lib/host.sh`
- Create: `vminstall/lib/docker.sh`
- Create: `vminstall/lib/release.sh`
- Create: `tests/vminstall-distributions.test.sh`
- Modify: `vminstall/installer-main.sh`
- Modify: `tests/vminstall-contract.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces: `vm_check_host`, `vm_verify_dns`, `vm_check_public_ports`, `vm_install_docker`, `vm_stage_release`, `vm_verify_release`.
- Consumes: `REMOTE_CHROME_TEST_ROOT`, `REMOTE_CHROME_FAKE_BIN`, `REMOTE_CHROME_DRY_RUN`, and validated installer configuration.
- Produces staging directory `${REMOTE_CHROME_INSTALL_ROOT}/releases/.staging-REF-PID`.

- [ ] **Step 1: Add the failing host-action matrix**

Create `tests/vminstall-distributions.test.sh` with a fake command directory.
Each fake appends its argv to `$COMMAND_LOG`. Run the installer library for
each OS fixture and assert:

```text
ubuntu 22.04 -> Docker Ubuntu repository, codename jammy
ubuntu 24.04 -> Docker Ubuntu repository, codename noble
debian 12    -> Docker Debian repository, codename bookworm
```

The test must also assert:

- `dpkg --print-architecture` equals `amd64`;
- dry-run without a canonical explicit temp root fails before the command log
  records any mutation;
- traversal, symlink, and absolute override attempts cannot escape the temp
  root;
- package commands are not run before domain/email/DNS/port validation;
- existing `docker compose version` skips Docker installation;
- port 80 or 443 listeners cause failure before package changes;
- DNS mismatch fails unless `SKIP_DNS_CHECK=1`;
- generic installer never invokes `mkfs`, `fdisk`, `parted`, or `wipefs`.

Use fixture-generated fake `getent`, `curl`, `ss`, `apt-get`, `dpkg`,
`systemctl`, and `docker`; do not inspect or mutate the host.

- [ ] **Step 2: Verify the host-action matrix fails**

Run:

```bash
bash tests/vminstall-distributions.test.sh
```

Expected: FAIL because `vm_check_host` and `vm_install_docker` are undefined.

- [ ] **Step 3: Implement platform and network preflight**

Create `vminstall/lib/host.sh` with these exact validation boundaries:

```bash
vm_load_platform() {
  local source=${REMOTE_CHROME_OS_RELEASE:-/etc/os-release}
  [[ -r $source ]] || return 1
  OS_ID=
  OS_VERSION=
  # Source only ID and VERSION_ID assignments after rejecting all other keys.
  while IFS='=' read -r key value; do
    case "$key" in
      ID) OS_ID=${value//\"/} ;;
      VERSION_ID) OS_VERSION=${value//\"/} ;;
    esac
  done <"$source"
}

vm_validate_platform() {
  local arch=${REMOTE_CHROME_TEST_ARCH:-$(uname -m)}
  [[ $arch == x86_64 || $arch == amd64 ]] || return 1
  [[ $OS_ID == ubuntu && ( $OS_VERSION == 22.04 || $OS_VERSION == 24.04 ) ||
     $OS_ID == debian && $OS_VERSION == 12 ]]
}
```

Implement `vm_verify_dns` so it:

1. resolves A/AAAA with `getent ahosts`;
2. discovers GCE external IP from the metadata server when available;
3. otherwise uses `https://api.ipify.org` with a 5-second timeout;
4. compares normalized addresses;
5. prints both values on mismatch without exposing secrets.

Implement `vm_check_public_ports` with `ss -H -ltnp`; report owning processes
for `:80` and `:443` and return failure without killing them.

- [ ] **Step 4: Implement official Docker apt installation**

Create `vminstall/lib/docker.sh`. The command sequence must:

```text
apt-get update
apt-get install -y ca-certificates curl gnupg openssl tar gzip coreutils
install -m 0755 -d /etc/apt/keyrings
download https://download.docker.com/linux/OS/gpg
gpg --dearmor into /etc/apt/keyrings/docker.gpg
write /etc/apt/sources.list.d/docker.list with signed-by
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker compose version
```

Use `install` and `mv` from temporary files; never overwrite the key or apt
source with partial downloads. In `REMOTE_CHROME_DRY_RUN=1`, emit commands
into `COMMAND_LOG` and write only beneath `REMOTE_CHROME_TEST_ROOT`.

- [ ] **Step 5: Implement verified release staging**

Create `vminstall/lib/release.sh` with:

```bash
vm_release_dir() {
  printf '%s/releases/%s' "$REMOTE_CHROME_INSTALL_ROOT" "$SELECTED_VERSION"
}

vm_stage_release() {
  local archive=$1
  local staging="$REMOTE_CHROME_INSTALL_ROOT/releases/.staging-${SELECTED_VERSION}-$$"
  install -d -m 0755 "$staging"
  tar --extract --gzip --file "$archive" --directory "$staging" \
    --strip-components=1 --no-same-owner --no-same-permissions
  [[ -f "$staging/compose.yaml" && -f "$staging/vminstall/compose.vm.yaml" ]]
}
```

Before extracting pinned releases, require:

```bash
sha256sum -c "remotechromemcp-${SELECTED_VERSION}.tar.gz.sha256"
```

Reject archives containing absolute paths, `..` components, device files, or
links escaping the extraction root. `master` archives are marked unpinned in
both logs and `/etc/remote-chrome/install.env`.

- [ ] **Step 6: Wire preflight order into installer main**

`vm_installer_main` must execute:

```text
parse arguments
collect missing interactive values
validate domain/email/data path
load/validate platform
require root and host resources
verify DNS
check ports
install/verify Docker
stage/verify release
```

It must not yet activate Compose; Task 4 adds activation.

- [ ] **Step 7: Verify and commit host/release handling**

Run:

```bash
chmod +x tests/vminstall-distributions.test.sh
bash tests/vminstall-distributions.test.sh
bash tests/vminstall-contract.test.sh
./tests/run.sh
```

Expected: PASS with no host mutations.

Commit:

```bash
git add vminstall/lib vminstall/installer-main.sh tests \
  tests/run.sh
git commit -m "feat: add VM host and release preflight"
```

---

### Task 4: Configuration, Credentials, Activation, and Connection Handoff

**Files:**
- Create: `vminstall/lib/config.sh`
- Create: `vminstall/lib/activate.sh`
- Create: `vminstall/remote-chrome.service.in`
- Create: `tests/vminstall-management.test.sh`
- Modify: `vminstall/installer-main.sh`
- Modify: `tests/vminstall-contract.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces files `/etc/remote-chrome/install.env`, `compose.env`, and `credentials.env`, all root-owned mode 600.
- Produces directories `${REMOTE_CHROME_DATA_DIR}/{profile,caddy-data,caddy-config,backups,restore-staging}`.
- Produces `vm_prepare_config`, `vm_generate_credentials`, `vm_render_compose_env`, `vm_activate_release`, `vm_rollback_release`, `vm_verify_public_stack`, `vm_print_connection_handoff`.
- Installs `remote-chrome.service` and `/opt/remotechromemcp/current`.

- [ ] **Step 1: Add failing credential/activation contracts**

Extend `tests/vminstall-management.test.sh` with temp-root tests that assert:

- first install generates a 64-lowercase-hex MCP token;
- login password is generated independently from at least 36 random bytes;
- Caddy bcrypt hash is obtained without exposing plaintext in command logs;
- all three config files are mode 600;
- reinstall preserves token, username, password, domain backup settings, and
  Caddy directories;
- `--rotate-credentials` changes both auth domains deliberately;
- data/profile paths remain beneath the canonical configured data root;
- `current` is switched only after Compose config and health succeed;
- activation failure restores prior symlink/environment and calls health on
  the prior version;
- only host 80/443 appear in rendered Compose;
- connection output includes MCP URL, bearer token, compatibility endpoint,
  login URL, login username/password, certificate status, and management
  commands.

Use fake `docker`, `systemctl`, `curl`, and `openssl` binaries. Generate token
fixtures at runtime rather than storing 64-hex secrets in test source.

- [ ] **Step 2: Verify activation contracts fail**

Run:

```bash
bash tests/vminstall-management.test.sh
```

Expected: FAIL because configuration and activation functions are undefined.

- [ ] **Step 3: Implement protected configuration**

Create `vminstall/lib/config.sh` with safe file writer:

```bash
vm_write_secret_file() {
  local destination=$1
  local temporary="${destination}.tmp.$$"
  umask 077
  install -d -m 0700 "$(dirname "$destination")"
  : >"$temporary"
  chmod 0600 "$temporary"
  cat >"$temporary"
  chown root:root "$temporary"
  mv -fT "$temporary" "$destination"
}
```

`credentials.env` contains:

```dotenv
MCP_URL=https://chrome.example.com/mcp
MCP_TOKEN=generated-at-install
MCP_COMPATIBILITY_URL=https://chrome.example.com/generated-at-install/mcp
LOGIN_URL=https://chrome.example.com/login/
LOGIN_USERNAME=remotechrome
LOGIN_PASSWORD=generated-at-install
```

Tests substitute synthetic values; tracked files never contain real
credentials.

`compose.env` contains domain, ACME email, MCP token, login username, quoted
bcrypt hash, MCP version 0.0.78, geometry, and data directory. Preserve the
single-quoted bcrypt value so Compose does not interpolate `$`.

- [ ] **Step 4: Implement staging and systemd service rendering**

Create `vminstall/remote-chrome.service.in`:

```ini
[Unit]
Description=Remote Chrome MCP Docker Compose
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/remotechromemcp/current
EnvironmentFile=/etc/remote-chrome/install.env
ExecStart=/usr/bin/docker compose -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env up -d
ExecStartPost=/usr/local/sbin/remote-chrome wait-ready
ExecStop=/usr/bin/docker compose -f compose.yaml -f vminstall/compose.vm.yaml --env-file /etc/remote-chrome/compose.env down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

Render only fixed absolute paths; reject newline-containing configuration.

- [ ] **Step 5: Implement health-gated activation and rollback**

Create `vminstall/lib/activate.sh`. Required order:

```text
record previous current symlink
install staged release into releases/REF
write candidate config to .candidate files
run docker compose config using candidate config
switch current symlink atomically
install candidate config atomically
daemon-reload and enable/start service
poll browser+proxy container health
POST bearer initialize through public HTTPS
close MCP session with DELETE
verify one Content-Type, GET 405, noVNC Basic auth, WebSocket 101
record active version only after all checks
```

On any failure after symlink/config switch:

```text
stop candidate Compose project
restore prior current symlink
restore prior config files
daemon-reload
start prior service
verify prior health
return nonzero and preserve redacted candidate logs
```

Do not report success when rollback health fails; return a distinct exit 70.

- [ ] **Step 6: Implement connection handoff**

`vm_print_connection_handoff` prints:

```text
Remote Chrome is ready.
Preferred MCP URL: https://chrome.example.com/mcp
Authorization: Bearer [generated token]
Compatibility MCP URL: https://chrome.example.com/[generated token]/mcp
Login URL: https://chrome.example.com/login/
Login username: remotechrome
Login password: [generated password]
Credentials file: /etc/remote-chrome/credentials.env
Profile: /var/lib/remote-chrome/profile
Status: sudo remote-chrome status
Credentials: sudo remote-chrome credentials
Backup: sudo remote-chrome backup
Restore: sudo remote-chrome restore
```

Also print JSON and TOML client snippets using the actual installed domain and
token. Ensure no handoff is written to journal/syslog; write directly to the
installer's controlling terminal and the root-only credentials file.

- [ ] **Step 7: Verify and commit activation**

Run:

```bash
chmod +x tests/vminstall-management.test.sh
bash tests/vminstall-management.test.sh
./tests/run.sh
```

Expected: PASS.

Commit:

```bash
git add vminstall tests/vminstall-management.test.sh tests/run.sh
git commit -m "feat: activate VM installs with connection handoff"
```

---

### Task 5: Installed Management CLI, Updates, Status, and Uninstall

**Files:**
- Create: `vminstall/remote-chrome`
- Create: `vminstall/lib/management.sh`
- Modify: `vminstall/installer-main.sh`
- Modify: `tests/vminstall-management.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces installed command `/usr/local/sbin/remote-chrome`.
- Produces subcommands: `status`, `credentials`, `login`, `wait-ready`, `update --version REF`, `backup`, `restore`, and `uninstall`.
- Consumes root-only state from `/etc/remote-chrome` and release functions from `/opt/remotechromemcp/current/vminstall/lib`.

- [ ] **Step 1: Add failing CLI dispatch and safety tests**

Extend `tests/vminstall-management.test.sh` to invoke
`vminstall/remote-chrome` with `REMOTE_CHROME_TEST_ROOT` and assert:

```text
no arguments -> usage, exit 2
unknown command -> usage, exit 2
status -> redacted service/container/TLS/MCP/profile report
credentials as non-root -> exit 77
credentials as root -> exact installed connection fields
login -> URL and username, never password
wait-ready -> requires browser, proxy, public MCP, login HTTP, and WebSocket
update without --version -> exit 2
update v1.0.1 -> verified staged activation and rollback contract
uninstall default -> releases/service removed; config/data/backups preserved
uninstall --delete-profile -> exact managed profile only
uninstall --delete-all-data -> explicit confirmation plus canonical target
```

Tests must reject `/`, parent directories, symlink escapes, and arbitrary
absolute profile overrides.

- [ ] **Step 2: Verify CLI tests fail**

Run:

```bash
bash tests/vminstall-management.test.sh
```

Expected: FAIL because `vminstall/remote-chrome` does not exist.

- [ ] **Step 3: Implement root-aware dispatch**

Create `vminstall/remote-chrome`:

```bash
#!/usr/bin/env bash
set -euo pipefail

install_root=${REMOTE_CHROME_INSTALL_ROOT:-/opt/remotechromemcp}
state_root=${REMOTE_CHROME_CONFIG_ROOT:-/etc/remote-chrome}
source "$install_root/current/vminstall/lib/common.sh"
source "$install_root/current/vminstall/lib/management.sh"

command=${1:-}
[[ -n $command ]] || {
  vm_management_usage >&2
  exit 2
}
shift
vm_management_dispatch "$command" "$@"
```

`vm_management_dispatch` uses an explicit `case`; never construct function
names from user input.

- [ ] **Step 4: Implement status, credentials, login, and readiness**

`status` reports:

- active release and prior release;
- systemd service state;
- browser/proxy container health;
- Chrome version and absence of `HeadlessChrome`;
- MCP initialize/playbook marker;
- public 401/405 and one Content-Type;
- login Basic-auth HTTP and WebSocket status;
- TLS issuer and expiration;
- profile/data disk usage;
- last backup manifest.

`credentials` requires effective UID 0 and reads only the fixed credentials
path. `login` prints URL and username only. `wait-ready` reuses the same
health functions and never prints secrets.

- [ ] **Step 5: Implement update and uninstall**

`update --version v1.0.1` calls the release staging and activation interfaces
from Tasks 3-4. Reject `master` unless `--allow-unpinned` is present.

`uninstall`:

```text
stop/disable remote-chrome.service
remove service file and daemon-reload
remove /usr/local/sbin/remote-chrome
remove /opt/remotechromemcp releases
preserve /etc/remote-chrome and /var/lib/remote-chrome by default
```

`--delete-profile`, `--delete-backups`, and `--delete-all-data` each require
canonical equality with the configured managed paths. `--delete-all-data`
requires typing the installed domain on `/dev/tty` unless `--force` is
explicitly provided.

- [ ] **Step 6: Install CLI from installer and verify**

`installer-main.sh` installs the CLI with:

```bash
install -o root -g root -m 0755 \
  "$candidate_release/vminstall/remote-chrome" \
  /usr/local/sbin/remote-chrome
```

Run:

```bash
bash tests/vminstall-management.test.sh
./tests/run.sh
```

Expected: PASS.

- [ ] **Step 7: Commit management lifecycle**

```bash
git add vminstall tests/vminstall-management.test.sh tests/run.sh
git commit -m "feat: add installed remote Chrome management CLI"
```

---

### Task 6: Quiesced GCS Backup and Transactional Restore

**Files:**
- Create: `vminstall/lib/backup.sh`
- Create: `vminstall/remote-chrome-backup.service.in`
- Create: `vminstall/remote-chrome-backup.timer.in`
- Create: `tests/vminstall-backup.test.sh`
- Modify: `vminstall/lib/management.sh`
- Modify: `vminstall/installer-main.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces: `vm_backup_profile GCS_PREFIX`, `vm_restore_profile GCS_MANIFEST`, `vm_validate_backup_archive`, `vm_with_maintenance_lock`.
- Consumes: `GCS_BUCKET`, optional `BACKUP_SCHEDULE`, `/usr/bin/gcloud`, and fixed profile/backup/restore-staging paths.
- Produces three GCS objects per backup: `.tar.gz`, `.sha256`, and `.manifest`.

- [ ] **Step 1: Add failing backup/restore behavior tests**

Create `tests/vminstall-backup.test.sh` using temp roots and fake
`remote-chrome`, `tar`, `sha256sum`, and `gcloud`. Add named tests:

```text
backup_stops_browser_before_tar
backup_uploads_archive_checksum_manifest
backup_upload_failure_restarts_stack
backup_health_failure_returns_nonzero
backup_lock_rejects_concurrency
restore_rejects_checksum_mismatch
restore_rejects_absolute_path
restore_rejects_traversal
restore_rejects_escaping_symlink
restore_preserves_current_profile
restore_health_failure_rolls_back
restore_success_removes_staging_only
```

The fake command log must prove ordering:

```text
lock -> pre-health -> stop -> tar -> checksum -> upload -> start -> health
```

and restore ordering:

```text
lock -> download -> validate -> stop -> preserve -> extract -> chown -> start -> health
```

- [ ] **Step 2: Verify backup tests fail**

Run:

```bash
bash tests/vminstall-backup.test.sh
```

Expected: FAIL because `vminstall/lib/backup.sh` does not exist.

- [ ] **Step 3: Implement maintenance lock and backup**

Create `vminstall/lib/backup.sh`:

```bash
vm_with_maintenance_lock() {
  local lock_file="$REMOTE_CHROME_DATA_DIR/.maintenance.lock"
  exec 9>"$lock_file"
  flock -n 9 || vm_die 75 'Another backup, restore, update, or uninstall is active'
  "$@"
}
```

`vm_backup_profile` must:

1. require configured bucket and `gcloud storage`;
2. verify stack health;
3. run `docker compose -f compose.yaml -f vminstall/compose.vm.yaml
   --env-file /etc/remote-chrome/compose.env stop -t 30 browser` and confirm
   the browser container is stopped;
4. create the archive in `/var/lib/remote-chrome/backups/.staging`;
5. use `tar --numeric-owner --one-file-system`;
6. write SHA-256 and a manifest containing version, UTC timestamp, Chrome
   version, archive name, checksum name, and source profile path;
7. upload to unique UTC timestamp plus random-suffix object names;
8. restart in an EXIT trap;
9. require post-restart health;
10. leave local archive only when `KEEP_LOCAL_BACKUPS=1`.

Never include MCP/login credentials or Compose environment files.

- [ ] **Step 4: Implement archive validation and restore**

Before extraction, list the archive and reject:

```text
absolute paths
.. path components
character/block devices
FIFOs or sockets
hard links
symbolic links
entries outside profile/
```

Extract into a new staging directory with `--no-same-owner` and
`--no-same-permissions`. Move the current profile atomically to
`profile.rollback-UTC-PID`, move validated staging into `profile`, fix
ownership, start, and health-check. On failure, stop, restore rollback,
restart, verify, and return nonzero.

- [ ] **Step 5: Add optional systemd backup timer**

Create service:

```ini
[Unit]
Description=Remote Chrome GCS Profile Backup
After=remote-chrome.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remote-chrome backup
```

Create timer template:

```ini
[Unit]
Description=Schedule Remote Chrome GCS Profile Backup

[Timer]
OnCalendar=@BACKUP_SCHEDULE@
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
```

Render and enable the timer only when the user supplied and confirmed a
schedule.

- [ ] **Step 6: Verify and commit backup/restore**

Run:

```bash
chmod +x tests/vminstall-backup.test.sh
bash tests/vminstall-backup.test.sh
bash tests/vminstall-management.test.sh
./tests/run.sh
```

Expected: PASS.

Commit:

```bash
git add vminstall tests/vminstall-backup.test.sh tests/run.sh
git commit -m "feat: add quiesced GCS profile backup and restore"
```

---

### Task 7: GCE Manual Guide, Release Packaging, Skill Guidance, and CI Contracts

**Files:**
- Create: `docs/gce-manual.md`
- Create: `docs/vm-install.md`
- Create: `scripts/package-release.sh`
- Create: `tests/vminstall-gce-docs.test.sh`
- Modify: `skills/remote-chrome-mcp/SKILL.md`
- Modify: `tests/playbook-contract.test.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces release assets `dist/remotechromemcp-v1.0.0.tar.gz` and matching `.sha256`.
- Produces copy-paste manual GCE commands with no production project/domain.
- Produces installation guidance in the existing portable skill.
- Produces CI-ready commands consumed by the original plan's Task 6.

- [ ] **Step 1: Add failing documentation/release contracts**

Create `tests/vminstall-gce-docs.test.sh` requiring these literal sections in
`docs/gce-manual.md`:

```text
Prerequisites
Reserve a Static IP
Create the Service Account
Create the Backup Bucket
Create and Attach the Persistent Disk
Create the VM
Open Ports 80 and 443
Prepare the Data Disk
Run the Interactive Installer
Verify HTTPS and MCP
Configure GCS Backup
Reboot and Restore Test
```

Require the exact quick-install command and a pinned `v1.0.0` command in
`docs/vm-install.md`.

Require the skill to contain:

```text
ask for the domain
certificate email
DNS
data directory
GCS
/dev/tty
remote-chrome credentials
never format
```

Reject `eladrave.com` deployment hostnames, 64-hex bearer candidates, and
literal passwords in documentation/skill content. The GitHub repository URL
is allowed only when its host is `github.com` or
`raw.githubusercontent.com`.

- [ ] **Step 2: Verify documentation contracts fail**

Run:

```bash
bash tests/vminstall-gce-docs.test.sh
```

Expected: FAIL because the GCE and VM installation guides do not exist.

- [ ] **Step 3: Write the manual GCE guide**

Use concrete examples:

```bash
export GCP_PROJECT=remote-chrome-example
export GCP_REGION=us-central1
export GCP_ZONE=us-central1-a
export VM_NAME=remote-chrome
export DISK_NAME=remote-chrome-data
export BUCKET_NAME=remote-chrome-example-backups
```

Commands must:

- enable `compute.googleapis.com` and `storage.googleapis.com`;
- create a service account;
- create a bucket with uniform bucket-level access and public access
  prevention;
- grant the VM identity `roles/storage.objectUser` on the selected bucket for
  upload, list, download, and restore;
- reserve a regional static address;
- create a balanced 50 GiB Persistent Disk;
- create an Ubuntu 24.04 x86_64 VM with at least 2 vCPU and 8 GiB RAM;
- attach the disk and a dedicated `remote-chrome-server` network tag;
- create firewall rules for TCP 80 and 443 only;
- SSH to the VM.

Disk preparation must resolve:

```text
/dev/disk/by-id/google-remote-chrome-data
```

Run `blkid` first. Format ext4 only after the user confirms the exact empty
disk; mount by UUID at `/var/lib/remote-chrome`. Include rollback commands for
an incorrect `/etc/fstab` entry.

- [ ] **Step 4: Write the generic VM guide**

`docs/vm-install.md` must document:

- supported OS/architecture;
- DNS and 80/443 prerequisites;
- interactive quick install;
- pinned production install;
- noninteractive flags;
- installer questions;
- exact connection handoff;
- management commands;
- existing-proxy conflict behavior;
- update and rollback;
- backup/restore;
- uninstall preservation.

State that the generic installer never formats disks or silently changes
firewalls.

- [ ] **Step 5: Extend the portable skill**

Before editing, read and follow both `skill-creator/SKILL.md` and
`superpowers:writing-skills/SKILL.md`.

Add an `Installation on a Remote VM` section that makes an agent:

1. ask domain, email, DNS, data directory, and GCS preference;
2. recommend Docker Compose for a new SSH-only VM;
3. use the interactive raw GitHub command only when the user chose the guided
   latest install;
4. use pinned `--version` for production automation;
5. never guess or format disks;
6. never expose internal ports or replace an existing proxy;
7. hand back all protected connection details and management commands.

Pressure-test prompts:

```text
Install this on my Ubuntu VM; I have not chosen a domain.
Use /dev/sdb for the profile; I do not know whether it contains data.
Port 443 already has nginx listening.
Install noninteractively but no certificate email was provided.
The install succeeded; where do I retrieve the MCP token next week?
```

Expected: ask for missing domain/email, refuse to format unknown disk, stop on
proxy conflict, fail incomplete noninteractive setup, and use
`sudo remote-chrome credentials`.

- [ ] **Step 6: Implement release packaging**

Create `scripts/package-release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_dir/dist"
archive="$dist_dir/remotechromemcp-${version}.tar.gz"
mkdir -p "$dist_dir"
[[ -z $(git -C "$repo_dir" status --porcelain=v1) ]] || {
  printf 'Working tree must be clean before packaging\n' >&2
  exit 1
}
git -C "$repo_dir" archive --format=tar.gz --prefix="remotechromemcp-${version}/" \
  --output="$archive" HEAD
(cd "$dist_dir" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")
printf '%s\n' "$archive" "$archive.sha256"
```

Add `dist/` to `.gitignore`. Test reproducible filenames, dirty-tree refusal,
and valid SHA-256 verification.

- [ ] **Step 7: Add CI-ready distribution test command**

`tests/vminstall-distributions.test.sh` must support:

```bash
CI=1 VM_INSTALL_TEST_IMAGE=ubuntu:22.04 bash tests/vminstall-distributions.test.sh
CI=1 VM_INSTALL_TEST_IMAGE=ubuntu:24.04 bash tests/vminstall-distributions.test.sh
CI=1 VM_INSTALL_TEST_IMAGE=debian:12 bash tests/vminstall-distributions.test.sh
```

When Docker is unavailable locally, run fixture tests and print a SKIP. In
`CI=1`, Docker absence or a distribution-container skip is a failure.

Add the distribution and GCE documentation contracts to `tests/run.sh`.
The original plan's Task 6 must invoke all three CI image commands plus:

```bash
shellcheck setup.sh login.sh status.sh uninstall.sh scripts/*.sh \
  docker/*.sh lib/*.sh vminstall/*.sh vminstall/lib/*.sh tests/*.sh
CI=1 bash tests/compose-smoke.test.sh
```

- [ ] **Step 8: Verify this plan's complete deliverable**

Run:

```bash
./tests/run.sh
bash tests/vminstall-bootstrap.test.sh
bash tests/vminstall-contract.test.sh
bash tests/vminstall-distributions.test.sh
bash tests/vminstall-management.test.sh
bash tests/vminstall-backup.test.sh
bash tests/vminstall-gce-docs.test.sh
git diff --check
```

If ShellCheck is installed:

```bash
shellcheck setup.sh login.sh status.sh uninstall.sh scripts/*.sh \
  docker/*.sh lib/*.sh vminstall/*.sh vminstall/lib/*.sh tests/*.sh
```

Expected: all non-Docker tests PASS; Docker-only checks may SKIP locally but
must fail on skip in CI.

- [ ] **Step 9: Commit docs, skill, packaging, and CI contracts**

```bash
git add docs/gce-manual.md docs/vm-install.md \
  skills/remote-chrome-mcp/SKILL.md scripts/package-release.sh \
  tests/vminstall-gce-docs.test.sh tests/vminstall-distributions.test.sh \
  tests/playbook-contract.test.sh tests/run.sh .gitignore
git commit -m "docs: add guided VM and GCE installation"
```

---

## Completion and Return to the Parent Plan

After all seven tasks pass independent reviews:

1. run a whole-plan review from the commit before Task 1 through current HEAD;
2. carry any Docker-only runtime gaps into the original plan's Task 6 CI;
3. resume `2026-07-26-remote-chrome-guidance-login-deployments.md` at Task 6;
4. do not publish the installer command as production-ready until GitHub CI
   passes, a release asset exists, and the user authorizes push/release.
