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

bucket_63=$(printf 'a%.0s' {1..63})
for valid_bucket in abc a-b.c "$bucket_63"; do
  vm_validate_gcs_bucket "$valid_bucket" ||
    fail "valid GCS bucket must be accepted: $valid_bucket"
done
bucket_64=$(printf 'a%.0s' {1..64})
for invalid_bucket in \
  ab \
  "$bucket_64" \
  bad_bucket \
  Badbucket \
  a..b \
  a.-b \
  a-.b \
  192.168.1.1 \
  .abc \
  abc. \
  -abc \
  abc-; do
  ! vm_validate_gcs_bucket "$invalid_bucket" ||
    fail "invalid GCS bucket must be rejected: $invalid_bucket"
done

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
[[ ${GCS_BUCKET_SET:-0} -eq 1 && ${BACKUP_SCHEDULE_SET:-0} -eq 1 ]] ||
  fail 'explicit GCS values must be distinguished from omitted rerun values'
[[ ${ENABLE_GCS_BACKUP:-0} -eq 1 ]] ||
  fail 'an explicit GCS bucket or schedule must enable backup'
[[ "$NON_INTERACTIVE" -eq 1 &&
   "$SKIP_DNS_CHECK" -eq 1 &&
   "$ROTATE_CREDENTIALS" -eq 1 ]] ||
  fail 'boolean installer flags were not preserved'

vm_parse_args \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --disable-gcs-backup \
  --disable-backup-schedule \
  --non-interactive
[[ ${ENABLE_GCS_BACKUP:-0} -eq 0 &&
   ${DISABLE_GCS_BACKUP:-0} -eq 1 &&
   ${DISABLE_BACKUP_SCHEDULE:-0} -eq 1 ]] ||
  fail 'safe GCS and schedule disable flags must be parsed explicitly'

vm_parse_args \
  --domain chrome.example.com \
  --email admin@example.com \
  --data-dir "$test_root/data" \
  --enable-gcs-backup \
  --non-interactive
[[ ${ENABLE_GCS_BACKUP:-0} -eq 1 &&
   ${DISABLE_GCS_BACKUP:-0} -eq 0 ]] ||
  fail 'GCS backup must require an explicit enable state'

for conflicting_flags in \
  '--enable-gcs-backup --disable-gcs-backup' \
  '--gcs-bucket fixture-backups --disable-gcs-backup' \
  '--backup-schedule daily --disable-backup-schedule'; do
  read -r -a conflict_args <<<"$conflicting_flags"
  set +e
  (
    vm_parse_args \
      --domain chrome.example.com \
      --email admin@example.com \
      --data-dir "$test_root/data" \
      --non-interactive \
      "${conflict_args[@]}"
  ) >"$test_root/conflict.stdout" 2>"$test_root/conflict.stderr"
  conflict_status=$?
  set -e
  [[ $conflict_status -eq 2 ]] ||
    fail "conflicting backup flags must exit 2: $conflicting_flags"
done

tty_fixture="$test_root/tty-input"
printf 'prompted.example.com\n' >"$tty_fixture"
prompted_value="$(REMOTE_CHROME_TTY="$tty_fixture" vm_prompt 'Domain: ')"
[[ "$prompted_value" == prompted.example.com ]] ||
  fail 'wizard prompt must read from the explicit TTY path'

wizard_input="$test_root/wizard-input"
wizard_prompts="$test_root/wizard-prompts"
printf '%s\n' \
  yes \
  guided.example.com \
  admin@guided.example.com \
  "$test_root/guided-data" \
  yes \
  guided-backups \
  '*-*-* 03:00:00' >"$wizard_input"
: >"$wizard_prompts"
vm_parse_args
REMOTE_CHROME_TTY="$wizard_input"
REMOTE_CHROME_TTY_OUTPUT="$wizard_prompts"
vm_collect_configuration
[[ $DOMAIN == guided.example.com ]] ||
  fail 'interactive wizard must collect the domain first'
[[ $ACME_EMAIL == admin@guided.example.com ]] ||
  fail 'interactive wizard must collect the certificate email second'
[[ $REMOTE_CHROME_DATA_DIR == "$test_root/guided-data" ]] ||
  fail 'interactive wizard must collect the data directory third'
