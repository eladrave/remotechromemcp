#!/usr/bin/env bash
set -euo pipefail

profile_dir=/data/chrome-profile
runtime_dir=/run/remote-chrome

: "${SCREEN_GEOMETRY:?SCREEN_GEOMETRY is required}"
if [[ ! "$SCREEN_GEOMETRY" =~ ^[0-9]+x[0-9]+x(16|24|32)$ ]]; then
  printf 'Invalid SCREEN_GEOMETRY: %s\n' "$SCREEN_GEOMETRY" >&2
  exit 64
fi

mkdir -p "$profile_dir" "$runtime_dir"
[[ -w "$profile_dir" ]] || {
  printf 'Chrome profile is not writable: %s\n' "$profile_dir" >&2
  exit 73
}
[[ -w "$runtime_dir" ]] || {
  printf 'Runtime directory is not writable: %s\n' "$runtime_dir" >&2
  exit 73
}

# Chrome leaves these locks behind after an unclean container stop. Do not
# remove any other profile state: cookies and authenticated sessions persist.
rm -f -- "$profile_dir"/Singleton*

exec /usr/bin/supervisord \
  --nodaemon \
  --configuration /opt/remote-chrome/supervisord.conf
