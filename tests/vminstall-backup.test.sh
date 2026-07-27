#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

required_tests=(
  backup_stops_browser_before_tar
  backup_uploads_archive_checksum_manifest
  backup_upload_failure_restarts_stack
  backup_partial_stop_failure_restarts_browser
  backup_health_failure_returns_nonzero
  backup_lock_rejects_concurrency
  backup_rejects_invalid_gcs_prefix
  restore_rejects_checksum_mismatch
  restore_rejects_malformed_manifest
  restore_rejects_absolute_path
  restore_rejects_traversal
  restore_rejects_escaping_symlink
  restore_preserves_current_profile
  restore_health_failure_rolls_back
  restore_unconfirmed_rollback_stop_preserves_all
  restore_candidate_profile_rename_failure_preserves_canonical
  restore_rollback_profile_rename_failure_restores_candidate
  restore_rollback_restart_failure_preserves_recovery
  restore_rollback_health_failure_preserves_recovery
  restore_cleanup_failure_keeps_healthy_profile_and_rollback
  restore_rejects_mismatched_identity
  restore_success_removes_staging_only
  backup_timer_lifecycle_follows_schedule
  backup_timer_empty_schedule_without_prior_succeeds
  backup_timer_schedule_removal_matrix
  backup_timer_rollback_restores_prior_state
  management_dispatch_uses_backup_contract
)

[[ -f vminstall/lib/backup.sh ]] ||
  fail 'vminstall/lib/backup.sh is missing'

