import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import {
  BridgeError,
  CodexAppServer,
  buildResponsesRequest,
  createBridgeServer,
  createToolNames,
  launchExecutable,
  setClaudeEnvironment,
  translateCompletedResponse,
} from '../clcd-win.mjs';

const openedServers = [];

async function startServer(options = {}) {
  const bridge = createBridgeServer({ token: 'unit-test-token', ...options });
  await new Promise((resolve, reject) => {
    bridge.server.once('error', reject);
    bridge.server.listen(0, '127.0.0.1', resolve);
  });
  openedServers.push(bridge.server);
  return { ...bridge, base: `http://127.0.0.1:${bridge.server.address().port}` };
}

after(async () => {
  await Promise.all(openedServers.map((server) => new Promise((resolve) => server.close(resolve))));
});

test('maps Messages requests, tools, images, and model aliases', () => {
  const { request, toolNames } = buildResponsesRequest({
    model: 'claude-opus-4-1',
    system: [{ type: 'text', text: 'rules' }],
    messages: [
      { role: 'user', content: [{ type: 'text', text: 'look' }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AA==' } }] },
      { role: 'assistant', content: [{ type: 'tool_use', id: 'call1', name: 'name with spaces', input: { path: 'a' } }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'call1', is_error: true, content: [{ type: 'text', text: 'missing' }] }] },
    ],
    tools: [{ name: 'name with spaces', description: 'read', input_schema: { type: 'object' } }],
    tool_choice: { type: 'tool', name: 'name with spaces', disable_parallel_tool_use: true },
  }, { model: 'gpt-6.1-sol', mapping: { opus: 'provider-pro' }, effort: 'medium' });
  assert.equal(request.model, 'provider-pro');
  assert.equal(request.instructions, 'rules');
  assert.equal(request.input[1].content[0].image_url, 'data:image/png;base64,AA==');
  assert.equal(request.input[2].name, 'clcd_tool_0');
  assert.equal(request.input[3].output, '[Tool error]\nmissing');
  assert.equal(request.tools[0].name, 'clcd_tool_0');
  assert.deepEqual(request.tool_choice, { type: 'function', name: 'clcd_tool_0' });
  assert.equal(request.parallel_tool_calls, false);
  assert.equal(toolNames.reverse.clcd_tool_0, 'name with spaces');
});

test('rejects unsupported sampling, structured output, thinking, and blocks', () => {
  for (const extra of [{ temperature: 0.1 }, { stop_sequences: ['x'] }, { output_format: { type: 'json' } }, { thinking: { type: 'enabled', budget_tokens: 20 } }]) {
    assert.throws(() => buildResponsesRequest({ messages: [{ role: 'user', content: 'hi' }], ...extra }), BridgeError);
  }
  assert.throws(() => buildResponsesRequest({ messages: [{ role: 'user', content: [{ type: 'unsupported' }] }] }), /Unsupported content block/);
});

test('maps completed Responses output and cached-token usage', () => {
  const message = translateCompletedResponse({
    id: 'resp_1', status: 'completed',
    output: [
      { type: 'message', content: [{ type: 'output_text', text: 'hello' }] },
      { type: 'function_call', call_id: 'call1', name: 'clcd_tool_0', arguments: '{"x":1}' },
    ],
    usage: { input_tokens: 100, input_tokens_details: { cached_tokens: 30 }, output_tokens: 7 },
  }, 'gpt-test', { clcd_tool_0: 'name with spaces' });
  assert.equal(message.stop_reason, 'tool_use');
  assert.deepEqual(message.content[1], { type: 'tool_use', id: 'call1', name: 'name with spaces', input: { x: 1 } });
  assert.deepEqual(message.usage, { input_tokens: 70, cache_read_input_tokens: 30, cache_creation_input_tokens: 0, output_tokens: 7 });
});

test('requires local token and returns approximate count_tokens', async () => {
  const { base } = await startServer();
  const denied = await fetch(`${base}/health`);
  assert.equal(denied.status, 401);
  const counted = await fetch(`${base}/v1/messages/count_tokens`, {
    method: 'POST', headers: { 'x-api-key': 'unit-test-token', 'content-type': 'application/json' },
    body: JSON.stringify({ system: 'rules', messages: [{ role: 'user', content: 'hello' }], tools: [] }),
  });
  assert.equal(counted.status, 200);
  assert.ok((await counted.json()).input_tokens > 0);
});

test('serves non-streaming Messages from the Codex Responses event stream', async () => {
  let submitted;
  const { base } = await startServer({
    model: 'gpt-test',
    codex: {},
    upstream: async (_codex, payload) => {
      submitted = payload;
      return new Response('data: {"type":"response.created","response":{"id":"r1"}}\n\ndata: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"CLCD_OK"}]}],"usage":{"input_tokens":8,"output_tokens":2}}}\n\n', { status: 200 });
    },
  });
  const response = await fetch(`${base}/v1/messages`, {
    method: 'POST', headers: { 'x-api-key': 'unit-test-token', 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'claude-sonnet-4-1', max_tokens: 20, messages: [{ role: 'user', content: 'test' }] }),
  });
  assert.equal(response.status, 200);
  const message = await response.json();
  assert.equal(message.content[0].text, 'CLCD_OK');
  assert.equal(message.model, 'gpt-test');
  assert.equal(submitted.stream, true);
  assert.equal(submitted.store, false);
});

