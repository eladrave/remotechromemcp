#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');

const DEFAULT_ENDPOINT = 'http://127.0.0.1:8931/mcp';
const DEFAULT_OPERATIONS = 30;
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const PROTOCOL_VERSION = '2025-06-18';
const SNAPSHOT_TOOL = 'browser_snapshot';
const READ_ONLY_TOOL = 'browser_console_messages';
const WAIT_TOOL = 'browser_wait_for';

class RegressionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RegressionError';
  }
}

function usage() {
  return [
    'Usage:',
    '  node tests/mcp-browser-lifecycle-regression.cjs [options]',
    '',
    'Options:',
    `  --endpoint URL                 Loopback MCP endpoint (default: ${DEFAULT_ENDPOINT})`,
    `  --seed VALUE                   Deterministic seed (default: lifecycle-regression)`,
    `  --operations NUMBER            Seeded stress operations (default: ${DEFAULT_OPERATIONS})`,
    '  --server-idle-timeout-ms N     Configured MCP idle timeout (default: environment or 1000)',
    '  --idle-wait-ms NUMBER          Idle-expiry wait (default: idle timeout plus a margin)',
    `  --request-timeout-ms NUMBER    Per-request timeout (default: ${DEFAULT_REQUEST_TIMEOUT_MS})`,
    '  --mcp-process-match VALUE      MCP process command marker (default: playwright-mcp)',
    '  --chrome-process-match VALUE   Chrome main-process marker (default: /usr/bin/google-chrome --display=:99 --remote-debugging-port=9222)',
    '  --self-check                   Validate deterministic helpers without contacting MCP',
    '  -h, --help                     Show this help',
    '',
    'Run this inside the isolated browser test container with a shortened',
    'REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS. The client never prints MCP',
    'response bodies, page contents, endpoint credentials, or session IDs.',
  ].join('\n');
}