test_root="$(mktemp -d /tmp/remote-chrome-vminstall-backup.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
[[ -d $test_root && $test_root == /tmp/* && ! -L $test_root ]] ||
  fail 'backup test root must be a canonical directory beneath /tmp'

fake_bin="$test_root/fake-bin"
mkdir "$fake_bin"

cat >"$fake_bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
case "$*" in
  *" stop -t 30 browser")
    : >"$FAKE_BROWSER_STOPPED"
    ;;
  *" start browser")
    start_count=0
    [[ ! -f ${FAKE_START_COUNT:-} ]] || start_count=$(<"$FAKE_START_COUNT")
    start_count=$((start_count + 1))
    [[ -z ${FAKE_START_COUNT:-} ]] ||
      printf '%s\n' "$start_count" >"$FAKE_START_COUNT"
    [[ ${FAKE_START_FAIL_ON:-0} -ne $start_count ]] || exit 93
    rm -f "$FAKE_BROWSER_STOPPED"
    ;;
  *" ps --status running --services browser")
    count=0
    [[ ! -f ${FAKE_PS_COUNT:-} ]] || count=$(<"$FAKE_PS_COUNT")
    count=$((count + 1))
    [[ -z ${FAKE_PS_COUNT:-} ]] || printf '%s\n' "$count" >"$FAKE_PS_COUNT"
    if [[ ${FAKE_PS_HANG_ON:-0} -eq $count ]]; then
      exec /bin/sleep 30
    fi
    [[ ${FAKE_PS_FAIL_ON:-0} -ne $count ]] || exit 92
    [[ -e $FAKE_BROWSER_STOPPED ]] || printf 'browser\n'
    ;;
  *" exec -T browser google-chrome --version")
    printf 'Google Chrome 123.0.0.0\n'
    ;;
esac
FAKE

cat >"$fake_bin/tar" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'tar <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
exec /usr/bin/tar "$@"
FAKE

cat >"$fake_bin/sha256sum" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'sha256sum <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
exec /usr/bin/sha256sum "$@"
FAKE

cat >"$fake_bin/chown" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'chown <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
FAKE

cat >"$fake_bin/openssl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-}:${2:-}:${3:-} == rand:-hex:6 ]] || exit 2
printf 'a1b2c3d4e5f6\n'
FAKE

cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
timer_enabled="$FAKE_SYSTEMD_STATE/backup-timer.enabled"
timer_active="$FAKE_SYSTEMD_STATE/backup-timer.active"
case "${1:-}" in
  is-enabled)
    [[ ${!#} == remote-chrome-backup.timer && -f $timer_enabled ]]
    ;;
  is-active)
    [[ ${!#} == remote-chrome-backup.timer && -f $timer_active ]]
    ;;
  enable)
    if [[ ${!#} == remote-chrome-backup.timer ]]; then
      : >"$timer_enabled"
      [[ " $* " != *" --now "* ]] || : >"$timer_active"
    fi
    ;;
  disable)
    if [[ ${!#} == remote-chrome-backup.timer ]]; then
      [[ ${FAKE_SYSTEMCTL_DISABLE_FAIL:-0} != 1 ]] || exit 6
      if [[ ${FAKE_SYSTEMCTL_DISABLE_ABSENT:-0} == 1 &&
            ! -e $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer &&
            ! -e $timer_enabled && ! -e $timer_active ]]; then
        exit 5
      fi
      rm -f -- "$timer_enabled" "$timer_active"
    fi
    ;;
  start)
    [[ ${!#} != remote-chrome-backup.timer ]] || : >"$timer_active"
    ;;
  stop)
    [[ ${!#} != remote-chrome-backup.timer ]] || rm -f -- "$timer_active"
    ;;
esac
FAKE
cat >"$fake_bin/mv" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'mv <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
source_path=${@: -2:1}
destination=${@: -1}
if [[ ${FAKE_MV_FAIL_CANDIDATE_TO_FAILED:-0} == 1 &&
      $source_path == "$REMOTE_CHROME_DATA_DIR/profile" &&
      $destination == "$REMOTE_CHROME_DATA_DIR/profile.failed-"* ]]; then
  exit 81
fi
if [[ ${FAKE_MV_FAIL_ROLLBACK_TO_PROFILE:-0} == 1 &&
      $source_path == "$REMOTE_CHROME_DATA_DIR/profile.rollback-"* &&
      $destination == "$REMOTE_CHROME_DATA_DIR/profile" ]]; then
  exit 82
fi
exec /usr/bin/mv "$@"
FAKE
cat >"$fake_bin/rm" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_RM_FAIL_RESTORE:-0} == 1 && " $* " == *"/restore-staging/"* ]]; then
  exit 99
fi
exec /usr/bin/rm "$@"
FAKE
chmod +x "$fake_bin"/*
export PATH="$fake_bin:$PATH"

REMOTE_CHROME_SKIP_MAIN=1
# shellcheck source=../vminstall/installer-main.sh
source vminstall/installer-main.sh
# shellcheck source=../vminstall/lib/backup.sh
source vminstall/lib/backup.sh
# shellcheck source=../vminstall/lib/management.sh
source vminstall/lib/management.sh

for required_function in \
  vm_backup_profile vm_restore_profile vm_validate_backup_archive \
  vm_with_maintenance_lock; do
  declare -F "$required_function" >/dev/null ||
    fail "$required_function is undefined"
done

assert_order() {
  local log=$1
  shift
  local previous=0 item line
  for item in "$@"; do
    line=$(grep -n -m1 -Fx -- "$item" "$log" | cut -d: -f1) ||
      fail "missing ordered backup event: $item"
    ((line > previous)) ||
      fail "backup event is out of order: $item"
    previous=$line
  done
}

setup_fixture() {
  local name=$1
  fixture_root="$test_root/$name"
  mkdir -p \
    "$fixture_root/opt/remotechromemcp/releases/v1.0.0/vminstall" \
    "$fixture_root/etc/remote-chrome" \
    "$fixture_root/etc/systemd/system" \
    "$fixture_root/run/systemd-state" \
    "$fixture_root/usr/local/sbin" \
    "$fixture_root/usr/bin" \
    "$fixture_root/var/lib/remote-chrome/profile" \
    "$fixture_root/var/lib/remote-chrome/backups/.staging" \
    "$fixture_root/var/lib/remote-chrome/restore-staging" \
    "$fixture_root/gcs"
  ln -s releases/v1.0.0 "$fixture_root/opt/remotechromemcp/current"
  cp compose.yaml "$fixture_root/opt/remotechromemcp/releases/v1.0.0/compose.yaml"
  cp vminstall/compose.vm.yaml \
    "$fixture_root/opt/remotechromemcp/releases/v1.0.0/vminstall/compose.vm.yaml"
  cp "$fake_bin/tar" "$fake_bin/sha256sum" "$fake_bin/openssl" \
    "$fake_bin/chown" "$fixture_root/usr/bin/"
  printf 'old-profile\n' \
    >"$fixture_root/var/lib/remote-chrome/profile/current-marker"
  chmod 0700 "$fixture_root/var/lib/remote-chrome/profile"
  printf '%s\n' \
    'DOMAIN=chrome.example.com' \
    'ACME_EMAIL=ops@example.com' \
    "REMOTE_CHROME_DATA_DIR=$fixture_root/var/lib/remote-chrome" \
    'GCS_BUCKET=fixture-backups' \
    'BACKUP_SCHEDULE=' \
    'SELECTED_VERSION=v1.0.0' \
    >"$fixture_root/etc/remote-chrome/install.env"
  : >"$fixture_root/etc/remote-chrome/compose.env"

cat >"$fixture_root/usr/local/sbin/remote-chrome" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${REMOTE_CHROME_HEALTH_PHASE:-health}" \
  >>"$REMOTE_CHROME_BACKUP_LOG"
count=0
[[ ! -f $FAKE_HEALTH_COUNT ]] || count=$(<"$FAKE_HEALTH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_HEALTH_COUNT"
[[ ,${FAKE_HEALTH_FAIL_ON:-}, != *",$count,"* ]]
FAKE
  chmod +x "$fixture_root/usr/local/sbin/remote-chrome"

  cat >"$fixture_root/usr/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'gcloud <%s>\n' "$*" >>"$FAKE_COMMAND_LOG"
[[ ${1:-}:${2:-} == storage:cp && $# -eq 4 ]] || exit 2
source_path=$3
destination=$4
map_uri() {
  case "$1" in
    gs://*) printf '%s/%s' "$FAKE_GCS_ROOT" "${1#gs://}" ;;
    *) printf '%s' "$1" ;;
  esac
}
source_file=$(map_uri "$source_path")
destination_file=$(map_uri "$destination")
if [[ $destination == gs://* ]]; then
  upload_count=0
  [[ ! -f $FAKE_UPLOAD_COUNT ]] || upload_count=$(<"$FAKE_UPLOAD_COUNT")
  upload_count=$((upload_count + 1))
  printf '%s\n' "$upload_count" >"$FAKE_UPLOAD_COUNT"
  [[ ${FAKE_GCLOUD_FAIL_UPLOAD:-0} -ne $upload_count ]] || exit 91
fi
mkdir -p "$(dirname "$destination_file")"
cp -- "$source_file" "$destination_file"
FAKE
  chmod +x "$fixture_root/usr/bin/gcloud"

  export REMOTE_CHROME_TEST_ROOT="$fixture_root"
  export REMOTE_CHROME_CANONICAL_TEST_ROOT="$fixture_root"
  export REMOTE_CHROME_INSTALL_ROOT="$fixture_root/opt/remotechromemcp"
  export REMOTE_CHROME_CONFIG_ROOT="$fixture_root/etc/remote-chrome"
  export REMOTE_CHROME_SYSTEMD_ROOT="$fixture_root/etc/systemd/system"
  export REMOTE_CHROME_CLI_ROOT="$fixture_root/usr/local/sbin"
  export REMOTE_CHROME_TRUSTED_INSTALL_ROOT="$REMOTE_CHROME_INSTALL_ROOT"
  export REMOTE_CHROME_TRUSTED_CONFIG_ROOT="$REMOTE_CHROME_CONFIG_ROOT"
  export REMOTE_CHROME_TRUSTED_SYSTEMD_ROOT="$REMOTE_CHROME_SYSTEMD_ROOT"
  export REMOTE_CHROME_TRUSTED_CLI_ROOT="$REMOTE_CHROME_CLI_ROOT"
  export REMOTE_CHROME_DATA_DIR="$fixture_root/var/lib/remote-chrome"
  export GCS_BUCKET=fixture-backups
  export SELECTED_VERSION=v1.0.0
  export REMOTE_CHROME_COMMAND_TIMEOUT=5
  export REMOTE_CHROME_BACKUP_LOG="$fixture_root/events.log"
  export FAKE_COMMAND_LOG="$fixture_root/commands.log"
  export FAKE_BROWSER_STOPPED="$fixture_root/browser.stopped"
  export FAKE_GCS_ROOT="$fixture_root/gcs"
  export FAKE_HEALTH_COUNT="$fixture_root/health.count"
  export FAKE_START_COUNT="$fixture_root/start.count"
  export FAKE_UPLOAD_COUNT="$fixture_root/upload.count"
  export FAKE_PS_COUNT="$fixture_root/ps.count"
  export FAKE_SYSTEMD_STATE="$fixture_root/run/systemd-state"
  unset FAKE_GCLOUD_FAIL_UPLOAD FAKE_HEALTH_FAIL_ON KEEP_LOCAL_BACKUPS
  unset FAKE_PS_FAIL_ON FAKE_PS_HANG_ON FAKE_RM_FAIL_RESTORE
  unset FAKE_START_FAIL_ON FAKE_MV_FAIL_CANDIDATE_TO_FAILED
  unset FAKE_MV_FAIL_ROLLBACK_TO_PROFILE FAKE_SYSTEMCTL_DISABLE_FAIL
  unset FAKE_SYSTEMCTL_DISABLE_ABSENT
  : >"$REMOTE_CHROME_BACKUP_LOG"
  : >"$FAKE_COMMAND_LOG"
}

make_restore_fixture() {
  local mode=${1:-valid}
  local object_dir="$FAKE_GCS_ROOT/fixture-backups/remote-chrome"
  local base=remote-chrome-profile-20260727T120000Z-a1b2c3d4e5f6
  local archive="$object_dir/$base.tar.gz"
  mkdir -p "$object_dir" "$fixture_root/restore-source/profile"
  printf 'new-profile\n' >"$fixture_root/restore-source/profile/restored-marker"
  case "$mode" in
    valid|checksum)
      /usr/bin/tar -czf "$archive" -C "$fixture_root/restore-source" profile
      ;;
    absolute|traversal|symlink|hardlink|device|fifo)
      ARCHIVE_PATH="$archive" ARCHIVE_MODE="$mode" python3 <<'PY'
import io, os, tarfile
path, mode = os.environ["ARCHIVE_PATH"], os.environ["ARCHIVE_MODE"]
with tarfile.open(path, "w:gz") as archive:
    def regular(name, data=b"x\n"):
        info=tarfile.TarInfo(name); info.size=len(data); info.mode=0o600
        archive.addfile(info, io.BytesIO(data))
    regular("profile/restored-marker")
    info=tarfile.TarInfo({
        "absolute": "/tmp/backup-escape",
        "traversal": "profile/../../backup-escape",
        "symlink": "profile/escape-link",
        "hardlink": "profile/escape-hardlink",
        "device": "profile/device",
        "fifo": "profile/fifo",
    }[mode])
    if mode == "symlink":
        info.type=tarfile.SYMTYPE; info.linkname="../../outside"
    elif mode == "hardlink":
        info.type=tarfile.LNKTYPE; info.linkname="../../outside"
    elif mode == "device":
        info.type=tarfile.CHRTYPE; info.devmajor=1; info.devminor=3
    elif mode == "fifo":
        info.type=tarfile.FIFOTYPE
    else:
        data=b"escape\n"; info.size=len(data)
        archive.addfile(info, io.BytesIO(data)); info=None
    if info is not None: archive.addfile(info)
PY
      ;;
  esac
  (
    cd "$object_dir"
    /usr/bin/sha256sum "$base.tar.gz" >"$base.sha256"
  )
  if [[ $mode == checksum ]]; then
    printf '%064d  %s\n' 0 "$base.tar.gz" >"$object_dir/$base.sha256"
  fi
  printf '%s\n' \
    'MANIFEST_VERSION=1' \
    'TIMESTAMP_UTC=20260727T120000Z' \
    'CHROME_VERSION=Google Chrome 123.0.0.0' \
    "ARCHIVE_NAME=$base.tar.gz" \
    "CHECKSUM_NAME=$base.sha256" \
    "SOURCE_PROFILE=$REMOTE_CHROME_DATA_DIR/profile" \
    >"$object_dir/$base.manifest"
  RESTORE_MANIFEST_URI="gs://fixture-backups/remote-chrome/$base.manifest"
}

backup_stops_browser_before_tar() {
  setup_fixture "$FUNCNAME"
  vm_backup_profile gs://fixture-backups/remote-chrome
  assert_order "$REMOTE_CHROME_BACKUP_LOG" \
    lock pre-health stop tar checksum upload start health
  grep -Fq ' stop -t 30 browser' "$FAKE_COMMAND_LOG" ||
    fail 'backup must stop the browser with a 30-second grace'
  [[ ! -e $FAKE_BROWSER_STOPPED ]] ||
    fail 'backup must restart the browser'
}

backup_uploads_archive_checksum_manifest() {
  setup_fixture "$FUNCNAME"
  vm_backup_profile gs://fixture-backups/remote-chrome
  mapfile -t uploads < <(find "$FAKE_GCS_ROOT" -type f | sort)
  [[ ${#uploads[@]} -eq 3 &&
     ${uploads[0]} == *.manifest &&
     ${uploads[1]} == *.sha256 &&
     ${uploads[2]} == *.tar.gz ]] ||
    fail 'backup must upload archive, checksum, and manifest only'
  [[ $(grep '^gcloud' "$FAKE_COMMAND_LOG" | tail -n 1) == gcloud*manifest* ]] ||
    fail 'manifest must upload last as the commit marker'
  ! /usr/bin/tar -tzf "${uploads[2]}" | grep -Eq 'credentials|compose\\.env' ||
    fail 'backup archive must not contain configuration or credentials'
}

backup_upload_failure_restarts_stack() {
  setup_fixture "$FUNCNAME"
  export FAKE_GCLOUD_FAIL_UPLOAD=2
  set +e
  vm_backup_profile gs://fixture-backups/remote-chrome
  status=$?
  set -e
  [[ $status -ne 0 && ! -e $FAKE_BROWSER_STOPPED ]] ||
    fail 'upload failure must restart the browser'
  [[ $(tail -n 2 "$REMOTE_CHROME_BACKUP_LOG") == $'start\nhealth' ]] ||
    fail 'upload failure recovery must restart and health-check'
}

backup_partial_stop_failure_restarts_browser() {
  setup_fixture "$FUNCNAME"
  export FAKE_PS_FAIL_ON=1
  set +e
  vm_backup_profile gs://fixture-backups/remote-chrome
  status=$?
  set -e
  [[ $status -ne 0 && ! -e $FAKE_BROWSER_STOPPED ]] ||
    fail 'backup stop-confirmation failure must restart the browser'
  [[ $(tail -n 2 "$REMOTE_CHROME_BACKUP_LOG") == $'start\nhealth' ]] ||
    fail 'partial stop failure must restart and health-check'
}

backup_health_failure_returns_nonzero() {
  setup_fixture "$FUNCNAME"
  export FAKE_HEALTH_FAIL_ON=1
  set +e
  vm_backup_profile gs://fixture-backups/remote-chrome
  status=$?
  set -e
  [[ $status -ne 0 && ! -e $FAKE_BROWSER_STOPPED ]] ||
    fail 'pre-health failure must return nonzero without stopping the browser'
}

backup_lock_rejects_concurrency() {
  setup_fixture "$FUNCNAME"
  exec 8>"$REMOTE_CHROME_DATA_DIR/.maintenance.lock"
  /usr/bin/flock -n 8
  set +e
  (vm_backup_profile gs://fixture-backups/remote-chrome) >/dev/null 2>&1
  status=$?
  set -e
  exec 8>&-
  [[ $status -eq 75 ]] ||
    fail 'maintenance lock contention must return 75 immediately'
}

backup_rejects_invalid_gcs_prefix() {
  setup_fixture "$FUNCNAME"
  ! vm_backup_profile gs://fixture-backups/remote-chrome/../escape ||
    fail 'backup must reject traversal in the GCS object prefix'
  ! vm_backup_profile gs://other-bucket/remote-chrome ||
    fail 'backup must reject a bucket other than the configured bucket'
  [[ ! -e $FAKE_BROWSER_STOPPED && ! -s $FAKE_COMMAND_LOG ]] ||
    fail 'invalid GCS destinations must fail before health or quiescing'
}

restore_rejects_checksum_mismatch() {
  setup_fixture "$FUNCNAME"; make_restore_fixture checksum
  set +e; vm_restore_profile "$RESTORE_MANIFEST_URI"; status=$?; set -e
  [[ $status -ne 0 && -f $REMOTE_CHROME_DATA_DIR/profile/current-marker ]] ||
    fail 'checksum mismatch must preserve the current profile'
}

restore_rejects_malformed_manifest() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  printf 'UNEXPECTED_FIELD=value\n' \
    >>"$FAKE_GCS_ROOT/fixture-backups/remote-chrome/"*.manifest
  ! vm_restore_profile "$RESTORE_MANIFEST_URI" ||
    fail 'restore must reject a manifest with extra fields'
  [[ -f $REMOTE_CHROME_DATA_DIR/profile/current-marker ]] ||
    fail 'malformed manifest rejection must preserve the current profile'
}

restore_rejects_absolute_path() {
  setup_fixture "$FUNCNAME"; make_restore_fixture absolute
  ! vm_restore_profile "$RESTORE_MANIFEST_URI" ||
    fail 'restore must reject absolute archive paths'
}

restore_rejects_traversal() {
  setup_fixture "$FUNCNAME"; make_restore_fixture traversal
  ! vm_restore_profile "$RESTORE_MANIFEST_URI" ||
    fail 'restore must reject traversal archive paths'
}

restore_rejects_escaping_symlink() {
  local archive_mode
  for archive_mode in symlink hardlink device fifo; do
    setup_fixture "$FUNCNAME-$archive_mode"; make_restore_fixture "$archive_mode"
    ! vm_restore_profile "$RESTORE_MANIFEST_URI" ||
      fail "restore must reject archive member type: $archive_mode"
  done
}

restore_preserves_current_profile() {
  setup_fixture "$FUNCNAME"; make_restore_fixture checksum
  ! vm_restore_profile "$RESTORE_MANIFEST_URI" || return 1
  grep -Fxq old-profile "$REMOTE_CHROME_DATA_DIR/profile/current-marker" ||
    fail 'validation failure must leave the current profile untouched'
}

restore_health_failure_rolls_back() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2
  set +e; vm_restore_profile "$RESTORE_MANIFEST_URI"; status=$?; set -e
  [[ $status -ne 0 ]] || fail 'new-profile health failure must return nonzero'
  grep -Fxq old-profile "$REMOTE_CHROME_DATA_DIR/profile/current-marker" ||
    fail 'new-profile health failure must restore the old profile'
  [[ ! -e $FAKE_BROWSER_STOPPED ]] ||
    fail 'rollback must leave the old browser running'
}

restore_unconfirmed_rollback_stop_preserves_all() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2
  export FAKE_PS_FAIL_ON=2
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI" \
    >"$fixture_root/restore.stdout" 2>"$fixture_root/restore.stderr"
  status=$?
  set -e
  rollback=$(find "$REMOTE_CHROME_DATA_DIR" -maxdepth 1 \
    -type d -name 'profile.rollback-*' -print -quit)
  staging=$(find "$REMOTE_CHROME_DATA_DIR/restore-staging" -mindepth 1 \
    -maxdepth 1 -type d -print -quit)
  [[ $status -eq 70 &&
     -f $REMOTE_CHROME_DATA_DIR/profile/restored-marker &&
     -n $rollback && -f $rollback/current-marker &&
     -n $staging ]] ||
    fail 'unconfirmed rollback stop must retain current, rollback, and staging with status 70'
  for retained in "$REMOTE_CHROME_DATA_DIR/profile" "$rollback" "$staging"; do
    grep -Fq -- "$retained" "$fixture_root/restore.stderr" ||
      fail "unconfirmed rollback must report retained path: $retained"
  done
}

assert_confirmed_stop_recovery_failure() {
  local expected_marker=$1
  local recovery rollback staging failed retained
  recovery=$(find "$REMOTE_CHROME_DATA_DIR" -maxdepth 1 -type d \
    \( -name 'profile.rollback-*' -o -name 'profile.failed-*' \) \
    -print -quit)
  staging=$(find "$REMOTE_CHROME_DATA_DIR/restore-staging" -mindepth 1 \
    -maxdepth 1 -type d -print -quit)
  [[ -n $recovery && -n $staging ]] ||
    fail 'confirmed-stop recovery failure must retain recovery and staging'
  if [[ $recovery == *'/profile.rollback-'* ]]; then
    rollback=$recovery
    failed=${rollback/profile.rollback-/profile.failed-}
  else
    failed=$recovery
    rollback=${failed/profile.failed-/profile.rollback-}
  fi
  [[ $status -eq 70 &&
     -f $REMOTE_CHROME_DATA_DIR/profile/"$expected_marker" ]] ||
    fail 'confirmed-stop recovery failure must return 70 with a canonical profile'
  if [[ $expected_marker == restored-marker ]]; then
    [[ -f $rollback/current-marker ]] ||
      fail 'candidate-preserving recovery failure must retain the old rollback'
  else
    [[ -f $failed/restored-marker ]] ||
      fail 'old-profile recovery failure must retain the failed candidate'
  fi
  for retained in \
      "$REMOTE_CHROME_DATA_DIR/profile" "$failed" "$rollback" "$staging"; do
    grep -Fq -- "$retained" "$fixture_root/restore.stderr" ||
      fail "confirmed-stop recovery failure must report exact path: $retained"
  done
}

restore_candidate_profile_rename_failure_preserves_canonical() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2
  export FAKE_MV_FAIL_CANDIDATE_TO_FAILED=1
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI" \
    >"$fixture_root/restore.stdout" 2>"$fixture_root/restore.stderr"
  status=$?
  set -e
  assert_confirmed_stop_recovery_failure restored-marker
}

restore_rollback_profile_rename_failure_restores_candidate() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2
  export FAKE_MV_FAIL_ROLLBACK_TO_PROFILE=1
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI" \
    >"$fixture_root/restore.stdout" 2>"$fixture_root/restore.stderr"
  status=$?
  set -e
  assert_confirmed_stop_recovery_failure restored-marker
}

restore_rollback_restart_failure_preserves_recovery() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2
  export FAKE_START_FAIL_ON=2
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI" \
    >"$fixture_root/restore.stdout" 2>"$fixture_root/restore.stderr"
  status=$?
  set -e
  assert_confirmed_stop_recovery_failure current-marker
}

restore_rollback_health_failure_preserves_recovery() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_HEALTH_FAIL_ON=2,3
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI" \
    >"$fixture_root/restore.stdout" 2>"$fixture_root/restore.stderr"
  status=$?
  set -e
  assert_confirmed_stop_recovery_failure current-marker
}

restore_cleanup_failure_keeps_healthy_profile_and_rollback() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  export FAKE_RM_FAIL_RESTORE=1
  set +e
  vm_restore_profile "$RESTORE_MANIFEST_URI"
  status=$?
  set -e
  rollback=$(find "$REMOTE_CHROME_DATA_DIR" -maxdepth 1 \
    -type d -name 'profile.rollback-*' -print -quit)
  staging=$(find "$REMOTE_CHROME_DATA_DIR/restore-staging" -mindepth 1 \
    -maxdepth 1 -type d -print -quit)
  [[ $status -ne 0 &&
     -f $REMOTE_CHROME_DATA_DIR/profile/restored-marker &&
     -n $rollback && -f $rollback/current-marker &&
     -n $staging ]] ||
    fail 'cleanup failure must retain healthy profile, rollback, and staging'
}

restore_rejects_mismatched_identity() {
  local identity_case object_dir manifest base replacement
  for identity_case in manifest-name timestamp archive checksum; do
    setup_fixture "$FUNCNAME-$identity_case"; make_restore_fixture valid
    object_dir="$FAKE_GCS_ROOT/fixture-backups/remote-chrome"
    base=remote-chrome-profile-20260727T120000Z-a1b2c3d4e5f6
    manifest="$object_dir/$base.manifest"
    case "$identity_case" in
      manifest-name)
        replacement=remote-chrome-profile-20260727T120001Z-a1b2c3d4e5f6
        mv "$manifest" "$object_dir/$replacement.manifest"
        RESTORE_MANIFEST_URI="gs://fixture-backups/remote-chrome/$replacement.manifest"
        ;;
      timestamp)
        sed -i 's/TIMESTAMP_UTC=20260727T120000Z/TIMESTAMP_UTC=20260727T120001Z/' "$manifest"
        ;;
      archive)
        sed -i 's/ARCHIVE_NAME=.*$/ARCHIVE_NAME=remote-chrome-profile-20260727T120000Z-b1b2c3d4e5f6.tar.gz/' "$manifest"
        ;;
      checksum)
        sed -i 's/CHECKSUM_NAME=.*$/CHECKSUM_NAME=remote-chrome-profile-20260727T120000Z-b1b2c3d4e5f6.sha256/' "$manifest"
        ;;
    esac
    set +e
    vm_restore_profile "$RESTORE_MANIFEST_URI"
    status=$?
    set -e
    [[ $status -ne 0 &&
       $(grep -c '^gcloud' "$FAKE_COMMAND_LOG") -eq 1 ]] ||
      fail "restore must reject mismatched $identity_case identity before pair downloads"
  done
}

restore_success_removes_staging_only() {
  setup_fixture "$FUNCNAME"; make_restore_fixture valid
  local expected_owner
  expected_owner=$(stat -c '%u:%g' "$REMOTE_CHROME_DATA_DIR/profile")
  : >"$REMOTE_CHROME_DATA_DIR/restore-staging/unrelated"
  vm_restore_profile "$RESTORE_MANIFEST_URI"
  [[ -f $REMOTE_CHROME_DATA_DIR/profile/restored-marker &&
     -f $REMOTE_CHROME_DATA_DIR/restore-staging/unrelated ]] ||
    fail 'successful restore must install only the validated profile'
  ! find "$REMOTE_CHROME_DATA_DIR" -maxdepth 1 \
    -name 'profile.rollback-*' -o -name 'profile.failed-*' | grep -q . ||
    fail 'successful restore must remove its rollback artifacts'
  grep -Fq "chown <-R $expected_owner " "$FAKE_COMMAND_LOG" ||
    fail 'restore must preserve the numeric profile owner'
  [[ $(stat -c '%a' "$REMOTE_CHROME_DATA_DIR/profile") == 700 ]] ||
    fail 'restore must preserve the root-only profile mode'
  assert_order "$REMOTE_CHROME_BACKUP_LOG" \
    lock download validate stop preserve extract chown start health
}

backup_timer_lifecycle_follows_schedule() {
  setup_fixture "$FUNCNAME"
  cp vminstall/remote-chrome \
    "$REMOTE_CHROME_INSTALL_ROOT/releases/v1.0.0/vminstall/remote-chrome"
  chmod +x \
    "$REMOTE_CHROME_INSTALL_ROOT/releases/v1.0.0/vminstall/remote-chrome"
  cp "$REMOTE_CHROME_CONFIG_ROOT/install.env" \
    "$REMOTE_CHROME_CONFIG_ROOT/install.env.candidate"
  : >"$REMOTE_CHROME_CONFIG_ROOT/compose.env.candidate"
  : >"$REMOTE_CHROME_CONFIG_ROOT/credentials.env.candidate"
  SELECTED_VERSION=v1.0.0
  vm_render_systemd_service
  BACKUP_SCHEDULE='*-*-* 03:15:00'
  vm_render_backup_units
  local service="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service.candidate"
  local timer="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer.candidate"
  [[ -f $service && -f $timer &&
     $(stat -c '%a' "$service") == 644 &&
     $(stat -c '%a' "$timer") == 644 ]] ||
    fail 'configured backup schedule must render root-managed unit candidates'
  grep -Fxq 'OnCalendar=*-*-* 03:15:00' "$timer" ||
    fail 'timer must render the confirmed schedule exactly'
  vm_install_candidate_config
  [[ -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service &&
     -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer ]] ||
    fail 'scheduled activation must install both backup units'
  vm_activate_backup_timer
  grep -Fq 'systemctl <enable --now remote-chrome-backup.timer>' \
    "$FAKE_COMMAND_LOG" ||
    fail 'configured timer must be enabled and started'

  BACKUP_SCHEDULE=
  vm_render_backup_units
  [[ ! -e $service && ! -e $timer ]] ||
    fail 'empty schedule must not render timer candidates'
  vm_install_candidate_config
  [[ -e $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service &&
     -e $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer ]] ||
    fail 'schedule removal must retain prior units until activation commits'
  vm_activate_backup_timer
  [[ ! -e $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service &&
     ! -e $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer ]] ||
    fail 'confirmed schedule removal must remove both installed backup units'
  grep -Fq 'systemctl <disable --now remote-chrome-backup.timer>' \
    "$FAKE_COMMAND_LOG" ||
    fail 'removed schedule must disable and stop the prior timer'
}

backup_timer_rollback_restores_prior_state() {
  setup_fixture "$FUNCNAME"
  SELECTED_VERSION=v2.0.0
  local candidate="$REMOTE_CHROME_INSTALL_ROOT/releases/v2.0.0"
  mkdir -p "$candidate/vminstall"
  cp compose.yaml "$candidate/compose.yaml"
  cp vminstall/compose.vm.yaml "$candidate/vminstall/compose.vm.yaml"
  local snapshot="$REMOTE_CHROME_CONFIG_ROOT/.timer-rollback"
  mkdir -p "$snapshot"
  cp vminstall/remote-chrome-backup.service.in \
    "$snapshot/remote-chrome-backup.service"
  cp vminstall/remote-chrome-backup.timer.in \
    "$snapshot/remote-chrome-backup.timer"
  : >"$snapshot/remote-chrome-backup.service.present"
  : >"$snapshot/remote-chrome-backup.timer.present"
  : >"$snapshot/backup-timer.enabled"
  : >"$snapshot/backup-timer.active"
  : >"$FAKE_COMMAND_LOG"
  vm_rollback_release releases/v1.0.0 "$snapshot" "$candidate"
  grep -Fq 'systemctl <enable remote-chrome-backup.timer>' \
    "$FAKE_COMMAND_LOG" &&
    grep -Fq 'systemctl <start remote-chrome-backup.timer>' \
      "$FAKE_COMMAND_LOG" ||
    fail 'activation rollback must restore prior timer enabled and active state'
  [[ -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service &&
     -f $REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer ]] ||
    fail 'activation rollback must restore prior backup unit files'
}

backup_timer_empty_schedule_without_prior_succeeds() {
  setup_fixture "$FUNCNAME"
  BACKUP_SCHEDULE=
  export FAKE_SYSTEMCTL_DISABLE_ABSENT=1
  vm_activate_backup_timer ||
    fail 'empty schedule without a prior timer must be a successful no-op'
  unset FAKE_SYSTEMCTL_DISABLE_ABSENT
}

backup_timer_schedule_removal_matrix() {
  local timer_case service timer disable_expected
  for timer_case in service-only timer-only disabled-pair enabled-active; do
    setup_fixture "$FUNCNAME-$timer_case"
    service="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.service"
    timer="$REMOTE_CHROME_SYSTEMD_ROOT/remote-chrome-backup.timer"
    disable_expected=1
    case "$timer_case" in
      service-only)
        : >"$service"
        disable_expected=0
        export FAKE_SYSTEMCTL_DISABLE_ABSENT=1
        ;;
      timer-only)
        : >"$timer"
        ;;
      disabled-pair)
        : >"$service"
        : >"$timer"
        ;;
      enabled-active)
        : >"$service"
        : >"$timer"
        : >"$FAKE_SYSTEMD_STATE/backup-timer.enabled"
        : >"$FAKE_SYSTEMD_STATE/backup-timer.active"
        ;;
    esac
    BACKUP_SCHEDULE=
    vm_activate_backup_timer ||
      fail "schedule removal must handle $timer_case timer state"
    [[ ! -e $service && ! -e $timer ]] ||
      fail "schedule removal must remove $timer_case unit files"
    if ((disable_expected)); then
      grep -Fq 'systemctl <disable --now remote-chrome-backup.timer>' \
        "$FAKE_COMMAND_LOG" ||
        fail "schedule removal must disable $timer_case timer state"
    else
      ! grep -Fq 'systemctl <disable --now remote-chrome-backup.timer>' \
        "$FAKE_COMMAND_LOG" ||
        fail 'service-only stale state must skip absent timer disable'
    fi
    grep -Fq 'systemctl <daemon-reload>' "$FAKE_COMMAND_LOG" ||
      fail "schedule removal must daemon-reload after $timer_case cleanup"
  done
}

management_dispatch_uses_backup_contract() {
  grep -Fq 'release activate backup management' vminstall/remote-chrome ||
    fail 'installed CLI must source the backup library before management'
  local backup_body restore_body update_body uninstall_body
  backup_body=$(declare -f vm_management_backup)
  restore_body=$(declare -f vm_management_restore)
  update_body=$(declare -f vm_management_update)
  uninstall_body=$(declare -f vm_management_uninstall)
  grep -Fq 'gs://$GCS_BUCKET/remote-chrome' <<<"$backup_body" ||
    fail 'backup CLI must use the configured default GCS prefix'
  grep -Fq '*.manifest' <<<"$restore_body" ||
    fail 'restore CLI must require one exact manifest URI'
  grep -Fq 'vm_with_maintenance_lock vm_management_update_locked' \
    <<<"$update_body" ||
    fail 'update must share the maintenance lock'
  grep -Fq 'vm_with_maintenance_lock vm_management_uninstall_locked' \
    <<<"$uninstall_body" ||
    fail 'uninstall must share the maintenance lock'
}

for test_name in "${required_tests[@]}"; do
  "$test_name"
  printf 'ok - %s\n' "$test_name"
done

printf 'PASS: VM quiesced GCS backup and transactional restore contracts\n'
