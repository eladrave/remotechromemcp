#!/usr/bin/env bash
set -euo pipefail

installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$installer_dir/lib/common.sh"
# shellcheck source=lib/wizard.sh
source "$installer_dir/lib/wizard.sh"
# shellcheck source=lib/host.sh
source "$installer_dir/lib/host.sh"
# shellcheck source=lib/docker.sh
source "$installer_dir/lib/docker.sh"
# shellcheck source=lib/release.sh
source "$installer_dir/lib/release.sh"
# shellcheck source=lib/config.sh
source "$installer_dir/lib/config.sh"
# shellcheck source=lib/activate.sh
source "$installer_dir/lib/activate.sh"

vm_installer_main() {
  vm_parse_args "$@" || return $?
  vm_collect_configuration
  vm_init_paths
  vm_load_platform ||
    vm_die 65 'Unable to load platform metadata'
  vm_validate_platform ||
    vm_die 65 "Unsupported platform: $PLATFORM_ID $PLATFORM_VERSION_ID $PLATFORM_ARCH"
  vm_check_host
  vm_verify_dns ||
    vm_die 69 'DNS verification failed'
  vm_check_public_ports ||
    vm_die 69 'Ports 80 and 443 must be available'
  vm_install_docker
  [[ -n ${REMOTE_CHROME_RELEASE_ARCHIVE:-} ]] ||
    vm_die 66 'REMOTE_CHROME_RELEASE_ARCHIVE is required for release staging'
  vm_stage_release "$REMOTE_CHROME_RELEASE_ARCHIVE" ||
    vm_die 66 'Release verification or staging failed'
  vm_verify_release "$STAGED_RELEASE_DIR" ||
    vm_die 66 'Staged release is incomplete'
  vm_activate_release ||
    vm_die $? 'Release activation failed; prior release recovery was attempted'
  vm_print_connection_handoff ||
    vm_die 74 'Release activated, but connection handoff could not be written'
}

if [[ ${REMOTE_CHROME_SKIP_MAIN:-0} != 1 ]]; then
  vm_installer_main "$@"
fi
