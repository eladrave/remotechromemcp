'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
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

test('patches and verifies the exact Playwright MCP 0.0.78 bundle', t => {
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

test('refuses any @playwright/mcp version other than 0.0.78', t => {
  const fixture = createFixture(t);
  const metadata = JSON.parse(
    fs.readFileSync(fixture.mcpPackageJson, 'utf8')
  );
  metadata.version = '0.0.79';
  fs.writeFileSync(
    fixture.mcpPackageJson,
    `${JSON.stringify(metadata, null, 2)}\n`
  );

  const result = runPatch(fixture.mcpPackageJson);
  assertFailed(result, /expected @playwright\/mcp@0\.0\.78/);
});

test('check mode fails closed on an unpatched exact bundle', t => {
  const fixture = createFixture(t);
  const result = runPatch(fixture.mcpPackageJson, '--check');
  assertFailed(result, /patched coreBundle\.js SHA-256 mismatch/);
});

test('patched transport reuses sessions and closes resources on TTL and DELETE', t => {
  const fixture = createFixture(t, { fullCore: true });
  const patched = runPatch(fixture.mcpPackageJson);
  assert.equal(patched.status, 0, patched.stderr);

  const probeSource = String.raw`
    'use strict';
    const net = require('node:net');
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
        create: async () => ({
          callTool: async () => ({
            content: [{ type: 'text', text: 'ok' }]
          })
        }),
        disposed: async () => {
          disposed += 1;
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
      await post({
        jsonrpc: '2.0',
        id: 11,
        method: 'tools/call',
        params: { name: 'probe', arguments: {} }
      }, deletedSession.sessionId);
      const deletion = await fetch(url, {
        method: 'DELETE',
        headers: {
          accept: 'application/json, text/event-stream',
          'mcp-session-id': deletedSession.sessionId
        }
      });
      await deletion.text();
      const afterDelete = await post({
        jsonrpc: '2.0',
        id: 12,
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
        afterDelete: afterDelete.status,
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
      REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS: '200'
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
    afterDelete: 404,
    disposed: 2
  });
});
