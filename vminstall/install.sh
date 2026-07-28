#!/bin/sh
set -eu

bootstrap_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

bootstrap_archive_path_is_safe() {
  archive_member=$1
  [ -n "$archive_member" ] || return 1
  case "$archive_member" in
    /*|*\\*) return 1 ;;
  esac

  old_ifs=$IFS
  IFS=/
  set -f
  set -- $archive_member
  set +f
  IFS=$old_ifs
  for component do
    [ "$component" != .. ] || return 1
  done
}

bootstrap_validate_archive() {
  archive_to_validate=$1
  archive_names=$(
    LC_ALL=C tar --list --gzip --file "$archive_to_validate" \
      --quoting-style=escape
  ) || return 1
  while IFS= read -r archive_member; do
    bootstrap_archive_path_is_safe "$archive_member" || return 1
  done <<EOF
$archive_names
EOF

  archive_types=$(
    LC_ALL=C tar --list --verbose --gzip --file "$archive_to_validate" \
      --quoting-style=escape
  ) || return 1
  while IFS= read -r archive_line; do
    archive_type=${archive_line%"${archive_line#?}"}
    case "$archive_type" in
      -|d) ;;
      *) return 1 ;;
    esac
  done <<EOF
$archive_types
EOF
}

bootstrap_validate_checksum_manifest() {
  manifest=$1
  expected_archive=$2
  [ -f "$manifest" ] || return 1
  awk 'END { exit NR == 1 ? 0 : 1 }' "$manifest" || return 1
  IFS= read -r manifest_line <"$manifest" || return 1
  manifest_hash=${manifest_line%% *}
  [ "$manifest_line" = "$manifest_hash  $expected_archive" ] || return 1
  [ "${#manifest_hash}" -eq 64 ] || return 1
  case "$manifest_hash" in
    *[!0123456789abcdefABCDEF]*) return 1 ;;
  esac
}

if [ "${1:-}" = --validate-archive ]; then
  [ "$#" -eq 2 ] ||
    bootstrap_fail '--validate-archive requires exactly one archive'
  bootstrap_validate_archive "$2" ||
    bootstrap_fail 'release archive contains an unsafe member'
  exit 0
fi

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

bootstrap_usage() {
  printf '%s\n' \
    'Usage: install.sh [--version REF] [installer options]' \
    'Installer options include optional --domain, required --email and --data-dir,' \
    'plus --enable-gcs-backup and --non-interactive.'
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

if [ -n "${REMOTE_CHROME_FAKE_BIN:-}" ]; then
  [ -d "$REMOTE_CHROME_FAKE_BIN" ] ||
    bootstrap_fail 'REMOTE_CHROME_FAKE_BIN must name a directory'
  PATH=$REMOTE_CHROME_FAKE_BIN:$PATH
  export PATH
fi

case "$selected_ref" in
  master)
    archive_name=remotechromemcp-master.tar.gz
    archive_url=https://github.com/eladrave/remotechromemcp/archive/refs/heads/master.tar.gz
    printf '%s\n' '[remote-chrome] Installing unpinned master archive'
    ;;
  *)
    archive_name=remotechromemcp-$selected_ref.tar.gz
    archive_url=https://github.com/eladrave/remotechromemcp/releases/download/$selected_ref/$archive_name
    checksum_name=$archive_name.sha256
    checksum_url=$archive_url.sha256
    ;;
esac

archive_file=$tmp_dir/$archive_name
curl -fsSL "$archive_url" -o "$archive_file"

if [ "$selected_ref" != master ]; then
  checksum_file=$tmp_dir/$checksum_name
  curl -fsSL "$checksum_url" -o "$checksum_file"
  bootstrap_validate_checksum_manifest "$checksum_file" "$archive_name" ||
    bootstrap_fail 'release checksum manifest is invalid'
  (
    cd "$tmp_dir"
    sha256sum -c "$checksum_name"
  )
fi

bootstrap_validate_archive "$archive_file" ||
  bootstrap_fail 'release archive contains an unsafe member'
extract_root=$tmp_dir/extracted
mkdir -p "$extract_root"
tar -xzf "$archive_file" -C "$extract_root"

set -- "$extract_root"/*
[ "$#" -eq 1 ] && [ -d "$1" ] ||
  bootstrap_fail 'release archive must contain one top-level directory'
extracted_dir=$1
[ -f "$extracted_dir/vminstall/installer-main.sh" ] ||
  bootstrap_fail 'release archive is missing vminstall/installer-main.sh'

set --
while IFS= read -r bootstrap_arg || [ -n "$bootstrap_arg" ]; do
  set -- "$@" "$bootstrap_arg"
done <"$args_file"

REMOTE_CHROME_RELEASE_ARCHIVE=$archive_file
export REMOTE_CHROME_RELEASE_ARCHIVE
bash "$extracted_dir/vminstall/installer-main.sh" "$@"
