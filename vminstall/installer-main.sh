#!/usr/bin/env bash
set -euo pipefail

installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$installer_dir/lib/common.sh"
# shellcheck source=lib/wizard.sh
source "$installer_dir/lib/wizard.sh"

vm_installer_main() {
  vm_parse_args "$@" || return $?
  vm_require_root
  vm_init_paths
  vm_load_platform
  vm_validate_platform ||
    vm_die 65 "Unsupported platform: $PLATFORM_ID $PLATFORM_VERSION_ID $PLATFORM_ARCH"
  vm_collect_configuration
  vm_log 'Validation complete; no host changes have been made'
}

if [[ ${REMOTE_CHROME_SKIP_MAIN:-0} != 1 ]]; then
  vm_installer_main "$@"
fi
