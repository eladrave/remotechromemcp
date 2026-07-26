#!/usr/bin/env bash
set -euo pipefail

npm test
for script in setup.sh login.sh status.sh uninstall.sh scripts/*.sh docker/*.sh lib/*.sh tests/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done
