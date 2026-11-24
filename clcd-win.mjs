import { randomBytes } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const execFileAsync = promisify(execFile);
const DEFAULT_MODEL = 'gpt-6.1-sol';
const CODEX_ENDPOINT = 'https://chatgpt.com/backend-api/codex/responses';
const MAX_BODY_BYTES = 32 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;
const HEADER_TIMEOUT_MS = 120 * 1000;

export class BridgeError extends Error {
  constructor(status, message, type = 'invalid_request_error') {
    super(message);
    this.status = status;
    this.type = type;
  }
}

function assert(condition, message) {
  if (!condition) throw new BridgeError(400, message);
}

export function createToolNames(tools = []) {
  const forward = Object.create(null);
  const reverse = Object.create(null);
  for (const [index, tool] of tools.entries()) {
    assert(typeof tool?.name === 'string' && tool.name.length > 0, 'Unsupported server-side tool');
    const wire = /^[A-Za-z0-9_-]{1,64}$/.test(tool.name) && !tool.name.startsWith('clcd_tool_')
      ? tool.name
      : `clcd_tool_${index}`;
    forward[tool.name] = wire;
    reverse[wire] = tool.name;
  }
  return { forward, reverse };
}

function contentParts(content, role) {
  if (typeof content === 'string') return [{ type: role === 'assistant' ? 'output_text' : 'input_text', text: content }];
  assert(Array.isArray(content), 'Unsupported message content');
  return content.map((part) => {
    if (part?.type === 'text' && typeof part.text === 'string') {
      return { type: role === 'assistant' ? 'output_text' : 'input_text', text: part.text };
    }
    if (part?.type === 'image' && role === 'user') {
      if (part.source?.type === 'base64' && part.source.media_type && typeof part.source.data === 'string') {
        return { type: 'input_image', image_url: `data:${part.source.media_type};base64,${part.source.data}` };
      }
      if (part.source?.type === 'url' && typeof part.source.url === 'string') return { type: 'input_image', image_url: part.source.url };
      throw new BridgeError(400, 'Unsupported image source');
    }
    throw new BridgeError(400, `Unsupported content block: ${part?.type ?? 'unknown'}`);
  });
}

function transformMessages(messages, toolNames) {
  assert(Array.isArray(messages), 'Expected a messages array');
  const input = [];
  for (const message of messages) {
    const role = message?.role === 'system' ? 'developer' : message?.role;
    assert(['user', 'assistant', 'developer'].includes(role), 'Unsupported message role');
    if (typeof message.content === 'string') {
      input.push({ type: 'message', role, content: contentParts(message.content, role) });
      continue;
    }
    assert(Array.isArray(message.content), 'Unsupported message content');
    for (const block of message.content) {
      if (block?.type === 'tool_use') {
        input.push({ type: 'function_call', call_id: block.id, name: toolNames.forward[block.name] ?? block.name, arguments: JSON.stringify(block.input ?? {}) });
      } else if (block?.type === 'tool_result') {
        const pieces = Array.isArray(block.content)
          ? block.content.map((part) => {
            if (part?.type === 'text') return part.text;
            if (part?.type === 'image') return null;
            throw new BridgeError(400, 'Unsupported tool result block');
          }).filter((piece) => piece !== null)
          : [String(block.content ?? '')];
        const prefix = block.is_error ? '[Tool error]\n' : '';
        input.push({ type: 'function_call_output', call_id: block.tool_use_id, output: prefix + pieces.join('\n') });
        if (Array.isArray(block.content)) {
          for (const part of block.content) {
            if (part?.type === 'image') input.push({ type: 'message', role: 'user', content: contentParts([part], 'user') });
          }
        }
      } else if (block?.type === 'thinking' || block?.type === 'redacted_thinking') {
        // Codex does not accept hidden Claude reasoning blocks as input.
      } else {
        input.push({ type: 'message', role, content: contentParts([block], role) });
      }
    }
  }
  return input;
}

function selectModel(requested, model, mapping) {
  if (requested == null) return model;
  const mappedValues = Object.values(mapping ?? {});
  if (mappedValues.includes(requested)) return requested;
  if (['opus', 'fable', 'sonnet', 'haiku', 'subagent'].includes(requested)) return mapping?.[requested] ?? model;
  if (requested === 'default') return model;
  if (typeof requested === 'string' && requested.startsWith('claude-')) {
    const match = requested.match(/(?:^|-)(opus|fable|sonnet|haiku)(?:-|$)/);
    return match ? mapping?.[match[1]] ?? model : model;
  }
  return requested;
}

