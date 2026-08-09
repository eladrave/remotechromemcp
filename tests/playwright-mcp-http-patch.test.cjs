'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repoRoot = path.resolve(__dirname, '..');
const patchScript =
  path.join(repoRoot, 'docker', 'patch-playwright-mcp-http.cjs');
const localMcpPackage =
  path.join(repoRoot, 'node_modules', '@playwright', 'mcp', 'package.json');
const localCorePackage =
  path.join(repoRoot, 'node_modules', 'playwright-core', 'package.json');
const localCoreBundle =
  path.join(repoRoot, 'node_modules', 'playwright-core', 'lib', 'coreBundle.js');
const localCoreRoot =
  path.join(repoRoot, 'node_modules', 'playwright-core');
const { END_MARKER, START_MARKER, originalBlockBounds } = require(patchScript);

function createFixture(t, options = {}) {
  const fixtureRoot =
    fs.mkdtempSync(path.join(os.tmpdir(), 'remote-chrome-mcp-patch-'));
  t.after(() => fs.rmSync(fixtureRoot, { recursive: true, force: true }));

  const mcpRoot =
    path.join(fixtureRoot, 'node_modules', '@playwright', 'mcp');
  const coreRoot = path.join(mcpRoot, 'node_modules', 'playwright-core');
  const coreLib = path.join(coreRoot, 'lib');
  fs.mkdirSync(coreLib, { recursive: true });

  const mcpPackageJson = path.join(mcpRoot, 'package.json');
  const corePackageJson = path.join(coreRoot, 'package.json');
  const coreBundle = path.join(coreLib, 'coreBundle.js');
  fs.copyFileSync(localMcpPackage, mcpPackageJson);
  if (options.fullCore) {
    fs.rmSync(coreRoot, { recursive: true, force: true });
    fs.cpSync(localCoreRoot, coreRoot, { recursive: true });
  } else {
    fs.copyFileSync(localCorePackage, corePackageJson);
    fs.copyFileSync(localCoreBundle, coreBundle);
  }

  return { mcpPackageJson, corePackageJson, coreBundle };
}

function runPatch(mcpPackageJson, ...extraArguments) {
  return spawnSync(
    process.execPath,
    [
      patchScript,
      ...extraArguments,
      '--mcp-package-json',
      mcpPackageJson
    ],
    { encoding: 'utf8' }
  );
}

function assertFailed(result, expectedMessage) {
  assert.notEqual(result.status, 0, result.stdout);
  assert.match(result.stderr, expectedMessage);
}

test('patches and verifies the exact Playwright MCP 0.0.79 bundle', t => {
  const fixture = createFixture(t);

  const patched = runPatch(fixture.mcpPackageJson);
  assert.equal(patched.status, 0, patched.stderr);
  assert.match(patched.stdout, /patched Playwright MCP HTTP sessions/);

  const verified = runPatch(fixture.mcpPackageJson, '--check');
  assert.equal(verified.status, 0, verified.stderr);
  assert.match(verified.stdout, /verified Playwright MCP HTTP session patch/);

  const source = fs.readFileSync(fixture.coreBundle, 'utf8');
  assert.match(source, /REMOTE_CHROME_MCP_HTTP_SESSION_PATCH=1/);
  assert.match(
    source,
    /REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS \?\? "1800000"/
  );
  assert.match(
    source,
    /REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS \?\? "300000"/
  );
  assert.match(source, /active HTTP request drain timed out/);
  assert.match(source, /setImmediate\(\(\) => process\.exit\(1\)\)/);
  assert.match(
    source,
    /connect\(serverBackendFactory, sessionInfo\.transport, sessionInfo\.transportInitialized, false\)/
  );
  assert.match(source, /sessionInfo\.transport\.close\(\)\.catch\(debug12\)/);
  assert.match(source, /sessions\.delete\(sessionId2\)/);
  assert.doesNotMatch(
    source,
    /connect\(serverBackendFactory, sessionInfo\.transport, sessionInfo\.transportInitialized, true\)/
  );
});

