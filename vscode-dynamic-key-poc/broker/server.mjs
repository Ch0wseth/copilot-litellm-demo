import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const KEY_DURATION_MS = 60 * 60 * 1000;
const KEY_REFRESH_MARGIN_MS = 5 * 60 * 1000;

function isLoopback(hostname) {
  return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]';
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function sendJson(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

export function createBrokerServer({
  baseUrl,
  masterKey,
  model = 'qwen3:4b-8k',
  brokerToken,
  fetchImpl = fetch
}) {
  const litellmUrl = new URL(baseUrl);
  if (!isLoopback(litellmUrl.hostname) || litellmUrl.protocol !== 'http:') {
    throw new Error('The local POC accepts only an HTTP LiteLLM endpoint on loopback.');
  }
  if (!masterKey || !brokerToken) {
    throw new Error('LiteLLM master key and broker token are required.');
  }

  let cachedKey;
  let refreshAt = 0;
  let issuingKey;
  let closeBroker;

  async function revokeKey(key) {
    try {
      const response = await fetchImpl(new URL('/key/delete', litellmUrl), {
        method: 'POST',
        headers: {
          authorization: `Bearer ${masterKey}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ keys: [key] })
      });
      if (!response.ok) {
        console.error(`LiteLLM key revocation failed with HTTP ${response.status}.`);
      }
    } catch (error) {
      console.error(`LiteLLM key revocation failed: ${error.message}`);
    }
  }

  async function getIndividualKey() {
    if (cachedKey && Date.now() < refreshAt) return cachedKey;
    if (issuingKey) return issuingKey;

    issuingKey = (async () => {
      const response = await fetchImpl(new URL('/key/generate', litellmUrl), {
        method: 'POST',
        headers: {
          authorization: `Bearer ${masterKey}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({
          models: [model],
          key_alias: `vscode-poc-${randomUUID()}`,
          duration: '1h'
        })
      });

      if (!response.ok) {
        throw new Error(`LiteLLM key generation failed with HTTP ${response.status}.`);
      }

      const payload = await response.json();
      if (typeof payload.key !== 'string' || payload.key.length < 8) {
        throw new Error('LiteLLM did not return a valid virtual key.');
      }

      const previousKey = cachedKey;
      cachedKey = payload.key;
      refreshAt = Date.now() + KEY_DURATION_MS - KEY_REFRESH_MARGIN_MS;
      if (previousKey && previousKey !== cachedKey) await revokeKey(previousKey);
      return cachedKey;
    })();

    try {
      return await issuingKey;
    } finally {
      issuingKey = undefined;
    }
  }

  const server = createServer(async (request, response) => {
    if (request.method === 'GET' && request.url === '/healthz') {
      sendJson(response, 200, { status: 'ok' });
      return;
    }

    const keyRequest = request.method === 'POST' && request.url === '/v1/key';
    const shutdownRequest = request.method === 'POST' && request.url === '/v1/shutdown';
    if (!keyRequest && !shutdownRequest) {
      sendJson(response, 404, { error: 'Not found' });
      return;
    }

    const authorization = request.headers.authorization || '';
    const suppliedToken = authorization.startsWith('Bearer ')
      ? authorization.slice('Bearer '.length)
      : '';
    if (!safeEqual(suppliedToken, brokerToken)) {
      sendJson(response, 401, { error: 'Unauthorized' });
      return;
    }

    if (shutdownRequest) {
      sendJson(response, 202, { status: 'stopping' });
      setImmediate(() => { void closeBroker(); });
      return;
    }

    try {
      const key = await getIndividualKey();
      sendJson(response, 200, {
        apiKey: key,
        expiresInSeconds: Math.floor((refreshAt - Date.now() + KEY_REFRESH_MARGIN_MS) / 1000)
      });
    } catch (error) {
      console.error(`Key broker request failed: ${error.message}`);
      sendJson(response, 502, { error: 'Could not obtain an individual LiteLLM key.' });
    }
  });

  closeBroker = async () => {
    if (cachedKey) {
      await revokeKey(cachedKey);
      cachedKey = undefined;
    }

    if (server.listening) {
      await new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
      });
    }
  };

  return {
    server,
    close: closeBroker
  };
}

async function start() {
  const masterKey = process.env.LITELLM_MASTER_KEY;
  const tokenFile = process.env.LITELLM_POC_TOKEN_FILE ||
    join(process.env.LOCALAPPDATA || process.env.HOME || '.', 'CopilotLiteLLMPoc', 'broker-token');
  const brokerToken = randomBytes(32).toString('base64url');
  const broker = createBrokerServer({
    baseUrl: process.env.LITELLM_BASE_URL || 'http://127.0.0.1:4000',
    masterKey,
    model: process.env.LITELLM_POC_MODEL || 'qwen3:4b-8k',
    brokerToken
  });

  const port = Number(process.env.LITELLM_POC_BROKER_PORT || 43128);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error('LITELLM_POC_BROKER_PORT must be a valid TCP port.');
  }

  await new Promise((resolve, reject) => {
    broker.server.once('error', reject);
    broker.server.listen(port, '127.0.0.1', resolve);
  });

  try {
    await mkdir(dirname(tokenFile), { recursive: true });
    await writeFile(tokenFile, `${brokerToken}\n`, { encoding: 'utf8', mode: 0o600 });
  } catch (error) {
    await new Promise(resolve => broker.server.close(resolve));
    throw error;
  }

  console.log(`Local key broker listening on http://127.0.0.1:${broker.server.address().port}`);
  console.log('The broker token is stored in the current Windows user profile.');
  console.log('Press Ctrl+C to revoke the temporary LiteLLM key and stop the broker.');

  let stopping;
  const stop = () => {
    if (stopping) return;
    stopping = (async () => {
      await broker.close();
      await rm(tokenFile, { force: true });
    })();
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  await new Promise(resolve => broker.server.once('close', resolve));
  if (stopping) await stopping;
  else await rm(tokenFile, { force: true });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  start().catch(error => {
    console.error(`Local key broker could not start: ${error.message}`);
    process.exitCode = 1;
  });
}
