# remotechromemcp

Exposes a [Playwright MCP](https://github.com/microsoft/playwright-mcp) server backed by **your real Chrome profile** (with your saved logins and cookies) over HTTP with bearer token authentication. Intended for remote AI agents (Warp Oz, ChatGPT, Codex, etc.) that need to browse the web as you.

## Architecture

```
Remote MCP client
        │  HTTP  Authorization: Bearer <token>
        ▼
  nginx :8932  ──── bearer token check ────► 401 if invalid
        │
        │  proxy_pass (internal)
        ▼
  Playwright MCP  :8931
        │
        │  Chrome DevTools Protocol (CDP)
        ▼
  Chrome :9222  (headless, your profile copy)
```

All three components run as systemd user services that start automatically at boot.

## Prerequisites

- Ubuntu / Debian Linux
- Google Chrome installed (`/usr/bin/google-chrome`)
- Node.js + npx
- nginx (`sudo apt install nginx`)
- `sudo` access (for nginx config and global npm install)
- `openssl`, `curl`

## Quick Start

```bash
git clone https://github.com/<your-username>/remotechromemcp.git
cd remotechromemcp
chmod +x setup.sh login.sh status.sh uninstall.sh
./setup.sh
```

The script will print your endpoint URL and bearer token when done.

### What `setup.sh` does

1. Copies `~/.config/google-chrome` → `~/.config/chrome-mcp-profile` (one-time, skipped if exists)
2. Generates a 256-bit bearer token and saves it to `~/.config/mcp-bearer-token.env`
3. Installs `@playwright/mcp` globally via npm
4. Writes an nginx site config on port `8932` that validates the bearer token and proxies (with streaming support) to Playwright MCP
5. Creates two systemd user services: `chrome-mcp` and `playwright-mcp`
6. Enables both services and runs `loginctl enable-linger` so they survive logout
7. Starts everything and runs a smoke test

### Environment variables

All defaults can be overridden:

| Variable | Default | Description |
|---|---|---|
| `CHROME_BIN` | `/usr/bin/google-chrome` | Path to Chrome binary |
| `CHROME_MCP_PROFILE` | `~/.config/chrome-mcp-profile` | Profile directory used by the service |
| `TOKEN_FILE` | `~/.config/mcp-bearer-token.env` | Where the bearer token is stored |
| `CDP_PORT` | `9222` | Chrome DevTools Protocol port (internal) |
| `MCP_INTERNAL_PORT` | `8931` | Playwright MCP port (internal) |
| `MCP_PUBLIC_PORT` | `8932` | nginx public port |

## Client Configuration

After `setup.sh` completes, connect your MCP client to:

```
http://<your-public-ip>:8932/mcp
```

with the `Authorization: Bearer <token>` header.

### Warp / Oz

Add to Warp's MCP settings (Settings → MCP Servers):

```json
{
  "url": "http://<your-public-ip>:8932/mcp",
  "headers": {
    "Authorization": "Bearer <token>"
  }
}
```

### ChatGPT Desktop / Codex CLI

```toml
[mcp_servers.remote_chrome]
url = "http://<your-public-ip>:8932/mcp"
headers = { Authorization = "Bearer <token>" }
tool_timeout_sec = 120
```

### Claude Desktop

```json
{
  "mcpServers": {
    "playwright": {
      "url": "http://<your-public-ip>:8932/mcp",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
```

Your current token is always in `~/.config/mcp-bearer-token.env`.

## Logging In to Sites

Chrome runs headless as a service — you cannot interact with it directly. To log in to a site:

```bash
./login.sh
```

This stops the services, opens Chrome **headed** with your MCP profile, lets you log in manually, and restarts the services once you close Chrome. Your new cookies are immediately available to the MCP server.

## Checking Status

```bash
./status.sh
```

Shows service states, CDP reachability, and runs an end-to-end MCP smoke test.

## Managing Services

```bash
# Restart everything
systemctl --user restart chrome-mcp.service
sleep 5
systemctl --user restart playwright-mcp.service

# View live logs
journalctl --user -u chrome-mcp.service -f
journalctl --user -u playwright-mcp.service -f

# Stop
systemctl --user stop playwright-mcp.service chrome-mcp.service

# Start
systemctl --user start chrome-mcp.service
sleep 5
systemctl --user start playwright-mcp.service
```

## Uninstalling

```bash
./uninstall.sh
```

Removes services, nginx config, and the Chrome profile copy. Your original `~/.config/google-chrome` and bearer token file are untouched.

## Security Notes

- **CDP port 9222 is bound to `127.0.0.1` only** — never exposed publicly. CDP access is full control of that Chrome instance including all sessions and cookies.
- The **bearer token is the only public-facing auth**. Keep it secret and rotate it by deleting `~/.config/mcp-bearer-token.env` and re-running `setup.sh`.
- The endpoint is **plain HTTP** — suitable for trusted private networks or VPNs. For public Internet exposure, put it behind HTTPS (Cloudflare Tunnel, Caddy, certbot+nginx).
- The Chrome MCP profile is a **copy** of your real profile. Cookies written during MCP sessions stay in the copy and do not affect your normal Chrome.

## Troubleshooting

**Services won't start after reboot**

Check if linger is enabled:
```bash
loginctl show-user "$USER" | grep Linger
```
If `Linger=no`, run `loginctl enable-linger "$USER"`.

**Chrome exits with status=21 (SingletonLock)**

The profile has a stale lock file. The service clears it automatically via `ExecStartPre`, but you can also run:
```bash
rm -f ~/.config/chrome-mcp-profile/Singleton*
systemctl --user restart chrome-mcp.service
```

**HTTP 403 from MCP endpoint**

The nginx `Host` header must be `localhost:<MCP_INTERNAL_PORT>`. This is set in the nginx config. If you changed the port, re-run `setup.sh`.

**HTTP 401 with correct token**

The token in the nginx config doesn't match. Re-run `setup.sh` to regenerate the nginx config from the current token file.

**Chrome crashes / high memory**

The headless Chrome instance loads your full profile including extensions. Disable heavy extensions in the MCP profile via `./login.sh` to reduce memory usage.