function parseInteger(value, name, minimum = 1) {
  if (!/^[0-9]+$/.test(String(value)))
    throw new RegressionError(`${name} must be an integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum)
    throw new RegressionError(`${name} must be at least ${minimum}`);
  return parsed;
}

function takeValue(argv, index, option) {
  if (index + 1 >= argv.length)
    throw new RegressionError(`${option} requires a value`);
  return argv[index + 1];
}

function parseArgs(argv, env = process.env) {
  const environmentIdle = env.REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS;
  const defaultIdle = environmentIdle ?
    parseInteger(environmentIdle, 'REMOTE_CHROME_MCP_SESSION_IDLE_TIMEOUT_MS') :
    1000;
  const options = {
    endpoint: DEFAULT_ENDPOINT,
    seed: 'lifecycle-regression',
    operations: DEFAULT_OPERATIONS,
    serverIdleTimeoutMs: defaultIdle,
    idleWaitMs: undefined,
    requestTimeoutMs: DEFAULT_REQUEST_TIMEOUT_MS,
    mcpProcessMatch: 'playwright-mcp',
    chromeProcessMatch:
      '/usr/bin/google-chrome --display=:99 --remote-debugging-port=9222',
    selfCheck: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h')
      return { help: true };
    if (argument === '--self-check') {
      options.selfCheck = true;
      continue;
    }
    const valueOptions = new Map([
      ['--endpoint', 'endpoint'],
      ['--seed', 'seed'],
      ['--mcp-process-match', 'mcpProcessMatch'],
      ['--chrome-process-match', 'chromeProcessMatch'],
    ]);
    if (valueOptions.has(argument)) {
      options[valueOptions.get(argument)] = takeValue(argv, index, argument);
      index += 1;
      continue;
    }
    const integerOptions = new Map([
      ['--operations', ['operations', 1]],
      ['--server-idle-timeout-ms', ['serverIdleTimeoutMs', 50]],
      ['--idle-wait-ms', ['idleWaitMs', 50]],
      ['--request-timeout-ms', ['requestTimeoutMs', 100]],
    ]);
    if (integerOptions.has(argument)) {
      const [property, minimum] = integerOptions.get(argument);
      options[property] = parseInteger(
        takeValue(argv, index, argument),
        argument,
        minimum,
      );
      index += 1;
      continue;
    }
    throw new RegressionError('unknown command-line argument');
  }

  if (!options.seed || /[\r\n]/.test(options.seed))
    throw new RegressionError('--seed must be nonempty and contain no newline');
  options.seedValue = normalizeSeed(options.seed);
  for (const [name, value] of [
    ['--mcp-process-match', options.mcpProcessMatch],
    ['--chrome-process-match', options.chromeProcessMatch],
  ]) {
    if (!value || /[\r\n\0]/.test(value))
      throw new RegressionError(`${name} contains an invalid value`);
  }
  options.idleWaitMs ??=
    options.serverIdleTimeoutMs + Math.max(300, Math.ceil(options.serverIdleTimeoutMs / 4));
  if (options.idleWaitMs <= options.serverIdleTimeoutMs)
    throw new RegressionError('--idle-wait-ms must exceed --server-idle-timeout-ms');
  options.endpoint = validateEndpoint(options.endpoint);
  return options;
}

function validateEndpoint(value) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new RegressionError('--endpoint is not a valid URL');
  }
  const loopback = new Set(['127.0.0.1', 'localhost', '::1']);
  if (endpoint.protocol !== 'http:' || !loopback.has(endpoint.hostname))
    throw new RegressionError('--endpoint must use unauthenticated loopback HTTP');
  if (endpoint.pathname !== '/mcp' || endpoint.search || endpoint.hash ||
      endpoint.username || endpoint.password) {
    throw new RegressionError('--endpoint must be the plain loopback /mcp route');
  }
  return endpoint;
}

function sanitize(value) {
  return String(value)
    .replace(/https?:\/\/[^\s"'<>]+/gi, '<redacted-url>')
    .replace(/mcp-session-id\s*:\s*\S+/gi, 'Mcp-Session-Id: <redacted>')
    .replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, '<redacted-id>')
    .replace(/\b[0-9a-f]{32,}\b/gi, '<redacted-secret>')
    .slice(0, 500);
}

function seedHash(value) {
  let hash = 2166136261;
  for (const character of String(value)) {
    hash ^= character.codePointAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function normalizeSeed(value) {
  if (/^[0-9]+$/.test(String(value))) {
    const parsed = Number(value);
    if (Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= 0xFFFFFFFF)
      return parsed >>> 0;
  }
  return seedHash(value);
}

function seededRandom(seed) {
  let state = typeof seed === 'number' ? seed >>> 0 : normalizeSeed(seed);
  return () => {
    state += 0x6D2B79F5;
    let value = state;
    value = Math.imul(value ^ value >>> 15, value | 1);
    value ^= value + Math.imul(value ^ value >>> 7, value | 61);
    return ((value ^ value >>> 14) >>> 0) / 4294967296;
  };
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function request(endpoint, options = {}) {
  const {
    method = 'POST',
    payload,
    sessionId,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  } = options;
  const body = payload === undefined ? undefined : JSON.stringify(payload);
  const headers = { Accept: 'application/json, text/event-stream' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  if (sessionId)
    headers['Mcp-Session-Id'] = sessionId;

  return new Promise((resolve, reject) => {
    const outgoing = http.request(endpoint, { method, headers });
    let settled = false;
    const fail = error => {
      if (settled)
        return;
      settled = true;
      reject(new RegressionError(sanitize(error.message || 'MCP request failed')));
    };
    outgoing.setTimeout(timeoutMs, () =>
      outgoing.destroy(new RegressionError(`${method} request timed out`)));
    outgoing.on('error', fail);
    outgoing.on('response', response => {
      const chunks = [];
      let responseBytes = 0;
      response.on('data', chunk => {
        responseBytes += chunk.length;
        if (responseBytes > MAX_RESPONSE_BYTES) {
          response.destroy(new RegressionError('MCP response exceeded the size limit'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('error', fail);
      response.on('end', () => {
        if (settled)
          return;
        settled = true;
        resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        });
      });
    });
    if (body !== undefined)
      outgoing.write(body);
    outgoing.end();
  });
}

function parseMessages(response) {
  const contentType = String(response.headers['content-type'] || '')
    .split(';', 1)[0]
    .trim()
    .toLowerCase();
  if (!response.body)
    return [];
  if (contentType === 'text/event-stream') {
    const messages = [];
    for (const block of response.body.split(/\r?\n\r?\n/)) {
      const data = block
        .split(/\r?\n/)
        .filter(line => line.startsWith('data:'))
        .map(line => line.slice(5).replace(/^ /, ''))
        .join('\n');
      if (!data || data === '[DONE]')
        continue;
      try {
        messages.push(JSON.parse(data));
      } catch {
        throw new RegressionError('MCP returned malformed SSE JSON');
      }
    }
    return messages;
  }
  try {
    const parsed = JSON.parse(response.body);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    throw new RegressionError('MCP returned malformed JSON');
  }
}

function rpcResult(response, expectedId, stage) {
  if (response.status !== 200)
    throw new RegressionError(`${stage} returned HTTP ${response.status}`);
  const message = parseMessages(response)
    .find(candidate => candidate && String(candidate.id) === String(expectedId));
  if (!message)
    throw new RegressionError(`${stage} omitted its JSON-RPC response`);
  if (message.error)
    throw new RegressionError(`${stage} returned a JSON-RPC error`);
  if (!Object.hasOwn(message, 'result'))
    throw new RegressionError(`${stage} omitted its result`);
  return message.result;
}

function assertToolResult(result, toolName) {
  if (!result || result.isError)
    throw new RegressionError(`${toolName} returned a tool error`);
  if (!Array.isArray(result.content))
    throw new RegressionError(`${toolName} returned no content array`);
  const hasErrorText = result.content.some(item =>
    item && item.type === 'text' &&
    typeof item.text === 'string' &&
    item.text.trimStart().startsWith('### Error'));
  if (hasErrorText)
    throw new RegressionError(`${toolName} returned error text`);
}

class McpSession {
  constructor(endpoint, timeoutMs, ordinal) {
    this.endpoint = endpoint;
    this.timeoutMs = timeoutMs;
    this.ordinal = ordinal;
    this.nextId = 1;
    this.sessionId = undefined;
    this.closed = false;
  }

  async open() {
    const id = this.nextId++;
    const response = await request(this.endpoint, {
      timeoutMs: this.timeoutMs,
      payload: {
        jsonrpc: '2.0',
        id,
        method: 'initialize',
        params: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: {
            name: 'remote-chrome-browser-lifecycle-regression',
            version: '1.0',
          },
        },
      },
    });
    rpcResult(response, id, 'initialize');
    const sessionId = String(response.headers['mcp-session-id'] || '').trim();
    if (!sessionId || /[\r\n]/.test(sessionId))
      throw new RegressionError('initialize returned no valid session identifier');
    this.sessionId = sessionId;

    const initialized = await request(this.endpoint, {
      timeoutMs: this.timeoutMs,
      sessionId: this.sessionId,
      payload: {
        jsonrpc: '2.0',
        method: 'notifications/initialized',
        params: {},
      },
    });
    if (![200, 202, 204].includes(initialized.status))
      throw new RegressionError(`initialized notification returned HTTP ${initialized.status}`);

    const tools = await this.rpc('tools/list', {}, 'tools/list');
    if (!Array.isArray(tools.tools))
      throw new RegressionError('tools/list returned no tool catalog');
    const byName = new Map(tools.tools.map(tool => [tool.name, tool]));
    if (!byName.has(SNAPSHOT_TOOL) || !byName.has(READ_ONLY_TOOL) ||
        !byName.has(WAIT_TOOL)) {
      throw new RegressionError('tools/list omitted a required read-only browser tool');
    }
    const readOnly = byName.get(READ_ONLY_TOOL);
    if (readOnly.annotations && readOnly.annotations.readOnlyHint !== true)
      throw new RegressionError(`${READ_ONLY_TOOL} is not marked read-only`);
    return this;
  }

  async rpc(method, params, stage = method) {
    if (!this.sessionId || this.closed)
      throw new RegressionError(`${stage} attempted to use a closed session`);
    const id = this.nextId++;
    const response = await request(this.endpoint, {
      timeoutMs: this.timeoutMs,
      sessionId: this.sessionId,
      payload: { jsonrpc: '2.0', id, method, params },
    });
    return rpcResult(response, id, stage);
  }

  async tool(name, argumentsValue = {}) {
    const result = await this.rpc(
      'tools/call',
      { name, arguments: argumentsValue },
      name,
    );
    assertToolResult(result, name);
  }

  async probe() {
    await this.tool(SNAPSHOT_TOOL, {});
    await this.tool(READ_ONLY_TOOL, { level: 'error', all: false });
  }

  async close() {
    if (!this.sessionId || this.closed)
      return;
    const response = await request(this.endpoint, {
      method: 'DELETE',
      timeoutMs: this.timeoutMs,
      sessionId: this.sessionId,
    });
    if (![200, 202, 204].includes(response.status))
      throw new RegressionError(`session DELETE returned HTTP ${response.status}`);
    this.closed = true;
  }

  async expectRejected() {
    if (!this.sessionId)
      throw new RegressionError('cannot verify a session that was never initialized');
    const response = await request(this.endpoint, {
      timeoutMs: this.timeoutMs,
      sessionId: this.sessionId,
      payload: {
        jsonrpc: '2.0',
        id: this.nextId++,
        method: 'tools/list',
        params: {},
      },
    });
    if (response.status !== 404)
      throw new RegressionError(`retired session returned HTTP ${response.status}, expected 404`);
    this.closed = true;
  }

  async bestEffortClose() {
    if (!this.sessionId || this.closed)
      return;
    try {
      await this.close();
    } catch {
      // Cleanup must never reveal a response body or session identifier.
    }
    this.closed = true;
  }
}

function readProcessTable() {
  const processes = [];
  for (const entry of fs.readdirSync('/proc', { withFileTypes: true })) {
    if (!entry.isDirectory() || !/^[0-9]+$/.test(entry.name))
      continue;
    const pid = Number(entry.name);
    try {
      const command = fs.readFileSync(`/proc/${pid}/cmdline`)
        .toString('utf8')
        .split('\0')
        .filter(Boolean)
        .join(' ');
      if (command)
        processes.push({ pid, command });
    } catch {
      // Processes may exit while /proc is being inspected.
    }
  }
  return processes;
}

function uniqueProcessId(marker, label) {
  const matches = readProcessTable()
    .filter(entry => entry.pid !== process.pid && entry.command.includes(marker));
  if (matches.length !== 1)
    throw new RegressionError(`expected exactly one ${label} process, found ${matches.length}`);
  return matches[0].pid;
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForChromeRestart(options, oldChromePid, mcpPid) {
  const deadline = Date.now() + Math.max(options.requestTimeoutMs, 30_000);
  let replacementPid;
  while (Date.now() < deadline) {
    if (!processExists(mcpPid))
      throw new RegressionError('Playwright MCP exited during the Chrome-only restart');
    try {
      const candidate = uniqueProcessId(options.chromeProcessMatch, 'Chrome browser');
      if (candidate !== oldChromePid) {
        const response = await request(new URL('http://127.0.0.1:9222/json/version'), {
          method: 'GET',
          timeoutMs: 1000,
        });
        if (response.status === 200) {
          replacementPid = candidate;
          break;
        }
      }
    } catch {
      // Chrome is expected to disappear briefly during its targeted restart.
    }
    await delay(100);
  }
  if (!replacementPid)
    throw new RegressionError('replacement Chrome did not become ready');
  const afterMcpPid = uniqueProcessId(options.mcpProcessMatch, 'Playwright MCP');
  if (afterMcpPid !== mcpPid)
    throw new RegressionError('Playwright MCP PID changed during the Chrome-only restart');
  return replacementPid;
}

function logProgress(stage, fields = {}) {
  process.stdout.write(`${JSON.stringify({ stage, ...fields })}\n`);
}

async function openAndProbe(options, ordinal) {
  const session = new McpSession(options.endpoint, options.requestTimeoutMs, ordinal);
  try {
    await session.open();
    await session.probe();
    return session;
  } catch (error) {
    await session.bestEffortClose();
    throw error;
  }
}

async function runRegression(options) {
  const random = seededRandom(options.seedValue);
  const sessions = new Set();
  let createdSessions = 0;
  let explicitDeletes = 0;
  let seededOperations = 0;
  const createSession = async () => {
    const session = await openAndProbe(options, ++createdSessions);
    sessions.add(session);
    return session;
  };

  const mcpPid = uniqueProcessId(options.mcpProcessMatch, 'Playwright MCP');
  const initialChromePid = uniqueProcessId(options.chromeProcessMatch, 'Chrome browser');
  logProgress('start', {
    seed: options.seedValue,
    requestedOperations: options.operations,
  });

  try {
    const initial = await Promise.all(
      Array.from({ length: 5 }, () => createSession()),
    );
    logProgress('overlap-ready', { activeSessions: sessions.size });

    const deletedIndex = Math.floor(random() * initial.length);
    let idleIndex = Math.floor(random() * initial.length);
    if (idleIndex === deletedIndex)
      idleIndex = (idleIndex + 1) % initial.length;
    const deletedSession = initial[deletedIndex];
    const idleSession = initial[idleIndex];
    await deletedSession.close();
    explicitDeletes += 1;
    sessions.delete(deletedSession);
    await deletedSession.expectRejected();

    const activeSessions = initial.filter(
      session => session !== deletedSession && session !== idleSession,
    );
    await Promise.all(activeSessions.map(session => session.probe()));
    logProgress('delete-isolated', { activeSessions: sessions.size });

    const keepaliveInterval = Math.max(
      25,
      Math.min(1000, Math.floor(options.serverIdleTimeoutMs / 3)),
    );
    const idleDeadline = Date.now() + options.idleWaitMs;
    while (Date.now() < idleDeadline) {
      await Promise.all(activeSessions.map(session => session.probe()));
      const remaining = idleDeadline - Date.now();
      if (remaining > 0)
        await delay(Math.min(keepaliveInterval, remaining));
    }
    await idleSession.expectRejected();
    sessions.delete(idleSession);
    await Promise.all(activeSessions.map(session => session.probe()));
    logProgress('idle-isolated', { activeSessions: sessions.size });

    for (const session of [...sessions]) {
      await session.close();
      explicitDeletes += 1;
      sessions.delete(session);
      await session.expectRejected();
    }
    if (sessions.size !== 0)
      throw new RegressionError('could not establish a single-owner cleanup race');

    const racingSession = await createSession();
    const raceStartedAt = Date.now();
    const raceResults = await Promise.allSettled([
      racingSession.tool(WAIT_TOOL, { time: 1 }),
      (async () => {
        await delay(100);
        await racingSession.close();
      })(),
    ]);
    const [racingProbe, racingDelete] = raceResults;
    if (racingDelete.status !== 'fulfilled')
      throw new RegressionError('session DELETE failed while racing an active tool call');
    if (racingProbe.status !== 'fulfilled')
      throw new RegressionError('last-owner cleanup interrupted an active tool call');
    if (Date.now() - raceStartedAt < 750)
      throw new RegressionError('last-owner cleanup did not wait for the active tool call');
    explicitDeletes += 1;
    sessions.delete(racingSession);
    await racingSession.expectRejected();
    const afterRace = await createSession();
    await afterRace.probe();
    logProgress('cleanup-race-isolated', {
      toolCompleted: true,
      lastOwner: true,
      activeSessions: sessions.size,
    });

    for (let operation = 0; operation < options.operations; operation += 1) {
      const active = [...sessions];
      const choice = random();
      if (choice < 0.55 || active.length >= 8) {
        await active[Math.floor(random() * active.length)].probe();
      } else if (choice < 0.75) {
        await createSession();
      } else if (choice < 0.9 && active.length > 1) {
        const session = active[Math.floor(random() * active.length)];
        await session.close();
        explicitDeletes += 1;
        sessions.delete(session);
        await session.expectRejected();
      } else {
        await Promise.all(active.map(session => session.probe()));
      }
      seededOperations += 1;
    }
    logProgress('seeded-stress-complete', {
      operations: seededOperations,
      activeSessions: sessions.size,
    });

    await Promise.all([...sessions].map(session => session.probe()));
    const beforeRestartMcpPid = uniqueProcessId(
      options.mcpProcessMatch,
      'Playwright MCP',
    );
    if (beforeRestartMcpPid !== mcpPid)
      throw new RegressionError('Playwright MCP PID changed before the Chrome restart');
    const beforeRestartChromePid = uniqueProcessId(
      options.chromeProcessMatch,
      'Chrome browser',
    );
    if (beforeRestartChromePid !== initialChromePid)
      throw new RegressionError('Chrome PID changed before the targeted restart');
    try {
      process.kill(beforeRestartChromePid, 'SIGTERM');
    } catch (error) {
      throw new RegressionError(
        `cannot signal the targeted Chrome process: ${sanitize(error.message)}`,
      );
    }
    const replacementChromePid = await waitForChromeRestart(
      options,
      beforeRestartChromePid,
      mcpPid,
    );
    logProgress('chrome-restarted', { mcpPidUnchanged: true });

    const postRestart = await createSession();
    await postRestart.probe();
    await postRestart.close();
    explicitDeletes += 1;
    sessions.delete(postRestart);
    await postRestart.expectRejected();

    logProgress('pass', {
      seed: options.seedValue,
      operations: seededOperations,
      createdSessions,
      explicitDeletes,
      idleExpirations: 1,
      overlappingSessions: 5,
      mcpPidUnchanged: true,
      chromePidChanged: replacementChromePid !== beforeRestartChromePid,
    });
  } finally {
    await Promise.all([...sessions].map(session => session.bestEffortClose()));
  }
}

function selfCheck() {
  const first = seededRandom('fixture-seed');
  const second = seededRandom('fixture-seed');
  for (let index = 0; index < 20; index += 1) {
    if (first() !== second())
      throw new RegressionError('deterministic PRNG self-check failed');
  }
  const parsed = parseArgs([
    '--endpoint', DEFAULT_ENDPOINT,
    '--seed', 'fixture-seed',
    '--operations', '7',
    '--server-idle-timeout-ms', '100',
    '--idle-wait-ms', '500',
  ], {});
  if (parsed.operations !== 7 || parsed.idleWaitMs !== 500)
    throw new RegressionError('argument parser self-check failed');
  const secret = '0123456789abcdef0123456789abcdef';
  if (sanitize(`Mcp-Session-Id: ${secret}`).includes(secret))
    throw new RegressionError('sanitizer self-check failed');
  process.stdout.write('PASS: lifecycle regression client self-check\n');
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
    if (options.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    if (options.selfCheck) {
      selfCheck();
      return;
    }
    await runRegression(options);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'unknown failure';
    process.stderr.write(`FAIL: ${sanitize(message)}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  McpSession,
  RegressionError,
  parseArgs,
  parseMessages,
  runRegression,
  sanitize,
  seededRandom,
  validateEndpoint,
};

if (require.main === module)
  void main();
