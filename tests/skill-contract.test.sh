#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

skill=skills/remote-chrome-mcp/SKILL.md

# Application scenarios and literal expected decisions:
# 1. Navigation times out -> snapshot before retry.
# 2. Existing authenticated tab -> reuse it.
# 3. Agent guesses /ap/signin -> start at homepage and use visible login control.
# 4. MFA/CAPTCHA/security key -> stop and request human control at /login/.
# 5. User has no shell -> never instruct them to run login.sh remotely.
# 6. Element ref came from another session -> take a fresh snapshot.
# 7. Purchase/account change -> request explicit confirmation.
# 8. Server instructions conflict with skill -> follow server instructions.

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$skill" ]] || fail "required skill is missing: $skill"

if ! grep -Eq '^name:[[:space:]]*remote-chrome-mcp[[:space:]]*$' "$skill"; then
  fail 'skill frontmatter must name remote-chrome-mcp'
fi

required_concepts=(
  'server instructions'
  'snapshot'
  'timeout'
  'persistent'
  'session'
  '/login/'
  'no shell'
  'MFA'
  'CAPTCHA'
  'security key'
  'purchase'
  'account change'
  'homepage'
  'visible login'
)

for concept in "${required_concepts[@]}"; do
  if ! grep -Fqi "$concept" "$skill"; then
    fail "skill contract missing required concept: $concept"
  fi
done

production_domain_re='([[:alnum:]-]+\.)*elad'"rave"'\.com'
hex_token_re='(^|[^[:xdigit:]])[[:xdigit:]]{64}([^[:xdigit:]]|$)'

if grep -Eqi "$production_domain_re" "$skill"; then
  fail 'skill contains a forbidden production hostname'
fi

if grep -Eq "$hex_token_re" "$skill"; then
  fail 'skill contains a bearer-token candidate'
fi
