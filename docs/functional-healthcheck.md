# Remote Chrome functional healthcheck

The container's built-in health check verifies local processes, Chrome CDP,
the MCP listener, and noVNC. Those checks are intentionally lightweight and
non-mutating. They do not prove that Playwright can create a usable browser
connection and execute a real MCP browser tool.

The functional healthcheck closes that gap. It creates a temporary public MCP
session, sends `notifications/initialized`, discovers the tool catalog, calls
the read-only `browser_snapshot` tool, and explicitly deletes the temporary
session. Snapshot contents, credentials, and connection URLs are never written
to the journal.

## Install the hourly systemd timer

The VM installer stores `MCP_URL` and `MCP_TOKEN` in the root-only
`/etc/remote-chrome/credentials.env` file. From a trusted checkout, run:

```bash
sudo scripts/install-functional-healthcheck.sh
```

The installer copies the checker to
`/usr/local/libexec/remote-chrome-functional-healthcheck` and installs:

- `remote-chrome-functional-healthcheck.service`
- `remote-chrome-functional-healthcheck.timer`

The default schedule is `OnCalendar=hourly` with `Persistent=yes`. A missed run
is therefore executed after the host returns. To choose another systemd
calendar expression:

```bash
sudo scripts/install-functional-healthcheck.sh \
  --on-calendar '*-*-* *:15/30:00'
```

The checker validates that the credential file is root-owned and inaccessible
to group and other users. It supplies authorization through a temporary
mode-`0600` header file, so the bearer token is not exposed in the process
list. Do not put the token directly in the unit or installer arguments.

## Verify and operate

Run an immediate check:

```bash
sudo systemctl start remote-chrome-functional-healthcheck.service
```

Inspect the schedule and the last result:

```bash
systemctl list-timers remote-chrome-functional-healthcheck.timer
systemctl status remote-chrome-functional-healthcheck.timer
systemctl status remote-chrome-functional-healthcheck.service
journalctl -u remote-chrome-functional-healthcheck.service
```

A successful journal entry is:

```text
remote-chrome functional healthcheck passed: initialize, tools/list, browser_snapshot, DELETE
```

Failures identify only the failed protocol stage. The checker deliberately
does not log the endpoint, bearer token, snapshot, or page contents.

## Failure handling

The timer is alert-only: it does not restart the browser container. An
automatic restart could interrupt an active agent workflow. On failure:

1. Check `systemctl status remote-chrome.service` and the browser container.
2. Run the functional check manually and review its journal entry.
3. If the same browser-tool failure repeats and no workflow is active, restart
   only `remote-chrome.service`.
4. Run the functional check again before declaring recovery.

The persistent Chrome profile is bind-mounted outside the container. Do not use
`docker compose down --volumes` as a health-recovery action.

## Remove the timer

Removing the canary does not affect Chrome or its persistent profile:

```bash
sudo systemctl disable --now remote-chrome-functional-healthcheck.timer
sudo unlink /etc/systemd/system/remote-chrome-functional-healthcheck.timer
sudo unlink /etc/systemd/system/remote-chrome-functional-healthcheck.service
sudo unlink /usr/local/libexec/remote-chrome-functional-healthcheck
sudo systemctl daemon-reload
```
