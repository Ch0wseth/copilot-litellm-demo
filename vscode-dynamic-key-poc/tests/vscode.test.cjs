const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const vscode = require('vscode');

async function run() {
  assert.equal(process.env.LITELLM_MASTER_KEY, undefined, 'VS Code must not inherit the broker master key.');
  const models = await vscode.lm.selectChatModels({ vendor: 'litellm-dynamic-key-poc' });
  const model = models.find(candidate => candidate.id === 'qwen3:4b-8k');
  assert.ok(model, 'VS Code must discover the contributed LiteLLM model.');
  const cancellation = new vscode.CancellationTokenSource();
  try {
    for (let turn = 0; turn < 2; turn++) {
      const response = await model.sendRequest(
        [vscode.LanguageModelChatMessage.User(
          '/no_think Reply with exactly VSCODE_DYNAMIC_KEY_POC_OK and nothing else.'
        )],
        {},
        cancellation.token
      );
      let text = '';
      for await (const part of response.stream) {
        if (part instanceof vscode.LanguageModelTextPart) text += part.value;
      }
      assert.equal(text.trim(), 'VSCODE_DYNAMIC_KEY_POC_OK');
    }
    await fs.writeFile(process.env.LITELLM_POC_TEST_RESULT, JSON.stringify({
      modelDiscovered: true,
      completedRequests: 2,
      chatUiTested: false
    }));
    console.log('PASS: the real VS Code provider completed two requests with dynamic keys.');
  } finally {
    cancellation.dispose();
  }
}

module.exports = { run };
