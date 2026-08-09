#!/usr/bin/env bash
set -euo pipefail

credentials_file=/etc/remote-chrome/credentials.env
on_calendar=hourly
systemd_root=/etc/systemd/system
libexec_root=/usr/local/libexec
enable_timer=1

usage() {
  cat <<'EOF'
Usage: sudo scripts/install-functional-healthcheck.sh [options]

Options:
  --credentials-file PATH  Root-only file containing MCP_URL and MCP_TOKEN.
  --on-calendar VALUE      systemd OnCalendar value; default: hourly.
  --test-root PATH         Write beneath PATH and skip systemctl (tests only).
  -h, --help               Show this help text.
EOF
}

fail() {
  printf 'functional healthcheck installer failed: %s\n' "$1" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --credentials-file)
      (($# >= 2)) || fail 'missing value for --credentials-file'
      credentials_file=$2
      shift 2
      ;;
    --on-calendar)
      (($# >= 2)) || fail 'missing value for --on-calendar'
      on_calendar=$2
      shift 2
      ;;
    --test-root)
      (($# >= 2)) || fail 'missing value for --test-root'
      [[ $2 == /* ]] || fail '--test-root must be absolute'
      systemd_root=$2/etc/systemd/system
      libexec_root=$2/usr/local/libexec
      enable_timer=0
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || fail 'must run as root'
[[ $credentials_file =~ ^/[A-Za-z0-9._/-]+$ ]] ||
  fail 'credential path contains unsupported characters'
[[ -n $on_calendar && $on_calendar != *$'\n'* ]] ||
  fail 'OnCalendar value is empty or contains a newline'

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checker_source=$script_dir/remote-chrome-functional-healthcheck.sh
[[ -f $checker_source && ! -L $checker_source ]] ||
  fail 'healthcheck source script is missing or unsafe'
if ((enable_timer == 1)); then
  [[ -f $credentials_file && ! -L $credentials_file ]] ||
    fail 'credential file is missing or unsafe'
fi

install -d -m 0755 -- "$systemd_root" "$libexec_root"
install -m 0755 -- "$checker_source" \
  "$libexec_root/remote-chrome-functional-healthcheck"

service_candidate=$(mktemp)
timer_candidate=$(mktemp)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  [[ ! -e $service_candidate ]] || unlink "$service_candidate"
  [[ ! -e $timer_candidate ]] || unlink "$timer_candidate"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

cat >"$service_candidate" <<EOF
[Unit]
Description=Remote Chrome MCP functional healthcheck
Documentation=https://github.com/eladrave/remotechromemcp/blob/master/docs/functional-healthcheck.md
After=network-online.target remote-chrome.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
ExecStart=$libexec_root/remote-chrome-functional-healthcheck --credentials-file $credentials_file
TimeoutStartSec=120
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF

cat >"$timer_candidate" <<EOF
[Unit]
Description=Run the Remote Chrome MCP functional healthcheck hourly
Documentation=https://github.com/eladrave/remotechromemcp/blob/master/docs/functional-healthcheck.md

[Timer]
OnCalendar=$on_calendar
Persistent=yes
AccuracySec=1m
Unit=remote-chrome-functional-healthcheck.service

[Install]
WantedBy=timers.target
EOF

install -m 0644 -- "$service_candidate" \
  "$systemd_root/remote-chrome-functional-healthcheck.service"
install -m 0644 -- "$timer_candidate" \
  "$systemd_root/remote-chrome-functional-healthcheck.timer"

if ((enable_timer == 1)); then
  systemctl daemon-reload
  systemctl enable --now remote-chrome-functional-healthcheck.timer
  systemctl start remote-chrome-functional-healthcheck.service
  systemctl --no-pager --full status \
    remote-chrome-functional-healthcheck.timer
  printf '%s\n' \
    'Installed and validated the hourly Remote Chrome functional healthcheck.' \
    'Logs: journalctl -u remote-chrome-functional-healthcheck.service'
else
  printf 'Rendered functional healthcheck installation beneath %s\n' \
    "${systemd_root%/etc/systemd/system}"
fi