export function buildResponsesRequest(body, options = {}) {
  assert(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  const model = options.model ?? DEFAULT_MODEL;
  const mapping = options.mapping ?? {};
  const effort = options.effort ?? 'medium';
  const effortOverride = options.effortOverride === true;
  const requestedEffort = body.output_config?.effort;
  assert(['low', 'medium', 'high', 'xhigh'].includes(effort), 'CLCD_WIN_EFFORT must be low, medium, high, or xhigh');
  if (body.temperature != null || body.top_p != null || body.top_k != null || (body.stop_sequences ?? []).length > 0) {
    throw new BridgeError(400, 'Sampling parameters and stop_sequences are unsupported by this Codex bridge');
  }
  if (body.output_config?.format != null || body.output_format != null) {
    throw new BridgeError(400, 'Structured output format controls are unsupported by this Codex bridge');
  }
  if (body.thinking?.type === 'enabled') throw new BridgeError(400, 'Fixed thinking budgets are unsupported; use adaptive thinking or CLCD_WIN_EFFORT');
  if (!effortOverride && requestedEffort != null && !['low', 'medium', 'high', 'xhigh'].includes(requestedEffort)) {
    throw new BridgeError(400, 'Unsupported reasoning effort; supported levels: low, medium, high, xhigh');
  }
  const toolNames = createToolNames(body.tools ?? []);
  const system = typeof body.system === 'string'
    ? body.system
    : Array.isArray(body.system) ? body.system.map((part) => part?.text ?? '').join('\n') : '';
  const request = {
    model: selectModel(body.model, model, mapping),
    instructions: system,
    input: transformMessages(body.messages, toolNames),
    store: false,
    stream: true,
    reasoning: { effort: effortOverride ? effort : requestedEffort ?? effort },
    parallel_tool_calls: body.tool_choice?.disable_parallel_tool_use !== true,
    tools: (body.tools ?? []).map((tool) => {
      assert(typeof tool.name === 'string' && tool.input_schema != null, 'Unsupported server-side tool');
      return { type: 'function', name: toolNames.forward[tool.name], description: tool.description ?? '', parameters: tool.input_schema, strict: false };
    }),
  };
  if (body.tool_choice?.type === 'any') request.tool_choice = 'required';
  else if (body.tool_choice?.type === 'none') request.tool_choice = 'none';
  else if (body.tool_choice?.type === 'tool') request.tool_choice = { type: 'function', name: toolNames.forward[body.tool_choice.name] ?? body.tool_choice.name };
  return { request, toolNames };
}

function anthropicError(status, message, type = 'invalid_request_error') {
  return { type: 'error', error: { type, message } };
}

function responseUsage(usage = {}) {
  const cached = usage.input_tokens_details?.cached_tokens ?? 0;
  return {
    input_tokens: Math.max(0, (usage.input_tokens ?? 0) - cached),
    cache_read_input_tokens: cached,
    cache_creation_input_tokens: 0,
    output_tokens: usage.output_tokens ?? 0,
  };
}

function parseJwtPayload(token) {
  try {
    const payload = token.split('.')[1];
    return JSON.parse(Buffer.from(payload.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
  } catch {
    return {};
  }
}

export class CodexAppServer {
  constructor(command = process.env.CLCD_WIN_CODEX_BIN || 'codex', args = ['-c', 'model_provider="openai"', 'app-server', '--listen', 'stdio://']) {
    this.command = command;
    this.args = args;
    this.child = null;
    this.lines = null;
    this.pending = new Map();
    this.nextId = 0;
    this.writeChain = Promise.resolve();
    this.authChain = Promise.resolve();
    this.closed = false;
  }

  async start() {
    if (this.child) return;
    const args = this.args;
    if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(this.command)) {
      const env = { ...process.env, CLCD_WIN_CODEX_BIN: this.command };
      const script = `& $env:CLCD_WIN_CODEX_BIN -c 'model_provider="openai"' app-server --listen stdio://`;
      const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
      this.child = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedScript], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true, env });
    } else {
      this.child = spawn(this.command, args, { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    }
    this.child.once('error', (error) => this.failAll(new Error(`Could not start Codex CLI: ${error.message}`)));
    this.child.once('exit', (code) => this.failAll(new Error(`Codex app-server exited (${code ?? 'unknown status'})`)));
    this.lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on('line', (line) => this.onLine(line));
    await this.rpc('initialize', { clientInfo: { name: 'clcd-win', version: '0.1.0' }, capabilities: {} });
    await this.notify('initialized');
  }

  failAll(error) {
    if (this.closed) return;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  onLine(line) {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.id != null && this.pending.has(String(message.id))) {
      const pending = this.pending.get(String(message.id));
      this.pending.delete(String(message.id));
      if (message.error) pending.reject(new Error('Codex app-server RPC failed'));
      else pending.resolve(message.result);
      return;
    }
    if (message.id != null && typeof message.method === 'string') {
      this.send({ id: message.id, error: { code: -32601, message: 'Not supported' } }).catch(() => {});
    }
  }

  send(message) {
    const line = `${JSON.stringify(message)}\n`;
    const write = this.writeChain.then(() => new Promise((resolve, reject) => {
      if (!this.child || this.child.stdin.destroyed) return reject(new Error('Codex app-server stdin is closed'));
      this.child.stdin.write(line, 'utf8', (error) => error ? reject(error) : resolve());
    }));
    this.writeChain = write.catch(() => {});
    return write;
  }

  async rpc(method, params = {}) {
    const id = String(++this.nextId);
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex app-server timed out: ${method}`));
      }, 30000);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
    });
    try {
      await this.send({ id, method, params });
    } catch (error) {
      this.pending.delete(id);
      throw error;
    }
    return response;
  }

  async notify(method, params = {}) {
    return this.send({ method, params });
  }

  authStatus(refreshToken = false) {
    const task = this.authChain.then(async () => {
      let status = await this.rpc('getAuthStatus', { includeToken: true, refreshToken });
      if (status?.authMethod === 'chatgpt' && typeof status.authToken === 'string' && !refreshToken) {
        const expiry = Number(parseJwtPayload(status.authToken).exp ?? 0);
        if (expiry > 0 && expiry < Math.floor(Date.now() / 1000) + 600) {
          status = await this.rpc('getAuthStatus', { includeToken: true, refreshToken: true });
        }
      }
      if (status?.authMethod !== 'chatgpt' || status?.requiresOpenaiAuth === false || typeof status?.authToken !== 'string' || status.authToken.length === 0) {
        throw new BridgeError(503, 'Codex CLI is not logged in with a ChatGPT subscription. Run `codex login` and retry.', 'authentication_error');
      }
      const claims = parseJwtPayload(status.authToken);
      const account = claims['https://api.openai.com/auth']?.chatgpt_account_id;
      if (typeof account !== 'string' || !/^[A-Za-z0-9_.-]{1,256}$/.test(account)) {
        throw new BridgeError(503, 'Codex CLI did not provide a valid ChatGPT account identity.', 'authentication_error');
      }
      return { token: status.authToken, account };
    });
    this.authChain = task.catch(() => {});
    return task;
  }

  async close() {
    this.failAll(new Error('Codex app-server is shutting down.'));
    this.closed = true;
    this.lines?.close();
    if (!this.child || this.child.exitCode !== null) return;
    const child = this.child;
    if (process.platform === 'win32') {
      try { await execFileAsync('taskkill.exe', ['/pid', String(child.pid), '/t', '/f'], { windowsHide: true }); } catch {}
    } else {
      child.kill('SIGTERM');
    }
    await Promise.race([new Promise((resolve) => child.once('exit', resolve)), new Promise((resolve) => setTimeout(resolve, 3000))]);
  }
}

function instructionsFromBody(body) {
  return typeof body.system === 'string' ? body.system : Array.isArray(body.system) ? body.system.map((part) => part?.text ?? '').join('\n') : '';
}

function mapResponseContent(response, reverse) {
  const content = [];
  for (const output of response?.output ?? []) {
    if (output.type === 'message') {
      for (const part of output.content ?? []) {
        if (part.type === 'output_text') content.push({ type: 'text', text: part.text ?? '' });
        else if (part.type === 'refusal') content.push({ type: 'text', text: part.refusal ?? '' });
      }
    } else if (output.type === 'function_call') {
      let input;
      try { input = JSON.parse(output.arguments ?? '{}'); } catch { throw new BridgeError(502, 'Codex returned malformed tool arguments.', 'api_error'); }
      content.push({ type: 'tool_use', id: output.call_id, name: reverse[output.name] ?? output.name, input });
    }
  }
  return content;
}

export function translateCompletedResponse(response, model, reverse) {
  if (!response || !['completed', 'incomplete'].includes(response.status)) throw new BridgeError(502, 'Incomplete Codex response.', 'api_error');
  return {
    id: response.id,
    type: 'message',
    role: 'assistant',
    model,
    stop_sequence: null,
    stop_reason: response.status === 'incomplete' ? 'max_tokens' : (response.output ?? []).some((item) => item.type === 'function_call') ? 'tool_use' : 'end_turn',
    content: mapResponseContent(response, reverse),
    usage: responseUsage(response.usage),
  };
}

function streamTranslator(responseId, model, reverse) {
  const blocks = new Map();
  let nextIndex = 0;
  let toolUsed = false;
  let ended = false;
  function start(key, block) {
    const index = nextIndex++;
    blocks.set(key, { index, open: true, arguments: false });
    return { type: 'content_block_start', index, content_block: block };
  }
  function stop(key) {
    const block = blocks.get(key);
    if (!block?.open) return null;
    block.open = false;
    return { type: 'content_block_stop', index: block.index };
  }
  return (event) => {
    const events = [];
    const id = event.item_id ?? event.item?.id ?? '';
    if (event.type === 'response.created') {
      events.push({ type: 'message_start', message: { id: event.response?.id ?? responseId, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } });
    } else if (event.type === 'response.output_item.added' && event.item?.type === 'function_call') {
      toolUsed = true;
      events.push(start(id, { type: 'tool_use', id: event.item.call_id, name: reverse[event.item.name] ?? event.item.name, input: {} }));
    } else if (event.type === 'response.content_part.added' && ['output_text', 'refusal'].includes(event.part?.type)) {
      events.push(start(`${id}:${event.content_index}`, { type: 'text', text: '' }));
    } else if (event.type === 'response.output_text.delta' || event.type === 'response.refusal.delta') {
      const key = `${id}:${event.content_index}`;
      if (!blocks.has(key)) events.push(start(key, { type: 'text', text: '' }));
      events.push({ type: 'content_block_delta', index: blocks.get(key).index, delta: { type: 'text_delta', text: event.delta ?? '' } });
    } else if (event.type === 'response.function_call_arguments.delta') {
      const block = blocks.get(id);
      if (block) {
        block.arguments = true;
        events.push({ type: 'content_block_delta', index: block.index, delta: { type: 'input_json_delta', partial_json: event.delta ?? '' } });
      }
    } else if (event.type === 'response.output_item.done' && event.item?.type === 'function_call') {
      const block = blocks.get(id);
      if (block && !block.arguments) events.push({ type: 'content_block_delta', index: block.index, delta: { type: 'input_json_delta', partial_json: event.item.arguments ?? '{}' } });
      const endedBlock = stop(id);
      if (endedBlock) events.push(endedBlock);
    } else if (event.type === 'response.content_part.done' && ['output_text', 'refusal'].includes(event.part?.type)) {
      const endedBlock = stop(`${id}:${event.content_index}`);
      if (endedBlock) events.push(endedBlock);
    } else if (event.type === 'response.completed' || event.type === 'response.incomplete') {
      for (const key of blocks.keys()) {
        const endedBlock = stop(key);
        if (endedBlock) events.push(endedBlock);
      }
      ended = true;
      events.push({ type: 'message_delta', delta: { stop_reason: event.type === 'response.incomplete' ? 'max_tokens' : toolUsed ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: responseUsage(event.response?.usage) });
      events.push({ type: 'message_stop' });
    } else if (event.type === 'response.failed' || event.type === 'error') {
      ended = true;
      events.push({ type: 'error', error: { type: 'api_error', message: 'Codex returned an error.' } });
    }
    return { events, ended };
  };
}

async function* parseSse(stream) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let boundary;
    while ((boundary = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, boundary).replace(/\r$/, '');
      buffer = buffer.slice(boundary + 1);
      if (line.startsWith('data: ')) {
        const data = line.slice(6);
        if (data === '[DONE]') continue;
        try { yield JSON.parse(data); } catch { throw new BridgeError(502, 'Codex response stream contained invalid JSON.', 'api_error'); }
      }
    }
  }
  if (buffer.trim()) {
    const line = buffer.replace(/\r$/, '');
    if (line.startsWith('data: ') && line.slice(6) !== '[DONE]') {
      try { yield JSON.parse(line.slice(6)); } catch { throw new BridgeError(502, 'Codex response stream ended with invalid JSON.', 'api_error'); }
    }
  }
}

async function readJson(req) {
  const length = Number(req.headers['content-length'] ?? 0);
  if (!Number.isSafeInteger(length) || length < 0 || length > MAX_BODY_BYTES) throw new BridgeError(413, 'Invalid or excessive request length.');
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new BridgeError(413, 'Request body exceeds the 32 MiB limit.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new BridgeError(400, 'Request body must be valid JSON.'); }
}

function writeJson(res, status, body, headers = {}) {
  if (res.destroyed || res.writableEnded) return;
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(payload), connection: 'close', ...headers });
  res.end(payload);
}

function apiErrorStatus(status) {
  if (status === 429) return 'rate_limit_error';
  if (status === 401 || status === 403) return 'authentication_error';
  if (status >= 400 && status < 500) return 'invalid_request_error';
  return 'api_error';
}

async function openCodexResponse(codex, payload, signal) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const auth = await codex.authStatus(attempt === 1);
    const response = await fetch(CODEX_ENDPOINT, {
      method: 'POST',
      redirect: 'manual',
      signal,
      headers: {
        authorization: `Bearer ${auth.token}`,
        'chatgpt-account-id': auth.account,
        'openai-beta': 'responses=experimental',
        originator: 'codex_cli_rs',
        'content-type': 'application/json',
        accept: 'text/event-stream',
      },
      body: JSON.stringify(payload),
    });
    if (response.status === 401 && attempt === 0) {
      await response.body?.cancel();
      continue;
    }
    return response;
  }
  throw new BridgeError(401, 'Codex authentication was rejected; run `codex login` and retry.', 'authentication_error');
}

async function getUpstreamError(response) {
  let text = '';
  try { text = (await response.text()).slice(0, 65536); } catch {}
  let detail = '';
  try {
    const json = JSON.parse(text);
    detail = json.error?.message ?? json.detail ?? json.message ?? '';
  } catch {}
  detail = String(detail).replace(/eyJ[A-Za-z0-9_.-]+|sk-[A-Za-z0-9_*.-]+|xai-[A-Za-z0-9_*.-]+|AIza[A-Za-z0-9_*.-]+/g, '<redacted>').slice(0, 500);
  if (!detail) detail = 'Codex upstream request failed.';
  if (/context.{0,20}(length|window|limit)|too many tokens|prompt is too long/i.test(detail)) detail = `prompt is too long: ${detail}`;
  return { status: response.status, body: anthropicError(response.status, detail, apiErrorStatus(response.status)), retryAfter: response.headers.get('retry-after') };
}

export function createBridgeServer({ codex, model = process.env.CLCD_WIN_MODEL || DEFAULT_MODEL, effort = process.env.CLCD_WIN_EFFORT || 'medium', effortOverride = process.env.CLCD_WIN_EFFORT != null, token = randomBytes(32).toString('hex'), upstream = openCodexResponse } = {}) {
  const server = createServer(async (req, res) => {
    const localAuth = req.headers['x-api-key'] ?? (req.headers.authorization?.startsWith('Bearer ') ? req.headers.authorization.slice(7) : '');
    if (localAuth !== token) return writeJson(res, 401, anthropicError(401, 'Local proxy authentication required.', 'authentication_error'));
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/health') return writeJson(res, 200, { status: 'clcd-win' });
    if (req.method !== 'POST' || !['/v1/messages', '/v1/messages/count_tokens'].includes(url.pathname)) {
      return writeJson(res, 404, anthropicError(404, 'Unknown endpoint.'));
    }
    let body;
    try { body = await readJson(req); }
    catch (error) { return writeJson(res, error.status ?? 400, anthropicError(error.status ?? 400, error.message, error.type)); }
    if (url.pathname === '/v1/messages/count_tokens') {
      const json = JSON.stringify([body.system, body.messages, body.tools]);
      return writeJson(res, 200, { input_tokens: Math.ceil(json.length / 3) });
    }
    let built;
    try { built = buildResponsesRequest(body, { model, effort, effortOverride }); }
    catch (error) { return writeJson(res, error.status ?? 400, anthropicError(error.status ?? 400, error.message, error.type)); }

    const abort = new AbortController();
    let headerTimer = setTimeout(() => abort.abort(new Error('Codex response headers timed out.')), HEADER_TIMEOUT_MS);
    const totalTimer = setTimeout(() => abort.abort(new Error('Codex request timed out.')), REQUEST_TIMEOUT_MS);
    const onDisconnect = () => abort.abort(new Error('Claude Code disconnected.'));
    req.once('aborted', onDisconnect);
    res.once('close', () => { if (!res.writableEnded) onDisconnect(); });
    try {
      const response = await upstream(codex, built.request, abort.signal);
      clearTimeout(headerTimer);
      headerTimer = null;
      if (!response.ok) {
        const failure = await getUpstreamError(response);
        return writeJson(res, failure.status, failure.body, failure.retryAfter ? { 'retry-after': failure.retryAfter } : {});
      }
      if (!response.body) throw new BridgeError(502, 'Codex returned an empty response stream.', 'api_error');
      if (body.stream === true) {
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'close', 'x-accel-buffering': 'no' });
        const translate = streamTranslator('msg_clcd', built.request.model, built.toolNames.reverse);
        let ended = false;
        for await (const event of parseSse(response.body)) {
          const translated = translate(event);
          for (const item of translated.events) {
            if (res.destroyed) { abort.abort(); return; }
            res.write(`event: ${item.type}\ndata: ${JSON.stringify(item)}\n\n`);
          }
          ended ||= translated.ended;
        }
        if (!ended && !res.destroyed) res.write(`event: error\ndata: ${JSON.stringify({ type: 'error', error: { type: 'api_error', message: 'Codex stream ended before completion.' } })}\n\n`);
        if (!res.destroyed) res.end();
      } else {
        let finalResponse = null;
        for await (const event of parseSse(response.body)) {
          if (event.type === 'response.completed' || event.type === 'response.incomplete') finalResponse = event.response;
          else if (event.type === 'response.failed' || event.type === 'error') throw new BridgeError(502, 'Codex returned an error.', 'api_error');
        }
        writeJson(res, 200, translateCompletedResponse(finalResponse, built.request.model, built.toolNames.reverse));
      }
    } catch (error) {
      if (res.destroyed || res.writableEnded) return;
      if (abort.signal.aborted && abort.signal.reason?.message === 'Claude Code disconnected.') return;
      const status = error.status ?? (abort.signal.aborted ? 504 : 502);
      writeJson(res, status, anthropicError(status, error.message ?? 'Codex request failed.', error.type ?? 'api_error'));
    } finally {
      clearTimeout(headerTimer);
      clearTimeout(totalTimer);
      req.removeListener('aborted', onDisconnect);
    }
  });
  return { server, token };
}

export function setClaudeEnvironment(baseUrl, token, model) {
  const env = { ...process.env };
  for (const key of [
    'ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN', 'CLAUDE_CODE_OAUTH_SCOPES',
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'CLAUDE_CODE_USE_ANTHROPIC_AWS',
    'CLAUDE_CODE_EFFORT_LEVEL', 'OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN',
  ]) delete env[key];
  const profileRoot = process.env.USERPROFILE || process.env.HOME || process.cwd();
  env.CLAUDE_CONFIG_DIR = process.env.CLCD_WIN_PROFILE || `${profileRoot}\\.claude-codex-cli`;
  env.ANTHROPIC_BASE_URL = baseUrl;
  env.ANTHROPIC_AUTH_TOKEN = token;
  env.ANTHROPIC_API_KEY = '';
  env.ANTHROPIC_MODEL = model;
  env.ANTHROPIC_DEFAULT_OPUS_MODEL = model;
  env.ANTHROPIC_DEFAULT_FABLE_MODEL = model;
  env.ANTHROPIC_DEFAULT_SONNET_MODEL = model;
  env.ANTHROPIC_DEFAULT_HAIKU_MODEL = model;
  env.CLAUDE_CODE_SUBAGENT_MODEL = model;
  env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1';
  env.DISABLE_PROMPT_CACHING = '1';
  env.ENABLE_TOOL_SEARCH = 'false';
  env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = process.env.CLCD_WIN_CONTEXT_TOKENS || '1000000';
  env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '750000';
  env.NO_PROXY = '127.0.0.1,localhost';
  env.no_proxy = env.NO_PROXY;
  return env;
}

async function terminateProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  if (process.platform === 'win32' && child.pid) {
    try { await execFileAsync('taskkill.exe', ['/pid', String(child.pid), '/t', '/f'], { windowsHide: true }); } catch {}
  } else {
    child.kill('SIGTERM');
  }
}

function quoteWindowsArgument(value) {
  const input = String(value).replaceAll('%', '%CLCD_WIN_LITERAL_PERCENT%');
  let result = '"';
  let slashes = 0;
  for (const character of input) {
    if (character === '\\') {
      slashes++;
    } else if (character === '"') {
      result += '\\'.repeat(slashes * 2 + 1) + '"';
      slashes = 0;
    } else {
      result += '\\'.repeat(slashes) + character;
      slashes = 0;
    }
  }
  return result + '\\'.repeat(slashes * 2) + '"';
}

export function launchExecutable(command, args, options) {
  if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(command)) {
    const commandLine = `"${quoteWindowsArgument(command)} ${args.map(quoteWindowsArgument).join(' ')}"`;
    const env = { ...options.env, CLCD_WIN_LITERAL_PERCENT: '%' };
    return spawn('cmd.exe', ['/d', '/s', '/c', commandLine], { ...options, env, windowsHide: false, windowsVerbatimArguments: true });
  }
  return spawn(command, args, { ...options, windowsHide: false });
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) {
    process.stdout.write('Usage: .\\clcd-win.ps1 [Claude Code arguments]\n       .\\clcd-win.ps1 --check\n\nUses native Codex CLI `codex login` credentials through a local bridge. Requires Windows PowerShell 5.1+, Node.js 18+, Claude Code, and Codex CLI.\n');
    return 0;
  }
  const codexCommand = process.env.CLCD_WIN_CODEX_BIN || 'codex';
  const claudeCommand = process.env.CLCD_WIN_CLAUDE_BIN || 'claude';
  const model = process.env.CLCD_WIN_MODEL || DEFAULT_MODEL;
  const codex = new CodexAppServer(codexCommand);
  let claude = null;
  let listener = null;
  let shuttingDown = false;
  const shutdown = async (code = 0) => {
    if (shuttingDown) return;
    shuttingDown = true;
    listener?.close();
    listener?.closeAllConnections?.();
    await terminateProcessTree(claude);
    await codex.close();
    process.exitCode = code;
  };
  process.once('SIGINT', () => { void shutdown(130); });
  process.once('SIGTERM', () => { void shutdown(143); });

  try {
    await codex.start();
    await codex.authStatus(false);
    const { server, token } = createBridgeServer({ codex, model });
    listener = server;
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const address = server.address();
    const baseUrl = `http://127.0.0.1:${address.port}`;
    if (args[0] === '--check') {
      const response = await fetch(`${baseUrl}/v1/messages`, {
        method: 'POST',
        headers: { 'x-api-key': token, 'content-type': 'application/json' },
        body: JSON.stringify({ model, max_tokens: 64, messages: [{ role: 'user', content: 'Reply with exactly CLCD_OK' }] }),
      });
      if (!response.ok) throw new Error('Provider check failed.');
      const result = await response.json();
      const text = (result.content ?? []).filter((item) => item.type === 'text').map((item) => item.text).join('');
      if (text.trim() !== 'CLCD_OK') throw new Error('Unexpected provider check response.');
      process.stdout.write(`clcd-win: Codex subscription check passed (${model}).\n`);
      await shutdown(0);
      return 0;
    }
    const env = setClaudeEnvironment(baseUrl, token, model);
    claude = launchExecutable(claudeCommand, ['--dangerously-skip-permissions', ...args], { env, stdio: 'inherit' });
    const exitCode = await new Promise((resolve, reject) => {
      claude.once('error', reject);
      claude.once('exit', (code, signal) => resolve(signal ? 1 : (code ?? 1)));
    });
    await shutdown(exitCode);
    return exitCode;
  } catch (error) {
    process.stderr.write(`clcd-win: ${error.message}\n`);
    await shutdown(1);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then((code) => { process.exitCode = code; }).catch((error) => {
    process.stderr.write(`clcd-win: ${error.message}\n`);
    process.exitCode = 1;
  });
}
