const vscode = require('vscode');
const path = require('node:path');
const { LiteLlmProvider } = require('./provider');

function activate(context) {
  const provider = new LiteLlmProvider(vscode, {
    brokerUrl: 'http://127.0.0.1:43128',
    baseUrl: 'http://127.0.0.1:4000/v1',
    tokenFile: process.env.LITELLM_POC_TOKEN_FILE || path.join(
      process.env.LOCALAPPDATA || process.env.HOME || '.',
      'CopilotLiteLLMPoc',
      'broker-token'
    ),
    modelId: 'qwen3:4b-8k'
  });

  context.subscriptions.push(
    vscode.lm.registerLanguageModelChatProvider('litellm-dynamic-key-poc', provider),
    vscode.commands.registerCommand('litellmDynamicKeyPoc.checkConnection', async () => {
      try {
        await provider.checkConnection();
        void vscode.window.showInformationMessage('LiteLLM Dynamic Key POC is connected.');
      } catch (error) {
        void vscode.window.showErrorMessage(error.message);
      }
    }),
    vscode.commands.registerCommand('litellmDynamicKeyPoc.testChat', async () => {
      try {
        await provider.testChat();
        void vscode.window.showInformationMessage('VS Code provider returned the expected local model response.');
      } catch (error) {
        void vscode.window.showErrorMessage(error.message);
      }
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
