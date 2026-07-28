'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repositoryRoot = path.resolve(__dirname, '..');
const preloadPath = path.join(repositoryRoot, 'lib', 'inject-instructions.cjs');

function runInitialize(playbook) {
  const childProgram = `
    const { Server } = require('playwright-core/lib/utilsBundle');

    const server = new Server(
      { name: 'remote-chrome-test', version: '1.0.0' },
      { capabilities: {} }
    );

    server._oninitialize({
      method: 'initialize',
      params: {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'remote-chrome-test', version: '1.0.0' }
      }
    }).then(result => {
      process.stdout.write(result.instructions || '');
    });
  `;

  return spawnSync(
    process.execPath,
    ['--require', preloadPath, '--eval', childProgram],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        REMOTE_CHROME_PLAYBOOK: path.resolve(repositoryRoot, playbook)
      }
    }
  );
}

function runInitializeFromCliLocalCopy(playbook) {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'remote-chrome-cli-copy-'));
  const cliRoot = path.join(fixtureRoot, 'cli');
  const cliNodeModules = path.join(cliRoot, 'node_modules');
  const copiedPlaywrightCore = path.join(cliNodeModules, 'playwright-core');
  const cliPath = path.join(cliRoot, 'cli.cjs');

  try {
    fs.mkdirSync(cliNodeModules, { recursive: true });
    fs.cpSync(
      path.join(repositoryRoot, 'node_modules', 'playwright-core'),
      copiedPlaywrightCore,
      { recursive: true }
    );
    fs.writeFileSync(cliPath, `
      const { Server } = require('playwright-core/lib/utilsBundle');

      const server = new Server(
        { name: 'remote-chrome-cli-copy', version: '1.0.0' },
        { capabilities: {} }
      );

      server._oninitialize({
        method: 'initialize',
        params: {
          protocolVersion: '2025-06-18',
          capabilities: {},
          clientInfo: { name: 'remote-chrome-cli-copy', version: '1.0.0' }
        }
      }).then(result => {
        process.stdout.write(result.instructions || '');
      });
    `);

    return spawnSync(
      process.execPath,
      ['--require', preloadPath, cliPath],
      {
        cwd: repositoryRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          REMOTE_CHROME_PLAYBOOK: path.resolve(repositoryRoot, playbook)
        }
      }
    );
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

function runToolProbe(loginUrl, toolArguments = {}) {
  const childProgram = `
    const {
      CallToolRequestSchema,
      ListToolsRequestSchema,
      Server
    } = require('playwright-core/lib/utilsBundle');

    async function main() {
      const server = new Server(
        { name: 'remote-chrome-tool-test', version: '1.0.0' },
        { capabilities: { tools: {} } }
      );

      server.setRequestHandler(ListToolsRequestSchema, async () => ({
        tools: [{ name: 'existing_tool', inputSchema: { type: 'object' } }]
      }));
      server.setRequestHandler(CallToolRequestSchema, async request => ({
        content: [{
          type: 'text',
          text: 'delegated:' + request.params.name
        }]
      }));

      const list = await server._requestHandlers.get('tools/list')(
        { method: 'tools/list', params: {} },
        {}
      );
      const handoff = await server._requestHandlers.get('tools/call')(
        {
          method: 'tools/call',
          params: {
            name: 'remote_chrome_request_human_intervention',
            arguments: ${JSON.stringify(toolArguments)}
          }
        },
        {}
      );
      const delegated = await server._requestHandlers.get('tools/call')(
        {
          method: 'tools/call',
          params: { name: 'existing_tool', arguments: {} }
        },
        {}
      );

      process.stdout.write(JSON.stringify({ list, handoff, delegated }));
    }

    main().catch(error => {
      console.error(error);
      process.exit(1);
    });
  `;
  const env = { ...process.env };
  delete env.REMOTE_CHROME_LOGIN_TOKEN_URL;
  if (loginUrl !== undefined)
    env.REMOTE_CHROME_LOGIN_TOKEN_URL = loginUrl;

  return spawnSync(
    process.execPath,
    ['--require', preloadPath, '--eval', childProgram],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env
    }
  );
}

test('injects the configured playbook into initialize', () => {
  assert.match(runInitialize('tests/fixtures/valid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_VERSION=fixture/);
});

test('patches the playwright-core instance loaded by a separate MCP CLI', () => {
  const result = runInitializeFromCliLocalCopy('tests/fixtures/valid-playbook.md');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /REMOTE_CHROME_PLAYBOOK_VERSION=fixture/);
});

test('returns embedded fallback when playbook is missing', () => {
  assert.match(runInitialize('tests/fixtures/missing.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});

test('returns embedded fallback when playbook is empty', () => {
  assert.match(runInitialize('tests/fixtures/invalid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});

test('publishes a read-only no-argument human-intervention tool', () => {
  const loginUrl = 'https://chrome.example.test/login/?token=' + 'a'.repeat(64);
  const result = runToolProbe(loginUrl);
  assert.equal(result.status, 0, result.stderr);
  const probe = JSON.parse(result.stdout);
  const tool = probe.list.tools.find(
    candidate => candidate.name === 'remote_chrome_request_human_intervention'
  );

  assert(tool);
  assert.deepEqual(tool.inputSchema, {
    type: 'object',
    properties: {},
    additionalProperties: false
  });
  assert.equal(tool.annotations.readOnlyHint, true);
  assert.equal(tool.annotations.destructiveHint, false);
  assert.equal(tool.annotations.idempotentHint, true);
  assert.equal(tool.annotations.openWorldHint, false);
  assert.equal(probe.handoff.isError, undefined);
  assert.ok(probe.handoff.content[0].text.includes(loginUrl));
  assert.match(probe.handoff.content[0].text, /password-equivalent secret/);
  assert.equal(probe.delegated.content[0].text, 'delegated:existing_tool');
});

test('human-intervention tool rejects all credential-shaped arguments', () => {
  const loginUrl = 'https://chrome.example.test/login/?token=' + 'b'.repeat(64);
  const result = runToolProbe(loginUrl, {
    username: 'not-accepted',
    password: 'must-not-be-echoed',
    otp: '123456'
  });
  assert.equal(result.status, 0, result.stderr);
  const probe = JSON.parse(result.stdout);

  assert.equal(probe.handoff.isError, true);
  assert.match(probe.handoff.content[0].text, /accepts no arguments/);
  assert.doesNotMatch(probe.handoff.content[0].text, /not-accepted|must-not-be-echoed|123456/);
});

test('human-intervention tool fails closed for a missing or invalid URL', () => {
  for (const loginUrl of [
    undefined,
    'http://chrome.example.test/login/?token=' + 'c'.repeat(64),
    'https://chrome.example.test/login/?token=too-short',
    'https://chrome.example.test/not-login/?token=' + 'd'.repeat(64)
  ]) {
    const result = runToolProbe(loginUrl);
    assert.equal(result.status, 0, result.stderr);
    const probe = JSON.parse(result.stdout);
    assert.equal(probe.handoff.isError, true);
    assert.match(probe.handoff.content[0].text, /URL is unavailable/);
    if (loginUrl)
      assert.ok(!probe.handoff.content[0].text.includes(loginUrl));
  }
});
