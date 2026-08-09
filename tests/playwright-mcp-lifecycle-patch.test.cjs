'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { EventEmitter } = require('node:events');
const test = require('node:test');
const vm = require('node:vm');

const repoRoot = path.resolve(__dirname, '..');
const httpPatchScript =
  path.join(repoRoot, 'docker', 'patch-playwright-mcp-http.cjs');
const lifecyclePatchScript =
  path.join(repoRoot, 'docker', 'patch-playwright-mcp-lifecycle.cjs');
const localMcpPackage =
  path.join(repoRoot, 'node_modules', '@playwright', 'mcp', 'package.json');
const localCoreRoot = path.join(repoRoot, 'node_modules', 'playwright-core');
const {
  BACKEND_END,
  BACKEND_START,
  CALL_TOOL_FINALLY,
  CALL_TOOL_START,
  PATCHED_BACKEND_BLOCK,
  PATCHED_CALL_TOOL_FINALLY,
  PATCHED_CALL_TOOL_START,
  PATCHED_PROGRAM_BLOCK,
  blockBounds,
} = require(lifecyclePatchScript);

function loadPatchedBrowserBackend(overrides = {}) {
  const source = fs.readFileSync(
    path.join(localCoreRoot, 'lib', 'coreBundle.js'),
    'utf8',
  );
  const classStart = source.indexOf(BACKEND_START);
  const classEndMarker =
    '\n    };\n  }\n});\n\n// packages/playwright-core/src/tools/backend/common.ts';
  const classEnd = source.indexOf(classEndMarker, classStart);
  assert.notEqual(classStart, -1);
  assert.notEqual(classEnd, -1);
  let classSource = source.slice(classStart, classEnd + '\n    };'.length);
  const originalPrefixEnd = classSource.indexOf(BACKEND_END);
  assert.notEqual(originalPrefixEnd, -1);
  classSource = PATCHED_BACKEND_BLOCK + classSource.slice(originalPrefixEnd);
  classSource = classSource.replace(CALL_TOOL_START, PATCHED_CALL_TOOL_START);
  classSource = classSource.replace(
    CALL_TOOL_FINALLY,
    PATCHED_CALL_TOOL_FINALLY,
  );

  class FakeContext {
    constructor() {
      this.disposeCalls = 0;
    }
    setRunningTool() {}
    drainPendingUnhandledRejections() { return []; }
    async dispose() { this.disposeCalls += 1; }
  }
  class FakeResponse {
    addError() {}
    async serialize() { return { content: [] }; }
  }
  const sandbox = {
    BrowserBackend: undefined,
    Context: overrides.Context || FakeContext,
    Response4: FakeResponse,
    SessionLog: overrides.SessionLog || { create: async () => undefined },
    backendDebug: () => {},
    debug10: () => () => {},
    formatRejectionReason: String,
    import_events29: { EventEmitter },
    process: overrides.process || {
      env: {},
      exit: () => { throw new Error('unexpected process exit'); },
    },
    console: overrides.console || { error: () => {} },
    setTimeout,
    clearTimeout,
    setImmediate,
    z5: { ZodError: class extends Error {}, prettifyError: String },
  };
  vm.runInNewContext(`${classSource}\nthis.result = BrowserBackend;`, sandbox);
  return sandbox.result;
}

function fakeBrowserPair(browser = new EventEmitter()) {
  const browserContext = new EventEmitter();
  browserContext.browser = () => browser;
  return { browser, browserContext };
}

function createFixture(t) {
  const fixtureRoot =
    fs.mkdtempSync(path.join(os.tmpdir(), 'remote-chrome-lifecycle-patch-'));
  t.after(() => fs.rmSync(fixtureRoot, { recursive: true, force: true }));

  const mcpRoot =
    path.join(fixtureRoot, 'node_modules', '@playwright', 'mcp');
  const coreRoot = path.join(mcpRoot, 'node_modules', 'playwright-core');
  fs.mkdirSync(mcpRoot, { recursive: true });
  fs.copyFileSync(localMcpPackage, path.join(mcpRoot, 'package.json'));
  fs.cpSync(localCoreRoot, coreRoot, { recursive: true });

  return {
    mcpPackageJson: path.join(mcpRoot, 'package.json'),
    coreBundle: path.join(coreRoot, 'lib', 'coreBundle.js'),
  };
}

function run(script, mcpPackageJson, ...extraArguments) {
  return spawnSync(
    process.execPath,
    [script, ...extraArguments, '--mcp-package-json', mcpPackageJson],
    { encoding: 'utf8' },
  );
}

function applyHttpPatch(fixture) {
  const result = run(httpPatchScript, fixture.mcpPackageJson);
  assert.equal(result.status, 0, result.stderr);
}

function assertFailed(result, expectedMessage) {
  assert.notEqual(result.status, 0, result.stdout);
  assert.match(result.stderr, expectedMessage);
}

