#!/usr/bin/env bash
# login.sh — hand a human the authenticated remote Chrome login console.
set -euo pipefail

remote_root="${REMOTE_CHROME_ROOT:-/}"
if [[ "$remote_root" == "/" ]]; then
  remote_home="${REMOTE_CHROME_HOME:-$HOME}"
else
  remote_home="${REMOTE_CHROME_HOME:-${remote_root%/}/home}"
fi
login_env_file="${LOGIN_ENV_FILE:-$remote_home/.config/remote-chrome-login.env}"

if [[ ! -f "$login_env_file" ]]; then
  printf 'Login credentials are not configured at %s. Run ./setup.sh first.\n' \
    "$login_env_file" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$login_env_file"
if [[ -z "${LOGIN_URL-}" || -z "${LOGIN_USERNAME-}" || -z "${LOGIN_PASSWORD-}" ]]; then
  printf 'Login credential file is incomplete: %s\n' "$login_env_file" >&2
  exit 1
fi

cat <<EOF
Remote Chrome login console

URL: $LOGIN_URL
Username: $LOGIN_USERNAME

The password remains in $login_env_file and is not displayed.
Use the console to complete sign-in, MFA, CAPTCHA, or other human-only steps.
Chrome and Playwright MCP remain running while you use it.
EOF

if [[ -n "${DISPLAY-}${WAYLAND_DISPLAY-}" ]] && command -v xdg-open >/dev/null 2>&1; then
  if xdg-open "$LOGIN_URL" >/dev/null 2>&1 & then
    printf 'Opened the login console in your graphical session.\n'
  fi
else
  cat <<EOF

SSH-only session detected: open the URL above in a browser on your own
computer, then enter the stored username and password.
EOF
fi
