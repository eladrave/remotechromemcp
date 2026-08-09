#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

const EXPECTED_MCP_VERSION = '0.0.79';
const EXPECTED_PLAYWRIGHT_CORE_VERSION = '1.63.0-alpha-2026-08-05';
const EXPECTED_HTTP_PATCHED_SOURCE_SHA256 =
  '96d225418072857aed717efba7b518f919e5ef29ae602ff1a2c9480ec7bc3127';
const EXPECTED_ORIGINAL_BACKEND_BLOCK_SHA256 =
  'd623d4740c990083ea0f589652ca597de819f52de82550d2938259ae61bc5760';
const EXPECTED_ORIGINAL_PROGRAM_BLOCK_SHA256 =
  '23db690bc2f1cd7548714314fcccf0230b52165c999e1f99718fe521f27ac5e8';
const EXPECTED_PATCHED_SOURCE_SHA256 =
  '5d8ecd37a63e8ade5a8acc85f09b7221a1312af8a5e31763aaaa3ff5f631406e';

const DEFAULT_MCP_PACKAGE_JSON =
  '/usr/local/lib/node_modules/@playwright/mcp/package.json';
const PATCH_MARKER = 'REMOTE_CHROME_MCP_LIFECYCLE_PATCH=1';
const BACKEND_START =
  '    BrowserBackend = class extends import_events29.EventEmitter {';
const BACKEND_END =
  '\n      async callTool(name, rawArguments = {}, signal) {';
const PROGRAM_START =
  '    const useSharedBrowser = config.sharedBrowserContext || config.browser.isolated;';
const PROGRAM_END = '\n    await start(factory, config.server);';
const CALL_TOOL_START = `        const cwd = rawArguments._meta?.cwd;
        const raw = !!rawArguments._meta?.raw;
        const context2 = this._context;
        const response2 = new Response4(context2, name, parsedArguments, { relativeTo: cwd, raw, json });
        context2.setRunningTool(name);
        let responseObject;
        try {`;
const PATCHED_CALL_TOOL_START = `        if (this._disposed)
          throw new Error("Playwright MCP browser backend is disposing");
        this._activeCalls++;
        if (this._activeCalls === 1)
          this._drainPromise = new Promise((resolve) => this._resolveDrain = resolve);
        const cwd = rawArguments._meta?.cwd;
        const raw = !!rawArguments._meta?.raw;
        const context2 = this._context;
        const response2 = new Response4(context2, name, parsedArguments, { relativeTo: cwd, raw, json });
        context2.setRunningTool(name);
        let responseObject;
        try {`;
const CALL_TOOL_FINALLY = `        } finally {
          context2.setRunningTool(void 0);
        }`;
const PATCHED_CALL_TOOL_FINALLY = `        } finally {
          context2.setRunningTool(void 0);
          this._activeCalls--;
          if (this._activeCalls === 0) {
            const resolveDrain = this._resolveDrain;
            this._resolveDrain = void 0;
            resolveDrain?.();
          }
        }`;
const SERVER_DISCONNECT_LISTENER =
  '          backend2.once("disconnected", () => {';
const PATCHED_SERVER_DISCONNECT_LISTENER =
  '          backend2.onDisconnected(() => {';

