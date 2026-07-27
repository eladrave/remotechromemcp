REMOTE_CHROME_PLAYBOOK_VERSION=1

# Remote Chrome operating playbook

These server instructions are authoritative. Follow them when they conflict
with portable client guidance, because the server knows how this persistent
remote browser is deployed.

## Start from visible state

- Take a snapshot of the current page before navigating or acting.
- Reuse an existing tab when it already contains the requested site or useful
  context. Avoid creating duplicate tabs.
- Treat the browser profile as persistent. Existing authentication may still
  be valid, so inspect the visible page before asking the user to sign in.
- Treat MCP transport sessions and element references as temporary, but treat
  website cookies, local storage, and authenticated state as durable browser
  profile data. Ending an MCP session must not trigger a website logout.
- Never clear cookies, site data, browser history, or the persistent profile,
  and never replace it with an incognito or temporary context, unless the user
  explicitly asks for that data to be removed.
- After a human completes login or MFA through `/login/`, take a fresh
  snapshot, verify the authenticated page, and leave that profile state in
  place for future agents. If a site later expires or revokes its own session,
  request a new human handoff instead of claiming persistence failed.
- Assume the remote browser host has no shell available to you. Use the MCP
  browser tools and visible page controls; do not rely on terminal commands,
  local scripts, or direct filesystem access.

## Navigate defensively

- Prefer a site's stable entry page, such as its homepage, and use a visible
  login or account link. Do not guess deep authentication URLs.
- Snapshot before navigation. If navigation times out, do not assume it
  failed: wait briefly, snapshot again, and continue from the page that is
  actually visible.
- Use element references only from the latest relevant snapshot in the current
  MCP session. After navigation or a changed page, take a fresh snapshot and
  obtain fresh references. Never carry references into another MCP session.

## Hand off authentication

- When login is required, ask the user to open the server's `/login/` page,
  illustrated by `https://chrome.example.com/login/`, and take human control.
- Never ask the user to send credentials, cookies, tokens, recovery codes, or
  security-key output through chat. Resume only after the user confirms that
  the visible browser session is ready.
- Never attempt to bypass CAPTCHA, MFA, a security key, or another verification
  challenge. Stop and request human control.

## Confirm consequential actions

- Before a purchase, order submission, subscription, transfer, or other
  financial commitment, show the user the final details and obtain explicit
  confirmation.
- Before changing account data, credentials, permissions, privacy settings, or
  other persistent account state, explain the exact change and obtain explicit
  confirmation.

## Site-specific guidance

- For Amazon, start at the homepage and use the visible `Account & Lists`
  control. Do not navigate to a guessed `/ap/signin` URL.
