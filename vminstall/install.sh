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
  (
    cd "$tmp_dir"
    sha256sum -c "$checksum_name"
  )
fi

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