test('refuses to patch a bundle whose exact source signature changed', t => {
  const fixture = createFixture(t);
  const source = fs.readFileSync(fixture.coreBundle, 'utf8');
  fs.writeFileSync(
    fixture.coreBundle,
    source.replace('testDebug2(`create http session`);',
      'testDebug2(`changed http session`);')
  );

  const result = runPatch(fixture.mcpPackageJson);
  assertFailed(result, /original coreBundle\.js SHA-256 mismatch/);
});

test('refuses a second patch application and requires explicit verification', t => {
  const fixture = createFixture(t);
  const first = runPatch(fixture.mcpPackageJson);
  assert.equal(first.status, 0, first.stderr);

  const second = runPatch(fixture.mcpPackageJson);
  assertFailed(second, /already patched; use --check/);
});

test('refuses any @playwright/mcp version other than 0.0.79', t => {
  const fixture = createFixture(t);
  const metadata = JSON.parse(
    fs.readFileSync(fixture.mcpPackageJson, 'utf8')
  );
  metadata.version = '0.0.80';
  fs.writeFileSync(
    fixture.mcpPackageJson,
    `${JSON.stringify(metadata, null, 2)}\n`
  );

  const result = runPatch(fixture.mcpPackageJson);
  assertFailed(result, /expected @playwright\/mcp@0\.0\.79/);
});

test('check mode fails closed on an unpatched exact bundle', t => {
  const fixture = createFixture(t);
  const result = runPatch(fixture.mcpPackageJson, '--check');
  assertFailed(result, /patched coreBundle\.js SHA-256 mismatch/);
});

test('rejects ambiguous HTTP source signatures', () => {
  assert.throws(
    () => originalBlockBounds(
      `${START_MARKER}\nfirst${END_MARKER}\n${START_MARKER}\nsecond`,
    ),
    /expected one HTTP patch signature, got start=2 end=1/,
  );
});

