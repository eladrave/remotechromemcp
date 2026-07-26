#!/usr/bin/env bash
# status.sh — Show status of all Remote Chrome MCP components.
set -euo pipefail

TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/mcp-bearer-token.env}"
MCP_INTERNAL_PORT="${MCP_INTERNAL_PORT:-8931}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8932}"
CDP_PORT="${CDP_PORT:-9222}"

echo "════════════════════════════════════════════════════════"
echo "  Remote Chrome MCP — Status"
echo "════════════════════════════════════════════════════════"
echo ""

# 1. Chrome CDP service
echo "── chrome-mcp.service (headless Chrome + CDP) ──────────"
systemctl --user status chrome-mcp.service --no-pager -l 2>&1 | grep -E "Active:|Main PID:|○|●|✗" | head -3
CDP_UP=false
if curl -s --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" &>/dev/null; then
  CDP_UP=true
  echo "  CDP endpoint : ✓ reachable at 127.0.0.1:${CDP_PORT}"
else
  echo "  CDP endpoint : ✗ not reachable at 127.0.0.1:${CDP_PORT}"
fi
echo ""

# 2. Playwright MCP service
echo "── playwright-mcp.service ───────────────────────────────"
systemctl --user status playwright-mcp.service --no-pager -l 2>&1 | grep -E "Active:|Main PID:|○|●|✗" | head -3
MCP_UP=false
if curl -s --max-time 2 "http://127.0.0.1:${MCP_INTERNAL_PORT}/mcp" &>/dev/null; then
  MCP_UP=true
  echo "  MCP internal : ✓ reachable at 127.0.0.1:${MCP_INTERNAL_PORT}"
else
  echo "  MCP internal : ✗ not reachable at 127.0.0.1:${MCP_INTERNAL_PORT}"
fi
echo ""

# 3. nginx
echo "── nginx (bearer token auth proxy) ─────────────────────"
systemctl status nginx --no-pager 2>&1 | grep -E "Active:" | head -1
echo ""

# 4. End-to-end smoke test
echo "── End-to-end smoke test ────────────────────────────────"
if [[ -f "$TOKEN_FILE" ]]; then
  source "$TOKEN_FILE"
  SMOKE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    --max-time 10 \
    "http://127.0.0.1:${MCP_PUBLIC_PORT}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"status-check","version":"1.0"}}}' 2>/dev/null || echo "000")

  if [[ "$SMOKE" == "200" ]]; then
    echo "  MCP e2e      : ✓ HTTP 200 — fully operational"
  elif [[ "$SMOKE" == "401" ]]; then
    echo "  MCP e2e      : ✗ HTTP 401 — auth rejected (token mismatch?)"
  elif [[ "$SMOKE" == "000" ]]; then
    echo "  MCP e2e      : ✗ connection refused — nginx or MCP not running"
  else
    echo "  MCP e2e      : ✗ HTTP $SMOKE — unexpected response"
  fi

  echo ""
  echo "  Bearer token : ${BEARER_TOKEN}"
  PUBLIC_IP=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || echo "<unknown>")
  echo "  Endpoint     : http://${PUBLIC_IP}:${MCP_PUBLIC_PORT}/mcp"
else
  echo "  Token file not found at $TOKEN_FILE — run setup.sh first."
fi

echo ""
echo "════════════════════════════════════════════════════════"
