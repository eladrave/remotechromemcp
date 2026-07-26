#!/usr/bin/env bash
set -euo pipefail

npm test
bash tests/compose-config.test.sh
bash tests/vm-compose-contract.test.sh
bash tests/skill-contract.test.sh
bash tests/docker-fix-round1.test.sh
for script in setup.sh login.sh status.sh uninstall.sh scripts/*.sh docker/*.sh lib/*.sh tests/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done
