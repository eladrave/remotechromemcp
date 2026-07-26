#!/usr/bin/env bash
# setup.sh — Remote Chrome MCP setup
# Sets up Playwright MCP backed by your real Chrome profile, exposed via nginx with bearer token auth.
# Safe to re-run (idempotent).
set -euo pipefail

##############################################################################
# Config — override with env vars before running
##############################################################################
CHROME_BIN="${CHROME_BIN:-/usr/bin/google-chrome}"
CHROME_MCP_PROFILE="${CHROME_MCP_PROFILE:-$HOME/.config/chrome-mcp-profile}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/mcp-bearer-token.env}"
NGINX_SITE="/etc/nginx/sites-available/playwright-mcp"
NGINX_ENABLED="/etc/nginx/sites-enabled/playwright-mcp"
NGINX_HASH_CONF="/etc/nginx/conf.d/map-hash-bucket.conf"
MCP_INTERNAL_PORT="${MCP_INTERNAL_PORT:-8931}"
MCP_PUBLIC_PORT="${MCP_PUBLIC_PORT:-8932}"
CDP_PORT="${CDP_PORT:-9222}"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

##############################################################################
# Helpers
##############################################################################
info()    { echo "▶ $*"; }
success() { echo "✓ $*"; }
warn()    { echo "⚠ $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Please install it first."; exit 1; }
}

##############################################################################
# 1. Preflight checks
##############################################################################
info "Checking prerequisites..."
require_cmd "$CHROME_BIN"
require_cmd node
require_cmd npx
require_cmd nginx
require_cmd openssl

PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
if [[ -z "$PUBLIC_IP" ]]; then
  warn "Could not detect public IP. You'll need to find it manually."
  PUBLIC_IP="<your-public-ip>"
fi
info "Detected public IP: $PUBLIC_IP"

##############################################################################
# 2. Copy Chrome profile (one-time)
##############################################################################
if [[ -d "$CHROME_MCP_PROFILE" ]]; then
  success "Chrome MCP profile already exists at $CHROME_MCP_PROFILE — skipping copy."
else
  DEFAULT_PROFILE="$HOME/.config/google-chrome"
  if [[ ! -d "$DEFAULT_PROFILE" ]]; then
    warn "Default Chrome profile not found at $DEFAULT_PROFILE."
    warn "Chrome MCP profile will be created fresh (no existing cookies/logins)."
    mkdir -p "$CHROME_MCP_PROFILE"
  else
    info "Copying Chrome profile from $DEFAULT_PROFILE → $CHROME_MCP_PROFILE ..."
    cp -r "$DEFAULT_PROFILE" "$CHROME_MCP_PROFILE"
    success "Chrome profile copied."
  fi
fi
# Always remove stale singleton locks (leftover from a previous run or copy)
rm -f "$CHROME_MCP_PROFILE"/Singleton*

##############################################################################
# 3. Generate (or reuse) bearer token
##############################################################################
if [[ -f "$TOKEN_FILE" ]]; then
  source "$TOKEN_FILE"
  success "Reusing existing bearer token from $TOKEN_FILE."
else
  BEARER_TOKEN=$(openssl rand -hex 32)
  echo "BEARER_TOKEN=$BEARER_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  success "New bearer token generated and saved to $TOKEN_FILE."
fi

##############################################################################
# 4. Install @playwright/mcp globally (skip if already installed)
##############################################################################
if command -v playwright-mcp &>/dev/null; then
  success "playwright-mcp already installed at $(command -v playwright-mcp)."
else
  info "Installing @playwright/mcp globally..."
  sudo npm install -g @playwright/mcp@latest
  success "playwright-mcp installed."
fi

##############################################################################
# 5. Configure nginx
##############################################################################
info "Configuring nginx..."

# Increase map_hash_bucket_size for long bearer token strings
if [[ ! -f "$NGINX_HASH_CONF" ]]; then
  echo 'map_hash_bucket_size 128;' | sudo tee "$NGINX_HASH_CONF" > /dev/null
fi

sudo tee "$NGINX_SITE" > /dev/null << NGINXEOF
map \$http_authorization \$mcp_auth_ok {
    "Bearer ${BEARER_TOKEN}" 1;
    default                  0;
}

