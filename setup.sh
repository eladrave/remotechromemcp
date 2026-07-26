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
# 10. HTTPS setup with Let's Encrypt (optional)
##############################################################################
echo ""
echo "════════════════════════════════════════════════════════"
echo "  HTTPS Setup (Let's Encrypt)"
echo "════════════════════════════════════════════════════════"
echo ""
read -rp "Set up HTTPS with a free Let's Encrypt certificate? [Y/n]: " _HTTPS_CHOICE
_HTTPS_CHOICE="${_HTTPS_CHOICE:-Y}"

ENDPOINT="http://${PUBLIC_IP}:${MCP_PUBLIC_PORT}/mcp"
DOMAIN=""

if [[ "${_HTTPS_CHOICE^^}" == "Y" ]]; then

  # --- Domain ---
  echo ""
  read -rp "  Domain/subdomain for the MCP endpoint (e.g. chrome.example.com): " DOMAIN
  if [[ -z "$DOMAIN" ]]; then
    warn "No domain entered — skipping HTTPS setup."
  else

    # --- Email for Let's Encrypt ---
    read -rp "  Email address for Let's Encrypt renewal notices: " CERTBOT_EMAIL
    if [[ -z "$CERTBOT_EMAIL" ]]; then
      warn "No email entered — skipping HTTPS setup."
      DOMAIN=""
    fi
  fi
fi

if [[ -n "$DOMAIN" ]]; then

  # --- DNS A record instructions ---
  echo ""
  echo "  ── DNS Setup ────────────────────────────────────────────"
  echo "  You need an A record pointing ${DOMAIN} → ${PUBLIC_IP}"
  echo ""
  echo "  Provider-specific instructions:"
  echo ""
  echo "  Cloudflare"
  echo "    1. Log in → select your domain"
  echo "    2. DNS → Records → Add record"
  echo "    3. Type: A  |  Name: ${DOMAIN%%.*}  |  IPv4: ${PUBLIC_IP}"
  echo "    4. Proxy status: DNS only (grey cloud)  ←  important!"
  echo ""
  echo "  AWS Route 53"
  echo "    1. Hosted Zones → your zone → Create record"
  echo "    2. Record name: ${DOMAIN%%.*}  |  Type: A  |  Value: ${PUBLIC_IP}"
  echo ""
  echo "  GoDaddy / Namecheap / other registrars"
  echo "    DNS Management → Add → Type: A"
  echo "    Host/Name: ${DOMAIN%%.*}  |  Points to: ${PUBLIC_IP}  |  TTL: 600"
  echo ""
  echo "  ─────────────────────────────────────────────────────────"
  read -rp "  Press Enter once the A record is saved and you're ready to continue..."

  # --- DNS propagation check ---
  info "Checking DNS for ${DOMAIN}..."
  RESOLVED=$(dig +short "${DOMAIN}" A 2>/dev/null | head -1 || true)
  if [[ "$RESOLVED" == "$PUBLIC_IP" ]]; then
    success "DNS resolved: ${DOMAIN} → ${RESOLVED} ✓"
  else
    warn "${DOMAIN} currently resolves to '${RESOLVED}' (expected '${PUBLIC_IP}')."
    warn "DNS may not have propagated yet (can take a few minutes)."
    echo ""
    read -rp "  Continue anyway and attempt certificate issuance? [y/N]: " _DNS_SKIP
    if [[ "${_DNS_SKIP^^}" != "Y" ]]; then
      warn "Skipping HTTPS. Re-run setup.sh once DNS has propagated."
      DOMAIN=""
    fi
  fi
fi

if [[ -n "$DOMAIN" ]]; then

  # --- Install certbot if needed ---
  if ! command -v certbot &>/dev/null; then
    info "Installing certbot..."
    sudo apt-get install -y certbot python3-certbot-nginx
    success "certbot installed."
  else
    success "certbot already installed."
  fi

  # --- Obtain certificate ---
  info "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  sudo certbot certonly --nginx \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${CERTBOT_EMAIL}" \
    --no-eff-email
  success "Certificate obtained — valid 90 days, auto-renews via certbot systemd timer."

  # --- Rewrite nginx config for HTTPS ---
  info "Updating nginx for HTTPS on port 443..."

  sudo tee "$NGINX_SITE" > /dev/null << NGINXEOF
map \$http_authorization \$mcp_auth_ok {
    "Bearer ${BEARER_TOKEN}" 1;
    default                  0;
}

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

# HTTPS — MCP endpoint
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        if (\$mcp_auth_ok = 0) {
            return 401 '{"error":"Unauthorized"}';
        }

        proxy_pass         http://127.0.0.1:${MCP_INTERNAL_PORT};
        proxy_http_version 1.1;

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

  sudo nginx -t
  sudo systemctl reload nginx
  success "nginx updated for HTTPS."

  ENDPOINT="https://${DOMAIN}/mcp"
fi

##############################################################################
# Summary
##############################################################################
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Remote Chrome MCP — Setup Complete"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  MCP endpoint : ${ENDPOINT}"
echo "  Bearer token : ${BEARER_TOKEN}"
echo ""
echo "  Token file   : ${TOKEN_FILE}"
if [[ -n "$DOMAIN" ]]; then
echo "  TLS cert     : /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
echo "  Auto-renews  : yes (certbot.timer)"
fi
echo ""
echo "  Client config snippet:"
echo '  {'
echo '    "mcpServers": {'
echo '      "playwright": {'
echo "        \"url\": \"${ENDPOINT}\","
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