const PATCHED_BACKEND_BLOCK = `    BrowserBackend = class extends import_events29.EventEmitter {
      constructor(config, browserContext, tools, disposeCallback) {
        super();
        if (!browserContext)
          throw new Error("Playwright MCP browser connection has no BrowserContext");
        this._disconnected = false;
        this._disposed = false;
        this._activeCalls = 0;
        this._drainPromise = Promise.resolve();
        this._resolveDrain = void 0;
        this._disposePromise = void 0;
        this._config = config;
        this._tools = tools;
        this._browserContext = browserContext;
        this._browser = browserContext.browser();
        this._disposeCallback = disposeCallback;
        this._markDisconnected = () => {
          if (this._disconnected)
            return;
          backendDebug("browser disconnected");
          this._disconnected = true;
          this.emit("disconnected");
        };
        this._browserContext.once("close", this._markDisconnected);
        this._browser?.once("disconnected", this._markDisconnected);
      }
      onDisconnected(listener) {
        if (this._disconnected)
          listener();
        else
          this.once("disconnected", listener);
      }
      async initialize(clientInfo) {
        try {
          this._sessionLog = this._config.saveSession ? await SessionLog.create(this._config, clientInfo.cwd) : void 0;
          this._context = new Context(this._browserContext, {
            config: this._config,
            sessionLog: this._sessionLog,
            cwd: clientInfo.cwd
          });
        } catch (error) {
          await this.dispose();
          throw error;
        }
      }
      dispose() {
        if (!this._disposePromise) {
          this._disposed = true;
          this._disposePromise = (async () => {
            if (this._activeCalls) {
              const rawDrainTimeout = process.env.REMOTE_CHROME_MCP_REQUEST_DRAIN_TIMEOUT_MS ?? "300000";
              const parsedDrainTimeout = Number(rawDrainTimeout);
              const drainTimeoutMs = /^[1-9][0-9]*$/.test(rawDrainTimeout) &&
                Number.isSafeInteger(parsedDrainTimeout) && parsedDrainTimeout <= 2147483647 ? parsedDrainTimeout : 300000;
              let drainTimer;
              const drained = await Promise.race([
                this._drainPromise.then(() => true),
                new Promise((resolve) => {
                  drainTimer = setTimeout(() => resolve(false), drainTimeoutMs);
                  drainTimer.unref?.();
                })
              ]);
              clearTimeout(drainTimer);
              if (!drained) {
                console.error("[remote-chrome-mcp] active browser tool drain timed out; exiting for a clean restart");
                setImmediate(() => process.exit(1));
                return;
              }
            }
            this._browserContext.off("close", this._markDisconnected);
            this._browser?.off("disconnected", this._markDisconnected);
            await this._context?.dispose().catch((e) => debug10("pw:tools:error")(e));
            await this._disposeCallback?.().catch((e) => debug10("pw:tools:error")(e));
          })();
        }
        return this._disposePromise;
      }
`;

const PATCHED_PROGRAM_BLOCK = `    // ${PATCH_MARKER}
    const useSharedBrowser = config.sharedBrowserContext || config.browser.isolated;
    let sharedBrowserPromise;
    const clientOwners = /* @__PURE__ */ new Set();
    const clientNameCounters = /* @__PURE__ */ new Map();
    process.on("unhandledRejection", () => {
      console.error("[remote-chrome-mcp] fatal unhandled rejection; exiting for a clean restart");
      setImmediate(() => process.exit(1));
    });
    const createSharedBrowser = (clientInfo) => {
      const promise = (async () => {
        const { browser, canBind } = await createBrowserWithInfo(config, clientInfo, options);
        browser.once("disconnected", () => {
          if (sharedBrowserPromise === promise)
            sharedBrowserPromise = void 0;
        });
        if (canBind)
          await browser.bind(clientInfo.clientName, { workspaceDir: clientInfo.cwd });
        if (!browser.isConnected())
          throw new Error("Playwright MCP browser disconnected during initialization");
        return browser;
      })().catch((error) => {
        if (sharedBrowserPromise === promise)
          sharedBrowserPromise = void 0;
        throw error;
      });
      sharedBrowserPromise = promise;
      return promise;
    };
    const factory = {
      name: "Playwright",
      nameInConfig: "playwright",
      version: version2,
      toolSchemas: tools.map((tool) => tool.schema),
      create: async (clientInfo) => {
        if (useSharedBrowser && !sharedBrowserPromise)
          createSharedBrowser(clientInfo);
        const owner = { released: false };
        clientOwners.add(owner);
        try {
          let promise = sharedBrowserPromise;
          let { browser, canBind } = promise ? { browser: await promise, canBind: false } : await createBrowserWithInfo(config, clientInfo, options);
          if (canBind) {
            const count = (clientNameCounters.get(clientInfo.clientName) ?? 0) + 1;
            clientNameCounters.set(clientInfo.clientName, count);
            const sessionName = count > 1 ? clientInfo.clientName + " (" + count + ")" : clientInfo.clientName;
            await browser.bind(sessionName, { workspaceDir: clientInfo.cwd });
          }
          let browserContext = config.browser.isolated ? await browser.newContext(config.browser.contextOptions) : browser.contexts()[0];
          if (!browserContext && useSharedBrowser && !config.browser.isolated) {
            if (sharedBrowserPromise === promise) {
              sharedBrowserPromise = void 0;
              await browser.close().catch(() => {
              });
            }
            promise = sharedBrowserPromise ?? createSharedBrowser(clientInfo);
            browser = await promise;
            canBind = false;
            browserContext = browser.contexts()[0];
          }
          if (!browserContext)
            throw new Error("Playwright MCP could not acquire a BrowserContext after reconnecting");
          return new BrowserBackend(config, browserContext, tools, async () => {
            if (owner.released)
              return;
            owner.released = true;
            clientOwners.delete(owner);
            if (sharedBrowserPromise && clientOwners.size > 0) {
              if (config.browser.isolated) {
                testDebug3("close context");
                await browserContext.close().catch(() => {
                });
              }
              return;
            }
            testDebug3("close browser");
            if (sharedBrowserPromise === promise)
              sharedBrowserPromise = void 0;
            await browserContext.close().catch(() => {
            });
            await browser.close().catch(() => {
            });
          });
        } catch (error) {
          owner.released = true;
          clientOwners.delete(owner);
          throw error;
        }
      }
    };`;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function countOccurrences(source, needle) {
  return source.split(needle).length - 1;
}

