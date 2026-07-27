#!/usr/bin/env bash

vm_validate_release_ref() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

vm_release_dir() {
  vm_validate_release_ref "${SELECTED_VERSION:-}" || return 1
  printf '%s/releases/%s' "$REMOTE_CHROME_INSTALL_ROOT" "$SELECTED_VERSION"
}

vm_validate_archive() {
  local archive=$1 validator
  validator="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
  dash "$validator" --validate-archive "$archive"
}

vm_validate_checksum_manifest() {
  local manifest=$1 expected_archive=$2 line hash
  [[ -f $manifest ]] || return 1
  [[ $(awk 'END { print NR }' "$manifest") == 1 ]] || return 1
  IFS= read -r line <"$manifest" || return 1
  hash=${line%% *}
  [[ $line == "$hash  $expected_archive" && ${#hash} -eq 64 ]] ||
    return 1
  [[ $hash != *[!0123456789abcdefABCDEF]* ]]
}

vm_verify_pinned_release() {
  local archive=$1 archive_dir archive_name checksum_name
  archive_dir=$(cd "$(dirname "$archive")" && pwd -P) || return 1
  archive_name=${archive##*/}
  checksum_name="remotechromemcp-${SELECTED_VERSION}.tar.gz.sha256"
  [[ $archive_name == "remotechromemcp-${SELECTED_VERSION}.tar.gz" ]] ||
    return 1
  [[ -f "$archive_dir/$checksum_name" ]] || return 1
  vm_validate_checksum_manifest \
    "$archive_dir/$checksum_name" "$archive_name" || return 1
  (
    cd "$archive_dir"
    sha256sum -c "$checksum_name"
  )
}

vm_mark_unpinned_release() {
  vm_log 'WARNING: master release is unpinned'
  vm_log_command release-verification unpinned
}

vm_cleanup_staging() {
  local staging=$1 releases_root expected
  releases_root="$REMOTE_CHROME_INSTALL_ROOT/releases"
  expected="$releases_root/.staging-${SELECTED_VERSION}-$$"
  [[ $staging == "$expected" && $staging != "$releases_root" &&
     ! -L $staging ]] || return 1
  vm_require_confined_destination "$staging" || return 1
  rm -rf -- "$staging"
}

vm_verify_release() {
  local staging=${1:-${STAGED_RELEASE_DIR:-}}
  [[ -n $staging && -d $staging && ! -L $staging ]] || return 1
  [[ -f "$staging/compose.yaml" &&
     -f "$staging/vminstall/compose.vm.yaml" &&
     -f "$staging/vminstall/remote-chrome" &&
     -x "$staging/vminstall/remote-chrome" &&
     -f "$staging/vminstall/remote-chrome-backup.service.in" &&
     -f "$staging/vminstall/remote-chrome-backup.timer.in" &&
     -f "$staging/vminstall/lib/backup.sh" ]]
}

vm_stage_release() {
  local archive=$1 releases_root staging
  vm_validate_release_ref "${SELECTED_VERSION:-}" || return 1
  [[ -f $archive && ! -L $archive ]] || return 1

  if [[ $SELECTED_VERSION != master ]]; then
    vm_verify_pinned_release "$archive" || return 1
  fi
  vm_validate_archive "$archive" || return 1
  if [[ $SELECTED_VERSION == master ]]; then
    vm_mark_unpinned_release || return 1
  fi

  releases_root="$REMOTE_CHROME_INSTALL_ROOT/releases"
  [[ ! -L $releases_root ]] || return 1
  vm_require_confined_destination "$releases_root" || return 1
  install -d -m 0755 "$releases_root"
  staging="$releases_root/.staging-${SELECTED_VERSION}-$$"
  [[ ! -e $staging && ! -L $staging ]] || return 1
  vm_require_confined_destination "$staging" || return 1
  install -d -m 0755 "$staging"

  vm_require_confined_destination "$staging" || return 1
  if ! tar --extract --gzip --file "$archive" --directory "$staging" \
    --strip-components=1 --no-same-owner --no-same-permissions; then
    vm_cleanup_staging "$staging"
    return 1
  fi
  if ! vm_verify_release "$staging"; then
    vm_cleanup_staging "$staging"
    return 1
  fi
  STAGED_RELEASE_DIR=$staging
}
