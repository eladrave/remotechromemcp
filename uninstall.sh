#!/usr/bin/env bash
# uninstall.sh — Remove Remote Chrome MCP setup.
# Does NOT delete your original Chrome profile or the bearer token file.
set -euo pipefail

CHROME_MCP_PROFILE="${CHROME_MCP_PROFILE:-$HOME/.config/chrome-mcp-profile}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/mcp-bearer-token.env}"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

echo "════════════════════════════════════════════════════════"
echo "  Remote Chrome MCP — Uninstall"
echo "════════════════════════════════════════════════════════"
echo ""
echo "This will remove:"
echo "  • systemd user services: chrome-mcp, playwright-mcp"
echo "  • nginx site config for playwright-mcp"
echo "  • nginx map-hash-bucket conf"
echo "  • Chrome MCP profile copy: $CHROME_MCP_PROFILE"
echo ""
echo "This will NOT remove:"
echo "  • Your original Chrome profile (~/.config/google-chrome)"
echo "  • The bearer token file ($TOKEN_FILE)"
echo "  • nginx itself or @playwright/mcp global install"
echo ""
read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

echo ""
echo "▶ Stopping and disabling services..."
systemctl --user stop playwright-mcp.service 2>/dev/null || true
systemctl --user stop chrome-mcp.service 2>/dev/null || true
systemctl --user disable playwright-mcp.service chrome-mcp.service 2>/dev/null || true

echo "▶ Removing service files..."
rm -f "$SYSTEMD_USER_DIR/chrome-mcp.service"
rm -f "$SYSTEMD_USER_DIR/playwright-mcp.service"
systemctl --user daemon-reload

echo "▶ Removing nginx config..."
sudo rm -f /etc/nginx/sites-enabled/playwright-mcp
sudo rm -f /etc/nginx/sites-available/playwright-mcp
sudo rm -f /etc/nginx/conf.d/map-hash-bucket.conf
sudo nginx -t && sudo systemctl reload nginx

echo "▶ Removing Chrome MCP profile copy..."
rm -rf "$CHROME_MCP_PROFILE"

echo ""
echo "✓ Uninstall complete."
echo "  Bearer token preserved at: $TOKEN_FILE"
echo "  Original Chrome profile untouched."
