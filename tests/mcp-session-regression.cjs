#!/usr/bin/env node
'use strict';

const http = require('node:http');
const https = require('node:https');

const DEFAULT_WAIT_SECONDS = 35;
const DEFAULT_TIMEOUT_SECONDS = 60;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const PROTOCOL_VERSION = '2025-06-18';
const INITIAL_MARKER = 'REMOTE_CHROME_SESSION_READY';
const CLICKED_MARKER = 'REMOTE_CHROME_SESSION_CLICKED';
const BUTTON_NAME = 'Activate regression probe';

class RegressionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RegressionError';
  }
}

function usage() {
  return [
    'Usage:',
    '  node tests/mcp-session-regression.cjs --endpoint URL [options]',
    '',
    'Options:',
    '  --endpoint URL          Token-in-URL MCP endpoint ending in /<token>/mcp',
    `  --wait-seconds NUMBER  Session idle wait (default: ${DEFAULT_WAIT_SECONDS})`,
    `  --timeout-seconds N     Per-request timeout (default: ${DEFAULT_TIMEOUT_SECONDS})`,
    '  --insecure              Disable TLS verification (loopback test endpoints only)',
    '  --help                  Show this help',
    '',
    'The endpoint and all MCP response bodies are omitted from output.',
  ].join('\n');
}

function parseNonNegativeNumber(value, name) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0)
    throw new RegressionError(`${name} must be a non-negative number`);
  return parsed;
}

function takeValue(argv, index, option) {
  if (index + 1 >= argv.length)
    throw new RegressionError(`${option} requires a value`);
  return argv[index + 1];
}

function parseArgs(argv) {
  let endpoint;
  let waitSeconds = DEFAULT_WAIT_SECONDS;
  let timeoutSeconds = DEFAULT_TIMEOUT_SECONDS;
  let insecure = false;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h')
      return { help: true };
    if (argument === '--endpoint') {
      endpoint = takeValue(argv, index, '--endpoint');
      index += 1;
      continue;
    }
    if (argument === '--wait-seconds') {
      waitSeconds = parseNonNegativeNumber(
        takeValue(argv, index, '--wait-seconds'),
        '--wait-seconds',
      );
      index += 1;
      continue;
    }
    if (argument === '--timeout-seconds') {
      timeoutSeconds = parseNonNegativeNumber(
        takeValue(argv, index, '--timeout-seconds'),
        '--timeout-seconds',
      );
      if (timeoutSeconds === 0)
        throw new RegressionError('--timeout-seconds must be greater than zero');
      index += 1;
      continue;
    }
    if (argument === '--insecure') {
      insecure = true;
      continue;
    }
    throw new RegressionError('unknown command-line argument');
  }

  if (!endpoint)
    throw new RegressionError('--endpoint is required');

  return {
    endpoint,
    waitMs: waitSeconds * 1000,
    timeoutMs: timeoutSeconds * 1000,
    insecure,
  };
}

function validateEndpoint(value, insecure = false) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new RegressionError('endpoint is not a valid URL');
  }

  if (endpoint.username || endpoint.password)
    throw new RegressionError('endpoint must not contain URL user information');
  if (endpoint.hash)
    throw new RegressionError('endpoint must not contain a fragment');

  const loopback = new Set(['localhost', '127.0.0.1', '::1']);
  if (endpoint.protocol !== 'https:' &&
      !(endpoint.protocol === 'http:' && loopback.has(endpoint.hostname))) {
    throw new RegressionError('endpoint must use HTTPS (HTTP is loopback-only)');
  }
  if (insecure && !loopback.has(endpoint.hostname))
    throw new RegressionError('--insecure is allowed only for loopback endpoints');

  const segments = endpoint.pathname.split('/').filter(Boolean);
  if (segments.length < 2 || segments.at(-1) !== 'mcp')
    throw new RegressionError('endpoint must end in /<token>/mcp');
  const token = decodeURIComponent(segments.at(-2));
  if (!token || token === 'mcp')
    throw new RegressionError('endpoint is missing its compatibility token');

  return { endpoint, token };
}