test('patched transport reuses sessions and closes resources on TTL and DELETE', t => {
  const fixture = createFixture(t, { fullCore: true });
  const patched = runPatch(fixture.mcpPackageJson);
  assert.equal(patched.status, 0, patched.stderr);

  const probeSource = String.raw`
    'use strict';
    const net = require('node:net');
    const { EventEmitter } = require('node:events');
    const { tools } = require(process.env.PATCHED_CORE_BUNDLE);
    const { z } = require(process.env.PATCHED_UTILS_BUNDLE);
    const delay = milliseconds =>
      new Promise(resolve => setTimeout(resolve, milliseconds));

    async function main() {
      const portProbe = net.createServer();
      await new Promise(resolve =>
        portProbe.listen(0, '127.0.0.1', resolve));
      const port = portProbe.address().port;
      await new Promise(resolve => portProbe.close(resolve));

      let disposed = 0;
      let activeCalls = 0;
      let completedCalls = 0;
      let disposedDuringActiveCall = false;
      const factory = {
        name: 'Remote Chrome patch probe',
        nameInConfig: 'remote-chrome-patch-probe',
        version: '1',
        toolSchemas: [{
          name: 'probe',
          title: 'Probe',
          description: 'Initialize the test backend',
          type: 'readOnly',
          inputSchema: z.object({})
        }],
        create: async () => {
          const backend = new EventEmitter();
          backend.callTool = async (_name, args) => {
            activeCalls += 1;
            if (args.wait)
              await delay(250);
            completedCalls += 1;
            activeCalls -= 1;
            return { content: [{ type: 'text', text: 'ok' }] };
          };
          backend.dispose = async () => {
            if (activeCalls)
              disposedDuringActiveCall = true;
            disposed += 1;
          };
          return backend;
        }
      };

      const originalError = console.error;
      console.error = () => {};
      await tools.start(factory, {
        host: '127.0.0.1',
        port,
        allowedHosts: ['*']
      });
      console.error = originalError;

      const url = 'http://127.0.0.1:' + port + '/mcp';
      const requestHeaders = {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream'
      };
      async function post(payload, sessionId) {
        const response = await fetch(url, {
          method: 'POST',
          headers: {
            ...requestHeaders,
            ...(sessionId ? { 'mcp-session-id': sessionId } : {})
          },
          body: JSON.stringify(payload)
        });
        await response.text();
        return response;
      }
      async function initialize(id) {
        const response = await post({
          jsonrpc: '2.0',
          id,
          method: 'initialize',
          params: {
            protocolVersion: '2024-11-05',
            capabilities: {},
            clientInfo: { name: 'probe', version: '1' }
          }
        });
        return {
          response,
          sessionId: response.headers.get('mcp-session-id')
        };
      }
      async function waitForDisposals(expected) {
        for (let attempt = 0; attempt < 50 && disposed < expected; attempt += 1)
          await delay(10);
      }

      const idleSession = await initialize(1);
      await post({
        jsonrpc: '2.0',
        method: 'notifications/initialized'
      }, idleSession.sessionId);
      const first = await post({
        jsonrpc: '2.0',
        id: 2,
        method: 'tools/call',
        params: { name: 'probe', arguments: {} }
      }, idleSession.sessionId);
      await delay(100);
      const second = await post({
        jsonrpc: '2.0',
        id: 3,
        method: 'tools/list',
        params: {}
      }, idleSession.sessionId);
      await delay(250);
      const afterIdle = await post({
        jsonrpc: '2.0',
        id: 4,
        method: 'tools/list',
        params: {}
      }, idleSession.sessionId);
      await waitForDisposals(1);

      const deletedSession = await initialize(10);
      await post({
        jsonrpc: '2.0',
        method: 'notifications/initialized'
      }, deletedSession.sessionId);
      const activeCall = post({
        jsonrpc: '2.0',
        id: 11,
        method: 'tools/call',
        params: { name: 'probe', arguments: { wait: true } }
      }, deletedSession.sessionId);
      await delay(50);
      const deletionStartedAt = Date.now();
      const deletionPromise = fetch(url, {
        method: 'DELETE',
        headers: {
          accept: 'application/json, text/event-stream',
          'mcp-session-id': deletedSession.sessionId
        }
      });
      await delay(25);
      const whileRetiring = await post({
        jsonrpc: '2.0',
        id: 12,
        method: 'tools/list',
        params: {}
      }, deletedSession.sessionId);
      const [activeResponse, deletion] = await Promise.all([
        activeCall,
        deletionPromise,
      ]);
      const deletionElapsed = Date.now() - deletionStartedAt;
      await deletion.text();
      const afterDelete = await post({
        jsonrpc: '2.0',
        id: 13,
        method: 'tools/list',
        params: {}
      }, deletedSession.sessionId);
      await waitForDisposals(2);

      process.stdout.write(JSON.stringify({
        initialization: idleSession.response.status,
        first: first.status,
        second: second.status,
        afterIdle: afterIdle.status,
        deletion: deletion.status,
        activeResponse: activeResponse.status,
        whileRetiring: whileRetiring.status,
        afterDelete: afterDelete.status,
        deletionWaited: deletionElapsed >= 150,
        completedCalls,
        disposedDuringActiveCall,
        disposed
      }));
    }

    main().then(
      () => process.exit(0),
      error => {
        console.error(error);
        process.exit(1);
      }
    );
  `;
  const result = spawnSync(process.execPath, ['--eval', probeSource], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATCHED_CORE_BUNDLE: fixture.coreBundle,
      PATCHED_UTILS_BUNDLE:
        path.join(path.dirname(fixture.coreBundle), 'utilsBundle.js'),
      REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS: '200',
      REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS: '1000'
    },
    timeout: 10_000
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    initialization: 200,
    first: 200,
    second: 200,
    afterIdle: 404,
    deletion: 200,
    activeResponse: 200,
    whileRetiring: 404,
    afterDelete: 404,
    deletionWaited: true,
    completedCalls: 2,
    disposedDuringActiveCall: false,
    disposed: 2
  });
});

