#!/usr/bin/env bash
# setup.sh — install or migrate the native headed Remote Chrome deployment.
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/native-config.sh
source "$project_dir/lib/native-config.sh"

native_setup_main "$@"
