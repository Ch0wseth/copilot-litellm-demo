import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const fakeKey = 'local-demo-key';
const model = 'mock-model';
const answer = 'LOCAL_MOCK_OK';
const cli = process.env.COPILOT_CLI_PATH
  ? resolve(process.env.COPILOT_CLI_PATH)
  : (process.env.PATH || '').split(delimiter)
    .filter(Boolean)
    .map(directory => join(directory.replace(/^"|"$/g, ''), 'copilot.exe'))
    .find(existsSync);
const sdkPath = process.env.COPILOT_APP_SDK_PATH ||
  join(process.env.LOCALAPPDATA || '', 'Programs', 'GitHub Copilot', 'copilot-sdk', 'index.js');

if (process.platform !== 'win32') {
  throw new Error('This reproduction requires Windows.');
}
if (!cli || !existsSync(cli)) {
  throw new Error('Copilot CLI not found. Install it or set COPILOT_CLI_PATH to copilot.exe.');
}
if (!existsSync(sdkPath)) {
  throw new Error(`Copilot app SDK not found at ${sdkPath}. Set COPILOT_APP_SDK_PATH to its index.js.`);
}

const { CopilotClient, RuntimeConnection } = await import(pathToFileURL(sdkPath).href);
const workDir = await mkdtemp(join(tmpdir(), 'copilot-byok-demo-'));
const commandScript = join(workDir, 'get-fake-key.ps1');
const requests = [];
let currentScenario = '';

