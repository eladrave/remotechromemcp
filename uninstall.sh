#!/usr/bin/env bash
# uninstall.sh — remove generated native deployment configuration.
set -euo pipefail

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

remote_root="${REMOTE_CHROME_ROOT:-/}"
if [[ "$remote_root" == "/" ]]; then
  remote_home="${REMOTE_CHROME_HOME:-$HOME}"
else
  remote_home="${REMOTE_CHROME_HOME:-${remote_root%/}/home}"
fi
profile="${CHROME_MCP_PROFILE:-$remote_home/.config/chrome-mcp-profile}"
token_file="${TOKEN_FILE:-$remote_home/.config/mcp-bearer-token.env}"
login_file="${LOGIN_ENV_FILE:-$remote_home/.config/remote-chrome-login.env}"
marker="${MIGRATION_MARKER:-$remote_home/.config/remote-chrome-headed-migration}"
systemd_user_dir="${SYSTEMD_USER_DIR:-$remote_home/.config/systemd/user}"
if [[ "$remote_root" == "/" ]]; then
  nginx_site=/etc/nginx/sites-available/playwright-mcp
  nginx_enabled=/etc/nginx/sites-enabled/playwright-mcp
  htpasswd_file=/etc/nginx/.remote-chrome-login.htpasswd
else
  nginx_site="${remote_root%/}/etc/nginx/sites-available/playwright-mcp"
  nginx_enabled="${remote_root%/}/etc/nginx/sites-enabled/playwright-mcp"
  htpasswd_file="${remote_root%/}/etc/nginx/.remote-chrome-login.htpasswd"
fi
units=(
  chrome-display.service
  chrome-window-manager.service
  chrome-mcp.service
  chrome-vnc.service
  chrome-novnc.service
  playwright-mcp.service
)

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
  systemctl --user disable "${units[@]}" 2>/dev/null || true
fi

for unit in "${units[@]}"; do
  rm -f -- "$systemd_user_dir/$unit"
done
rm -f -- "$marker"

if [[ "$remote_root" == "/" ]]; then
  sudo rm -f -- "$nginx_enabled" "$nginx_site"
else
  rm -f -- "$nginx_enabled" "$nginx_site"
fi

if [[ "${REMOTE_CHROME_DRY_RUN:-0}" != 1 ]]; then
  systemctl --user daemon-reload
  sudo nginx -t && sudo systemctl reload nginx
fi

if [[ "$delete_profile" == 1 ]]; then
  if [[ "$profile" != /* || "$profile" == "/" || "$profile" == "$remote_home" ]]; then
    printf 'Refusing unsafe profile deletion target: %s\n' "$profile" >&2
    exit 1
  fi
  rm -rf -- "$profile"
  profile_result="removed: $profile"
else
  profile_result="preserved: $profile"
fi

cat <<EOF

Removed:
  generated user units in $systemd_user_dir
  nginx site $nginx_site
  nginx link $nginx_enabled
  headed migration marker $marker

Preserved:
  bearer token $token_file
  login credential file $login_file
  login htpasswd secret $htpasswd_file
  browser profile $profile_result
  configuration backups under $remote_home/.config/remote-chrome-backups
EOF
