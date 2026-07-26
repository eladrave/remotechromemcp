#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_root="$(mktemp -d /tmp/remote-chrome-vminstall-contract.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
[[ -d "$test_root" && "$test_root" == /tmp/* ]] ||
  fail 'test root must be a real directory beneath /tmp'

REMOTE_CHROME_SKIP_MAIN=1
# shellcheck source=../vminstall/installer-main.sh
source vminstall/installer-main.sh

vm_validate_domain chrome.example.com ||
  fail 'valid domain must be accepted'
! vm_validate_domain https://chrome.example.com ||
  fail 'domain must reject URL schemes'
! vm_validate_domain chrome.example.com/path ||
  fail 'domain must reject URL paths'
vm_validate_email admin@example.com ||
  fail 'valid email must be accepted'
! vm_validate_email admin ||
  fail 'email must require a domain'

vm_validate_data_dir /var/lib/remote-chrome ||
  fail 'safe absolute data directory must be accepted'
for unsafe_data_dir in relative / /home /root /etc /var; do
  ! vm_validate_data_dir "$unsafe_data_dir" ||
    fail "unsafe data directory must be rejected: $unsafe_data_dir"
done
newline_data_dir="$(printf '/tmp/first\n/tmp/second')"
! vm_validate_data_dir "$newline_data_dir" ||
  fail 'data directory must reject newlines'

for fixture in tests/fixtures/os-release-*; do
  REMOTE_CHROME_OS_RELEASE="$fixture" \
    REMOTE_CHROME_TEST_ARCH=x86_64 \
    vm_load_platform
  vm_validate_platform ||
    fail "supported platform fixture must be accepted: $fixture"
done

REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-debian-12 \
  REMOTE_CHROME_TEST_ARCH=aarch64 \
  vm_load_platform
! vm_validate_platform ||
  fail 'unsupported aarch64 platform must be rejected'

REMOTE_CHROME_TEST_ROOT="$test_root" vm_init_paths
[[ "$REMOTE_CHROME_INSTALL_ROOT" == "$test_root/opt/remotechromemcp" ]] ||
  fail 'install root must be confined beneath the test root'
[[ "$REMOTE_CHROME_CONFIG_ROOT" == "$test_root/etc/remote-chrome" ]] ||
  fail 'config root must be confined beneath the test root'
[[ "$REMOTE_CHROME_SYSTEMD_ROOT" == "$test_root/etc/systemd/system" ]] ||
  fail 'systemd root must be confined beneath the test root'
[[ "$REMOTE_CHROME_CLI_ROOT" == "$test_root/usr/local/sbin" ]] ||
  fail 'CLI root must be confined beneath the test root'

set +e
(
  REMOTE_CHROME_TEST_EUID=1000
  vm_require_root
) >"$test_root/non-root.stdout" 2>"$test_root/non-root.stderr"
non_root_status=$?
set -e
[[ "$non_root_status" -eq 77 ]] ||
  fail "non-root execution must fail with status 77, got $non_root_status"
grep -Fq 'sudo sh' "$test_root/non-root.stderr" ||
  fail 'root requirement must provide an actionable sudo example'

set +e
(
  unset REMOTE_CHROME_TEST_ROOT
  REMOTE_CHROME_DRY_RUN=1
  vm_init_paths
) >"$test_root/unconfined.stdout" 2>"$test_root/unconfined.stderr"
unconfined_status=$?
set -e
[[ "$unconfined_status" -eq 64 ]] ||
  fail "unconfined dry-run must fail with status 64, got $unconfined_status"
grep -Fq 'Dry-run requires REMOTE_CHROME_TEST_ROOT' \
  "$test_root/unconfined.stderr" ||
  fail 'unconfined dry-run failure must explain the required test root'

mkdir "$test_root/real-root"
ln -s "$test_root/real-root" "$test_root/root-link"
set +e
(
  REMOTE_CHROME_TEST_ROOT="$test_root/root-link"
  vm_init_paths
) >"$test_root/symlink.stdout" 2>"$test_root/symlink.stderr"
symlink_status=$?
set -e
[[ "$symlink_status" -eq 64 ]] ||
  fail "symlink test root must fail with status 64, got $symlink_status"

parse_injection="$test_root/parse-injected"
literal_domain="chrome.example.com; \$(touch $parse_injection)"
vm_parse_args \
  --version v1.0.0 \
  --domain "$literal_domain" \
  --email 'ops+alerts@example.com' \
  --data-dir "$test_root/data dir" \
  --gcs-bucket 'bucket;not-a-command' \
  --backup-schedule '*-*-* 03:00:00' \
  --non-interactive \
  --skip-dns-check \
  --rotate-credentials
[[ "$SELECTED_VERSION" == v1.0.0 ]] ||
  fail 'version parser value was not preserved'
[[ "$DOMAIN" == "$literal_domain" && ! -e "$parse_injection" ]] ||
  fail 'argument parser must preserve domain metacharacters without evaluation'
[[ "$ACME_EMAIL" == 'ops+alerts@example.com' ]] ||
  fail 'email parser value was not preserved'
[[ "$REMOTE_CHROME_DATA_DIR" == "$test_root/data dir" ]] ||
  fail 'data directory parser value was not preserved'
[[ "$GCS_BUCKET" == 'bucket;not-a-command' ]] ||
  fail 'GCS bucket parser value was not preserved'
[[ "$BACKUP_SCHEDULE" == '*-*-* 03:00:00' ]] ||
  fail 'backup schedule parser value was not preserved'
[[ "$NON_INTERACTIVE" -eq 1 &&
   "$SKIP_DNS_CHECK" -eq 1 &&
   "$ROTATE_CREDENTIALS" -eq 1 ]] ||
  fail 'boolean installer flags were not preserved'

tty_fixture="$test_root/tty-input"
printf 'prompted.example.com\n' >"$tty_fixture"
prompted_value="$(REMOTE_CHROME_TTY="$tty_fixture" vm_prompt 'Domain: ')"
[[ "$prompted_value" == prompted.example.com ]] ||
  fail 'wizard prompt must read from the explicit TTY path'

missing_tty="$test_root/missing-tty"
set +e
printf 'stdin-must-not-be-used.example.com\n' |
  (
    REMOTE_CHROME_TTY="$missing_tty"
    vm_prompt 'Domain: '
  ) >"$test_root/prompt-no-tty.stdout" 2>"$test_root/prompt-no-tty.stderr"
prompt_no_tty_status=$?
set -e
[[ "$prompt_no_tty_status" -eq 2 ]] ||
  fail "prompt without TTY must fail with status 2, got $prompt_no_tty_status"
grep -Fq 'Interactive input unavailable' "$test_root/prompt-no-tty.stderr" ||
  fail 'prompt without TTY must explain noninteractive alternatives'
[[ ! -s "$test_root/prompt-no-tty.stdout" ]] ||
  fail 'prompt without TTY must not consume piped stdin'

set +e
env -u REMOTE_CHROME_TTY \
  REMOTE_CHROME_SKIP_MAIN=1 \
  bash -c \
    'source vminstall/installer-main.sh; vm_prompt "Domain: "' \
    </dev/null \
    >"$test_root/no-controlling-tty.stdout" \
    2>"$test_root/no-controlling-tty.stderr"
no_controlling_tty_status=$?
set -e
[[ "$no_controlling_tty_status" -eq 2 ]] ||
  fail "prompt without a controlling TTY must exit 2, got $no_controlling_tty_status"
grep -Fq 'Interactive input unavailable' \
  "$test_root/no-controlling-tty.stderr" ||
  fail 'missing controlling TTY must report the actionable noninteractive flags'

set +e
printf 'stdin-must-not-be-used.example.com\n' |
  env \
    REMOTE_CHROME_TEST_ROOT="$test_root" \
    REMOTE_CHROME_OS_RELEASE=tests/fixtures/os-release-ubuntu-24.04 \
    REMOTE_CHROME_TEST_ARCH=x86_64 \
    REMOTE_CHROME_TEST_EUID=0 \
    REMOTE_CHROME_TTY="$missing_tty" \
    bash vminstall/installer-main.sh --non-interactive \
      >"$test_root/no-tty.stdout" 2>"$test_root/no-tty.stderr"
no_tty_status=$?
set -e
[[ "$no_tty_status" -eq 2 ]] ||
  fail "incomplete noninteractive invocation must exit 2, got $no_tty_status"
for required_flag in --domain --email --data-dir; do
  grep -Fq -- "$required_flag" "$test_root/no-tty.stderr" ||
    fail "noninteractive failure must name missing $required_flag"
done
[[ ! -e "$missing_tty" ]] ||
  fail 'noninteractive mode must not create or read a fallback input path'

printf 'PASS: VM installer validation, platform, and no-TTY contracts\n'
