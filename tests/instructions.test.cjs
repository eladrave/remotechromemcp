'use strict';

const assert = require('node:assert/strict');
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

test('injects the configured playbook into initialize', () => {
  assert.match(runInitialize('tests/fixtures/valid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_VERSION=fixture/);
});

test('returns embedded fallback when playbook is missing', () => {
  assert.match(runInitialize('tests/fixtures/missing.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});

test('returns embedded fallback when playbook is empty', () => {
  assert.match(runInitialize('tests/fixtures/invalid-playbook.md').stdout, /REMOTE_CHROME_PLAYBOOK_FALLBACK=1/);
});