test('HTTP drain timeout returns 503 and exits with a data-free diagnostic', async t => {
  const fixture = createFixture(t, { fullCore: true });
  const patched = runPatch(fixture.mcpPackageJson);
  assert.equal(patched.status, 0, patched.stderr);

  const serverSource = String.raw`
    'use strict';
    const net = require('node:net');
    const { EventEmitter } = require('node:events');
    const { tools } = require(process.env.PATCHED_CORE_BUNDLE);
    const { z } = require(process.env.PATCHED_UTILS_BUNDLE);

    async function main() {
      const portProbe = net.createServer();
      await new Promise(resolve =>
        portProbe.listen(0, '127.0.0.1', resolve));
      const port = portProbe.address().port;
      await new Promise(resolve => portProbe.close(resolve));
      const factory = {
        name: 'Remote Chrome drain timeout probe',
        nameInConfig: 'remote-chrome-drain-timeout-probe',
        version: '1',
        toolSchemas: [{
          name: 'never_finishes',
          title: 'Never finishes',
          description: 'Exercise the bounded HTTP request drain',
          type: 'readOnly',
          inputSchema: z.object({ marker: z.string().optional() })
        }],
        create: async () => {
          const backend = new EventEmitter();
          backend.callTool = async () => new Promise(() => {});
          backend.dispose = async () => {};
          return backend;
        }
      };
      const originalError = console.error;
      console.error = () => {};
      await tools.start(factory, {
        host: '127.0.0.1',
        port,
        allowedHosts: ['*']
      });
      console.error = originalError;
      process.stdout.write(JSON.stringify({ port }) + '\n');
    }
    main().catch(error => {
      console.error('probe setup failed');
      process.exit(2);
    });
  `;
  const child = spawn(process.execPath, ['--eval', serverSource], {
    env: {
      ...process.env,
      PATCHED_CORE_BUNDLE: fixture.coreBundle,
      PATCHED_UTILS_BUNDLE:
        path.join(path.dirname(fixture.coreBundle), 'utilsBundle.js'),
      REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS: '5000',
      REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS: '50'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  t.after(() => {
    if (child.exitCode === null)
      child.kill('SIGKILL');
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });

  const ready = await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('drain timeout probe did not become ready')),
      5000,
    );
    const inspect = () => {
      const newline = stdout.indexOf('\n');
      if (newline === -1)
        return;
      clearTimeout(timer);
      child.stdout.off('data', inspect);
      resolve(JSON.parse(stdout.slice(0, newline)));
    };
    child.stdout.on('data', inspect);
    inspect();
    child.once('exit', code => {
      clearTimeout(timer);
      reject(new Error(`drain timeout probe exited before ready: ${code}`));
    });
  });
  const url = `http://127.0.0.1:${ready.port}/mcp`;
  const baseHeaders = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream'
  };
  const initialize = await fetch(url, {
    method: 'POST',
    headers: baseHeaders,
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'timeout-probe', version: '1' }
      }
    })
  });
  await initialize.text();
  const sessionId = initialize.headers.get('mcp-session-id');
  assert.ok(sessionId);
  const sessionHeaders = { ...baseHeaders, 'mcp-session-id': sessionId };
  await fetch(url, {
    method: 'POST',
    headers: sessionHeaders,
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'notifications/initialized'
    })
  }).then(response => response.text());

  const sensitiveMarker = 'SENSITIVE_PAGE_TEXT_MUST_NOT_REACH_LOGS';
  const activeRequest = fetch(url, {
    method: 'POST',
    headers: sessionHeaders,
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: {
        name: 'never_finishes',
        arguments: { marker: sensitiveMarker }
      }
    })
  }).catch(() => undefined);
  await new Promise(resolve => setTimeout(resolve, 100));
  const deletion = await fetch(url, {
    method: 'DELETE',
    headers: {
      accept: 'application/json, text/event-stream',
      'mcp-session-id': sessionId
    }
  });
  assert.equal(deletion.status, 503);
  await deletion.text();

  const exit = await new Promise((resolve, reject) => {
    if (child.exitCode !== null) {
      resolve({ code: child.exitCode, signal: child.signalCode });
      return;
    }
    const timer = setTimeout(
      () => reject(new Error('drain timeout probe did not exit')),
      5000,
    );
    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    });
  });
  await activeRequest;
  assert.deepEqual(exit, { code: 1, signal: null });
  assert.equal(
    stderr.trim(),
    '[remote-chrome-mcp] active HTTP request drain timed out; exiting for a clean restart',
  );
  assert.doesNotMatch(stderr, new RegExp(sensitiveMarker));
  assert.equal(stderr.includes(sessionId), false);
});
