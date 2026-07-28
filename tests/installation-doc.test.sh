#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

doc=installation.md

[[ -f $doc ]] || fail 'installation.md is required at the repository root'
grep -Fq '[`installation.md`](installation.md)' README.md ||
  fail 'README must link to the complete installation guide'

required_headings=(
  '## Path A: guided automatic VM installation'
  '## Path B: noninteractive automatic installation'
  '## AI agent execution contract'
  '## Path C: direct Docker Compose installation'
  '## Verify a managed installation'
  '## Human login and persistent website state'
  '## GCS backup notes'
  '## Security checklist'
  '## Installation completion checklist'
)
for heading in "${required_headings[@]}"; do
  grep -Fxq "$heading" "$doc" ||
    fail "installation guide is missing heading: $heading"
done

required_contracts=(
  'https://raw.githubusercontent.com/eladrave/remotechromemcp/master/vminstall/install.sh'
  '--non-interactive'
  '--domain none'
  '--enable-gcs-backup'
  '--gcs-bucket'
  'GCS backup is disabled by default.'
  'sudo remote-chrome status'
  'sudo remote-chrome credentials'
  'remote_chrome_request_human_intervention'
  'git clone https://github.com/eladrave/remotechromemcp.git'
  'sudo ./scripts/bootstrap-docker.sh'
  'sudo docker compose --env-file .env up -d --build'
  'Never publish ports 5900, 6080, 8931, or 9222.'
  'Never add `--volumes`'
  'Do not paste `sudo remote-chrome credentials` output into chat or logs.'
  'Google Cloud Run'
)
for contract in "${required_contracts[@]}"; do
  grep -Fq -- "$contract" "$doc" ||
    fail "installation guide is missing contract: $contract"
done

if grep -Eq \
  'raw[.]githubusercontent[.]com/eladrave/remotechromemcp/v[0-9]+[.][0-9]+[.][0-9]+/' \
  "$doc"; then
  fail 'installation guide must not advertise an unpublished version URL'
fi

for link in \
  README.md \
  docs/vm-install.md \
  docs/gce-manual.md \
  docs/remote-login.md \
  skills/remote-chrome-mcp/SKILL.md \
  AGENTS.md; do
  [[ -f $link ]] || fail "installation guide links to missing file: $link"
done

printf 'PASS: complete human and AI-agent installation documentation contracts\n'