function parseArguments(argv) {
  const options = { check: false, mcpPackageJson: DEFAULT_MCP_PACKAGE_JSON };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--check') {
      options.check = true;
      continue;
    }
    if (argv[index] === '--mcp-package-json' && argv[index + 1]) {
      options.mcpPackageJson = argv[++index];
      continue;
    }
    throw new Error(`unknown or incomplete argument: ${argv[index]}`);
  }
  return options;
}

function resolveCoreBundle(mcpPackageJsonArgument) {
  const mcpPackageJson = path.resolve(mcpPackageJsonArgument);
  const metadata = JSON.parse(fs.readFileSync(mcpPackageJson, 'utf8'));
  if (metadata.name !== '@playwright/mcp' ||
      metadata.version !== EXPECTED_MCP_VERSION) {
    throw new Error(
      `expected @playwright/mcp@${EXPECTED_MCP_VERSION}, got ` +
      `${metadata.name || '<unknown>'}@${metadata.version || '<unknown>'}`,
    );
  }
  const packageRequire = createRequire(mcpPackageJson);
  const corePackageJson = packageRequire.resolve('playwright-core/package.json');
  const coreMetadata = JSON.parse(fs.readFileSync(corePackageJson, 'utf8'));
  if (coreMetadata.version !== EXPECTED_PLAYWRIGHT_CORE_VERSION) {
    throw new Error(
      `expected playwright-core@${EXPECTED_PLAYWRIGHT_CORE_VERSION}, got ` +
      `${coreMetadata.version || '<unknown>'}`,
    );
  }
  return packageRequire.resolve('playwright-core/lib/coreBundle');
}

function blockBounds(source, startMarker, endMarker, label) {
  const startCount = countOccurrences(source, startMarker);
  const endCount = countOccurrences(source, endMarker);
  if (startCount !== 1 || endCount !== 1)
    throw new Error(`expected one ${label} signature, got start=${startCount} end=${endCount}`);
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  if (end === -1)
    throw new Error(`${label} end signature precedes its start signature`);
  return { start, end };
}

function replaceBlock(source, startMarker, endMarker, replacement, expectedHash, label) {
  const { start, end } = blockBounds(source, startMarker, endMarker, label);
  const blockHash = sha256(source.slice(start, end));
  if (blockHash !== expectedHash) {
    throw new Error(
      `${label} SHA-256 mismatch: expected ${expectedHash}, got ${blockHash}`,
    );
  }
  return source.slice(0, start) + replacement + source.slice(end);
}

