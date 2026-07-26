#!/usr/bin/env bash
# uninstall.sh — remove generated native deployment configuration.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/native-config.sh
source "$project_dir/lib/native-config.sh"

delete_profile=0
while (($#)); do
  case "$1" in
    --delete-profile)
      delete_profile=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./uninstall.sh [--delete-profile]

By default the Chrome profile and all secrets are preserved.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

requested_profile=${CHROME_MCP_PROFILE-}
native_initialize_paths
if [[ "$delete_profile" == 1 ]]; then
  deletion_target=${requested_profile:-$CHROME_MCP_PROFILE}
  native_validate_profile_deletion_target "$deletion_target" \
    "$EXPECTED_CHROME_MCP_PROFILE" "$REMOTE_CHROME_HOME" "$REMOTE_CHROME_ROOT"
fi

printf 'Remote Chrome MCP uninstall\n\n'
printf 'This removes six generated user units and the generated nginx site.\n'
printf 'It preserves the browser profile and secrets unless --delete-profile was supplied.\n'
read -r -p "Type 'yes' to continue: " confirmation
if [[ "$confirmation" != yes ]]; then
  printf 'Aborted.\n'
  exit 0
fi

if [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
  for unit in playwright-mcp.service chrome-novnc.service chrome-vnc.service \
    chrome-mcp.service chrome-window-manager.service chrome-display.service; do
    systemctl --user stop "$unit" 2>/dev/null || true
  done
  systemctl --user disable "${REMOTE_CHROME_UNITS[@]}" 2>/dev/null || true
fi

for unit in "${REMOTE_CHROME_UNITS[@]}"; do
  rm -f -- "$SYSTEMD_USER_DIR/$unit"
done
rm -f -- "$MIGRATION_MARKER"

if [[ "$REMOTE_CHROME_ROOT" == "/" ]]; then
  sudo rm -f -- "$NGINX_ENABLED" "$NGINX_SITE"
else
  rm -f -- "$NGINX_ENABLED" "$NGINX_SITE"
fi

if [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
  systemctl --user daemon-reload
  sudo nginx -t && sudo systemctl reload nginx
fi

if [[ "$delete_profile" == 1 ]]; then
  rm -rf -- "$CHROME_MCP_PROFILE"
  profile_result="removed: $CHROME_MCP_PROFILE"
else
  profile_result="preserved: $CHROME_MCP_PROFILE"
fi

cat <<EOF

Removed:
  generated user units in $SYSTEMD_USER_DIR
  nginx site $NGINX_SITE
  nginx link $NGINX_ENABLED
  headed migration marker $MIGRATION_MARKER

Preserved:
  bearer token $TOKEN_FILE
  login credential file $LOGIN_ENV_FILE
  login htpasswd secret $LOGIN_HTPASSWD_REAL
  browser profile $profile_result
  protected profile backup marker $PROFILE_BACKUP_MARKER
  configuration backups under $BACKUP_DIR
EOF
