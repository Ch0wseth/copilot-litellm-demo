import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Module from 'node:module';
import test from 'node:test';
import { createBrokerServer } from '../broker/server.mjs';
import { LiteLlmProvider } from '../extension/provider.js';

test('the extension registers the provider declared by its manifest', async () => {
  const require = createRequire(import.meta.url);
  const manifest = JSON.parse(await readFile(new URL('../extension/package.json', import.meta.url), 'utf8'));
  const registrations = [];
  const mockVscode = {
    lm: {
      registerLanguageModelChatProvider(vendor, provider) {
        registrations.push({ vendor, provider });
        return { dispose() {} };
      }
    },
    commands: {
      registerCommand() {
        return { dispose() {} };
      }
    },
    window: {}
  };
  const originalLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    return request === 'vscode' ? mockVscode : originalLoad.call(this, request, parent, isMain);
  };

  try {
    const extensionPath = require.resolve('../extension/extension.js');
    delete require.cache[extensionPath];
    const extension = require(extensionPath);
    extension.activate({ subscriptions: [] });
  } finally {
    Module._load = originalLoad;
  }

  assert.equal(registrations.length, 1);
  assert.equal(registrations[0].vendor, manifest.contributes.languageModelChatProviders[0].vendor);
  assert.ok(registrations[0].provider instanceof LiteLlmProvider);
});

test('the VS Code provider obtains a scoped key dynamically through the local broker', async () => {
  const generatedKeys = [];
  const revokedKeys = [];
  const chatRequests = [];
  const liteLlm = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};

    if (request.url === '/key/generate' && request.method === 'POST') {
      assert.equal(request.headers.authorization, 'Bearer master-test-only');
      assert.deepEqual(body.models, ['qwen3:4b-8k']);
      assert.equal(body.duration, '1h');
      generatedKeys.push('sk-test-key');
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ key: 'sk-test-key' }));
      return;
    }

    if (request.url === '/key/delete' && request.method === 'POST') {
      assert.equal(request.headers.authorization, 'Bearer master-test-only');
      revokedKeys.push(...body.keys);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }

    if (request.url === '/v1/models' && request.method === 'GET') {
      assert.equal(request.headers.authorization, 'Bearer sk-test-key');
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ data: [{ id: 'qwen3:4b-8k' }] }));
      return;
    }

    if (request.url === '/v1/chat/completions' && request.method === 'POST') {
      assert.equal(request.headers.authorization, 'Bearer sk-test-key');
      chatRequests.push(body);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({
        choices: [{ message: { content: 'VSCODE_DYNAMIC_KEY_POC_OK' } }]
      }));
      return;
    }

    response.writeHead(404);
    response.end();
  });
  await new Promise(resolve => liteLlm.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${liteLlm.address().port}`;
  const brokerToken = 'local-broker-test-token';
  const broker = createBrokerServer({
    baseUrl,
    masterKey: 'master-test-only',
    brokerToken
  });
  await new Promise(resolve => broker.server.listen(0, '127.0.0.1', resolve));

  const tempDir = await mkdtemp(join(tmpdir(), 'litellm-dynamic-key-poc-'));
  const tokenFile = join(tempDir, 'broker-token');
  await writeFile(tokenFile, brokerToken, 'utf8');

  class MockTextPart {
    constructor(value) { this.value = value; }
  }
  let provider;
  const apiModel = {
    id: 'qwen3:4b-8k',
    async sendRequest(messages, _options, token) {
      const parts = [];
      await provider.provideLanguageModelChatResponse(
        apiModel,
        messages,
        {},
        { report(part) { parts.push(part); } },
        token
      );
      return {
        stream: (async function* () {
          for (const part of parts) yield part;
        })()
      };
    }
  };
  const vscode = {
    lm: {
      async selectChatModels() {
        return [apiModel];
      }
    },
    LanguageModelChatMessage: {
      User(value) {
        return { role: 1, content: [new MockTextPart(value)] };
      }
    },
    CancellationTokenSource: class {
      token = {
        onCancellationRequested() {
          return { dispose() {} };
        }
      };
      dispose() {}
    },
    LanguageModelTextPart: MockTextPart,
    LanguageModelChatMessageRole: { User: 1, Assistant: 2, System: 3 }
  };
  provider = new LiteLlmProvider(vscode, {
    brokerUrl: `http://127.0.0.1:${broker.server.address().port}`,
    baseUrl: `${baseUrl}/v1`,
    tokenFile,
    modelId: 'qwen3:4b-8k'
  });

  try {
    await provider.checkConnection();
    const parts = [];
    const cancellationToken = {
      onCancellationRequested() {
        return { dispose() {} };
      }
    };
    const messages = [{
      role: vscode.LanguageModelChatMessageRole.User,
      content: [new MockTextPart('Reply with a test marker.')]
    }];
    const model = { id: 'qwen3:4b-8k' };

    await provider.provideLanguageModelChatResponse(
      model,
      messages,
      {},
      { report(part) { parts.push(part); } },
      cancellationToken
    );

    assert.equal(parts[0]?.value, 'VSCODE_DYNAMIC_KEY_POC_OK');
    assert.equal(generatedKeys.length, 1);
    assert.equal(chatRequests.length, 1);
    assert.equal(chatRequests[0].messages[0].role, 'user');
    assert.deepEqual(revokedKeys, []);

    await provider.testChat();
    assert.equal(chatRequests.length, 2);

    const unauthorized = await fetch(`http://127.0.0.1:${broker.server.address().port}/v1/key`, {
      method: 'POST'
    });
    assert.equal(unauthorized.status, 401);
  } finally {
    await broker.close();
    await new Promise(resolve => liteLlm.close(resolve));
    await rm(tempDir, { recursive: true, force: true });
  }

  assert.deepEqual(revokedKeys, ['sk-test-key']);
});
