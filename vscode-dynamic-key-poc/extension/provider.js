const fs = require('node:fs/promises');

function assertLoopbackUrl(value, label) {
  const url = new URL(value);
  if (url.protocol !== 'http:' ||
      !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
    throw new Error(`${label} must use HTTP on loopback in this local POC.`);
  }
  return url;
}

class LiteLlmProvider {
  constructor(vscode, { brokerUrl, baseUrl, tokenFile, modelId, fetchImpl = fetch }) {
    this.vscode = vscode;
    this.brokerUrl = assertLoopbackUrl(brokerUrl, 'Broker URL');
    this.baseUrl = assertLoopbackUrl(baseUrl, 'LiteLLM URL');
    if (!this.baseUrl.pathname.endsWith('/')) this.baseUrl.pathname += '/';
    this.tokenFile = tokenFile;
    this.modelId = modelId;
    this.fetchImpl = fetchImpl;
  }

  async provideLanguageModelChatInformation() {
    return [{
      id: this.modelId,
      name: `Qwen via LiteLLM (${this.modelId})`,
      family: 'qwen',
      version: '1.0.0',
      maxInputTokens: 7680,
      maxOutputTokens: 512,
      capabilities: {
        imageInput: false,
        toolCalling: false
      }
    }];
  }

  async getIndividualKey() {
    let brokerToken;
    try {
      brokerToken = (await fs.readFile(this.tokenFile, 'utf8')).trim();
    } catch {
      throw new Error('Start the local key broker with vscode-dynamic-key-poc\\scripts\\start-broker.ps1.');
    }
    if (!brokerToken) {
      throw new Error('The local key broker token is missing. Restart the broker.');
    }

    let response;
    try {
      response = await this.fetchImpl(new URL('/v1/key', this.brokerUrl), {
        method: 'POST',
        headers: { authorization: `Bearer ${brokerToken}` }
      });
    } catch {
      throw new Error('The local key broker is unavailable. Start it before using this model.');
    }
    if (!response.ok) {
      throw new Error(`The local key broker refused the request (HTTP ${response.status}).`);
    }

    const payload = await response.json();
    if (typeof payload.apiKey !== 'string' || !payload.apiKey.startsWith('sk-')) {
      throw new Error('The local key broker returned an invalid LiteLLM key.');
    }
    return payload.apiKey;
  }

  async checkConnection() {
    const models = await this.vscode.lm.selectChatModels({
      vendor: 'litellm-dynamic-key-poc'
    });
    if (!models.some(model => model.id === this.modelId)) {
      throw new Error('VS Code did not discover the LiteLLM model from this provider.');
    }

    const key = await this.getIndividualKey();
    const response = await this.fetchImpl(new URL('models', this.baseUrl), {
      headers: { authorization: `Bearer ${key}` }
    });
    if (!response.ok) {
      throw new Error(`LiteLLM rejected the individual key (HTTP ${response.status}).`);
    }
  }

  async testChat() {
    const models = await this.vscode.lm.selectChatModels({
      vendor: 'litellm-dynamic-key-poc'
    });
    const model = models.find(candidate => candidate.id === this.modelId);
    if (!model) {
      throw new Error('VS Code did not discover the LiteLLM model from this provider.');
    }

    const cancellation = new this.vscode.CancellationTokenSource();
    try {
      const response = await model.sendRequest(
        [this.vscode.LanguageModelChatMessage.User(
          '/no_think Reply with exactly VSCODE_DYNAMIC_KEY_POC_OK and nothing else.'
        )],
        {},
        cancellation.token
      );
      let text = '';
      for await (const part of response.stream) {
        if (part instanceof this.vscode.LanguageModelTextPart) text += part.value;
      }
      if (!text.includes('VSCODE_DYNAMIC_KEY_POC_OK')) {
        throw new Error('The local model did not return the expected test marker.');
      }
    } finally {
      cancellation.dispose();
    }
  }

  async provideLanguageModelChatResponse(model, messages, _options, progress, token) {
    if (model.id !== this.modelId) {
      throw new Error('The selected model is not provided by this extension.');
    }

    const apiKey = await this.getIndividualKey();
    const controller = new AbortController();
    const cancellation = token.onCancellationRequested(() => controller.abort());
    try {
      const response = await this.fetchImpl(new URL('chat/completions', this.baseUrl), {
        method: 'POST',
        headers: {
          authorization: `Bearer ${apiKey}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({
          model: this.modelId,
          messages: messages.map(message => ({
            role: this.toRole(message.role),
            content: message.content
              .filter(part => part instanceof this.vscode.LanguageModelTextPart)
              .map(part => part.value)
              .join('')
          })),
          stream: false,
          max_tokens: 512
        }),
        signal: controller.signal
      });
      if (!response.ok) {
        throw new Error(`LiteLLM chat request failed (HTTP ${response.status}).`);
      }

      const payload = await response.json();
      const text = payload.choices?.[0]?.message?.content;
      if (typeof text !== 'string') {
        throw new Error('LiteLLM returned no text response.');
      }
      progress.report(new this.vscode.LanguageModelTextPart(text));
    } finally {
      cancellation.dispose();
    }
  }

  toRole(role) {
    const roles = this.vscode.LanguageModelChatMessageRole;
    if (role === roles.User) return 'user';
    if (role === roles.System) return 'system';
    return 'assistant';
  }

  async provideTokenCount(_model, text) {
    if (typeof text === 'string') return Math.ceil(text.length / 4);
    const content = text.content
      .filter(part => part instanceof this.vscode.LanguageModelTextPart)
      .map(part => part.value)
      .join('');
    return Math.ceil(content.length / 4);
  }
}

module.exports = { LiteLlmProvider };
