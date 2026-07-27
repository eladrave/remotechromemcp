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

package_residue_is_disposable() {
  local entry=$1 entry_name residue_version residue_archive residue_checksum
  local generated_dir generated_archive generated_checksum candidate_hash
  entry_name=${entry##*/}
  [[ $entry_name =~ ^package-(v[0-9]+\.[0-9]+\.[0-9]+)\.[A-Za-z0-9]{6}$ ]] ||
    return 1
  residue_version=${BASH_REMATCH[1]}
  residue_archive="$dist_dir/remotechromemcp-${residue_version}.tar.gz"
  residue_checksum="${residue_archive}.sha256"
  generated_dir="$entry/generated"
  generated_archive="$generated_dir/remotechromemcp-${residue_version}.tar.gz"
  generated_checksum="${generated_archive}.sha256"

  [[ -d $generated_dir && ! -L $generated_dir &&
     -d $entry/dist && ! -L $entry/dist &&
     -f $generated_archive && ! -L $generated_archive &&
     -f $generated_checksum && ! -L $generated_checksum ]] || return 1
  candidate_hash=$(
    /usr/bin/sha256sum "$generated_archive" | /usr/bin/cut -d' ' -f1
  ) ||
    return 1
  [[ $candidate_hash =~ ^[0-9a-f]{64}$ ]] || return 1
  /usr/bin/cmp -s -- "$generated_checksum" <(
    printf '%s  %s\n' "$candidate_hash" \
      "remotechromemcp-${residue_version}.tar.gz"
  ) || return 1
  (
    cd "$generated_dir"
    /usr/bin/sha256sum -c "${generated_checksum##*/}"
  ) >/dev/null || return 1

  if [[ ! -e $residue_archive && ! -L $residue_archive &&
        ! -e $residue_checksum && ! -L $residue_checksum ]]; then
    return 0
  fi
  [[ -f $residue_archive && ! -L $residue_archive &&
     -f $residue_checksum && ! -L $residue_checksum ]] || return 1
  /usr/bin/cmp -s -- "$residue_archive" "$generated_archive" || return 1
  /usr/bin/cmp -s -- "$residue_checksum" "$generated_checksum" || return 1
  (
    cd "$dist_dir"
    /usr/bin/sha256sum -c "${residue_checksum##*/}"
  ) >/dev/null
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
    if [[ ! $entry_name =~ ^(package|recovery)-v[0-9]+\.[0-9]+\.[0-9]+\.[A-Za-z0-9]{6}$ ]]; then
      printf 'Unexpected release staging entry requires review: %s\n' \
        "$entry" >&2
      return 1
    fi
    validate_staging_directory "$entry" "$repo_device" || {
      printf 'Release staging residue is unsafe: %s\n' "$entry" >&2
      return 1
    }
    if [[ $entry_name == recovery-* ]]; then
      printf 'Retained release recovery requires manual review: %s\n' \
        "$entry" >&2
      printf 'Do not delete this directory until dist and its recovery copy are verified.\n' \
        >&2
      return 1
    fi
    if [[ -e $entry/RECOVERY_REQUIRED ||
          -L $entry/RECOVERY_REQUIRED ]]; then
      printf 'Retained release recovery requires manual review: %s\n' \
        "$entry" >&2
      printf 'Do not delete this directory until dist and its recovery copy are verified.\n' \
        >&2
      return 1
    fi
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
    package_residue_is_disposable "$entry" || {
      printf 'Release staging residue is required for manual recovery: %s\n' \
        "$entry" >&2
      printf 'The public pair is absent, incomplete, or invalid; do not delete the residue.\n' \
        >&2
      return 1
    }
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
set_stage_paths() {
  generated="$stage/generated"
  staged_dist="$stage/dist"
  stage_archive="$generated/$archive_name"
  stage_checksum="$generated/$checksum_name"
}
set_stage_paths
/usr/bin/mkdir -m 0700 -- "$generated"
retain_stage=0

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [[ ${retain_stage:-0} == 0 && -n ${stage:-} &&
        -d $stage && ! -L $stage ]]; then
    case "$stage" in
      "$staging_root"/package-"$version".??????|\
      "$staging_root"/recovery-"$version".??????)
        /usr/bin/rm -rf --one-file-system -- "$stage"
        ;;
    esac
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

directory_identity() {
  /usr/bin/stat -c '%d:%i' -- "$1"
}

dist_tree_digest() {
  (
    unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE \
      PYTHONWARNINGS PYTHONBREAKPOINT PYTHONSAFEPATH
    cd /
    /usr/bin/python3 -I -S - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = os.fsencode(os.path.abspath(sys.argv[1]))
root_stat = os.lstat(root)
digest = hashlib.sha256()

def field(value):
    if isinstance(value, str):
        value = os.fsencode(value)
    if isinstance(value, int):
        value = str(value).encode("ascii")
    digest.update(str(len(value)).encode("ascii") + b":" + value)

def visit(path, relative):
    entries = sorted(os.scandir(path), key=lambda item: item.name)
    for entry in entries:
        entry_path = os.path.join(path, entry.name)
        entry_relative = os.path.join(relative, entry.name)
        metadata = entry.stat(follow_symlinks=False)
        if metadata.st_dev != root_stat.st_dev:
            raise RuntimeError("dist tree crosses filesystems")
        mode_type = stat.S_IFMT(metadata.st_mode)
        field(entry_relative)
        field(mode_type)
        field(stat.S_IMODE(metadata.st_mode))
        field(metadata.st_uid)
        field(metadata.st_gid)
        if stat.S_ISDIR(metadata.st_mode):
            visit(entry_path, entry_relative)
        elif stat.S_ISREG(metadata.st_mode):
            field(metadata.st_size)
            with open(entry_path, "rb") as stream:
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
        elif stat.S_ISLNK(metadata.st_mode):
            field(os.readlink(entry_path))
        else:
            raise RuntimeError("unsupported entry in dist tree")

field(stat.S_IMODE(root_stat.st_mode))
field(root_stat.st_uid)
field(root_stat.st_gid)
visit(root, b"")
print(digest.hexdigest())
PY
  )
}

publication_exchange_state() {
  local public_identity staged_identity
  public_identity=$(directory_identity "$dist_dir") || return 1
  staged_identity=$(directory_identity "$staged_dist") || return 1
  if [[ $public_identity == "$candidate_dist_identity" &&
        $staged_identity == "$prior_dist_identity" ]]; then
    printf 'exchanged\n'
  elif [[ $public_identity == "$prior_dist_identity" &&
          $staged_identity == "$candidate_dist_identity" ]]; then
    printf 'not-exchanged\n'
  else
    printf 'unknown\n'
  fi
}

verify_published_pair() {
  [[ -f $archive && ! -L $archive &&
     -f $checksum && ! -L $checksum ]] || return 1
  (cd "$dist_dir" && sha256sum -c "$checksum_name") >/dev/null ||
    return 1
  cmp -s -- "$archive" "$stage_archive" &&
    cmp -s -- "$checksum" "$stage_checksum"
}

verify_prior_dist() {
  [[ $(directory_identity "$dist_dir") == "$prior_dist_identity" &&
     $(directory_identity "$staged_dist") == "$candidate_dist_identity" ]] ||
    return 1
  [[ $(dist_tree_digest "$dist_dir") == "$prior_dist_digest" ]]
}

sync_staging_root() {
  (
    unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT PYTHONUSERBASE \
      PYTHONWARNINGS PYTHONBREAKPOINT PYTHONSAFEPATH
    cd /
    /usr/bin/python3 -I -S - "$staging_root" <<'PY'
import os
import sys

flags = os.O_RDONLY
if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
descriptor = os.open(sys.argv[1], flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  )
}

write_recovery_marker() {
  : >"$stage/RECOVERY_REQUIRED"
}

transition_to_recovery() {
  local stage_suffix recovery_stage
  stage_suffix=${stage##*.}
  [[ $stage_suffix =~ ^[A-Za-z0-9]{6}$ ]] || return 1
  recovery_stage="$staging_root/recovery-${version}.${stage_suffix}"
  [[ ! -e $recovery_stage && ! -L $recovery_stage ]] || return 1

  retain_stage=1
  /usr/bin/mv -- "$stage" "$recovery_stage" || return 1
  stage=$recovery_stage
  set_stage_paths
  sync_staging_root || return 1
  if ! write_recovery_marker; then
    printf 'WARNING: unable to write optional recovery marker; recovery name remains authoritative: %s\n' \
      "$stage" >&2
  fi
}

clear_verified_recovery() {
  [[ $stage == "$staging_root"/recovery-"$version".?????? &&
     -d $stage && ! -L $stage ]] || return 1
  /usr/bin/rm -rf --one-file-system -- "$stage" || return 1
  sync_staging_root || return 1
  stage=
  retain_stage=0
}

retain_publication_recovery() {
  retain_stage=1
  if [[ -n ${stage:-} && -d $stage && ! -L $stage ]] &&
     ! write_recovery_marker; then
    printf 'WARNING: unable to write optional recovery marker; recovery path remains protected by name or public-state proof\n' \
      >&2
  fi
  printf 'Release rollback could not be confirmed: %s\n' "$version" >&2
  printf 'Recovery material retained at: %s\n' "$stage" >&2
  printf 'Do not delete this directory. Inspect dist and %s/dist before any manual recovery.\n' \
    "$stage" >&2
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

prior_dist_identity=$(directory_identity "$dist_dir")
prior_dist_digest=$(dist_tree_digest "$dist_dir")
mkdir -p "$staged_dist"
cp -a -- "$dist_dir/." "$staged_dist/"
cp -- "$stage_archive" "$staged_dist/$archive_name"
cp -- "$stage_checksum" "$staged_dist/$checksum_name"
(cd "$staged_dist" && sha256sum -c "$checksum_name") >/dev/null
candidate_dist_identity=$(directory_identity "$staged_dist")
publish_dist_exchange
exchange_state=$(publication_exchange_state)
if [[ $exchange_state == exchanged ]] && verify_published_pair; then
  printf '%s\n%s\n' "$archive" "$checksum"
  exit 0
fi

if [[ $exchange_state == exchanged ]]; then
  if ! transition_to_recovery; then
    retain_publication_recovery
    exit 1
  fi
  if publish_dist_exchange && verify_prior_dist; then
    if clear_verified_recovery; then
      printf 'Published release pair failed verification and was rolled back: %s\n' \
        "$version" >&2
      exit 1
    fi
    retain_publication_recovery
    exit 1
  fi
  retain_publication_recovery
  exit 1
fi

if [[ $exchange_state == not-exchanged ]]; then
  printf 'Published release pair failed verification; no exchange occurred: %s\n' \
    "$version" >&2
  exit 1
fi

retain_publication_recovery
exit 1
