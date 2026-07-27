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
