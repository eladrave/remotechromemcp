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
command -v setsid >/dev/null 2>&1 ||
  fail 'setsid is required to test the Linux no-controlling-TTY contract'
setsid --help 2>&1 | grep -Fq -- '--wait' ||
  fail 'setsid --wait support is required for the no-controlling-TTY contract'

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
ln -s /etc "$test_root/protected-root-link"
for unsafe_data_dir in \
  relative \
  / \
  // \
  /tmp/.. \
  /var/.. \
  /home \
  /home/ \
  /root \
  /root/ \
  /etc \
  /etc/ \
  /var \
  /var/ \
  /var/lib/../.. \
  /safe/../../etc \
  "$test_root/../../etc" \
  "$test_root/protected-root-link"; do
  ! vm_validate_data_dir "$unsafe_data_dir" ||
    fail "unsafe data directory must be rejected: $unsafe_data_dir"
done
newline_data_dir="$(printf '/tmp/first\n/tmp/second')"
! vm_validate_data_dir "$newline_data_dir" ||
  fail 'data directory must reject newlines'

mkdir "$test_root/canonical-data"
ln -s "$test_root/canonical-data" "$test_root/data-link"
vm_parse_args \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data-link/profile" \
  --non-interactive
vm_collect_configuration
[[ "$REMOTE_CHROME_DATA_DIR" == "$test_root/canonical-data/profile" ]] ||
  fail 'validated data directory must be stored as its canonical path'

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

os_release_injection="$test_root/os-release-injection"
malicious_os_release="$test_root/os-release-malicious"
{
  printf '%s\n' \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    "NAME=\$(touch $os_release_injection)"
} >"$malicious_os_release"
REMOTE_CHROME_OS_RELEASE="$malicious_os_release" \
  REMOTE_CHROME_TEST_ARCH=x86_64 \
  vm_load_platform
vm_validate_platform ||
  fail 'platform parser must accept supported ID and VERSION_ID assignments'
[[ ! -e $os_release_injection ]] ||
  fail 'platform parser must never execute os-release content'

REMOTE_CHROME_TEST_ROOT="$test_root" vm_init_paths
[[ "$REMOTE_CHROME_INSTALL_ROOT" == "$test_root/opt/remotechromemcp" ]] ||
  fail 'install root must be confined beneath the test root'
[[ "$REMOTE_CHROME_CONFIG_ROOT" == "$test_root/etc/remote-chrome" ]] ||
  fail 'config root must be confined beneath the test root'
[[ "$REMOTE_CHROME_SYSTEMD_ROOT" == "$test_root/etc/systemd/system" ]] ||
  fail 'systemd root must be confined beneath the test root'
[[ "$REMOTE_CHROME_CLI_ROOT" == "$test_root/usr/local/sbin" ]] ||
  fail 'CLI root must be confined beneath the test root'

REMOTE_CHROME_INSTALL_ROOT=/etc/remote-chrome-test-contamination
REMOTE_CHROME_CONFIG_ROOT=/var/remote-chrome-test-contamination
REMOTE_CHROME_SYSTEMD_ROOT=/usr/lib/systemd/system
REMOTE_CHROME_CLI_ROOT=/usr/local/sbin
REMOTE_CHROME_TEST_ROOT="$test_root"
vm_init_paths
[[ "$REMOTE_CHROME_INSTALL_ROOT" == "$test_root/opt/remotechromemcp" ]] ||
  fail 'test mode must ignore a contaminated inherited install root'
[[ "$REMOTE_CHROME_CONFIG_ROOT" == "$test_root/etc/remote-chrome" ]] ||
  fail 'test mode must ignore a contaminated inherited config root'
[[ "$REMOTE_CHROME_SYSTEMD_ROOT" == "$test_root/etc/systemd/system" ]] ||
  fail 'test mode must ignore a contaminated inherited systemd root'
[[ "$REMOTE_CHROME_CLI_ROOT" == "$test_root/usr/local/sbin" ]] ||
  fail 'test mode must ignore a contaminated inherited CLI root'

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
setsid --wait \
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

declare -F vm_stage_release >/dev/null ||
  fail 'vm_stage_release is undefined'
declare -F vm_verify_release >/dev/null ||
  fail 'vm_verify_release is undefined'
for management_function in \
  vm_prepare_config vm_generate_credentials vm_render_compose_env \
  vm_activate_release vm_rollback_release vm_verify_public_stack \
  vm_print_connection_handoff; do
  declare -F "$management_function" >/dev/null ||
    fail "$management_function is undefined"
done

release_fixture="$test_root/release-fixtures"
mkdir "$release_fixture"
export RELEASE_FIXTURE="$release_fixture"
export ARCHIVE_ABSOLUTE_ESCAPE="$test_root/absolute-archive-escape"
python3 <<'PY'
import io
import os
import tarfile

root = os.environ["RELEASE_FIXTURE"]

def add_file(archive, name, content=b"fixture\n"):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = 0o644
    archive.addfile(info, io.BytesIO(content))