[[ $GCS_BUCKET == guided-backups ]] ||
  fail 'interactive wizard must collect the selected GCS bucket'
[[ $BACKUP_SCHEDULE == '*-*-* 03:00:00' ]] ||
  fail 'interactive wizard must collect the optional backup schedule last'
cat >"$test_root/expected-wizard-prompts" <<'EOF'
The installer validates DNS and checks host ports 80 and 443 before provisioning.
Do you have a domain already pointing to this VM? [y/N]:
Domain:
ACME certificate email:
Data directory [/var/lib/remote-chrome]:
Enable GCS backup? [y/N]:
GCS bucket:
Optional backup schedule (systemd OnCalendar, blank for none):
EOF
cmp -s "$test_root/expected-wizard-prompts" "$wizard_prompts" ||
  fail 'interactive wizard must explain preflight and prompt in the documented order'

stdin_canary="$test_root/stdin-canary"
printf 'stdin.example.com\n' >"$stdin_canary"
printf '%s\n' \
  yes \
  tty.example.com \
  tty@example.com \
  "$test_root/tty-data" \
  no >"$wizard_input"
: >"$wizard_prompts"
vm_parse_args
REMOTE_CHROME_TTY="$wizard_input"
REMOTE_CHROME_TTY_OUTPUT="$wizard_prompts"
vm_collect_configuration <"$stdin_canary"
[[ $DOMAIN == tty.example.com && -z $GCS_BUCKET && -z $BACKUP_SCHEDULE ]] ||
  fail 'interactive wizard must use only its TTY and skip GCS details after no'
[[ $(<"$stdin_canary") == stdin.example.com ]] ||
  fail 'interactive wizard must not consume piped standard input'

auto_wizard_input="$test_root/auto-wizard-input"
auto_wizard_prompts="$test_root/auto-wizard-prompts"
printf '%s\n' \
  no \
  auto@example.com \
  "$test_root/auto-data" \
  no >"$auto_wizard_input"
: >"$auto_wizard_prompts"
(
  vm_generate_sslip_domain() {
    printf '203-0-113-10.sslip.io'
  }
  vm_parse_args
  REMOTE_CHROME_TTY="$auto_wizard_input"
  REMOTE_CHROME_TTY_OUTPUT="$auto_wizard_prompts"
  vm_collect_configuration
  [[ $DOMAIN == 203-0-113-10.sslip.io &&
     $AUTO_DOMAIN -eq 1 &&
     $DISABLE_GCS_BACKUP -eq 1 &&
     -z $GCS_BUCKET ]] ||
    fail 'interactive no-domain setup must generate sslip.io and disable backup by default'
)
grep -Fxq \
  'Do you have a domain already pointing to this VM? [y/N]:' \
  "$auto_wizard_prompts" ||
  fail 'interactive auto-domain mode must ask a yes-or-no domain question'
grep -Fxq 'Using automatic domain: 203-0-113-10.sslip.io' \
  "$auto_wizard_prompts" ||
  fail 'interactive auto-domain mode must report the generated hostname'

(
  vm_generate_sslip_domain() {
    printf '198-51-100-24.sslip.io'
  }
  vm_parse_args \
    --email automated@example.com \
    --data-dir "$test_root/automated-data" \
    --non-interactive
  vm_collect_configuration
  [[ $DOMAIN == 198-51-100-24.sslip.io &&
     $AUTO_DOMAIN -eq 1 &&
     $DISABLE_GCS_BACKUP -eq 1 &&
     -z $GCS_BUCKET && -z $BACKUP_SCHEDULE ]] ||
    fail 'noninteractive setup must auto-generate a domain and leave backup disabled'
)

(
  vm_generate_sslip_domain() {
    printf '192-0-2-44.sslip.io'
  }
  vm_parse_args \
    --domain none \
    --email none@example.com \
    --data-dir "$test_root/none-data" \
    --non-interactive
  vm_collect_configuration
  [[ $DOMAIN == 192-0-2-44.sslip.io && $AUTO_DOMAIN -eq 1 ]] ||
    fail '--domain none must explicitly request automatic sslip.io mode'
)

