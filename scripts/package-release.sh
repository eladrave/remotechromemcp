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
stage="$(mktemp -d "$dist_dir/.package-${version}.XXXXXX")"
backup="$stage/prior"
stage_archive="$stage/$archive_name"
stage_checksum="$stage/$checksum_name"
install_started=0
had_prior=0

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if ((status != 0 && install_started == 1)); then
    if ((had_prior == 0)); then
      rm -f -- "$archive" "$checksum"
    else
      if [[ -f $backup/$archive_name ]]; then
        rm -f -- "$archive"
        mv -- "$backup/$archive_name" "$archive"
      fi
      if [[ -f $backup/$checksum_name ]]; then
        rm -f -- "$checksum"
        mv -- "$backup/$checksum_name" "$checksum"
      fi
    fi
  fi
  rm -rf -- "$stage"
  exit "$status"
}

package_signal() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

trap cleanup EXIT
trap 'package_signal 129' HUP
trap 'package_signal 130' INT
trap 'package_signal 143' TERM

if [[ -e $archive || -e $checksum ]]; then
  [[ -f $archive && ! -L $archive && -f $checksum && ! -L $checksum ]] || {
    printf 'Existing release output is incomplete or unsafe: %s\n' "$version" >&2
    exit 1
  }
  (cd "$dist_dir" && sha256sum -c "$checksum_name") >/dev/null || {
    printf 'Existing release output has an invalid checksum: %s\n' "$version" >&2
    exit 1
  }
  had_prior=1
fi

git -C "$repo_dir" archive \
  --format=tar.gz \
  --prefix="remotechromemcp-${version}/" \
  --output="$stage_archive" \
  "$tag_ref"
(cd "$stage" && sha256sum "$archive_name" >"$checksum_name")
(cd "$stage" && sha256sum -c "$checksum_name") >/dev/null
first_member="$(tar -tzf "$stage_archive" | sed -n '1p')"
[[ $first_member == "remotechromemcp-${version}/"* ]] || {
    printf 'Release archive has an invalid prefix\n' >&2
    exit 1
  }

mkdir -p "$backup"
install_started=1
if ((had_prior == 1)); then
  mv -- "$archive" "$backup/$archive_name"
  mv -- "$checksum" "$backup/$checksum_name"
fi
mv -- "$stage_archive" "$archive"
mv -- "$stage_checksum" "$checksum"
install_started=0

printf '%s\n%s\n' "$archive" "$checksum"