def base_archive(path):
    archive = tarfile.open(path, "w:gz")
    add_file(archive, "remotechromemcp-v1.2.3/compose.yaml")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/compose.vm.yaml")
    return archive

with base_archive(os.path.join(root, "remotechromemcp-v1.2.3.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-v1.2.3/README.md")

with base_archive(os.path.join(root, "absolute.tar.gz")) as archive:
    add_file(archive, os.environ["ARCHIVE_ABSOLUTE_ESCAPE"])

with base_archive(os.path.join(root, "traversal.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-v1.2.3/../../archive-escape")

with base_archive(os.path.join(root, "symlink.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-v1.2.3/vminstall/escape-link")
    info.type = tarfile.SYMTYPE
    info.linkname = "../../../archive-escape -> harmless"
    archive.addfile(info)

with base_archive(os.path.join(root, "hardlink.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-v1.2.3/vminstall/escape-hardlink")
    info.type = tarfile.LNKTYPE
    info.linkname = "../../archive-escape link to harmless"
    archive.addfile(info)

with base_archive(os.path.join(root, "device.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-v1.2.3/vminstall/device")
    info.type = tarfile.CHRTYPE
    info.devmajor = 1
    info.devminor = 3
    archive.addfile(info)

with base_archive(os.path.join(root, "fifo.tar.gz")) as archive:
    info = tarfile.TarInfo("remotechromemcp-v1.2.3/vminstall/fifo")
    info.type = tarfile.FIFOTYPE
    archive.addfile(info)

with base_archive(os.path.join(root, "newline.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-v1.2.3/newline\nmember")

with base_archive(os.path.join(root, "control.tar.gz")) as archive:
    add_file(archive, "remotechromemcp-v1.2.3/control-\x01-member")

with tarfile.open(os.path.join(root, "remotechromemcp-master.tar.gz"), "w:gz") as archive:
    add_file(archive, "remotechromemcp-master/compose.yaml")
    add_file(archive, "remotechromemcp-master/vminstall/compose.vm.yaml")
PY

(
  cd "$release_fixture"
  sha256sum remotechromemcp-v1.2.3.tar.gz \
    >remotechromemcp-v1.2.3.tar.gz.sha256
)
for hostile_archive in \
  absolute traversal symlink hardlink device fifo newline control; do
  mkdir "$release_fixture/$hostile_archive"
  cp "$release_fixture/$hostile_archive.tar.gz" \
    "$release_fixture/$hostile_archive/remotechromemcp-v1.2.3.tar.gz"
  (
    cd "$release_fixture/$hostile_archive"
    sha256sum remotechromemcp-v1.2.3.tar.gz \
      >remotechromemcp-v1.2.3.tar.gz.sha256
  )
done

REMOTE_CHROME_TEST_ROOT="$test_root" vm_init_paths
SELECTED_VERSION=v1.2.3
vm_stage_release "$release_fixture/remotechromemcp-v1.2.3.tar.gz"
expected_staging="$REMOTE_CHROME_INSTALL_ROOT/releases/.staging-v1.2.3-$$"
[[ "$STAGED_RELEASE_DIR" == "$expected_staging" && -d "$expected_staging" ]] ||
  fail 'verified release must be extracted to the PID-scoped staging directory'
vm_verify_release "$STAGED_RELEASE_DIR" ||
  fail 'staged release must contain both Compose manifests'
[[ ! -e "$(vm_release_dir)" ]] ||
  fail 'release staging must not create or replace the final release directory'

for hostile_archive in \
  absolute traversal symlink hardlink device fifo newline control; do
  rm -rf -- "$expected_staging"
  set +e
  (
    SELECTED_VERSION=v1.2.3
    vm_stage_release \
      "$release_fixture/$hostile_archive/remotechromemcp-v1.2.3.tar.gz"
  ) >"$test_root/$hostile_archive.stdout" \
    2>"$test_root/$hostile_archive.stderr"
  hostile_status=$?
  set -e
  [[ $hostile_status -ne 0 ]] ||
    fail "$hostile_archive archive must be rejected"
  [[ ! -e "$test_root/archive-escape" &&
     ! -e "$ARCHIVE_ABSOLUTE_ESCAPE" ]] ||
    fail "$hostile_archive archive must not escape extraction"
  [[ ! -d "$expected_staging" ]] ||
    fail "$hostile_archive archive must be rejected before extraction"
done

checksum_file="$release_fixture/remotechromemcp-v1.2.3.tar.gz.sha256"
cp "$checksum_file" "$checksum_file.valid"
printf '%064d  remotechromemcp-v1.2.3.tar.gz\n' 0 >"$checksum_file"
rm -rf -- "$expected_staging"
set +e
(
  SELECTED_VERSION=v1.2.3
  vm_stage_release "$release_fixture/remotechromemcp-v1.2.3.tar.gz"
) >"$test_root/checksum.stdout" 2>"$test_root/checksum.stderr"
checksum_status=$?
set -e
[[ $checksum_status -ne 0 ]] ||
  fail 'pinned release with an invalid checksum must fail'
[[ ! -d "$expected_staging" ]] ||
  fail 'checksum must be verified before creating the extraction staging directory'
mv "$checksum_file.valid" "$checksum_file"

alternate_file="$release_fixture/not-the-release.tar.gz"
printf 'alternate\n' >"$alternate_file"
alternate_hash="$(sha256sum "$alternate_file" | awk '{print $1}')"
valid_hash="$(sha256sum "$release_fixture/remotechromemcp-v1.2.3.tar.gz" |
  awk '{print $1}')"
for manifest_case in alternate extra malformed; do
  case "$manifest_case" in
    alternate)
      printf '%s  %s\n' "$alternate_hash" "${alternate_file##*/}" \
        >"$checksum_file"
      ;;
    extra)
      {
        printf '%s  %s\n' \
          "$valid_hash" remotechromemcp-v1.2.3.tar.gz
        printf '%s  %s\n' "$alternate_hash" "${alternate_file##*/}"
      } >"$checksum_file"
      ;;
    malformed)
      printf '%s  %s\n' not-a-sha256 remotechromemcp-v1.2.3.tar.gz \
        >"$checksum_file"
      ;;
  esac
  rm -rf -- "$expected_staging"
  set +e
  (
    SELECTED_VERSION=v1.2.3
    vm_stage_release "$release_fixture/remotechromemcp-v1.2.3.tar.gz"
  ) >"$test_root/manifest-$manifest_case.stdout" \
    2>"$test_root/manifest-$manifest_case.stderr"
  manifest_status=$?
  set -e
  [[ $manifest_status -ne 0 ]] ||
    fail "pinned release must reject a $manifest_case checksum manifest"
  [[ ! -d "$expected_staging" ]] ||
    fail "$manifest_case checksum manifest must fail before staging"
done
printf '%s  %s\n' "$valid_hash" remotechromemcp-v1.2.3.tar.gz \
  >"$checksum_file"

sentinel="$REMOTE_CHROME_INSTALL_ROOT/releases/keep-me"
mkdir -p "$sentinel"
: >"$sentinel/sentinel"
set +e
(
  SELECTED_VERSION=v1.2.3
  vm_stage_release \
    "$release_fixture/traversal/remotechromemcp-v1.2.3.tar.gz"
) >/dev/null 2>&1
cleanup_status=$?
set -e
[[ $cleanup_status -ne 0 && -f "$sentinel/sentinel" ]] ||
  fail 'failed staging cleanup must preserve unrelated release content'

release_symlink_root="$test_root/release-symlink-root"
release_symlink_escape="$test_root/release-symlink-escape"
mkdir "$release_symlink_root" "$release_symlink_escape"
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_ROOT="$release_symlink_root"
vm_init_paths
ln -s ../release-symlink-escape "$release_symlink_root/opt"
set +e
(
  SELECTED_VERSION=v1.2.3
  vm_stage_release "$release_fixture/remotechromemcp-v1.2.3.tar.gz"
) >"$test_root/release-symlink.stdout" \
  2>"$test_root/release-symlink.stderr"
release_symlink_status=$?
set -e
[[ $release_symlink_status -ne 0 ]] ||
  fail 'release staging must reject a descendant symlink escape'
[[ -z $(find "$release_symlink_escape" -mindepth 1 -print -quit) ]] ||
  fail 'release staging must not write through a descendant symlink escape'

config_symlink_root="$test_root/config-symlink-root"
config_symlink_escape="$test_root/config-symlink-escape"
mkdir "$config_symlink_root" "$config_symlink_escape"
REMOTE_CHROME_TEST_ROOT="$config_symlink_root"
vm_init_paths
ln -s ../config-symlink-escape "$config_symlink_root/etc"
set +e
(
  SELECTED_VERSION=master
  vm_stage_release "$release_fixture/remotechromemcp-master.tar.gz"
) >"$test_root/config-symlink.stdout" \
  2>"$test_root/config-symlink.stderr"
config_symlink_status=$?
set -e
[[ $config_symlink_status -ne 0 ]] ||
  fail 'unpinned release marking must reject a descendant symlink escape'
[[ ! -e "$config_symlink_escape/remote-chrome/install.env" ]] ||
  fail 'unpinned release marking must not escape the dry-run fixture root'

REMOTE_CHROME_DRY_RUN=0
REMOTE_CHROME_TEST_ROOT="$test_root"
vm_init_paths
SELECTED_VERSION=master
master_log="$test_root/master.log"
COMMAND_LOG="$master_log"
: >"$master_log"
vm_stage_release "$release_fixture/remotechromemcp-master.tar.gz"
grep -Fqi unpinned "$master_log" ||
  fail 'master staging must mark the release unpinned in logs'
grep -Fxq 'RELEASE_VERIFICATION=unpinned' \
  "$REMOTE_CHROME_CONFIG_ROOT/install.env" ||
  fail 'master staging must persist its unpinned status'

printf 'PASS: VM installer validation, platform, no-TTY, and release contracts\n'