const server = createServer((request, response) => {
  let body = '';
  request.setEncoding('utf8');
  request.on('data', chunk => { body += chunk; });
  request.on('end', () => {
    if (request.method !== 'POST' || request.url !== '/v1/chat/completions') {
      response.writeHead(404, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: { message: 'Not found' } }));
      return;
    }

    const authorized = request.headers.authorization === `Bearer ${fakeKey}`;
    requests.push({ scenario: currentScenario, authorized });
    if (!authorized) {
      response.writeHead(401, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: { message: 'Invalid local test key', type: 'authentication_error' } }));
      return;
    }

    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      response.writeHead(400, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: { message: 'Invalid JSON' } }));
      return;
    }

    const created = Math.floor(Date.now() / 1000);
    if (payload.stream) {
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      const chunk = { id: 'local', object: 'chat.completion.chunk', created, model };
      response.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: { role: 'assistant', content: answer }, finish_reason: null }] })}\n\n`);
      response.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
      response.end('data: [DONE]\n\n');
      return;
    }

    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({
      id: 'local',
      object: 'chat.completion',
      created,
      model,
      choices: [{ index: 0, message: { role: 'assistant', content: answer }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
    }));
  });
});

function isolatedEnv(home, marker, baseUrl) {
  const env = {};
  for (const name of [
    'PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP',
    'USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA',
    'PROCESSOR_ARCHITECTURE'
  ]) {
    if (process.env[name] !== undefined) env[name] = process.env[name];
  }
  return {
    ...env,
    COPILOT_HOME: home,
    COPILOT_OFFLINE: 'true',
    COPILOT_PROVIDER_BASE_URL: baseUrl,
    COPILOT_PROVIDER_TYPE: 'openai',
    COPILOT_MODEL: model,
    COPILOT_MOCK_MARKER: marker
  };
}

async function invocationCount(marker) {
  if (!existsSync(marker)) return 0;
  return (await readFile(marker, 'utf8')).trim().split(/\r?\n/).length;
}

function runCli(env, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(cli, [
      '--no-custom-instructions',
      '--disable-builtin-mcps',
      '--stream', 'off',
      '--silent',
      '--prompt', 'Reply with a short confirmation. Do not use tools.'
    ], { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', code => {
      if (code !== 0) {
        reject(new Error(`Copilot CLI exited with code ${code}: ${stderr.trim()}`));
      } else {
        resolve(stdout.trim());
      }
    });
  });
}

async function runSdkScenario(name, config, env, home, turns = 1) {
  currentScenario = name;
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: cli, env }),
    mode: 'empty',
    baseDirectory: home,
    logLevel: 'error'
  });
  try {
    await client.start();
    const session = await client.createSession({ availableTools: [], ...config });
    try {
      let result;
      for (let turn = 0; turn < turns; turn++) {
        result = await session.sendAndWait({ prompt: 'Reply with a short confirmation.' }, 60000);
      }
      return { answer: result?.data?.content };
    } catch (error) {
      return { error };
    }
  } finally {
    const errors = await client.stop();
    if (errors.length) throw new Error(`Could not stop the Copilot runtime: ${errors[0].message}`);
  }
}

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

try {
  await writeFile(commandScript, [
    "$ErrorActionPreference = 'Stop'",
    "Add-Content -LiteralPath $env:COPILOT_MOCK_MARKER -Value 'called'",
    `[Console]::Out.Write('${fakeKey}')`,
    ''
  ].join('\r\n'), 'utf8');
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
  const keyCommand = `powershell.exe -NoProfile -File "${commandScript}"`;

  const cliHome = join(workDir, 'cli');
  const cliMarker = join(workDir, 'cli-calls.txt');
  await mkdir(cliHome);
  const cliEnv = isolatedEnv(cliHome, cliMarker, baseUrl);
  cliEnv.COPILOT_PROVIDER_API_KEY_COMMAND = keyCommand;
  currentScenario = 'cli';
  const cliAnswer = await runCli(cliEnv, cliHome);
  const cliHits = requests.filter(item => item.scenario === 'cli');
  requireCondition(cliAnswer === answer && cliHits.length > 0 &&
    cliHits.every(item => item.authorized) && await invocationCount(cliMarker) > 0,
  'CLI dynamic key was not executed and accepted as expected.');
  console.log('PASS: CLI environment key command reached the local mock.');

  const inlineHome = join(workDir, 'cli-inline');
  const inlineMarker = join(workDir, 'cli-inline-calls.txt');
  await mkdir(inlineHome);
  const inlineEnv = isolatedEnv(inlineHome, inlineMarker, baseUrl);
  inlineEnv.LITELLM_USER_KEY = fakeKey;
  inlineEnv.COPILOT_PROVIDERS_CONFIG = join(inlineHome, 'unused-providers.json');
  inlineEnv.COPILOT_PROVIDER_API_KEY_COMMAND =
    `powershell.exe -NoProfile -Command "Add-Content -LiteralPath $env:COPILOT_MOCK_MARKER -Value 'called'; [Console]::Out.Write($env:LITELLM_USER_KEY)"`;
  currentScenario = 'cli-inline';
  const inlineAnswer = await runCli(inlineEnv, inlineHome);
  const inlineHits = requests.filter(item => item.scenario === 'cli-inline');
  requireCondition(inlineAnswer === answer && inlineHits.length > 0 &&
    inlineHits.every(item => item.authorized) && await invocationCount(inlineMarker) > 0,
  'CLI key command could not read the test key from its process environment.');
  console.log('PASS: CLI key command read the test key from the process environment.');

  const sessionHome = join(workDir, 'session');
  const sessionMarker = join(workDir, 'session-calls.txt');
  await mkdir(sessionHome);
  const sessionResult = await runSdkScenario('session', {
    model,
    provider: { type: 'openai', baseUrl, wireModel: model, apiKeyCommand: keyCommand }
  }, isolatedEnv(sessionHome, sessionMarker, baseUrl), sessionHome, 2);
  const sessionHits = requests.filter(item => item.scenario === 'session');
  requireCondition(!sessionResult.error && sessionResult.answer === answer &&
    sessionHits.length >= 2 && sessionHits.every(item => item.authorized) &&
    await invocationCount(sessionMarker) === sessionHits.length,
  `SDK session key command did not succeed: ${sessionResult.error?.message || 'unexpected result'}`);
  console.log('PASS: SDK session key command ran for each of two local model requests.');

  const namedEnvHome = join(workDir, 'named-env');
  const namedEnvMarker = join(workDir, 'named-env-calls.txt');
  await mkdir(namedEnvHome);
  const namedEnv = isolatedEnv(namedEnvHome, namedEnvMarker, baseUrl);
  namedEnv.COPILOT_PROVIDER_API_KEY_COMMAND = keyCommand;
  const namedEnvResult = await runSdkScenario('named-env', {
    model: `local/${model}`,
    providers: [{ name: 'local', type: 'openai', baseUrl }],
    models: [{ id: model, provider: 'local', wireModel: model, modelId: 'gpt-4o' }]
  }, namedEnv, namedEnvHome);
  const namedEnvHits = requests.filter(item => item.scenario === 'named-env');
  requireCondition(namedEnvResult.error && namedEnvHits.length > 0 &&
    namedEnvHits.every(item => !item.authorized) && await invocationCount(namedEnvMarker) === 0,
  'Named-provider environment result changed: inspect the SDK version and the provider response.');
  console.log('PASS: CLI environment key command was not used for the SDK named provider; the mock returned HTTP 401.');

  const namedHome = join(workDir, 'named');
  const namedMarker = join(workDir, 'named-calls.txt');
  await mkdir(namedHome);
  const namedResult = await runSdkScenario('named-command', {
    model: `local/${model}`,
    providers: [{ name: 'local', type: 'openai', baseUrl, apiKeyCommand: keyCommand }],
    models: [{ id: model, provider: 'local', wireModel: model, modelId: 'gpt-4o' }]
  }, isolatedEnv(namedHome, namedMarker, baseUrl), namedHome);
  const namedHits = requests.filter(item => item.scenario === 'named-command');
  requireCondition(namedResult.error && namedHits.length > 0 &&
    namedHits.every(item => !item.authorized) && await invocationCount(namedMarker) === 0,
  'Named-provider result changed: inspect the SDK version and the provider response.');
  console.log('PASS: unsupported named-provider key command was not executed; the mock returned HTTP 401.');

  const staticHome = join(workDir, 'named-static');
  const staticMarker = join(workDir, 'named-static-calls.txt');
  await mkdir(staticHome);
  const staticResult = await runSdkScenario('named-static', {
    model: `local/${model}`,
    providers: [{ name: 'local', type: 'openai', baseUrl, apiKey: fakeKey }],
    models: [{ id: model, provider: 'local', wireModel: model, modelId: 'gpt-4o' }]
  }, isolatedEnv(staticHome, staticMarker, baseUrl), staticHome);
  const staticHits = requests.filter(item => item.scenario === 'named-static');
  requireCondition(!staticResult.error && staticResult.answer === answer &&
    staticHits.length > 0 && staticHits.every(item => item.authorized) &&
    await invocationCount(staticMarker) === 0,
  `Named-provider static-key control did not succeed: ${staticResult.error?.message || 'unexpected result'}`);
  console.log('PASS: named provider with a static test key reached the local mock.');
} finally {
  try {
    if (server.listening) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
