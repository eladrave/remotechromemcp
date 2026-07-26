#!/usr/bin/env bash

vm_prompt() {
  local prompt=$1
  local tty_path=${REMOTE_CHROME_TTY:-/dev/tty}
  local value
  [[ -r $tty_path ]] ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --domain, --email, and --data-dir"
  read -r -p "$prompt" value 2>/dev/null <"$tty_path" ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --domain, --email, and --data-dir"
  printf '%s' "$value"
}

vm_validate_data_dir() {
  local candidate=$1
  [[ $candidate == /* ]] || return 1
  case "$candidate" in
    /|/home|/root|/etc|/var) return 1 ;;
  esac
  [[ "$candidate" != *$'\n'* ]]
}

vm_installer_usage() {
  printf '%s\n' \
    'Usage: installer-main.sh [options]' \
    '  --version REF' \
    '  --domain DOMAIN' \
    '  --email EMAIL' \
    '  --data-dir ABSOLUTE_PATH' \
    '  --gcs-bucket BUCKET' \
    '  --backup-schedule SYSTEMD_CALENDAR' \
    '  --non-interactive --skip-dns-check --rotate-credentials'
}

vm_parse_args() {
  SELECTED_VERSION=master
  DOMAIN=
  ACME_EMAIL=
  REMOTE_CHROME_DATA_DIR=/var/lib/remote-chrome
  GCS_BUCKET=
  BACKUP_SCHEDULE=
  NON_INTERACTIVE=0
  SKIP_DNS_CHECK=0
  ROTATE_CREDENTIALS=0
  DOMAIN_SET=0
  EMAIL_SET=0
  DATA_DIR_SET=0

  while (($#)); do
    case "$1" in
      --version|--domain|--email|--data-dir|--gcs-bucket|--backup-schedule)
        (($# >= 2)) || vm_die 2 "$1 requires a value"
        case "$1" in
          --version) SELECTED_VERSION=$2 ;;
          --domain) DOMAIN=$2; DOMAIN_SET=1 ;;
          --email) ACME_EMAIL=$2; EMAIL_SET=1 ;;
          --data-dir) REMOTE_CHROME_DATA_DIR=$2; DATA_DIR_SET=1 ;;
          --gcs-bucket) GCS_BUCKET=$2 ;;
          --backup-schedule) BACKUP_SCHEDULE=$2 ;;
        esac
        shift 2
        ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --rotate-credentials) ROTATE_CREDENTIALS=1; shift ;;
      --help|-h) vm_installer_usage; return 64 ;;
      *) vm_die 2 "Unknown installer argument: $1" ;;
    esac
  done
}

vm_collect_configuration() {
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    local missing=()
    [[ $DOMAIN_SET -eq 1 ]] || missing+=(--domain)
    [[ $EMAIL_SET -eq 1 ]] || missing+=(--email)
    [[ $DATA_DIR_SET -eq 1 ]] || missing+=(--data-dir)
    ((${#missing[@]} == 0)) ||
      vm_die 2 "Non-interactive mode requires ${missing[*]}"
  else
    [[ $DOMAIN_SET -eq 1 ]] ||
      DOMAIN=$(vm_prompt 'Domain: ')
    [[ $EMAIL_SET -eq 1 ]] ||
      ACME_EMAIL=$(vm_prompt 'ACME email: ')
    [[ $DATA_DIR_SET -eq 1 ]] ||
      REMOTE_CHROME_DATA_DIR=$(vm_prompt 'Data directory: ')
  fi

  vm_validate_domain "$DOMAIN" ||
    vm_die 2 "Invalid domain: $DOMAIN"
  vm_validate_email "$ACME_EMAIL" ||
    vm_die 2 "Invalid email: $ACME_EMAIL"
  vm_validate_data_dir "$REMOTE_CHROME_DATA_DIR" ||
    vm_die 2 "Invalid data directory: $REMOTE_CHROME_DATA_DIR"
}
