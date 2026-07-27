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
staging_root="$repo_dir/.release-staging"
archive_name="remotechromemcp-${version}.tar.gz"
checksum_name="${archive_name}.sha256"
archive="$dist_dir/$archive_name"
checksum="$dist_dir/$checksum_name"
tag_ref="refs/tags/${version}"

[[ -x /usr/bin/flock ]] || {
  printf 'Trusted publication lock is unavailable: /usr/bin/flock\n' >&2
  exit 1
}
exec {publication_lock_fd}<"$repo_dir" || {
  printf 'Unable to open repository publication lock\n' >&2
  exit 1
}
/usr/bin/flock -x "$publication_lock_fd" || {
  printf 'Unable to acquire repository publication lock\n' >&2
  exit 1
}

validate_release_source() {
  [[ -z $(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all) ]] || {
    printf 'Working tree must be clean, including untracked files, before packaging\n' >&2
    return 1
  }
  git -C "$repo_dir" show-ref --verify --quiet "$tag_ref" || {
    printf 'Release tag does not exist: %s\n' "$version" >&2
    return 1
  }
  local tag_commit head_commit
  tag_commit="$(git -C "$repo_dir" rev-parse --verify "${tag_ref}^{commit}")" || {
    printf 'Release tag does not resolve to a commit: %s\n' "$version" >&2
    return 1
  }
  head_commit="$(git -C "$repo_dir" rev-parse --verify HEAD)" || return 1
  [[ $tag_commit == "$head_commit" ]] || {
    printf 'Release tag %s does not bind the current commit\n' "$version" >&2
    return 1
  }
}

validate_staging_directory() {
  local candidate=$1 expected_device=$2
  [[ -d $candidate && ! -L $candidate ]] || return 1
  [[ $(/usr/bin/stat -c '%u' -- "$candidate") == "$EUID" ]] || return 1
  [[ $(/usr/bin/stat -c '%d' -- "$candidate") == "$expected_device" ]]
}

recover_staging_root() {
  local repo_device entry entry_name entry_metadata metadata_output
  repo_device=$(/usr/bin/stat -c '%d' -- "$repo_dir") || return 1
  if [[ -e $staging_root || -L $staging_root ]]; then
    validate_staging_directory "$staging_root" "$repo_device" || {
      printf 'Release staging namespace is unsafe: %s\n' "$staging_root" >&2
      return 1
    }
  else
    /usr/bin/mkdir -m 0700 -- "$staging_root" || return 1
  fi
  /usr/bin/chmod 0700 -- "$staging_root" || return 1

  shopt -s nullglob dotglob
  local entries=("$staging_root"/*)
  shopt -u nullglob dotglob
  for entry in "${entries[@]}"; do
    entry_name=${entry##*/}
    [[ $entry_name =~ ^package-v[0-9]+\.[0-9]+\.[0-9]+\.[A-Za-z0-9]{6}$ ]] ||
      {
        printf 'Unexpected release staging entry requires review: %s\n' \
          "$entry" >&2
        return 1
      }
    validate_staging_directory "$entry" "$repo_device" || {
      printf 'Release staging residue is unsafe: %s\n' "$entry" >&2
      return 1
    }
    metadata_output=$(
      /usr/bin/find -P "$entry" -xdev \
        -exec /usr/bin/stat -c '%d:%u' -- {} \;
    ) || return 1
    while IFS= read -r entry_metadata; do
      [[ -n $entry_metadata &&
         $entry_metadata == "$repo_device:$EUID" ]] || {
        printf 'Release staging residue has unsafe ownership or device: %s\n' \
          "$entry" >&2
        return 1
      }
    done <<<"$metadata_output"
    /usr/bin/rm -rf --one-file-system -- "$entry" || return 1
  done
}

recover_staging_root
validate_release_source

repo_device=$(/usr/bin/stat -c '%d' -- "$repo_dir")
if [[ -e $dist_dir || -L $dist_dir ]]; then
  validate_staging_directory "$dist_dir" "$repo_device" || {
    printf 'Release output directory is unsafe: %s\n' "$dist_dir" >&2
    exit 1
  }
else
  /usr/bin/mkdir -m 0700 -- "$dist_dir"
fi
stage="$(/usr/bin/mktemp -d "$staging_root/package-${version}.XXXXXX")"
generated="$stage/generated"
staged_dist="$stage/dist"
stage_archive="$generated/$archive_name"
stage_checksum="$generated/$checksum_name"
/usr/bin/mkdir -m 0700 -- "$generated"

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [[ -n ${stage:-} &&
        $stage == "$staging_root"/package-"$version".?????? &&
        -d $stage &&
        ! -L $stage ]]; then
    /usr/bin/rm -rf --one-file-system -- "$stage"
  fi
  exit "$status"
}

package_signal() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

publish_dist_exchange() {
  (
    unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE \
      PYTHONWARNINGS PYTHONBREAKPOINT PYTHONSAFEPATH
    cd /
    /usr/bin/python3 -I -S - "$staged_dist" "$dist_dir" <<'PY'
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
  )
}

verify_published_pair() {
  [[ -f $archive && ! -L $archive &&
     -f $checksum && ! -L $checksum ]] || return 1
  (cd "$dist_dir" && sha256sum -c "$checksum_name") >/dev/null ||
    return 1
  cmp -s -- "$archive" "$stage_archive" &&
    cmp -s -- "$checksum" "$stage_checksum"
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

validate_release_source

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
verify_published_pair || {
  printf 'Published release pair failed verification: %s\n' "$version" >&2
  exit 1
}

printf '%s\n%s\n' "$archive" "$checksum"
