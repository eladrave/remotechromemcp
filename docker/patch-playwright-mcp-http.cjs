'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

const EXPECTED_MCP_VERSION = '0.0.79';
const EXPECTED_PLAYWRIGHT_CORE_VERSION = '1.63.0-alpha-2026-08-05';
const EXPECTED_ORIGINAL_SOURCE_SHA256 =
  'adf9246486a03bee08b2895db057ba470c62377911d291693fe783d91d6fec52';
const EXPECTED_ORIGINAL_BLOCK_SHA256 =
  '9a0e47686295f3bb96fdd23015b3be0bad0f4ef706b455bbaa2cc5cec9f5c2a1';
const EXPECTED_PATCHED_SOURCE_SHA256 =
  '96d225418072857aed717efba7b518f919e5ef29ae602ff1a2c9480ec7bc3127';
const EXPECTED_LIFECYCLE_PATCHED_SOURCE_SHA256 =
  '5d8ecd37a63e8ade5a8acc85f09b7221a1312af8a5e31763aaaa3ff5f631406e';

const DEFAULT_MCP_PACKAGE_JSON =
  '/usr/local/lib/node_modules/@playwright/mcp/package.json';
const START_MARKER =
  'async function handleStreamable(serverBackendFactory, req, res, sessions) {';
const END_MARKER =
  '\nvar import_assert54, import_crypto30, debug12, SSEServerTransport, StreamableHTTPServerTransport, testDebug2;';
const PATCH_MARKER = 'REMOTE_CHROME_MCP_HTTP_SESSION_PATCH=1';

