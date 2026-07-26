#!/usr/bin/env bash
# login.sh — Open Chrome headed with the MCP profile for manual login.
# Stops the MCP services, opens headed Chrome so you can log in to sites,
# then restarts the services when you close Chrome.
set -euo pipefail

CHROME_BIN="${CHROME_BIN:-/usr/bin/google-chrome}"
CHROME_MCP_PROFILE="${CHROME_MCP_PROFILE:-$HOME/.config/chrome-mcp-profile}"

echo "════════════════════════════════════════════════════════"
echo "  Remote Chrome MCP — Login Mode"
echo "════════════════════════════════════════════════════════"
echo ""
echo "This will:"
echo "  1. Stop the MCP services (chrome-mcp + playwright-mcp)"
echo "  2. Open Chrome headed with your MCP profile"
echo "  3. Restart the services after you close Chrome"
echo ""
read -rp "Press Enter to continue, or Ctrl-C to cancel..."

echo ""
echo "▶ Stopping MCP services..."
systemctl --user stop playwright-mcp.service 2>/dev/null || true
systemctl --user stop chrome-mcp.service 2>/dev/null || true
sleep 1

# Remove singleton locks left by the stopped service
rm -f "$CHROME_MCP_PROFILE"/Singleton*

echo "✓ Services stopped."
echo ""
echo "▶ Opening Chrome with your MCP profile..."
echo "  Log in to any sites you need, then CLOSE Chrome to continue."
echo ""

"$CHROME_BIN" \
  --user-data-dir="$CHROME_MCP_PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --new-window \
  2>/dev/null || true

echo ""
echo "▶ Chrome closed. Removing singleton locks and restarting services..."
rm -f "$CHROME_MCP_PROFILE"/Singleton*

systemctl --user start chrome-mcp.service
sleep 5
systemctl --user start playwright-mcp.service
sleep 3

echo "✓ Services restarted."
echo ""
systemctl --user status chrome-mcp.service playwright-mcp.service --no-pager -l | grep -E "Active:|●"
echo ""
echo "✓ Login session complete. Your new cookies are now available to the MCP server."