test('streams translated text and completion events', async () => {
  const { base } = await startServer({
    codex: {},
    upstream: async () => new Response(
      'data: {"type":"response.created","response":{"id":"r2"}}\n\ndata: {"type":"response.output_text.delta","item_id":"m1","content_index":0,"delta":"hello"}\n\ndata: {"type":"response.completed","response":{"id":"r2","status":"completed","output":[],"usage":{"input_tokens":3,"output_tokens":1}}}\n\n',
      { status: 200 },
    ),
  });
  const response = await fetch(`${base}/v1/messages`, {
    method: 'POST', headers: { 'x-api-key': 'unit-test-token', 'content-type': 'application/json' },
    body: JSON.stringify({ stream: true, messages: [{ role: 'user', content: 'test' }] }),
  });
  assert.equal(response.status, 200);
  const stream = await response.text();
  assert.match(stream, /event: message_start/);
  assert.match(stream, /"text":"hello"/);
  assert.match(stream, /event: message_stop/);
});

test('isolates Claude environment and safely forwards arguments to a .cmd launcher', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'clcd-win-claude-'));
  const mockScript = path.join(directory, 'mock-claude.mjs');
  const commandFile = path.join(directory, 'claude wrapper.cmd');
  const outputFile = path.join(directory, 'received-args.json');
  await writeFile(mockScript, `import { writeFileSync } from 'node:fs'; writeFileSync(process.env.CLCD_TEST_ARGV, JSON.stringify(process.argv.slice(2)));`, 'utf8');
  await writeFile(commandFile, `@echo off\r\n"%CLCD_TEST_NODE%" "${mockScript}" %*\r\n`, 'utf8');
  try {
    const env = setClaudeEnvironment('http://127.0.0.1:43210', 'ephemeral-test-token', 'model-test');
    assert.equal(env.ANTHROPIC_BASE_URL, 'http://127.0.0.1:43210');
    assert.equal(env.ANTHROPIC_AUTH_TOKEN, 'ephemeral-test-token');
    assert.equal(env.ANTHROPIC_API_KEY, '');
    assert.match(env.CLAUDE_CONFIG_DIR, /\\.claude-codex-cli$/);
    assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
    const expectedArgs = ['--continue', 'folder with spaces', '&not-a-command', 'caret^value', '%CLCD_TEST_NODE%', 'quote"inside', 'trailing\\'];
    const child = launchExecutable(commandFile, expectedArgs, {
      env: { ...env, CLCD_TEST_NODE: process.execPath, CLCD_TEST_ARGV: outputFile },
      stdio: 'inherit',
    });
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (status) => resolve(status));
    });
    assert.equal(code, 0);
    assert.deepEqual(JSON.parse(await readFile(outputFile, 'utf8')), expectedArgs);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('uses Codex app-server RPC auth and rejects non-ChatGPT credentials', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'clcd-win-mock-'));
  const mock = path.join(directory, 'mock-codex.mjs');
  const source = `import { createInterface } from 'node:readline';\n` +
    `const mode = process.argv[2];\n` +
    `const rl = createInterface({ input: process.stdin });\n` +
    `for await (const line of rl) { const request = JSON.parse(line); if (request.id == null) continue; let result = {}; if (request.method === 'getAuthStatus') { const claims = { exp: Math.floor(Date.now() / 1000) + 3600, 'https://api.openai.com/auth': { chatgpt_account_id: 'account-test' } }; const token = 'a.' + Buffer.from(JSON.stringify(claims)).toString('base64url') + '.c'; result = mode === 'api' ? { authMethod: 'api', authToken: token } : { authMethod: 'chatgpt', requiresOpenaiAuth: true, authToken: token }; } process.stdout.write(JSON.stringify({ id: request.id, result }) + '\\n'); }\n`;
  await writeFile(mock, source, 'utf8');
  try {
    const valid = new CodexAppServer(process.execPath, [mock, 'chatgpt']);
    await valid.start();
    const identity = await valid.authStatus();
    assert.equal(identity.account, 'account-test');
    assert.ok(identity.token.startsWith('a.'));
    await valid.close();

    if (process.platform === 'win32') {
      const spacedDirectory = path.join(directory, 'Codex CLI');
      await mkdir(spacedDirectory);
      const commandFile = path.join(spacedDirectory, 'codex.cmd');
      await writeFile(commandFile, `@echo off\r\nnode "${mock}"\r\n`, 'utf8');
      const npmCommand = new CodexAppServer(commandFile);
      await npmCommand.start();
      assert.equal((await npmCommand.authStatus()).account, 'account-test');
      await npmCommand.close();
    }

    const invalid = new CodexAppServer(process.execPath, [mock, 'api']);
    await invalid.start();
    await assert.rejects(invalid.authStatus(), /ChatGPT subscription/);
    await invalid.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