server {
    listen ${MCP_PUBLIC_PORT};
    listen [::]:${MCP_PUBLIC_PORT};

    location / {
        if (\$mcp_auth_ok = 0) {
            return 401 '{"error":"Unauthorized"}';
        }

        proxy_pass         http://127.0.0.1:${MCP_INTERNAL_PORT};
        proxy_http_version 1.1;

        # Required for HTTP streaming / SSE
        proxy_set_header   Host "localhost:${MCP_INTERNAL_PORT}";
        proxy_set_header   Connection "";
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        add_header Content-Type application/json always;
    }
}
NGINXEOF

sudo ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
sudo nginx -t
sudo systemctl reload nginx
success "nginx configured and reloaded."

##############################################################################
# 6. Create systemd user services
##############################################################################
mkdir -p "$SYSTEMD_USER_DIR"
PLAYWRIGHT_MCP_BIN=$(command -v playwright-mcp)

info "Creating systemd user services..."

cat > "$SYSTEMD_USER_DIR/chrome-mcp.service" << SVCEOF
[Unit]
Description=Chrome MCP (CDP remote debugging)
After=network.target

[Service]
ExecStartPre=/bin/sh -c 'rm -f %h/.config/chrome-mcp-profile/Singleton*'
ExecStart=${CHROME_BIN} \\
  --remote-debugging-port=${CDP_PORT} \\
  --remote-debugging-address=127.0.0.1 \\
  --user-data-dir=%h/.config/chrome-mcp-profile \\
  --no-first-run \\
  --no-default-browser-check \\
  --headless=new \\
  --disable-gpu \\
  --disable-dev-shm-usage
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF

cat > "$SYSTEMD_USER_DIR/playwright-mcp.service" << SVCEOF
[Unit]
Description=Playwright MCP Server
After=chrome-mcp.service
Wants=chrome-mcp.service

[Service]
ExecStartPre=/bin/sleep 3
ExecStart=${PLAYWRIGHT_MCP_BIN} \\
  --cdp-endpoint http://127.0.0.1:${CDP_PORT} \\
  --host 127.0.0.1 \\
  --port ${MCP_INTERNAL_PORT} \\
  --shared-browser-context \\
  --cdp-timeout 10000
Restart=on-failure
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SVCEOF

##############################################################################
# 7. Enable services and linger
##############################################################################
info "Enabling systemd user services..."
systemctl --user daemon-reload
systemctl --user enable chrome-mcp.service playwright-mcp.service
loginctl enable-linger "$(whoami)" 2>/dev/null || true

##############################################################################
# 8. Start services
##############################################################################
info "Starting services..."
systemctl --user restart chrome-mcp.service
sleep 5
systemctl --user restart playwright-mcp.service
sleep 3

##############################################################################
# 9. Smoke test
##############################################################################
info "Running smoke test..."
SMOKE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  --max-time 10 \
  "http://127.0.0.1:${MCP_PUBLIC_PORT}/mcp" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}')

if [[ "$SMOKE" == "200" ]]; then
  success "Smoke test passed (HTTP 200)."
else
  warn "Smoke test returned HTTP $SMOKE — services may still be starting. Run ./status.sh to check."
fi

##############################################################################
# Summary
##############################################################################
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Remote Chrome MCP — Setup Complete"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  MCP endpoint : http://${PUBLIC_IP}:${MCP_PUBLIC_PORT}/mcp"
echo "  Bearer token : ${BEARER_TOKEN}"
echo ""
echo "  Token file   : ${TOKEN_FILE}"
echo ""
echo "  Client config snippet:"
echo '  {'
echo '    "mcpServers": {'
echo '      "playwright": {'
echo "        \"url\": \"http://${PUBLIC_IP}:${MCP_PUBLIC_PORT}/mcp\","
echo '        "headers": {'
echo "          \"Authorization\": \"Bearer ${BEARER_TOKEN}\""
echo '        }'
echo '      }'
echo '    }'
echo '  }'
echo ""
echo "  To log in to sites, run:  ./login.sh"
echo "  To check status, run:     ./status.sh"
echo "════════════════════════════════════════════════════════"
