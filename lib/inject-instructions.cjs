'use strict';

const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

function loadMcpUtilsBundle() {
  if (process.argv[1]) {
    try {
      const cliRequire = createRequire(fs.realpathSync(process.argv[1]));
      return cliRequire('playwright-core/lib/utilsBundle');
    } catch {
      // Tests and nonstandard launchers may not resolve from their entrypoint.
    }
  }
  return require('playwright-core/lib/utilsBundle');
}

const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Server
} = loadMcpUtilsBundle();

const PATCHED = Symbol.for('remote-chrome.inject-instructions.patched');
const HUMAN_HANDOFF_INPUT_SCHEMA = Object.freeze({
  type: 'object',
  properties: {},
  additionalProperties: false
});
const HUMAN_HANDOFF_ANNOTATIONS = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
});
const HUMAN_HANDOFF_TOOLS = Object.freeze([
  Object.freeze({
    name: 'remote_chrome_request_human_intervention',
    description: [
      'Return the protected noVNC handoff URL when login, MFA, CAPTCHA, a',
      'security key, consent, or another human-only step is required.',
      'This tool accepts no credentials or verification data.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Request human intervention',
      ...HUMAN_HANDOFF_ANNOTATIONS
    }
  }),
  Object.freeze({
    name: 'get_novnc_link',
    description: [
      'Return the protected token-embedded noVNC URL for the user to complete',
      'login, 2FA, CAPTCHA, a security key, consent, or any other human-only',
      'browser step. This tool accepts no credentials or verification data.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Get protected noVNC link',
      ...HUMAN_HANDOFF_ANNOTATIONS
    }
  })
]);
const HUMAN_HANDOFF_TOOL_NAMES = new Set(
  HUMAN_HANDOFF_TOOLS.map(tool => tool.name)
);
const FALLBACK = `REMOTE_CHROME_PLAYBOOK_FALLBACK=1

Snapshot the current page before navigating. After a timeout, snapshot again.
Stop and ask the user for human control when login, MFA, CAPTCHA, or a security key is required.
Never expose credentials, cookies, or tokens.`;

function humanHandoffUrl() {
  const configuredUrl = process.env.REMOTE_CHROME_LOGIN_TOKEN_URL;
  if (!configuredUrl)
    return;

  try {
    const parsed = new URL(configuredUrl);
    const queryKeys = [...parsed.searchParams.keys()];
    if (
      parsed.protocol !== 'https:' ||
      !parsed.hostname ||
      parsed.username ||
      parsed.password ||
      parsed.pathname !== '/login/' ||
      parsed.hash ||
      queryKeys.length !== 1 ||
      queryKeys[0] !== 'token' ||
      !/^[0-9a-f]{64}$/.test(parsed.searchParams.get('token') || '')
    ) {
      return;
    }
    return configuredUrl;
  } catch {
    return;
  }
}

function humanHandoffResult(request) {
  const argumentsValue = request?.params?.arguments;
  if (
    argumentsValue &&
    (typeof argumentsValue !== 'object' ||
      Array.isArray(argumentsValue) ||
      Object.keys(argumentsValue).length)
  ) {
    return {
      content: [{
        type: 'text',
        text: 'This tool accepts no arguments. Do not send credentials or verification data to the MCP server.'
      }],
      isError: true
    };
  }

  const url = humanHandoffUrl();
  if (!url) {
    return {
      content: [{
        type: 'text',
        text: 'The protected human-handoff URL is unavailable. Ask the server operator to verify the remote Chrome configuration.'
      }],
      isError: true
    };
  }

  return {
    content: [{
      type: 'text',
      text: [
        'Human intervention is required.',
        'Ask the user to open this protected noVNC URL in a trusted browser and complete the visible human-only step:',
        url,
        '',
        'Do not send passwords, MFA or recovery codes, security-key data, or CAPTCHA answers to the agent.',
        'This reusable URL is a password-equivalent secret until the server credentials are rotated.',
        'When finished, tell the agent to take a fresh snapshot before continuing.'
      ].join('\n')
    }]
  };
}

if (!Server.prototype[PATCHED]) {
  const originalInitialize = Server.prototype._oninitialize;
  const originalSetRequestHandler = Server.prototype.setRequestHandler;

  Object.defineProperty(Server.prototype, PATCHED, {
    value: true
  });

  Server.prototype.setRequestHandler = function remoteChromeSetRequestHandler(
    requestSchema,
    handler
  ) {
    if (requestSchema === ListToolsRequestSchema) {
      const wrappedListTools = async (...args) => {
        const result = await handler(...args);
        const tools = Array.isArray(result?.tools)
          ? result.tools.filter(
              tool => !HUMAN_HANDOFF_TOOL_NAMES.has(tool?.name)
            )
          : [];
        return {
          ...result,
          tools: [...tools, ...HUMAN_HANDOFF_TOOLS]
        };
      };
      return originalSetRequestHandler.call(this, requestSchema, wrappedListTools);
    }

    if (requestSchema === CallToolRequestSchema) {
      const wrappedCallTool = async (request, ...args) => {
        if (HUMAN_HANDOFF_TOOL_NAMES.has(request?.params?.name))
          return humanHandoffResult(request);
        return handler(request, ...args);
      };
      return originalSetRequestHandler.call(this, requestSchema, wrappedCallTool);
    }

    return originalSetRequestHandler.call(this, requestSchema, handler);
  };

  Server.prototype._oninitialize = async function remoteChromeInitialize(request) {
    const configuredPath = process.env.REMOTE_CHROME_PLAYBOOK;
    const playbookPath = configuredPath
      ? path.resolve(configuredPath)
      : path.resolve(__dirname, '..', 'browser-playbook.md');

    let instructions = FALLBACK;
    try {
      const candidate = fs.readFileSync(playbookPath, 'utf8').trim();
      if (candidate)
        instructions = candidate;
      else
        console.error(`[remote-chrome] empty playbook: ${playbookPath}; using fallback`);
    } catch (error) {
      console.error(`[remote-chrome] cannot read playbook: ${playbookPath}; using fallback`);
    }

    this._instructions = instructions;
    return originalInitialize.call(this, request);
  };
}
