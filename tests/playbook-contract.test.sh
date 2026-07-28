#!/usr/bin/env bash
set -euo pipefail

playbook=browser-playbook.md

required_concepts=(
  'REMOTE_CHROME_PLAYBOOK_VERSION=1'
  'snapshot'
  '/login/'
  'MFA'
  'CAPTCHA'
  'purchase'
  'Account & Lists'
  'server instructions'
  'Never clear cookies'
  'remote_chrome_request_human_intervention'
  'accepts no arguments'
)

for concept in "${required_concepts[@]}"; do
  if ! grep -Fq "$concept" "$playbook"; then
    echo "playbook contract missing required concept: $concept" >&2
    exit 1
  fi
done

production_domain_re='([[:alnum:]-]+\.)*elad'"rave"'\.com'
hex_token_re='(^|[^[:xdigit:]])[[:xdigit:]]{64}([^[:xdigit:]]|$)'

if grep -Eqi "$production_domain_re" "$playbook"; then
  echo 'playbook contract contains a forbidden production hostname' >&2
  exit 1
fi

if grep -Eq "$hex_token_re" "$playbook"; then
  echo 'playbook contract contains a bearer-token candidate' >&2
  exit 1
fi

if grep -Eiq '(MCP_TOKEN|MCP_PASSWORD|LOGIN_PASSWORD|PASSWORD)[[:space:]]*[:=][[:space:]]*["'\'']?[[:alnum:]_.!@#$%^&*+-]{8,}' "$playbook"; then
  echo 'playbook contract contains a literal secret assignment' >&2
  exit 1
fi
