#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2
  exit 2
}

export LC_ALL=C
export TZ=UTC
umask 077

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_dir/dist"
archive_name="remotechromemcp-${version}.tar.gz"
checksum_name="${archive_name}.sha256"
archive="$dist_dir/$archive_name"
checksum="$dist_dir/$checksum_name"
tag_ref="refs/tags/${version}"

[[ -z $(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all) ]] || {
  printf 'Working tree must be clean, including untracked files, before packaging\n' >&2
  exit 1
}
git -C "$repo_dir" show-ref --verify --quiet "$tag_ref" || {
  printf 'Release tag does not exist: %s\n' "$version" >&2
  exit 1
}
tag_commit="$(git -C "$repo_dir" rev-parse --verify "${tag_ref}^{commit}")" || {
  printf 'Release tag does not resolve to a commit: %s\n' "$version" >&2
  exit 1
}
head_commit="$(git -C "$repo_dir" rev-parse --verify HEAD)"
[[ $tag_commit == "$head_commit" ]] || {
  printf 'Release tag %s does not bind the current commit\n' "$version" >&2
  exit 1
}

mkdir -p "$dist_dir"
stage="$(mktemp -d "$repo_dir/.remotechromemcp-package-${version}.XXXXXX")"
generated="$stage/generated"
staged_dist="$stage/dist"
stage_archive="$generated/$archive_name"
stage_checksum="$generated/$checksum_name"
mkdir -p "$generated"

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  rm -rf -- "$stage"
  exit "$status"
}

package_signal() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

publish_dist_exchange() {
  /usr/bin/python3 - "$staged_dist" "$dist_dir" <<'PY'
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
]
renameat2.restype = ctypes.c_int
at_fdcwd = -100
rename_exchange = 2
result = renameat2(
    at_fdcwd,
    os.fsencode(sys.argv[1]),
    at_fdcwd,
    os.fsencode(sys.argv[2]),
    rename_exchange,
)
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
PY
}

trap cleanup EXIT
trap 'package_signal 129' HUP
trap 'package_signal 130' INT
trap 'package_signal 143' TERM

git -C "$repo_dir" archive \
  --format=tar.gz \
  --prefix="remotechromemcp-${version}/" \
  --output="$stage_archive" \
  "$tag_ref"
(cd "$generated" && sha256sum "$archive_name" >"$checksum_name")
(cd "$generated" && sha256sum -c "$checksum_name") >/dev/null
first_member="$(tar -tzf "$stage_archive" | sed -n '1p')"
[[ $first_member == "remotechromemcp-${version}/"* ]] || {
    printf 'Release archive has an invalid prefix\n' >&2
    exit 1
  }

if [[ -e $archive || -e $checksum ]]; then
  [[ -f $archive && ! -L $archive && -f $checksum && ! -L $checksum ]] || {
    printf 'Existing release output is incomplete or unsafe: %s\n' "$version" >&2
    exit 1
  }
  (cd "$dist_dir" && sha256sum -c "$checksum_name") >/dev/null || {
    printf 'Existing release output has an invalid checksum: %s\n' "$version" >&2
    exit 1
  }
  if cmp -s -- "$archive" "$stage_archive" &&
     cmp -s -- "$checksum" "$stage_checksum"; then
    printf '%s\n%s\n' "$archive" "$checksum"
    exit 0
  fi
  printf 'Existing release output differs from immutable tag: %s\n' \
    "$version" >&2
  exit 1
fi

mkdir -p "$staged_dist"
cp -a -- "$dist_dir/." "$staged_dist/"
cp -- "$stage_archive" "$staged_dist/$archive_name"
cp -- "$stage_checksum" "$staged_dist/$checksum_name"
(cd "$staged_dist" && sha256sum -c "$checksum_name") >/dev/null
publish_dist_exchange

printf '%s\n%s\n' "$archive" "$checksum"
