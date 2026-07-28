#!/usr/bin/env bash

vm_prompt() {
  local prompt=$1
  local tty_path=${REMOTE_CHROME_TTY:-/dev/tty}
  local tty_output=${REMOTE_CHROME_TTY_OUTPUT:-}
  local value
  if [[ -z $tty_output ]]; then
    if [[ -n ${REMOTE_CHROME_TTY:-} ]]; then
      tty_output=/dev/null
    else
      tty_output=/dev/tty
    fi
  fi
  [[ -r $tty_path ]] ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
  printf '%s\n' "$prompt" >>"$tty_output" ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
  IFS= read -r value <"$tty_path" ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
  printf '%s' "$value"
}

vm_open_tty() {
  local tty_path=${REMOTE_CHROME_TTY:-/dev/tty}
  local tty_output=${REMOTE_CHROME_TTY_OUTPUT:-}
  if [[ -z $tty_output ]]; then
    if [[ -n ${REMOTE_CHROME_TTY:-} ]]; then
      tty_output=/dev/null
    else
      tty_output=/dev/tty
    fi
  fi
  [[ -r $tty_path ]] ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
  exec {VM_TTY_INPUT_FD}<"$tty_path" ||
    vm_die 2 'Interactive input is unavailable'
  exec {VM_TTY_OUTPUT_FD}>>"$tty_output" ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
}

vm_close_tty() {
  exec {VM_TTY_INPUT_FD}<&-
  exec {VM_TTY_OUTPUT_FD}>&-
  unset VM_TTY_INPUT_FD VM_TTY_OUTPUT_FD
}

vm_tty_write_line() {
  printf '%s\n' "$1" >&"$VM_TTY_OUTPUT_FD" ||
    vm_die 2 'Interactive prompt output is unavailable'
}

vm_prompt_into() {
  local destination=$1 prompt=$2 value
  printf '%s\n' "$prompt" >&"$VM_TTY_OUTPUT_FD" ||
    vm_die 2 'Interactive prompt output is unavailable'
  IFS= read -r value <&"$VM_TTY_INPUT_FD" ||
    vm_die 2 "Interactive input unavailable; use --non-interactive with --email and --data-dir; --domain is optional"
  printf -v "$destination" '%s' "$value"
}