function sanitize(message, secrets = []) {
  let sanitized = String(message);
  for (const secret of secrets) {
    if (secret)
      sanitized = sanitized.split(secret).join('<redacted>');
  }
  sanitized = sanitized
    .replace(/Authorization:\s*Bearer\s+\S+/gi, 'Authorization: Bearer <redacted>')
    .replace(/https?:\/\/[^\s"'<>]+/gi, '<redacted-url>');
  return sanitized;
}

function request(endpoint, options) {
  const {
    method = 'POST',
    payload,
    sessionId,
    insecure = false,
    timeoutMs = DEFAULT_TIMEOUT_SECONDS * 1000,
  } = options;
  const body = payload === undefined ? undefined : JSON.stringify(payload);
  const transport = endpoint.protocol === 'https:' ? https : http;
  const headers = {
    Accept: 'application/json, text/event-stream',
  };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  if (sessionId)
    headers['Mcp-Session-Id'] = sessionId;

  return new Promise((resolve, reject) => {
    const req = transport.request(endpoint, {
      method,
      headers,
      rejectUnauthorized: !insecure,
    });
    const chunks = [];
    let size = 0;
    let settled = false;

    const fail = error => {
      if (settled)
        return;
      settled = true;
      reject(error);
    };

    req.setTimeout(timeoutMs, () => {
      req.destroy(new RegressionError(`${method} request timed out`));
    });
    req.on('error', fail);
    req.on('response', response => {
      response.on('data', chunk => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) {
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
      req.write(body);
    req.end();
  });
}

function parseSse(body) {
  const messages = [];
  for (const block of body.split(/\r?\n\r?\n/)) {
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
  if (!messages.length)
    throw new RegressionError('MCP SSE response contained no JSON-RPC message');
  return messages;
}

function parseResponse(response, expectedId) {
  const contentType = String(response.headers['content-type'] || '')
    .split(';', 1)[0]
    .trim()
    .toLowerCase();
  let messages;

  if (contentType === 'text/event-stream') {
    messages = parseSse(response.body);
  } else {
    try {
      const parsed = JSON.parse(response.body);
      messages = Array.isArray(parsed) ? parsed : [parsed];
    } catch {
      throw new RegressionError('MCP returned malformed JSON');
    }
  }

  const message = messages.find(candidate =>
    candidate && String(candidate.id) === String(expectedId));
  if (!message)
    throw new RegressionError(`MCP response omitted JSON-RPC id ${expectedId}`);
  if (message.error)
    throw new RegressionError(
      `JSON-RPC id ${expectedId} returned error code ${message.error.code ?? 'unknown'}`,
    );
  if (!Object.hasOwn(message, 'result'))
    throw new RegressionError(`JSON-RPC id ${expectedId} omitted its result`);
  return message.result;
}

async function rpc(endpoint, sessionId, id, method, params, options) {
  const response = await request(endpoint, {
    ...options,
    sessionId,
    payload: {
      jsonrpc: '2.0',
      id,
      method,
      ...(params === undefined ? {} : { params }),
    },
  });
  if (response.status !== 200)
    throw new RegressionError(`${method} returned HTTP ${response.status}`);
  return {
    result: parseResponse(response, id),
    response,
  };
}

function toolText(result, toolName) {
  if (!result || result.isError)
    throw new RegressionError(`${toolName} returned a tool error`);
  const text = (result.content || [])
    .filter(item => item && item.type === 'text' && typeof item.text === 'string')
    .map(item => item.text)
    .join('\n');
  if (!text)
    throw new RegressionError(`${toolName} returned no text content`);
  return text;
}

function requireMarker(text, marker, stage) {
  const stateLine = text
    .split(/\r?\n/)
    .find(line => line.includes(marker) && !/Page URL:/i.test(line));
  if (!stateLine)
    throw new RegressionError(`${stage} did not contain its expected state marker`);
}

function findButtonTarget(snapshot) {
  const line = snapshot
    .split(/\r?\n/)
    .find(candidate =>
      candidate.includes('button') && candidate.includes(`"${BUTTON_NAME}"`));
  const match = line && line.match(/\[ref=([^\]]+)\]/);
  if (!match)
    throw new RegressionError('browser_snapshot omitted the probe button reference');
  return match[1];
}

function inputProperties(tool) {
  return tool && tool.inputSchema && tool.inputSchema.properties || {};
}

async function runRegression(configuration) {
  const {
    endpoint: endpointValue,
    waitMs = DEFAULT_WAIT_SECONDS * 1000,
    timeoutMs = DEFAULT_TIMEOUT_SECONDS * 1000,
    insecure = false,
    logger = () => {},
  } = configuration;
  const { endpoint } = validateEndpoint(endpointValue, insecure);
  const requestOptions = { insecure, timeoutMs };
  let sessionId;
  let deleted = false;
  let nextId = 1;

  try {
    const initialize = await request(endpoint, {
      ...requestOptions,
      payload: {
        jsonrpc: '2.0',
        id: nextId,
        method: 'initialize',
        params: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: {
            name: 'remote-chrome-session-regression',
            version: '1.0',
          },
        },
      },
    });
    if (initialize.status !== 200)
      throw new RegressionError(`initialize returned HTTP ${initialize.status}`);
    parseResponse(initialize, nextId);
    nextId += 1;
    sessionId = String(initialize.headers['mcp-session-id'] || '').trim();
    if (!sessionId || /[\r\n]/.test(sessionId))
      throw new RegressionError('initialize returned no valid Mcp-Session-Id');

    const initialized = await request(endpoint, {
      ...requestOptions,
      sessionId,
      payload: {
        jsonrpc: '2.0',
        method: 'notifications/initialized',
      },
    });
    if (![200, 202, 204].includes(initialized.status))
      throw new RegressionError(
        `notifications/initialized returned HTTP ${initialized.status}`,
      );

    const listed = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/list',
      {},
      requestOptions,
    );
    const tools = listed.result && listed.result.tools;
    if (!Array.isArray(tools))
      throw new RegressionError('tools/list returned no tool list');
    const byName = new Map(tools.map(tool => [tool.name, tool]));
    for (const name of ['browser_navigate', 'browser_snapshot', 'browser_click']) {
      if (!byName.has(name))
        throw new RegressionError(`tools/list omitted ${name}`);
    }

    const page = [
      '<!doctype html><html><head>',
      '<title>Remote Chrome MCP session regression</title>',
      '</head><body>',
      `<p id="state" role="status">${INITIAL_MARKER}</p>`,
      '<button onclick="document.getElementById(\'state\').textContent=' +
        '[\'REMOTE\',\'CHROME\',\'SESSION\',\'CLICKED\'].join(\'_\')">',
      BUTTON_NAME,
      '</button>',
      '</body></html>',
    ].join('');
    const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(page)}`;

    const navigate = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/call',
      {
        name: 'browser_navigate',
        arguments: { url: dataUrl },
      },
      requestOptions,
    );
    if (navigate.result && navigate.result.isError)
      throw new RegressionError('browser_navigate returned a tool error');

    const initialSnapshot = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/call',
      {
        name: 'browser_snapshot',
        arguments: {},
      },
      requestOptions,
    );
    const initialText = toolText(initialSnapshot.result, 'browser_snapshot');
    requireMarker(initialText, INITIAL_MARKER, 'initial browser_snapshot');
    const buttonTarget = findButtonTarget(initialText);

    const clickProperties = inputProperties(byName.get('browser_click'));
    const targetName = Object.hasOwn(clickProperties, 'target') ? 'target' :
      Object.hasOwn(clickProperties, 'ref') ? 'ref' : undefined;
    if (!targetName)
      throw new RegressionError('browser_click has no supported target property');
    const click = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/call',
      {
        name: 'browser_click',
        arguments: {
          element: BUTTON_NAME,
          [targetName]: buttonTarget,
        },
      },
      requestOptions,
    );
    if (click.result && click.result.isError)
      throw new RegressionError('browser_click returned a tool error');

    const clickedSnapshot = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/call',
      {
        name: 'browser_snapshot',
        arguments: {},
      },
      requestOptions,
    );
    requireMarker(
      toolText(clickedSnapshot.result, 'browser_snapshot'),
      CLICKED_MARKER,
      'post-click browser_snapshot',
    );

    if (waitMs > 0)
      await new Promise(resolve => setTimeout(resolve, waitMs));

    const delayedSnapshot = await rpc(
      endpoint,
      sessionId,
      nextId++,
      'tools/call',
      {
        name: 'browser_snapshot',
        arguments: {},
      },
      requestOptions,
    );
    requireMarker(
      toolText(delayedSnapshot.result, 'browser_snapshot'),
      CLICKED_MARKER,
      'post-wait browser_snapshot',
    );

    const deletion = await request(endpoint, {
      ...requestOptions,
      method: 'DELETE',
      sessionId,
    });
    if (![200, 202, 204].includes(deletion.status))
      throw new RegressionError(`DELETE returned HTTP ${deletion.status}`);
    deleted = true;

    const afterDelete = await request(endpoint, {
      ...requestOptions,
      sessionId,
      payload: {
        jsonrpc: '2.0',
        id: nextId,
        method: 'tools/list',
        params: {},
      },
    });
    if (afterDelete.status !== 404)
      throw new RegressionError(
        `post-delete session request returned HTTP ${afterDelete.status}, expected 404`,
      );

    const summary = {
      browserCalls: 5,
      waitMs,
      deletionVerified: true,
    };
    logger(
      `PASS: one MCP session survived ${summary.browserCalls} browser calls, ` +
      'the configured wait, and explicit deletion',
    );
    return summary;
  } finally {
    if (sessionId && !deleted) {
      try {
        await request(endpoint, {
          ...requestOptions,
          method: 'DELETE',
          sessionId,
        });
      } catch {
        // Best-effort cleanup only. Never print a response or the secret URL.
      }
    }
  }
}

async function main() {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
    if (parsed.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    const { token } = validateEndpoint(parsed.endpoint, parsed.insecure);
    await runRegression({
      ...parsed,
      logger: message => process.stdout.write(`${message}\n`),
    });
  } catch (error) {
    const endpoint = parsed && parsed.endpoint;
    let token;
    if (endpoint) {
      try {
        token = validateEndpoint(endpoint, parsed.insecure).token;
      } catch {
        token = undefined;
      }
    }
    const message = error instanceof Error ? error.message : 'unknown failure';
    process.stderr.write(`FAIL: ${sanitize(message, [endpoint, token])}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  BUTTON_NAME,
  CLICKED_MARKER,
  INITIAL_MARKER,
  parseArgs,
  parseResponse,
  parseSse,
  request,
  rpc,
  runRegression,
  sanitize,
  toolText,
  validateEndpoint,
};

if (require.main === module)
  void main();
