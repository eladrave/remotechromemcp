'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');
const {
  BUTTON_NAME,
  CLICKED_MARKER,
  INITIAL_MARKER,
  parseArgs,
  runRegression,
  sanitize,
  validateEndpoint,
} = require('./mcp-session-regression.cjs');

const TOKEN = 'fixture-token-that-must-never-be-printed';
const SESSION_ID = 'fixture-session-id';

function json(response, status, value, headers = {}) {
  response.writeHead(status, {
    'Content-Type': 'application/json',
    ...headers,
  });
  response.end(JSON.stringify(value));
}

function sse(response, value, headers = {}) {
  response.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    ...headers,
  });
  response.end(`event: message\ndata: ${JSON.stringify(value)}\n\n`);
}

function rpcResult(id, result) {
  return { jsonrpc: '2.0', id, result };
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request)
    chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
  });
}

test('reuses one session across notification, tools, wait, and deletion', async () => {
  const requests = [];
  let clicked = false;
  let deleted = false;
  let toolCallCount = 0;

  const tools = [
    {
      name: 'browser_navigate',
      inputSchema: {
        type: 'object',
        properties: { url: { type: 'string' } },
      },
    },
    {
      name: 'browser_snapshot',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'browser_click',
      inputSchema: {
        type: 'object',
        properties: {
          element: { type: 'string' },
          target: { type: 'string' },
        },
      },
    },
  ];

  const server = http.createServer(async (request, response) => {
    try {
      const expectedPath = `/${TOKEN}/mcp`;
      assert.equal(request.url, expectedPath);
      const session = request.headers['mcp-session-id'];
      const payload = request.method === 'POST' ? await readJson(request) : undefined;
      requests.push({
        method: request.method,
        rpcMethod: payload && payload.method,
        session,
      });

      if (request.method === 'DELETE') {
        assert.equal(session, SESSION_ID);
        deleted = true;
        response.writeHead(204);
        response.end();
        return;
      }
      if (deleted) {
        response.writeHead(404, { 'Content-Type': 'text/plain' });
        response.end(`Session not found at ${expectedPath}`);
        return;
      }
      if (payload.method === 'initialize') {
        assert.equal(session, undefined);
        sse(
          response,
          rpcResult(payload.id, {
            protocolVersion: '2025-06-18',
            capabilities: {},
            serverInfo: { name: 'fixture', version: '1' },
          }),
          { 'Mcp-Session-Id': SESSION_ID },
        );
        return;
      }

      assert.equal(session, SESSION_ID);
      if (payload.method === 'notifications/initialized') {
        response.writeHead(202);
        response.end();
        return;
      }
      if (payload.method === 'tools/list') {
        sse(response, rpcResult(payload.id, { tools }));
        return;
      }
      if (payload.method !== 'tools/call')
        throw new Error(`unexpected method ${payload.method}`);

      toolCallCount += 1;
      const name = payload.params.name;
      if (name === 'browser_navigate') {
        assert.match(payload.params.arguments.url, /^data:text\/html/);
        assert.equal(payload.params.arguments.url.includes(TOKEN), false);
        json(response, 200, rpcResult(payload.id, {
          content: [{ type: 'text', text: 'navigated' }],
        }));
        return;
      }
      if (name === 'browser_click') {
        assert.equal(payload.params.arguments.target, 'probe-button');
        assert.equal(payload.params.arguments.element, BUTTON_NAME);
        clicked = true;
        json(response, 200, rpcResult(payload.id, {
          content: [{ type: 'text', text: 'clicked' }],
        }));
        return;
      }
      if (name === 'browser_snapshot') {
        const marker = clicked ? CLICKED_MARKER : INITIAL_MARKER;
        sse(response, rpcResult(payload.id, {
          content: [{
            type: 'text',
            text: [
              `- status: ${marker}`,
              `- button "${BUTTON_NAME}" [ref=probe-button]`,
            ].join('\n'),
          }],
        }));
        return;
      }
      throw new Error(`unexpected tool ${name}`);
    } catch (error) {
      response.destroy(error);
    }
  });

  const port = await listen(server);
  const output = [];
  try {
    const result = await runRegression({
      endpoint: `http://127.0.0.1:${port}/${TOKEN}/mcp`,
      waitMs: 5,
      timeoutMs: 1000,
      logger: message => output.push(message),
    });

    assert.deepEqual(result, {
      browserCalls: 5,
      waitMs: 5,
      deletionVerified: true,
    });
    assert.equal(toolCallCount, 5);
    assert.equal(deleted, true);
    assert.deepEqual(
      requests.map(entry => [entry.method, entry.rpcMethod]),
      [
        ['POST', 'initialize'],
        ['POST', 'notifications/initialized'],
        ['POST', 'tools/list'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['DELETE', undefined],
        ['POST', 'tools/list'],
      ],
    );
    for (const entry of requests.slice(1))
      assert.equal(entry.session, SESSION_ID);
    assert.equal(output.length, 1);
    assert.equal(output[0].includes(TOKEN), false);
    assert.match(output[0], /^PASS:/);
  } finally {
    await close(server);
  }
});

test('validates compatibility URLs and CLI timing options without leaking input', () => {
  const parsed = parseArgs([
    '--endpoint',
    `https://chrome.example.test/${TOKEN}/mcp`,
    '--wait-seconds',
    '0.125',
    '--timeout-seconds',
    '3',
  ]);
  assert.equal(parsed.waitMs, 125);
  assert.equal(parsed.timeoutMs, 3000);
  assert.equal(
    validateEndpoint(parsed.endpoint).token,
    TOKEN,
  );

  assert.throws(
    () => validateEndpoint('https://chrome.example.test/mcp'),
    /endpoint must end in/,
  );
  assert.throws(
    () => validateEndpoint(`http://chrome.example.test/${TOKEN}/mcp`),
    /must use HTTPS/,
  );

  const sanitized = sanitize(
    `failed at https://chrome.example.test/${TOKEN}/mcp with ${TOKEN}`,
    [TOKEN],
  );
  assert.equal(sanitized.includes(TOKEN), false);
  assert.equal(sanitized.includes('https://'), false);
});