const PATCHED_BLOCK = `// ${PATCH_MARKER}
async function handleStreamable(serverBackendFactory, req, res, sessions) {
  const removeSession = (sessionId2, sessionInfo, reason) => {
    if (sessions.get(sessionId2) !== sessionInfo)
      return false;
    sessions.delete(sessionId2);
    if (sessionInfo.idleTimer) {
      clearTimeout(sessionInfo.idleTimer);
      sessionInfo.idleTimer = void 0;
    }
    testDebug2(reason + " http session");
    return true;
  };
  const refreshIdleTimeout = (sessionId2, sessionInfo) => {
    if (sessions.get(sessionId2) !== sessionInfo || sessionInfo.retiring ||
        sessionInfo.activeRequests !== 0)
      return;
    if (sessionInfo.idleTimer)
      clearTimeout(sessionInfo.idleTimer);
    sessionInfo.idleTimer = setTimeout(() => {
      sessionInfo.idleTimer = void 0;
      if (!removeSession(sessionId2, sessionInfo, "expire"))
        return;
      void sessionInfo.transport.close().catch(debug12);
    }, sessionInfo.idleTimeoutMs);
    sessionInfo.idleTimer.unref?.();
  };
  const notifyRequestDrain = (sessionInfo) => {
    if (!sessionInfo.retiring || sessionInfo.activeRequests > 1)
      return;
    const waiters = sessionInfo.drainWaiters.splice(0);
    for (const resolve of waiters)
      resolve();
  };
  const waitForRequestDrain = (sessionInfo) => new Promise((resolve) => {
    let settled = false;
    const finish = (drained) => {
      if (settled)
        return;
      settled = true;
      clearTimeout(timer);
      const index = sessionInfo.drainWaiters.indexOf(onDrain);
      if (index !== -1)
        sessionInfo.drainWaiters.splice(index, 1);
      resolve(drained);
    };
    const onDrain = () => finish(true);
    const timer = setTimeout(() => finish(false), sessionInfo.drainTimeoutMs);
    timer.unref?.();
    sessionInfo.drainWaiters.push(onDrain);
  });
  const sessionId = req.headers["mcp-session-id"];
  if (sessionId) {
    const sessionInfo = sessions.get(sessionId);
    if (!sessionInfo) {
      res.statusCode = 404;
      res.end("Session not found");
      return;
    }
    if (sessionInfo.retiring) {
      res.statusCode = 404;
      res.end("Session not found");
      return;
    }
    if (sessionInfo.idleTimer) {
      clearTimeout(sessionInfo.idleTimer);
      sessionInfo.idleTimer = void 0;
    }
    sessionInfo.activeRequests++;
    try {
      if (req.method === "DELETE") {
        sessionInfo.retiring = true;
        if (sessionInfo.activeRequests > 1 &&
            !await waitForRequestDrain(sessionInfo)) {
          console.error("[remote-chrome-mcp] active HTTP request drain timed out; exiting for a clean restart");
          res.statusCode = 503;
          res.end("Session cleanup timed out");
          setImmediate(() => process.exit(1));
          return;
        }
      }
      if (req.method === "GET")
        sessionInfo.transportInitialized.resolve();
      return await sessionInfo.transport.handleRequest(req, res);
    } finally {
      sessionInfo.activeRequests--;
      notifyRequestDrain(sessionInfo);
      refreshIdleTimeout(sessionId, sessionInfo);
    }
  }
  if (req.method === "POST") {
    const idleTimeoutRaw = process.env.REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS ?? "1800000";
    const drainTimeoutRaw = process.env.REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS ?? "300000";
    const validTimeout = (value2) => /^[1-9][0-9]*$/.test(value2) &&
      Number.isSafeInteger(Number(value2)) && Number(value2) <= 2147483647;
    if (!validTimeout(idleTimeoutRaw)) {
      res.statusCode = 500;
      res.end("Invalid REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS");
      return;
    }
    if (!validTimeout(drainTimeoutRaw)) {
      res.statusCode = 500;
      res.end("Invalid REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS");
      return;
    }
    const idleTimeoutMs = Number(idleTimeoutRaw);
    let sessionInfo;
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => import_crypto30.default.randomUUID(),
      onsessioninitialized: async (sessionId2) => {
        testDebug2("create http session");
        sessionInfo = {
          transport,
          transportInitialized: new ManualPromise(),
          idleTimeoutMs,
          drainTimeoutMs: Number(drainTimeoutRaw),
          idleTimer: void 0,
          activeRequests: 1,
          retiring: false,
          drainWaiters: []
        };
        const rootsFallbackTimer = setTimeout(() => sessionInfo.transportInitialized.resolve(), 5e3);
        rootsFallbackTimer.unref?.();
        sessions.set(sessionId2, sessionInfo);
        try {
          await connect(serverBackendFactory, sessionInfo.transport, sessionInfo.transportInitialized, false);
        } catch (error) {
          removeSession(sessionId2, sessionInfo, "fail");
          await transport.close().catch(debug12);
          throw error;
        }
      }
    });
    transport.onclose = () => {
      if (!transport.sessionId || !sessionInfo)
        return;
      removeSession(transport.sessionId, sessionInfo, "delete");
    };
    try {
      await transport.handleRequest(req, res);
    } finally {
      if (sessionInfo) {
        sessionInfo.activeRequests--;
        notifyRequestDrain(sessionInfo);
        refreshIdleTimeout(transport.sessionId, sessionInfo);
      }
    }
    return;
  }
  res.statusCode = 400;
  res.end("Invalid request");
}`;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function countOccurrences(source, needle) {
  let count = 0;
  let offset = 0;
  while (true) {
    const index = source.indexOf(needle, offset);
    if (index === -1)
      return count;
    count += 1;
    offset = index + needle.length;
  }
}

function parseArguments(argv) {
  const options = {
    check: false,
    mcpPackageJson: DEFAULT_MCP_PACKAGE_JSON
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--check') {
      options.check = true;
      continue;
    }
    if (argument === '--mcp-package-json') {
      const value = argv[index + 1];
      if (!value)
        throw new Error('--mcp-package-json requires a path');
      options.mcpPackageJson = value;
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${argument}`);
  }
  return options;
}

function readPackageJson(packageJsonPath, label) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read ${label} package metadata at ${packageJsonPath}: ${error.message}`);
  }
  return parsed;
}

function resolveTargets(mcpPackageJsonArgument) {
  const mcpPackageJson = path.resolve(mcpPackageJsonArgument);
  const mcpPackage = readPackageJson(mcpPackageJson, '@playwright/mcp');
  if (mcpPackage.name !== '@playwright/mcp' ||
      mcpPackage.version !== EXPECTED_MCP_VERSION) {
    throw new Error(
      `expected @playwright/mcp@${EXPECTED_MCP_VERSION}, got ` +
      `${mcpPackage.name || '<unknown>'}@${mcpPackage.version || '<unknown>'}`
    );
  }

  const packageRequire = createRequire(mcpPackageJson);
  let playwrightCorePackageJson;
  let coreBundle;
  try {
    playwrightCorePackageJson =
      packageRequire.resolve('playwright-core/package.json');
    coreBundle = packageRequire.resolve('playwright-core/lib/coreBundle');
  } catch (error) {
    throw new Error(`cannot resolve Playwright MCP's playwright-core dependency: ${error.message}`);
  }
  const playwrightCorePackage =
    readPackageJson(playwrightCorePackageJson, 'playwright-core');
  if (playwrightCorePackage.version !== EXPECTED_PLAYWRIGHT_CORE_VERSION) {
    throw new Error(
      `expected playwright-core@${EXPECTED_PLAYWRIGHT_CORE_VERSION}, got ` +
      `${playwrightCorePackage.version || '<unknown>'}`
    );
  }
  return { coreBundle };
}