vm_canonicalize_data_dir() {
  local candidate=${1:-}
  [[ $candidate == /* ]] || return 1
  [[ "$candidate" != *$'\n'* ]] || return 1
  realpath -m -- "$candidate"
}

vm_validate_data_dir() {
  local canonical
  canonical=$(vm_canonicalize_data_dir "${1:-}") || return 1
  case "$canonical" in
    /|/home|/root|/etc|/var) return 1 ;;
  esac
}

vm_installer_usage() {
  printf '%s\n' \
    'Usage: installer-main.sh [options]' \
    '  --version REF' \
    '  --domain DOMAIN' \
    '  --email EMAIL' \
    '  --data-dir ABSOLUTE_PATH' \
    '  --enable-gcs-backup' \
    '  --gcs-bucket BUCKET' \
    '  --backup-schedule SYSTEMD_CALENDAR' \
    '  --disable-gcs-backup --disable-backup-schedule' \
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
  AUTO_DOMAIN=0
  ENABLE_GCS_BACKUP=0
  DISABLE_GCS_BACKUP=0
  DISABLE_BACKUP_SCHEDULE=0
  INSTALLATION_EXISTS=0
  DOMAIN_SET=0
  EMAIL_SET=0
  DATA_DIR_SET=0
  GCS_BUCKET_SET=0
  BACKUP_SCHEDULE_SET=0

  while (($#)); do
    case "$1" in
      --version|--domain|--email|--data-dir|--gcs-bucket|--backup-schedule)
        (($# >= 2)) || vm_die 2 "$1 requires a value"
        case "$1" in
          --version) SELECTED_VERSION=$2 ;;
          --domain)
            DOMAIN=$2
            DOMAIN_SET=1
            case "${DOMAIN,,}" in
              auto|none)
                DOMAIN=
                AUTO_DOMAIN=1
                ;;
            esac
            ;;
          --email) ACME_EMAIL=$2; EMAIL_SET=1 ;;
          --data-dir) REMOTE_CHROME_DATA_DIR=$2; DATA_DIR_SET=1 ;;
          --gcs-bucket) GCS_BUCKET=$2; GCS_BUCKET_SET=1 ;;
          --backup-schedule)
            BACKUP_SCHEDULE=$2
            BACKUP_SCHEDULE_SET=1
            ;;
        esac
        shift 2
        ;;
      --disable-gcs-backup) DISABLE_GCS_BACKUP=1; shift ;;
      --enable-gcs-backup) ENABLE_GCS_BACKUP=1; shift ;;
      --disable-backup-schedule) DISABLE_BACKUP_SCHEDULE=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --rotate-credentials) ROTATE_CREDENTIALS=1; shift ;;
      --help|-h) vm_installer_usage; return 64 ;;
      *) vm_die 2 "Unknown installer argument: $1" ;;
    esac
  done

  ((ENABLE_GCS_BACKUP == 0 || DISABLE_GCS_BACKUP == 0)) ||
    vm_die 2 '--enable-gcs-backup conflicts with --disable-gcs-backup'
  ((GCS_BUCKET_SET == 0 || DISABLE_GCS_BACKUP == 0)) ||
    vm_die 2 '--gcs-bucket conflicts with --disable-gcs-backup'
  ((BACKUP_SCHEDULE_SET == 0 || DISABLE_BACKUP_SCHEDULE == 0)) ||
    vm_die 2 '--backup-schedule conflicts with --disable-backup-schedule'
  ((BACKUP_SCHEDULE_SET == 0 || DISABLE_GCS_BACKUP == 0)) ||
    vm_die 2 '--backup-schedule conflicts with --disable-gcs-backup'
  if [[ $GCS_BUCKET_SET -eq 1 || $BACKUP_SCHEDULE_SET -eq 1 ]]; then
    ENABLE_GCS_BACKUP=1
  fi
}

vm_collect_configuration() {
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    local missing=()
    if [[ ${INSTALLATION_EXISTS:-0} -eq 0 ]]; then
      [[ $EMAIL_SET -eq 1 ]] || missing+=(--email)
      [[ $DATA_DIR_SET -eq 1 ]] || missing+=(--data-dir)
    fi
    ((${#missing[@]} == 0)) ||
      vm_die 2 "Non-interactive mode requires ${missing[*]}"
    if [[ ${INSTALLATION_EXISTS:-0} -eq 0 && $DOMAIN_SET -eq 0 ]]; then
      AUTO_DOMAIN=1
    fi
  else
    local answer=
    vm_open_tty
    vm_tty_write_line \
      'The installer validates DNS and checks host ports 80 and 443 before provisioning.'
    if [[ ${INSTALLATION_EXISTS:-0} -eq 0 && $DOMAIN_SET -eq 0 ]]; then
      vm_prompt_into answer \
        'Do you have a domain already pointing to this VM? [y/N]:'
      case "${answer,,}" in
        y|yes)
          vm_prompt_into answer 'Domain:'
          case "${answer,,}" in
            ''|auto|none)
              DOMAIN=
              AUTO_DOMAIN=1
              ;;
            *)
              DOMAIN=$answer
              ;;
          esac
          ;;
        ''|n|no|none)
          DOMAIN=
          AUTO_DOMAIN=1
          ;;
        *)
          vm_die 2 'Answer yes or no when asked whether you have a domain'
          ;;
      esac
    fi
    if [[ $EMAIL_SET -eq 0 ]]; then
      vm_prompt_into answer 'ACME certificate email:'
      [[ -z $answer ]] || ACME_EMAIL=$answer
      EMAIL_SET=1
    fi
    if [[ $DATA_DIR_SET -eq 0 ]]; then
      vm_prompt_into answer \
        'Data directory [/var/lib/remote-chrome]:'
      [[ -z $answer ]] || REMOTE_CHROME_DATA_DIR=$answer
      DATA_DIR_SET=1
    fi

    if [[ ${INSTALLATION_EXISTS:-0} -eq 0 &&
          $ENABLE_GCS_BACKUP -eq 0 &&
          $DISABLE_GCS_BACKUP -eq 0 ]]; then
      vm_prompt_into answer 'Enable GCS backup? [y/N]:'
      case "${answer,,}" in
        y|yes)
          ENABLE_GCS_BACKUP=1
          ;;
        ''|n|no)
          DISABLE_GCS_BACKUP=1
          ;;
        *)
          vm_die 2 'Enable GCS backup with yes or no'
          ;;
      esac
    fi
    if [[ $DISABLE_GCS_BACKUP -eq 0 &&
          ( $ENABLE_GCS_BACKUP -eq 1 || -n $GCS_BUCKET ) ]]; then
      ENABLE_GCS_BACKUP=1
      if [[ -z $GCS_BUCKET ]]; then
        vm_prompt_into answer 'GCS bucket:'
        [[ -z $answer ]] || GCS_BUCKET=$answer
        GCS_BUCKET_SET=1
      fi
      if [[ $BACKUP_SCHEDULE_SET -eq 0 &&
            ${INSTALLATION_EXISTS:-0} -eq 0 ]]; then
        vm_prompt_into answer \
          'Optional backup schedule (systemd OnCalendar, blank for none):'
        if [[ -n $answer ]]; then
          BACKUP_SCHEDULE=$answer
          BACKUP_SCHEDULE_SET=1
        fi
      fi
    fi
  fi

  if [[ $DISABLE_GCS_BACKUP -eq 1 ||
        ( $ENABLE_GCS_BACKUP -eq 0 && -z $GCS_BUCKET ) ]]; then
    DISABLE_GCS_BACKUP=1
    GCS_BUCKET=
    BACKUP_SCHEDULE=
  elif [[ $DISABLE_BACKUP_SCHEDULE -eq 1 ]]; then
    BACKUP_SCHEDULE=
  fi
  if [[ $DISABLE_GCS_BACKUP -eq 0 && -z $GCS_BUCKET ]]; then
    vm_die 2 '--enable-gcs-backup requires --gcs-bucket in non-interactive mode or a bucket answer in interactive mode'
  fi
  [[ -z $BACKUP_SCHEDULE || -n $GCS_BUCKET ]] ||
    vm_die 2 'A backup schedule requires a GCS bucket'
  if [[ ${AUTO_DOMAIN:-0} -eq 1 ]]; then
    DOMAIN=$(vm_generate_sslip_domain) ||
      vm_die 69 'Unable to generate an sslip.io domain from the public IPv4 address'
    if [[ $NON_INTERACTIVE -eq 0 ]]; then
      vm_tty_write_line "Using automatic domain: $DOMAIN"
    fi
  fi
  if [[ $NON_INTERACTIVE -eq 0 ]]; then
    vm_close_tty
  fi
  vm_validate_domain "$DOMAIN" ||
    vm_die 2 "Invalid domain: $DOMAIN"
  vm_validate_email "$ACME_EMAIL" ||
    vm_die 2 "Invalid email: $ACME_EMAIL"
  local canonical_data_dir
  canonical_data_dir=$(vm_canonicalize_data_dir "$REMOTE_CHROME_DATA_DIR") ||
    vm_die 2 "Invalid data directory: $REMOTE_CHROME_DATA_DIR"
  vm_validate_data_dir "$canonical_data_dir" ||
    vm_die 2 "Invalid data directory: $REMOTE_CHROME_DATA_DIR"
  REMOTE_CHROME_DATA_DIR=$canonical_data_dir
  [[ -z $GCS_BUCKET ]] || vm_validate_gcs_bucket "$GCS_BUCKET" ||
    vm_die 2 "Invalid GCS bucket: $GCS_BUCKET"
}