function replaceExact(source, original, replacement, label) {
  const count = countOccurrences(source, original);
  if (count !== 1)
    throw new Error(`expected one ${label} signature, got ${count}`);
  return source.replace(original, replacement);
}

function verifyPatchedSource(source) {
  const sourceHash = sha256(source);
  if (sourceHash !== EXPECTED_PATCHED_SOURCE_SHA256) {
    throw new Error(
      `lifecycle-patched coreBundle.js SHA-256 mismatch: expected ` +
      `${EXPECTED_PATCHED_SOURCE_SHA256}, got ${sourceHash}`,
    );
  }
  if (countOccurrences(source, PATCH_MARKER) !== 1 ||
      countOccurrences(source, PATCHED_BACKEND_BLOCK) !== 1 ||
      countOccurrences(source, PATCHED_PROGRAM_BLOCK) !== 1 ||
      countOccurrences(source, PATCHED_CALL_TOOL_START) !== 1 ||
      countOccurrences(source, PATCHED_CALL_TOOL_FINALLY) !== 1 ||
      countOccurrences(source, PATCHED_SERVER_DISCONNECT_LISTENER) !== 1) {
    throw new Error('lifecycle-patched coreBundle.js failed its exact marker checks');
  }
}

function patch(options) {
  const coreBundle = resolveCoreBundle(options.mcpPackageJson);
  const source = fs.readFileSync(coreBundle, 'utf8');
  if (options.check) {
    verifyPatchedSource(source);
    process.stdout.write(`verified Playwright MCP lifecycle patch: ${coreBundle}\n`);
    return;
  }
  if (source.includes(PATCH_MARKER))
    throw new Error('coreBundle.js is already lifecycle patched; use --check');
  const sourceHash = sha256(source);
  if (sourceHash !== EXPECTED_HTTP_PATCHED_SOURCE_SHA256) {
    throw new Error(
      `expected HTTP-patched coreBundle.js SHA-256 ` +
      `${EXPECTED_HTTP_PATCHED_SOURCE_SHA256}, got ${sourceHash}`,
    );
  }
  let patched = replaceBlock(
    source,
    BACKEND_START,
    BACKEND_END,
    PATCHED_BACKEND_BLOCK,
    EXPECTED_ORIGINAL_BACKEND_BLOCK_SHA256,
    'BrowserBackend lifecycle block',
  );
  patched = replaceExact(
    patched,
    CALL_TOOL_START,
    PATCHED_CALL_TOOL_START,
    'BrowserBackend call start',
  );
  patched = replaceExact(
    patched,
    CALL_TOOL_FINALLY,
    PATCHED_CALL_TOOL_FINALLY,
    'BrowserBackend call cleanup',
  );
  patched = replaceExact(
    patched,
    SERVER_DISCONNECT_LISTENER,
    PATCHED_SERVER_DISCONNECT_LISTENER,
    'MCP backend disconnect listener',
  );
  patched = replaceBlock(
    patched,
    PROGRAM_START,
    PROGRAM_END,
    PATCHED_PROGRAM_BLOCK,
    EXPECTED_ORIGINAL_PROGRAM_BLOCK_SHA256,
    'MCP shared-browser program block',
  );
  verifyPatchedSource(patched);
  fs.writeFileSync(coreBundle, patched, 'utf8');
  verifyPatchedSource(fs.readFileSync(coreBundle, 'utf8'));
  process.stdout.write(`patched Playwright MCP lifecycle: ${coreBundle}\n`);
}

function main() {
  try {
    patch(parseArguments(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`Playwright MCP lifecycle patch failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  BACKEND_END,
  BACKEND_START,
  CALL_TOOL_FINALLY,
  CALL_TOOL_START,
  EXPECTED_PATCHED_SOURCE_SHA256,
  PATCHED_CALL_TOOL_FINALLY,
  PATCHED_CALL_TOOL_START,
  PATCHED_BACKEND_BLOCK,
  PATCHED_PROGRAM_BLOCK,
  PATCH_MARKER,
  PROGRAM_END,
  PROGRAM_START,
  blockBounds,
  sha256,
};

if (require.main === module)
  main();