function originalBlockBounds(source) {
  const startCount = countOccurrences(source, START_MARKER);
  const endCount = countOccurrences(source, END_MARKER);
  if (startCount !== 1 || endCount !== 1)
    throw new Error(`expected one HTTP patch signature, got start=${startCount} end=${endCount}`);
  const start = source.indexOf(START_MARKER);
  const end = source.indexOf(END_MARKER, start);
  if (end === -1)
    throw new Error('HTTP patch end signature precedes its start signature');
  return { start, end };
}

function verifyOriginalSource(source) {
  const sourceHash = sha256(source);
  if (sourceHash !== EXPECTED_ORIGINAL_SOURCE_SHA256) {
    throw new Error(
      `original coreBundle.js SHA-256 mismatch: expected ` +
      `${EXPECTED_ORIGINAL_SOURCE_SHA256}, got ${sourceHash}`
    );
  }
  const { start, end } = originalBlockBounds(source);
  const blockHash = sha256(source.slice(start, end));
  if (blockHash !== EXPECTED_ORIGINAL_BLOCK_SHA256) {
    throw new Error(
      `original handleStreamable block SHA-256 mismatch: expected ` +
      `${EXPECTED_ORIGINAL_BLOCK_SHA256}, got ${blockHash}`
    );
  }
  if (source.includes(PATCH_MARKER))
    throw new Error('coreBundle.js already contains the Remote Chrome HTTP session patch');
  return { start, end };
}

function verifyPatchedSource(source) {
  const sourceHash = sha256(source);
  if (sourceHash !== EXPECTED_PATCHED_SOURCE_SHA256 &&
      sourceHash !== EXPECTED_LIFECYCLE_PATCHED_SOURCE_SHA256) {
    throw new Error(
      `patched coreBundle.js SHA-256 mismatch: expected HTTP-only ` +
      `${EXPECTED_PATCHED_SOURCE_SHA256} or combined ` +
      `${EXPECTED_LIFECYCLE_PATCHED_SOURCE_SHA256}, got ${sourceHash}`
    );
  }
  if (countOccurrences(source, PATCH_MARKER) !== 1)
    throw new Error('patched coreBundle.js must contain exactly one patch marker');
  if (countOccurrences(source, PATCHED_BLOCK) !== 1)
    throw new Error('patched coreBundle.js does not contain the exact replacement block');
}

function patch(options) {
  const { coreBundle } = resolveTargets(options.mcpPackageJson);
  const source = fs.readFileSync(coreBundle, 'utf8');

  if (options.check) {
    verifyPatchedSource(source);
    process.stdout.write(`verified Playwright MCP HTTP session patch: ${coreBundle}\n`);
    return;
  }

  if (source.includes(PATCH_MARKER))
    throw new Error('coreBundle.js is already patched; use --check to verify it');
  const { start, end } = verifyOriginalSource(source);
  const patchedSource =
    source.slice(0, start) + PATCHED_BLOCK + source.slice(end);
  verifyPatchedSource(patchedSource);
  fs.writeFileSync(coreBundle, patchedSource, 'utf8');
  verifyPatchedSource(fs.readFileSync(coreBundle, 'utf8'));
  process.stdout.write(`patched Playwright MCP HTTP sessions: ${coreBundle}\n`);
}

function main() {
  try {
    patch(parseArguments(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`Playwright MCP HTTP patch failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  EXPECTED_ORIGINAL_SOURCE_SHA256,
  EXPECTED_ORIGINAL_BLOCK_SHA256,
  EXPECTED_PATCHED_SOURCE_SHA256,
  EXPECTED_LIFECYCLE_PATCHED_SOURCE_SHA256,
  PATCHED_BLOCK,
  PATCH_MARKER,
  START_MARKER,
  END_MARKER,
  originalBlockBounds,
  sha256
};

if (require.main === module)
  main();