set +e
(
  vm_parse_args \
    --email backup@example.com \
    --data-dir "$test_root/backup-data" \
    --enable-gcs-backup \
    --non-interactive
  vm_generate_sslip_domain() {
    printf '203-0-113-11.sslip.io'
  }
  vm_collect_configuration
) >"$test_root/backup-missing-bucket.stdout" \
  2>"$test_root/backup-missing-bucket.stderr"
backup_missing_bucket_status=$?
set -e
[[ $backup_missing_bucket_status -eq 2 ]] ||
  fail 'explicit backup enable without a bucket must exit 2'
grep -Fq -- '--enable-gcs-backup requires --gcs-bucket' \
  "$test_root/backup-missing-bucket.stderr" ||
  fail 'missing opt-in backup bucket must have an actionable error'

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
for required_flag in --email --data-dir; do
  grep -Fq -- "$required_flag" "$test_root/no-tty.stderr" ||
    fail "noninteractive failure must name missing $required_flag"
done
! grep -Fq -- 'requires --domain' "$test_root/no-tty.stderr" ||
  fail 'noninteractive mode must not require a domain'
[[ ! -e "$missing_tty" ]] ||
  fail 'noninteractive mode must not create or read a fallback input path'

installed_root="$test_root/installed-rerun"
mkdir "$installed_root"
REMOTE_CHROME_TEST_ROOT="$installed_root"
vm_init_paths
mkdir -p "$REMOTE_CHROME_CONFIG_ROOT"
cat >"$REMOTE_CHROME_CONFIG_ROOT/install.env" <<EOF
DOMAIN=installed.example.com
ACME_EMAIL='installed@example.com'
REMOTE_CHROME_DATA_DIR='$installed_root/var/lib/remote-chrome'
GCS_BUCKET='installed-backups'
BACKUP_SCHEDULE='daily'
SELECTED_VERSION=v1.0.0
EOF
chmod 0600 "$REMOTE_CHROME_CONFIG_ROOT/install.env"
vm_parse_args
vm_load_installed_configuration ||
  fail 'valid installed configuration must load before rerun prompts'
rerun_input="$installed_root/rerun-input"
rerun_prompts="$installed_root/rerun-prompts"
printf '\n\n\n\n' >"$rerun_input"
: >"$rerun_prompts"
REMOTE_CHROME_TTY="$rerun_input"
REMOTE_CHROME_TTY_OUTPUT="$rerun_prompts"
vm_collect_configuration
[[ $DOMAIN == installed.example.com &&
   $ACME_EMAIL == installed@example.com &&
   $REMOTE_CHROME_DATA_DIR == "$installed_root/var/lib/remote-chrome" &&
   $GCS_BUCKET == installed-backups &&
   $BACKUP_SCHEDULE == daily ]] ||
  fail 'blank interactive rerun answers must preserve valid installed settings'

unsafe_config_target="$test_root/unsafe-install.env"
cp "$REMOTE_CHROME_CONFIG_ROOT/install.env" "$unsafe_config_target"
for unsafe_type in symlink directory; do
  unsafe_root="$test_root/installed-$unsafe_type"
  mkdir "$unsafe_root"
  REMOTE_CHROME_TEST_ROOT="$unsafe_root"
  vm_init_paths
  mkdir -p "$REMOTE_CHROME_CONFIG_ROOT"
  case "$unsafe_type" in
    symlink)
      ln -s "$unsafe_config_target" "$REMOTE_CHROME_CONFIG_ROOT/install.env"
      ;;
    directory)
      mkdir "$REMOTE_CHROME_CONFIG_ROOT/install.env"
      ;;
  esac
  vm_parse_args
  set +e
  (vm_load_installed_configuration) \
    >"$unsafe_root/config.stdout" 2>"$unsafe_root/config.stderr"
  unsafe_config_status=$?
  set -e
  [[ $unsafe_config_status -ne 0 ]] ||
    fail "installed $unsafe_type configuration must fail closed before prompts"
done
REMOTE_CHROME_TEST_ROOT="$test_root"
vm_init_paths

declare -F vm_stage_release >/dev/null ||
  fail 'vm_stage_release is undefined'
declare -F vm_verify_release >/dev/null ||
  fail 'vm_verify_release is undefined'