test('patches and verifies the exact Playwright MCP 0.0.79 lifecycle', t => {
  const fixture = createFixture(t);
  applyHttpPatch(fixture);

  const patched = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assert.equal(patched.status, 0, patched.stderr);
  assert.match(patched.stdout, /patched Playwright MCP lifecycle/);

  const verified = run(
    lifecyclePatchScript,
    fixture.mcpPackageJson,
    '--check',
  );
  assert.equal(verified.status, 0, verified.stderr);
  assert.match(verified.stdout, /verified Playwright MCP lifecycle patch/);

  const httpVerifiedAfterLifecycle = run(
    httpPatchScript,
    fixture.mcpPackageJson,
    '--check',
  );
  assert.equal(
    httpVerifiedAfterLifecycle.status,
    0,
    httpVerifiedAfterLifecycle.stderr,
  );

  const source = fs.readFileSync(fixture.coreBundle, 'utf8');
  assert.match(source, /REMOTE_CHROME_MCP_LIFECYCLE_PATCH=1/);
  assert.match(
    source,
    /Playwright MCP browser connection has no BrowserContext/,
  );
  assert.match(source, /this\._browserContext\.off\("close"/);
  assert.match(source, /this\._browser\?\.off\("disconnected"/);
  assert.match(source, /backend2\.onDisconnected\(\(\) =>/);
  assert.match(source, /this\._drainPromise\.then\(\(\) => true\)/);
  assert.match(source, /const clientOwners = .*new Set\(\)/);
  assert.match(source, /if \(owner\.released\)/);
  assert.match(source, /browser\.once\("disconnected"/);
  assert.match(source, /if \(!browser\.isConnected\(\)\)/);
  assert.match(source, /sharedBrowserPromise === promise/);
  assert.match(source, /browser\.contexts\(\)\[0\]/);
  assert.match(
    source,
    /Playwright MCP could not acquire a BrowserContext after reconnecting/,
  );
  assert.match(
    source,
    /fatal unhandled rejection; exiting for a clean restart/,
  );
  assert.doesNotMatch(
    PATCHED_PROGRAM_BLOCK,
    /rawMessage|sanitizedMessage|reason\.stack/,
  );
  assert.match(source, /setImmediate\(\(\) => process\.exit\(1\)\)/);
});

test('latches an early disconnect until the server attaches its listener', async () => {
  const BrowserBackend = loadPatchedBrowserBackend();
  const { browser, browserContext } = fakeBrowserPair();
  let disposeCalls = 0;
  const backend = new BrowserBackend(
    { saveSession: false },
    browserContext,
    [],
    async () => { disposeCalls += 1; },
  );
  await backend.initialize({ cwd: undefined });

  browser.emit('disconnected');
  let notifications = 0;
  backend.onDisconnected(() => { notifications += 1; });
  assert.equal(notifications, 1);

  await backend.dispose();
  await backend.dispose();
  assert.equal(disposeCalls, 1);
  assert.equal(browser.listenerCount('disconnected'), 0);
  assert.equal(browserContext.listenerCount('close'), 0);
});

test('releases ownership and listeners when backend initialization fails', async () => {
  const failures = [
    {
      label: 'session log',
      config: { saveSession: true },
      overrides: {
        SessionLog: {
          create: async () => { throw new Error('forced session log failure'); },
        },
      },
      expected: /forced session log failure/,
    },
    {
      label: 'context construction',
      config: { saveSession: false },
      overrides: {
        Context: class {
          constructor() { throw new Error('forced context construction failure'); }
        },
      },
      expected: /forced context construction failure/,
    },
  ];

  for (const failure of failures) {
    const BrowserBackend = loadPatchedBrowserBackend(failure.overrides);
    const { browser, browserContext } = fakeBrowserPair();
    let disposeCalls = 0;
    const backend = new BrowserBackend(
      failure.config,
      browserContext,
      [],
      async () => { disposeCalls += 1; },
    );
    await assert.rejects(
      backend.initialize({ cwd: undefined }),
      failure.expected,
      failure.label,
    );
    await backend.dispose();
    assert.equal(disposeCalls, 1, failure.label);
    assert.equal(browser.listenerCount('disconnected'), 0, failure.label);
    assert.equal(browserContext.listenerCount('close'), 0, failure.label);
  }
});

test('defers last-owner disposal until an active browser tool finishes', async () => {
  const BrowserBackend = loadPatchedBrowserBackend();
  const { browser, browserContext } = fakeBrowserPair();
  let releaseTool;
  let toolStarted;
  const started = new Promise(resolve => { toolStarted = resolve; });
  const toolGate = new Promise(resolve => { releaseTool = resolve; });
  const tools = [{
    schema: {
      name: 'controlled_tool',
      inputSchema: { parse: value => value },
    },
    handle: async () => {
      toolStarted();
      await toolGate;
    },
  }];
  let disposeCalls = 0;
  const backend = new BrowserBackend(
    { saveSession: false },
    browserContext,
    tools,
    async () => { disposeCalls += 1; },
  );
  await backend.initialize({ cwd: undefined });

  const tool = backend.callTool('controlled_tool', {});
  await started;
  let disposalFinished = false;
  const disposal = backend.dispose().then(() => { disposalFinished = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(disposalFinished, false);
  assert.equal(disposeCalls, 0);

  releaseTool();
  await tool;
  await disposal;
  await backend.dispose();
  assert.equal(disposeCalls, 1);
  assert.equal(browser.listenerCount('disconnected'), 0);
  assert.equal(browserContext.listenerCount('close'), 0);
  await assert.rejects(
    backend.callTool('controlled_tool', {}),
    /browser backend is disposing/,
  );
});

test('uses a bounded data-free fail-safe for a non-terminating browser tool', async () => {
  const exits = [];
  const logs = [];
  const BrowserBackend = loadPatchedBrowserBackend({
    process: {
      env: { REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS: '25' },
      exit: code => { exits.push(code); },
    },
    console: { error: message => { logs.push(message); } },
  });
  const { browserContext } = fakeBrowserPair();
  const tools = [{
    schema: {
      name: 'never_finishes',
      inputSchema: { parse: value => value },
    },
    handle: async () => new Promise(() => {}),
  }];
  let disposeCalls = 0;
  const backend = new BrowserBackend(
    { saveSession: false },
    browserContext,
    tools,
    async () => { disposeCalls += 1; },
  );
  await backend.initialize({ cwd: undefined });
  void backend.callTool('never_finishes', {});
  await new Promise(resolve => setImmediate(resolve));

  const keepAlive = setInterval(() => {}, 1000);
  try {
    await backend.dispose();
    await new Promise(resolve => setImmediate(resolve));
  } finally {
    clearInterval(keepAlive);
  }
  assert.deepEqual(exits, [1]);
  assert.deepEqual(logs, [
    '[remote-chrome-mcp] active browser tool drain timed out; exiting for a clean restart',
  ]);
  assert.equal(disposeCalls, 0);
});

test('releases disconnect listeners and disposes each backend exactly once', async () => {
  const BrowserBackend = loadPatchedBrowserBackend();
  const browser = new EventEmitter();
  browser.setMaxListeners(0);
  const backends = [];
  let disposeCalls = 0;
  for (let index = 0; index < 100; index += 1) {
    const { browserContext } = fakeBrowserPair(browser);
    const backend = new BrowserBackend(
      { saveSession: false },
      browserContext,
      [],
      async () => { disposeCalls += 1; },
    );
    await backend.initialize({ cwd: undefined });
    backends.push({ backend, browserContext });
  }
  assert.equal(browser.listenerCount('disconnected'), backends.length);

  await Promise.all(backends.flatMap(({ backend }) => [
    backend.dispose(),
    backend.dispose(),
  ]));
  assert.equal(disposeCalls, backends.length);
  assert.equal(browser.listenerCount('disconnected'), 0);
  for (const { browserContext } of backends)
    assert.equal(browserContext.listenerCount('close'), 0);
});

test('requires the HTTP patch before applying the lifecycle patch', t => {
  const fixture = createFixture(t);
  const result = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assertFailed(result, /expected HTTP-patched coreBundle\.js SHA-256/);
});

test('refuses lifecycle patching when the exact HTTP-patched source drifts', t => {
  const fixture = createFixture(t);
  applyHttpPatch(fixture);
  fs.appendFileSync(fixture.coreBundle, '\n// unexpected drift\n');

  const result = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assertFailed(result, /expected HTTP-patched coreBundle\.js SHA-256/);
});

test('refuses a second lifecycle patch application', t => {
  const fixture = createFixture(t);
  applyHttpPatch(fixture);
  const first = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assert.equal(first.status, 0, first.stderr);

  const second = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assertFailed(second, /already lifecycle patched; use --check/);
});

test('check mode fails closed before lifecycle patching', t => {
  const fixture = createFixture(t);
  applyHttpPatch(fixture);

  const result = run(
    lifecyclePatchScript,
    fixture.mcpPackageJson,
    '--check',
  );
  assertFailed(result, /lifecycle-patched coreBundle\.js SHA-256 mismatch/);
});

test('refuses any @playwright/mcp version other than 0.0.79', t => {
  const fixture = createFixture(t);
  const metadata = JSON.parse(fs.readFileSync(fixture.mcpPackageJson, 'utf8'));
  metadata.version = '0.0.80';
  fs.writeFileSync(
    fixture.mcpPackageJson,
    `${JSON.stringify(metadata, null, 2)}\n`,
  );

  const result = run(lifecyclePatchScript, fixture.mcpPackageJson);
  assertFailed(result, /expected @playwright\/mcp@0\.0\.79/);
});

test('rejects ambiguous lifecycle source signatures', () => {
  assert.throws(
    () => blockBounds(
      `${BACKEND_START}\nfirst${BACKEND_END}\n${BACKEND_START}\nsecond`,
      BACKEND_START,
      BACKEND_END,
      'BrowserBackend lifecycle block',
    ),
    /expected one BrowserBackend lifecycle block signature, got start=2 end=1/,
  );
});
