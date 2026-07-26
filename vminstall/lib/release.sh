#!/usr/bin/env bash

vm_validate_release_ref() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

vm_release_dir() {
  vm_validate_release_ref "${SELECTED_VERSION:-}" || return 1
  printf '%s/releases/%s' "$REMOTE_CHROME_INSTALL_ROOT" "$SELECTED_VERSION"
}

vm_archive_path_is_safe() {
  local path=${1%/}
  [[ -n $path && $path != /* && $path != *$'\n'* ]] || return 1
  [[ ! $path =~ (^|/)\.\.(/|$) ]]
}

vm_archive_link_is_safe() {
  local target=${1%/}
  [[ -n $target && $target != /* && $target != *$'\n'* ]] || return 1
  [[ ! $target =~ (^|/)\.\.(/|$) ]]
}

vm_validate_archive() {
  local archive=$1 listing verbose name line type target
  listing=$(tar --list --gzip --file "$archive" --quoting-style=escape) ||
    return 1
  while IFS= read -r name; do
    vm_archive_path_is_safe "$name" || return 1
  done <<<"$listing"

  verbose=$(
    tar --list --verbose --gzip --file "$archive" --quoting-style=escape
  ) || return 1
  while IFS= read -r line; do
    type=${line:0:1}
    case "$type" in
      b|c) return 1 ;;
      l)
        [[ $line == *' -> '* ]] || return 1
        target=${line##* -> }
        vm_archive_link_is_safe "$target" || return 1
        ;;
      h)
        [[ $line == *' link to '* ]] || return 1
        target=${line##* link to }
        vm_archive_link_is_safe "$target" || return 1
        ;;
    esac
  done <<<"$verbose"
}

vm_verify_pinned_release() {
  local archive=$1 archive_dir archive_name checksum_name
  archive_dir=$(cd "$(dirname "$archive")" && pwd -P) || return 1
  archive_name=${archive##*/}
  checksum_name="remotechromemcp-${SELECTED_VERSION}.tar.gz.sha256"
  [[ $archive_name == "remotechromemcp-${SELECTED_VERSION}.tar.gz" ]] ||
    return 1
  [[ -f "$archive_dir/$checksum_name" ]] || return 1
  (
    cd "$archive_dir"
    sha256sum -c "$checksum_name"
  )
}

vm_mark_unpinned_release() {
  local install_env pending
  install_env="$REMOTE_CHROME_CONFIG_ROOT/install.env"
  pending="$install_env.pending.$$"
  install -d -m 0755 "$REMOTE_CHROME_CONFIG_ROOT"
  printf '%s\n' 'RELEASE_VERIFICATION=unpinned' >"$pending"
  mv -f -- "$pending" "$install_env"
  vm_log 'WARNING: master release is unpinned'
  vm_log_command release-verification unpinned
}

vm_cleanup_staging() {
  local staging=$1 releases_root expected
  releases_root="$REMOTE_CHROME_INSTALL_ROOT/releases"
  expected="$releases_root/.staging-${SELECTED_VERSION}-$$"
  [[ $staging == "$expected" && $staging != "$releases_root" &&
     ! -L $staging ]] || return 1
  rm -rf -- "$staging"
}

vm_verify_release() {
  local staging=${1:-${STAGED_RELEASE_DIR:-}}
  [[ -n $staging && -d $staging && ! -L $staging ]] || return 1
  [[ -f "$staging/compose.yaml" &&
     -f "$staging/vminstall/compose.vm.yaml" ]]
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
  install -d -m 0755 "$releases_root"
  staging="$releases_root/.staging-${SELECTED_VERSION}-$$"
  [[ ! -e $staging && ! -L $staging ]] || return 1
  install -d -m 0755 "$staging"

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