declare -F vm_ensure_gcloud >/dev/null ||
  fail 'vm_ensure_gcloud is undefined'
for management_function in \
  vm_prepare_config vm_generate_credentials vm_render_compose_env \
  vm_activate_release vm_rollback_release vm_verify_public_stack \
  vm_print_connection_handoff; do
  declare -F "$management_function" >/dev/null ||
    fail "$management_function is undefined"
done

gcloud_root="$test_root/gcloud"
mkdir "$gcloud_root"
REMOTE_CHROME_TEST_ROOT="$gcloud_root"
REMOTE_CHROME_DRY_RUN=1
REMOTE_CHROME_TEST_EUID=0
vm_init_paths
gcloud_log="$gcloud_root/gcloud-commands.log"
COMMAND_LOG="$gcloud_log"
: >"$gcloud_log"
GCS_BUCKET=
vm_ensure_gcloud
[[ ! -s $gcloud_log ]] ||
  fail 'gcloud provisioning must not run when GCS backup is not configured'

poisoned_path="$gcloud_root/poisoned-bin"
mkdir "$poisoned_path"
cat >"$poisoned_path/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'PATH gcloud must not run\n' >&2
exit 91
EOF
chmod +x "$poisoned_path/gcloud"
PATH="$poisoned_path:$PATH"
GCS_BUCKET=guided-backups
vm_ensure_gcloud
trusted_gcloud="$gcloud_root/usr/bin/gcloud"
[[ -f $trusted_gcloud && ! -L $trusted_gcloud && -x $trusted_gcloud ]] ||
  fail 'GCS setup must provision the trusted fixed /usr/bin/gcloud target'
grep -Fq \
  'curl <-fsSL> <--max-time> <30> <https://packages.cloud.google.com/apt/doc/apt-key.gpg>' \
  "$gcloud_log" ||
  fail 'gcloud setup must fetch the official key into an atomic temporary'
grep -Fq \
  'gpg <--dearmor> <--output>' "$gcloud_log" ||
  fail 'gcloud setup must dearmor the official key without a privileged pipe'
grep -Fxq 'apt-get <install> <-y> <google-cloud-cli>' "$gcloud_log" ||
  fail 'gcloud setup must install only the official google-cloud-cli package'
gcloud_source="$gcloud_root/etc/apt/sources.list.d/google-cloud-sdk.list"
grep -Fxq \
  "deb [signed-by=$gcloud_root/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  "$gcloud_source" ||
  fail 'gcloud setup must use the official signed-by apt repository'
! grep -Eqi '(^|[[:space:]<])(snap|gcloud[[:space:]<]+init)([[:space:]>]|$)' \
  "$gcloud_log" ||
  fail 'gcloud provisioning must never use snap or gcloud init'

: >"$gcloud_log"
vm_ensure_gcloud
[[ ! -s $gcloud_log ]] ||
  fail 'an existing trusted fixed gcloud executable must not reinstall'

rm -f "$trusted_gcloud"
ln -s "$poisoned_path/gcloud" "$trusted_gcloud"
set +e
(vm_ensure_gcloud) >"$gcloud_root/symlink.stdout" \
  2>"$gcloud_root/symlink.stderr"
gcloud_symlink_status=$?
set -e
[[ $gcloud_symlink_status -ne 0 ]] ||
  fail 'trusted gcloud validation must reject a symlink target'
rm -f "$trusted_gcloud"

