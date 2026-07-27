#!/usr/bin/env bash

vm_backup_event() {
  local event=$1
  [[ -n ${REMOTE_CHROME_BACKUP_LOG:-} ]] || return 0
  vm_require_management_destination "$REMOTE_CHROME_BACKUP_LOG" || return 1
  printf '%s\n' "$event" >>"$REMOTE_CHROME_BACKUP_LOG"
}

vm_backup_validate_data_root() {
  [[ -n ${REMOTE_CHROME_DATA_DIR:-} &&
     $REMOTE_CHROME_DATA_DIR == /* &&
     $REMOTE_CHROME_DATA_DIR != / &&
     -d $REMOTE_CHROME_DATA_DIR &&
     ! -L $REMOTE_CHROME_DATA_DIR ]] || return 64
  vm_require_management_destination "$REMOTE_CHROME_DATA_DIR"
}

vm_backup_validate_gcs_uri() {
  local uri=$1 bucket=${GCS_BUCKET:-}
  [[ -n $bucket &&
     ${#bucket} -ge 3 &&
     ${#bucket} -le 63 &&
     $bucket =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ &&
     $bucket != *..* &&
     $bucket != *.-* &&
     $bucket != *-.*
  ]] || return 64
  [[ ! $bucket =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ &&
     $uri == "gs://$bucket/"*
  ]] || return 64
  local object=${uri#gs://"$bucket"/} component
  [[ -n $object &&
     $object != *'//'* &&
     $object =~ ^[A-Za-z0-9._/-]+$ &&
     $object != /* &&
     $object != *\\* &&
     $object != *$'\n'* &&
     $object != *$'\r'* &&
     $object != *$'\t'* ]] || return 64
  IFS=/ read -r -a components <<<"$object"
  for component in "${components[@]}"; do
    [[ -n $component && $component != . && $component != .. ]] || return 64
  done
}

vm_backup_gcloud_path() {
  local command=/usr/bin/gcloud
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    command="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/bin/gcloud"
  fi
  [[ -f $command && ! -L $command && -x $command ]] || return 69
  printf '%s' "$command"
}

vm_backup_trusted_tool() {
  local name=$1 command
  command="/usr/bin/$name"
  if [[ -n ${REMOTE_CHROME_CANONICAL_TEST_ROOT:-} ]]; then
    command="$REMOTE_CHROME_CANONICAL_TEST_ROOT/usr/bin/$name"
  fi
  [[ -f $command && ! -L $command && -x $command ]] || return 69
  printf '%s' "$command"
}

vm_backup_gcloud_cp() {
  local source=$1 destination=$2 command
  command=$(vm_backup_gcloud_path) || return $?
  vm_run_with_timeout 310 "$command" storage cp "$source" "$destination"
}

vm_backup_unique_suffix() {
  local openssl
  openssl=$(vm_backup_trusted_tool openssl) || return $?
  vm_run_bounded "$openssl" rand -hex 6
}

vm_backup_health() {
  local phase=$1 cli="$REMOTE_CHROME_CLI_ROOT/remote-chrome"
  [[ -f $cli && ! -L $cli && -x $cli ]] || return 69
  REMOTE_CHROME_HEALTH_PHASE="$phase" vm_run_bounded "$cli" wait-ready
}

vm_backup_release_path() {
  if declare -F vm_management_release_path >/dev/null; then
    vm_management_release_path
    return
  fi
  local current="$REMOTE_CHROME_INSTALL_ROOT/current" target
  [[ -L $current ]] || return 1
  target=$(readlink "$current") || return 1
  [[ $target == releases/* &&
     $target != *..* &&
     $target != *$'\n'* ]] || return 1
  printf '%s/%s' "$REMOTE_CHROME_INSTALL_ROOT" "$target"
}

vm_backup_compose() {
  local release=$1
  shift
  vm_compose_for_release "$release" \
    "$REMOTE_CHROME_CONFIG_ROOT/compose.env" "$@"
}

vm_backup_stop_browser() {
  local release=$1 running
  vm_backup_event stop || return 1
  vm_backup_compose "$release" stop -t 30 browser || return 1
  running=$(
    vm_backup_compose "$release" \
      ps --status running --services browser
  ) || return 1
  [[ -z $running ]]
}

vm_backup_start_browser() {
  local release=$1
  vm_backup_event start || return 1
  vm_backup_compose "$release" start browser
}

vm_with_maintenance_lock() {
  vm_backup_validate_data_root || return $?
  local lock="$REMOTE_CHROME_DATA_DIR/.maintenance.lock" status=0
  vm_require_management_destination "$lock" || return 64
  exec {VM_MAINTENANCE_LOCK_FD}>"$lock" || return 73
  chmod 0600 "$lock" || {
    exec {VM_MAINTENANCE_LOCK_FD}>&-
    return 73
  }
  if ! /usr/bin/flock -n "$VM_MAINTENANCE_LOCK_FD"; then
    exec {VM_MAINTENANCE_LOCK_FD}>&-
    return 75
  fi
  vm_backup_event lock || status=$?
  if ((status == 0)); then
    "$@" || status=$?
  fi
  /usr/bin/flock -u "$VM_MAINTENANCE_LOCK_FD" || status=$?
  exec {VM_MAINTENANCE_LOCK_FD}>&-
  return "$status"
}

vm_backup_profile_locked() (
  local prefix=$1 release timestamp suffix base stage archive checksum manifest
  local chrome_version status=0 restart_required=0 tar_command sha_command
  vm_backup_validate_gcs_uri "$prefix" || return $?
  [[ -d $REMOTE_CHROME_DATA_DIR/profile &&
     ! -L $REMOTE_CHROME_DATA_DIR/profile ]] || return 66
  release=$(vm_backup_release_path) || return 69
  tar_command=$(vm_backup_trusted_tool tar) || return $?
  sha_command=$(vm_backup_trusted_tool sha256sum) || return $?
  timestamp=$(date -u +%Y%m%dT%H%M%SZ) || return 1
  suffix=$(vm_backup_unique_suffix) || return $?
  [[ $suffix =~ ^[0-9a-f]{12}$ ]] || return 1
  base="remote-chrome-profile-$timestamp-$suffix"
  stage="$REMOTE_CHROME_DATA_DIR/backups/.staging/$base.$$"
  archive="$stage/$base.tar.gz"
  checksum="$stage/$base.sha256"
  manifest="$stage/$base.manifest"
  vm_require_management_destination "$stage" || return 64
  install -d -m 0700 "$REMOTE_CHROME_DATA_DIR/backups" \
    "$REMOTE_CHROME_DATA_DIR/backups/.staging" "$stage" || return 73
  chmod 0700 "$REMOTE_CHROME_DATA_DIR/backups" \
    "$REMOTE_CHROME_DATA_DIR/backups/.staging" "$stage" || return 73

  cleanup_backup() {
    local original_status=$?
    trap - EXIT
    if ((restart_required)); then
      vm_backup_start_browser "$release" || true
      vm_backup_health health || true
    fi
    if [[ ${KEEP_LOCAL_BACKUPS:-0} != 1 ]]; then
      rm -rf -- "$stage"
    fi
    exit "$original_status"
  }
  trap cleanup_backup EXIT

  vm_backup_health pre-health || return $?
  chrome_version=$(
    vm_backup_compose "$release" \
      exec -T browser google-chrome --version
  ) || return $?
  [[ -n $chrome_version &&
     $chrome_version != *$'\n'* &&
     $chrome_version != *$'\r'* ]] || return 1
  restart_required=1
  vm_backup_stop_browser "$release" || return $?

  vm_backup_event tar || return 1
  vm_run_bounded "$tar_command" --create --gzip --file "$archive" \
    --numeric-owner --one-file-system \
    --directory "$REMOTE_CHROME_DATA_DIR" profile || return $?
  chmod 0600 "$archive" || return 1

  vm_backup_event checksum || return 1
  (
    cd "$stage"
    vm_run_bounded "$sha_command" "$base.tar.gz" >"$base.sha256"
  ) || return $?
  chmod 0600 "$checksum" || return 1
  printf '%s\n' \
    'MANIFEST_VERSION=1' \
    "TIMESTAMP_UTC=$timestamp" \
    "CHROME_VERSION=$chrome_version" \
    "ARCHIVE_NAME=$base.tar.gz" \
    "CHECKSUM_NAME=$base.sha256" \
    "SOURCE_PROFILE=$REMOTE_CHROME_DATA_DIR/profile" \
    >"$manifest" || return 1
  chmod 0600 "$manifest" || return 1

  vm_backup_event upload || return 1
  vm_backup_gcloud_cp "$archive" "$prefix/$base.tar.gz" || return $?
  vm_backup_gcloud_cp "$checksum" "$prefix/$base.sha256" || return $?
  vm_backup_gcloud_cp "$manifest" "$prefix/$base.manifest" || return $?

  vm_backup_start_browser "$release" || return $?
  vm_backup_health health || return $?
  restart_required=0
  printf '%s\n' "$prefix/$base.manifest"
  return 0
)

vm_backup_profile() {
  (($# == 1)) || return 2
  vm_with_maintenance_lock vm_backup_profile_locked "$1"
}

vm_validate_backup_archive() {
  local archive=$1 member type tar_command
  local names="$archive.names.$$" listing="$archive.listing.$$" status=0
  [[ -f $archive && ! -L $archive ]] || return 1
  tar_command=$(vm_backup_trusted_tool tar) || return $?
  vm_require_management_destination "$names" || return 64
  vm_require_management_destination "$listing" || return 64
  if ! vm_run_bounded "$tar_command" -tzf "$archive" >"$names"; then
    rm -f -- "$names" "$listing"
    return 1
  fi
  while IFS= read -r member; do
    if [[ -z $member ||
          $member == /* ||
          $member == *\\* ||
          $member == *$'\n'* ||
          $member == *$'\r'* ]]; then
      status=1
      break
    fi
    local component
    IFS=/ read -r -a components <<<"$member"
    for component in "${components[@]}"; do
      if [[ -z $component || $component == . || $component == .. ]]; then
        status=1
        break
      fi
    done
    [[ $member == profile || $member == profile/ ||
       $member == profile/* ]] || status=1
    ((status == 0)) || break
  done <"$names"
  if ((status == 0)); then
    if ! vm_run_bounded "$tar_command" -tvzf "$archive" >"$listing"; then
      status=1
    else
      while IFS= read -r type; do
        [[ ${type:0:1} == - || ${type:0:1} == d ]] || {
          status=1
          break
        }
      done <"$listing"
    fi
  fi
  rm -f -- "$names" "$listing"
  return "$status"
}

vm_parse_backup_manifest() {
  local manifest=$1
  local -a lines=()
  [[ -f $manifest && ! -L $manifest ]] || return 1
  mapfile -t lines <"$manifest" || return 1
  [[ ${#lines[@]} -eq 6 &&
     ${lines[0]} == MANIFEST_VERSION=1 &&
     ${lines[1]} == TIMESTAMP_UTC=* &&
     ${lines[2]} == CHROME_VERSION=* &&
     ${lines[3]} == ARCHIVE_NAME=* &&
     ${lines[4]} == CHECKSUM_NAME=* &&
     ${lines[5]} == SOURCE_PROFILE=* ]] || return 1
  VM_BACKUP_TIMESTAMP=${lines[1]#TIMESTAMP_UTC=}
  VM_BACKUP_CHROME_VERSION=${lines[2]#CHROME_VERSION=}
  VM_BACKUP_ARCHIVE_NAME=${lines[3]#ARCHIVE_NAME=}
  VM_BACKUP_CHECKSUM_NAME=${lines[4]#CHECKSUM_NAME=}
  VM_BACKUP_SOURCE_PROFILE=${lines[5]#SOURCE_PROFILE=}
  local base=${VM_BACKUP_ARCHIVE_NAME%.tar.gz}
  [[ $VM_BACKUP_TIMESTAMP =~ ^[0-9]{8}T[0-9]{6}Z$ &&
     -n $VM_BACKUP_CHROME_VERSION &&
     $VM_BACKUP_CHROME_VERSION != *$'\r'* &&
     $VM_BACKUP_CHROME_VERSION != *$'\n'* &&
     $VM_BACKUP_ARCHIVE_NAME =~ ^remote-chrome-profile-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\.tar\.gz$ &&
     $VM_BACKUP_CHECKSUM_NAME == "$base.sha256" &&
     $VM_BACKUP_SOURCE_PROFILE == "$REMOTE_CHROME_DATA_DIR/profile" ]] ||
    return 1
}

vm_verify_backup_checksum() {
  local directory=$1 archive_name=$2 checksum_name=$3
  local checksum_line expected actual output="$directory/.checksum.$$"
  local sha_command
  sha_command=$(vm_backup_trusted_tool sha256sum) || return $?
  vm_require_management_destination "$output" || return 64
  [[ -f $directory/$checksum_name &&
     ! -L $directory/$checksum_name ]] || return 1
  mapfile -t checksum_lines <"$directory/$checksum_name" || return 1
  [[ ${#checksum_lines[@]} -eq 1 ]] || return 1
  checksum_line=${checksum_lines[0]}
  [[ $checksum_line =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([^/]+)$ ]] ||
    return 1
  expected=${BASH_REMATCH[1]}
  [[ ${BASH_REMATCH[2]} == "$archive_name" ]] || return 1
  if ! (
    cd "$directory"
    vm_run_bounded "$sha_command" "$archive_name"
  ) >"$output"; then
    rm -f -- "$output"
    return 1
  fi
  IFS=' ' read -r actual _ <"$output" || {
    rm -f -- "$output"
    return 1
  }
  rm -f -- "$output"
  [[ $actual == "$expected" ]]
}

vm_restore_profile_locked() (
  local manifest_uri=$1 release timestamp suffix restore_root archive checksum
  local requested_manifest requested_identity requested_timestamp
  local manifest new_profile rollback failed status=0 preserved=0 completed=0
  local restart_required=0
  local profile_owner profile_mode tar_command chown_command
  vm_backup_validate_gcs_uri "$manifest_uri" || return $?
  [[ $manifest_uri == *.manifest ]] || return 64
  requested_manifest=${manifest_uri##*/}
  [[ $requested_manifest =~ ^(remote-chrome-profile-([0-9]{8}T[0-9]{6}Z)-[0-9a-f]{12})\.manifest$ ]] ||
    return 64
  requested_identity=${BASH_REMATCH[1]}
  requested_timestamp=${BASH_REMATCH[2]}
  [[ -d $REMOTE_CHROME_DATA_DIR/profile &&
     ! -L $REMOTE_CHROME_DATA_DIR/profile ]] || return 66
  profile_owner=$(stat -c '%u:%g' "$REMOTE_CHROME_DATA_DIR/profile") ||
    return 1
  profile_mode=$(stat -c '%a' "$REMOTE_CHROME_DATA_DIR/profile") ||
    return 1
  [[ $profile_owner =~ ^[0-9]+:[0-9]+$ &&
     $profile_mode =~ ^[0-7]{3,4}$ ]] || return 1
  release=$(vm_backup_release_path) || return 69
  tar_command=$(vm_backup_trusted_tool tar) || return $?
  chown_command=$(vm_backup_trusted_tool chown) || return $?
  timestamp=$(date -u +%Y%m%dT%H%M%SZ) || return 1
  suffix=$(vm_backup_unique_suffix) || return $?
  [[ $suffix =~ ^[0-9a-f]{12}$ ]] || return 1
  restore_root="$REMOTE_CHROME_DATA_DIR/restore-staging/restore-$timestamp-$suffix.$$"
  manifest="$restore_root/$requested_manifest"
  new_profile="$restore_root/profile-new"
  rollback="$REMOTE_CHROME_DATA_DIR/profile.rollback-$timestamp-$suffix"
  failed="$REMOTE_CHROME_DATA_DIR/profile.failed-$timestamp-$suffix"
  vm_require_management_destination "$restore_root" || return 64
  vm_require_management_destination "$rollback" || return 64
  vm_require_management_destination "$failed" || return 64
  install -d -m 0700 "$REMOTE_CHROME_DATA_DIR/restore-staging" \
    "$restore_root" || return 73
  chmod 0700 "$REMOTE_CHROME_DATA_DIR/restore-staging" \
    "$restore_root" || return 73

  cleanup_restore() {
    local original_status=$?
    trap - EXIT
    if ((preserved && ! completed)); then
      report_restore_recovery() {
        printf '%s\n' \
          'ERROR: rollback could not be confirmed; recovery retained:' \
          "  current profile: $REMOTE_CHROME_DATA_DIR/profile" \
          "  failed candidate: $failed" \
          "  rollback profile: $rollback" \
          "  restore staging: $restore_root" >&2
      }
      if ! vm_backup_stop_browser "$release"; then
        report_restore_recovery
        vm_backup_start_browser "$release" || true
        vm_backup_health health || true
        exit 70
      fi
      if [[ -e $REMOTE_CHROME_DATA_DIR/profile ||
            -L $REMOTE_CHROME_DATA_DIR/profile ]]; then
        if ! mv -- "$REMOTE_CHROME_DATA_DIR/profile" "$failed"; then
          vm_backup_start_browser "$release" || true
          vm_backup_health health || true
          report_restore_recovery
          exit 70
        fi
      fi
      if [[ -d $rollback && ! -L $rollback ]]; then
        if ! mv -- "$rollback" "$REMOTE_CHROME_DATA_DIR/profile"; then
          if [[ ! -e $REMOTE_CHROME_DATA_DIR/profile &&
                ! -L $REMOTE_CHROME_DATA_DIR/profile &&
                -d $failed && ! -L $failed ]]; then
            mv -- "$failed" "$REMOTE_CHROME_DATA_DIR/profile" || true
          fi
          vm_backup_start_browser "$release" || true
          vm_backup_health health || true
          report_restore_recovery
          exit 70
        fi
      else
        if [[ ! -e $REMOTE_CHROME_DATA_DIR/profile &&
              ! -L $REMOTE_CHROME_DATA_DIR/profile &&
              -d $failed && ! -L $failed ]]; then
          mv -- "$failed" "$REMOTE_CHROME_DATA_DIR/profile" || true
        fi
        vm_backup_start_browser "$release" || true
        vm_backup_health health || true
        report_restore_recovery
        exit 70
      fi
      if ! vm_backup_start_browser "$release"; then
        report_restore_recovery
        exit 70
      fi
      if ! vm_backup_health health; then
        report_restore_recovery
        exit 70
      fi
      if ! rm -rf -- "$failed" "$restore_root"; then
        report_restore_recovery
        exit 70
      fi
    elif ((! completed)); then
      if ((restart_required)); then
        vm_backup_start_browser "$release" || true
        vm_backup_health health || true
      fi
      rm -rf -- "$restore_root"
    fi
    exit "$original_status"
  }
  trap cleanup_restore EXIT

  vm_backup_event download || return 1
  vm_backup_gcloud_cp "$manifest_uri" "$manifest" || return $?
  vm_parse_backup_manifest "$manifest" || return 1
  [[ $VM_BACKUP_TIMESTAMP == "$requested_timestamp" &&
     $VM_BACKUP_ARCHIVE_NAME == "$requested_identity.tar.gz" &&
     $VM_BACKUP_CHECKSUM_NAME == "$requested_identity.sha256" ]] || return 1
  archive="$restore_root/$VM_BACKUP_ARCHIVE_NAME"
  checksum="$restore_root/$VM_BACKUP_CHECKSUM_NAME"
  local object_prefix=${manifest_uri%/*}
  vm_backup_gcloud_cp \
    "$object_prefix/$VM_BACKUP_CHECKSUM_NAME" "$checksum" || return $?
  vm_backup_gcloud_cp \
    "$object_prefix/$VM_BACKUP_ARCHIVE_NAME" "$archive" || return $?
  chmod 0600 "$manifest" "$checksum" "$archive" || return 1

  vm_backup_event validate || return 1
  vm_verify_backup_checksum "$restore_root" \
    "$VM_BACKUP_ARCHIVE_NAME" "$VM_BACKUP_CHECKSUM_NAME" || return 1
  vm_validate_backup_archive "$archive" || return 1
  vm_backup_health pre-health || return $?
  restart_required=1
  vm_backup_stop_browser "$release" || return $?

  vm_backup_event preserve || return 1
  mv -- "$REMOTE_CHROME_DATA_DIR/profile" "$rollback" || return 1
  preserved=1
  install -d -m 0700 "$new_profile" || return 1
  vm_backup_event extract || return 1
  vm_run_bounded "$tar_command" --extract --gzip --file "$archive" \
    --directory "$new_profile" --strip-components=1 \
    --no-same-owner --no-same-permissions || return $?
  chmod "$profile_mode" "$new_profile" || return 1
  vm_backup_event chown || return 1
  vm_run_bounded "$chown_command" -R "$profile_owner" "$new_profile" || return $?
  mv -- "$new_profile" "$REMOTE_CHROME_DATA_DIR/profile" || return 1
  vm_backup_start_browser "$release" || return $?
  vm_backup_health health || return $?
  restart_required=0

  completed=1
  rm -rf -- "$restore_root" || return $?
  rm -rf -- "$rollback" || return $?
  return 0
)

vm_restore_profile() {
  (($# == 1)) || return 2
  vm_with_maintenance_lock vm_restore_profile_locked "$1"
}
