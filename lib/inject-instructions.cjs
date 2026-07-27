'use strict';

const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

function loadMcpUtilsBundle() {
  if (process.argv[1]) {
    try {
      const cliRequire = createRequire(fs.realpathSync(process.argv[1]));
      return cliRequire('playwright-core/lib/utilsBundle');
    } catch {
      // Tests and nonstandard launchers may not resolve from their entrypoint.
    }
  }
  return require('playwright-core/lib/utilsBundle');
}

const { Server } = loadMcpUtilsBundle();

const PATCHED = Symbol.for('remote-chrome.inject-instructions.patched');
const FALLBACK = `REMOTE_CHROME_PLAYBOOK_FALLBACK=1

Snapshot the current page before navigating. After a timeout, snapshot again.
Stop and ask the user for human control when login, MFA, CAPTCHA, or a security key is required.
Never expose credentials, cookies, or tokens.`;

if (!Server.prototype[PATCHED]) {
  const originalInitialize = Server.prototype._oninitialize;

  Object.defineProperty(Server.prototype, PATCHED, {
    value: true
  });

  Server.prototype._oninitialize = async function remoteChromeInitialize(request) {
    const configuredPath = process.env.REMOTE_CHROME_PLAYBOOK;
    const playbookPath = configuredPath
      ? path.resolve(configuredPath)
      : path.resolve(__dirname, '..', 'browser-playbook.md');

    let instructions = FALLBACK;
    try {
      const candidate = fs.readFileSync(playbookPath, 'utf8').trim();
      if (candidate)
        instructions = candidate;
      else
        console.error(`[remote-chrome] empty playbook: ${playbookPath}; using fallback`);
    } catch (error) {
      console.error(`[remote-chrome] cannot read playbook: ${playbookPath}; using fallback`);
    }

    this._instructions = instructions;
    return originalInitialize.call(this, request);
  };
}