for failure_step in curl gpg install-source apt-final restore-failure; do
  rollback_root="$test_root/gcloud-rollback-$failure_step"
  mkdir "$rollback_root"
  REMOTE_CHROME_TEST_ROOT="$rollback_root"
  vm_init_paths
  rollback_key="$rollback_root/usr/share/keyrings/cloud.google.gpg"
  rollback_source="$rollback_root/etc/apt/sources.list.d/google-cloud-sdk.list"
  mkdir -p "${rollback_key%/*}" "${rollback_source%/*}"
  printf 'prior-key\n' >"$rollback_key"
  printf 'prior-source\n' >"$rollback_source"
  rollback_log="$rollback_root/commands.log"
  : >"$rollback_log"
  set +e
  (
    REMOTE_CHROME_DRY_RUN=1
    REMOTE_CHROME_TEST_EUID=0
    COMMAND_LOG="$rollback_log"
    GCS_BUCKET=guided-backups
    mutation_install_count=0
    provisioning_failed=0
    vm_run_mutation() {
      vm_log_command "$@" || return 1
      case "$failure_step:$1:$*" in
        curl:curl:*) return 91 ;;
        gpg:gpg:*) return 92 ;;
        install-source:install:*)
          mutation_install_count=$((mutation_install_count + 1))
          ((mutation_install_count != 2)) || return 93
          ;;
        apt-final:apt-get:*google-cloud-cli*) return 94 ;;
        restore-failure:apt-get:*google-cloud-cli*)
          provisioning_failed=1
          return 94
          ;;
        restore-failure:install:*)
          ((provisioning_failed == 0)) || return 95
          ;;
      esac
      return 0
    }
    vm_ensure_gcloud
  ) >"$rollback_root/stdout" 2>"$rollback_root/stderr"
  rollback_status=$?
  set -e
  [[ $rollback_status -ne 0 ]] ||
    fail "gcloud failure injection must fail at $failure_step"
  if [[ $failure_step == restore-failure ]]; then
    [[ $rollback_status -eq 70 ]] ||
      fail 'uncertain gcloud apt rollback must return distinct status 70'
    grep -Fq 'apt rollback could not be confirmed' \
      "$rollback_root/stderr" ||
      fail 'uncertain gcloud apt rollback must report the recovery state'
    retained_stage=$(
      sed -n 's/^  staging: //p' "$rollback_root/stderr" | tail -n 1
    )
    [[ $retained_stage == /tmp/* && -d $retained_stage ]] ||
      fail 'uncertain gcloud apt rollback must retain its staging snapshot'
    rm -rf -- "$retained_stage"
  else
    [[ $(<"$rollback_key") == prior-key &&
       $(<"$rollback_source") == prior-source ]] ||
      fail "gcloud failure at $failure_step must restore the prior apt key and source"
  fi
  [[ -z $(find "${rollback_key%/*}" "${rollback_source%/*}" \
      -name '*.pending.*' -print -quit) ]] ||
    fail "gcloud failure at $failure_step must remove pending apt configuration"
done

unset REMOTE_CHROME_DRY_RUN REMOTE_CHROME_TEST_EUID
PATH=${PATH#"$poisoned_path:"}
REMOTE_CHROME_TEST_ROOT="$test_root"
vm_init_paths

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
    info.mode = 0o755 if name.endswith("/remote-chrome") else 0o644
    archive.addfile(info, io.BytesIO(content))

def base_archive(path):
    archive = tarfile.open(path, "w:gz")
    add_file(archive, "remotechromemcp-v1.2.3/compose.yaml")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/compose.vm.yaml")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/remote-chrome")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/remote-chrome-backup.service.in")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/remote-chrome-backup.timer.in")
    add_file(archive, "remotechromemcp-v1.2.3/vminstall/lib/backup.sh")
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
    add_file(archive, "remotechromemcp-master/vminstall/remote-chrome")
    add_file(archive, "remotechromemcp-master/vminstall/remote-chrome-backup.service.in")
    add_file(archive, "remotechromemcp-master/vminstall/remote-chrome-backup.timer.in")
    add_file(archive, "remotechromemcp-master/vminstall/lib/backup.sh")
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
COMMAND_LOG="$config_symlink_root/master-staging.log"
set +e
(
  SELECTED_VERSION=master
  vm_stage_release "$release_fixture/remotechromemcp-master.tar.gz"
) >"$test_root/config-symlink.stdout" \
  2>"$test_root/config-symlink.stderr"
config_symlink_status=$?
set -e
[[ $config_symlink_status -eq 0 ]] ||
  fail 'master staging must not require configuration writes'
[[ ! -e "$config_symlink_escape/remote-chrome/install.env" ]] ||
  fail 'master staging must not write through a configuration symlink'

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
[[ ! -e $REMOTE_CHROME_CONFIG_ROOT/install.env ]] ||
  fail 'master staging must not create a partial installed configuration'

printf 'PASS: VM installer validation, platform, no-TTY, and release contracts\n'
