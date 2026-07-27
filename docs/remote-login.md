# Remote Chrome login console

The native deployment keeps one headed Chrome process attached to the
long-lived MCP profile. The login console is an authenticated noVNC view of
that same process, so a human can complete sign-in without stopping Chrome or
moving cookies between profiles.

## Open the console from a desktop session

Run:

```bash
./login.sh
```

The command prints the HTTPS login URL and username. It never prints the
password. When a graphical session and `xdg-open` are available, it also opens
the URL in the default browser. Read the password locally from
`~/.config/remote-chrome-login.env`, enter it in the HTTP Basic Authentication
prompt, and use the remote Chrome window normally.

Close the browser tab containing noVNC when the handoff is complete. Closing
that tab does not stop remote Chrome, Playwright MCP, or the signed-in website
session.

## Authentication persistence

MCP connections and snapshot element references are temporary, but website
authentication belongs to Chrome's persistent profile. After login and any
required MFA are complete, cookies, local storage, and other site state survive
closing the noVNC tab, disconnecting an MCP client, restarting the container,
and rebooting the host.

The Docker Compose deployment stores that profile in the `chrome-profile`
volume. The VM installer bind-mounts it from the configured persistent data
directory and includes it in profile backups. Keep the same Compose project
name and never run `docker compose down --volumes` unless you intentionally
want to delete browser state.

Container Chrome uses its built-in basic password-store backend because the
container has no durable GNOME or KDE desktop keyring. This makes encrypted
site state readable after container replacement, but it also means the profile
volume must be protected as sensitive data. The browser service has an extended
graceful-stop window so Chrome can finish writing profile state during planned
maintenance.

No server can force a third-party website to keep a login valid forever. Sites
may expire cookies, revoke sessions, or require periodic verification. When
that happens, complete the new verification through `/login/`; do not create a
replacement browser profile.

## Open the console from an SSH-only session

Run `./login.sh` on the server and copy the displayed HTTPS URL to a browser on
your own computer. Retrieve the username and password through your normal
secure server access; do not paste the credential file into chat, tickets, or
shell history.

The noVNC service listens only on loopback. nginx is the public boundary and
protects `/login/` with separate login-console credentials.

## Human handoff

An automation agent should stop at a sign-in prompt, MFA challenge, CAPTCHA,
consent dialog, or other human-only step and report the login-console URL. The
human opens the console, completes only the required step, and tells the agent
to continue. The agent should take a fresh browser snapshot after handoff
instead of assuming that the page stayed unchanged.

The login console is for authentication and other interactive browser work. It
does not broaden authority for purchases, messages, account changes, or other
consequential actions.

## Credential storage

Native setup creates:

- `~/.config/remote-chrome-login.env`, mode `600`, containing
  `LOGIN_USERNAME`, `LOGIN_PASSWORD`, and `LOGIN_URL`;
- `/etc/nginx/.remote-chrome-login.htpasswd`, mode `600`, containing the
  bcrypt verifier used by nginx;
- `~/.config/mcp-bearer-token.env`, mode `600`, containing the independent MCP
  bearer token.

The login password and MCP bearer token serve different endpoints and must not
be reused. Setup preserves both files on rerun. Uninstall also preserves the
profile and secret files by default.

## Rotate the login password

Rotation does not require restarting Chrome. Perform it from a trusted local
shell:

1. Back up `~/.config/remote-chrome-login.env` somewhere protected.
2. Generate a new value with `openssl rand -base64 36`.
3. Replace only `LOGIN_PASSWORD` in the mode-`600` environment file.
4. Generate a new bcrypt entry with
   `htpasswd -bnBC 12 "$LOGIN_USERNAME" "$LOGIN_PASSWORD"` and install it as
   `/etc/nginx/.remote-chrome-login.htpasswd` with owner-only permissions.
5. Validate nginx with `sudo nginx -t`, then reload nginx.
6. Confirm that the old password is rejected and the new password opens the
   console.

Avoid command forms that place the password directly in shell history or
print it to a terminal transcript. Do not change the MCP bearer token as part
of login-console password rotation.

## Troubleshooting

Run `./status.sh` first. It reports all six user services, Chrome CDP metadata,
the headed user-agent check, MCP initialization and playbook marker, local
noVNC HTTP, nginx, and the authenticated public MCP endpoint.

- **HTTP 401 at `/login/`:** verify the username and password from the local
  mode-`600` file. If credentials were rotated, regenerate the htpasswd entry,
  run `sudo nginx -t`, and reload nginx.
- **Blank or disconnected noVNC page:** inspect
  `chrome-display.service`, `chrome-window-manager.service`,
  `chrome-mcp.service`, `chrome-vnc.service`, and
  `chrome-novnc.service` with `journalctl --user -u UNIT`.
- **Chrome is visible but MCP fails:** inspect `playwright-mcp.service`, then
  check the CDP and initialize sections of `./status.sh`.
- **Headed check fails:** do not start another Chrome process against
  `~/.config/chrome-mcp-profile`. Confirm that the generated user unit has no
  headless flag and that only `chrome-mcp.service` owns the profile.
- **Certificate or proxy failure:** run `sudo nginx -t`, inspect the nginx
  journal, and confirm DNS and the certificate for the configured domain.
- **Migration activation failed:** setup restores the previous generated
  service and nginx configuration. Review the protected backups under
  `~/.config/remote-chrome-backups/` before retrying.

Do not delete `Singleton*` files while Chrome is running. The service owns
profile lifecycle and prevents concurrent Chrome processes from using the
same profile.
