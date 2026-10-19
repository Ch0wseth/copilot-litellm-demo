# GitHub Copilot + LiteLLM (local demo)

This demo connects **GitHub Copilot CLI** and **VS Code Chat** to a locally hosted LiteLLM proxy, which routes requests to the open-source Qwen 3 4B model running locally through Ollama.

```text
Copilot CLI / VS Code
        │  OpenAI-compatible Chat Completions
        ▼
LiteLLM proxy (localhost:4000)
        │  individual LiteLLM virtual key
        ▼
Ollama (localhost:11434) → Qwen 3 4B
```

The setup is local-only: Docker ports bind to loopback, the model runs on the machine, and no external model-provider API key is needed. Docker must download the container images and model weights on first start.

## What is demonstrated

- A self-hosted LiteLLM OpenAI-compatible endpoint.
- A separate, model-restricted LiteLLM virtual key for each demo user.
- Copilot CLI configured with the user's LiteLLM key through environment variables.
- VS Code configured with the **Custom Endpoint** BYOK provider and the same user's key stored through VS Code's input/secret mechanism.

The Copilot CLI path was tested end-to-end in this environment. The VS Code configuration is included, but has **not** been live-tested here; validate it in your VS Code installation and policy context.

## Requirements

- Windows 10/11 with PowerShell 7 recommended.
- Docker Desktop running with Linux containers enabled.
- GitHub Copilot CLI installed (`copilot` on `PATH`) for the CLI walkthrough.
- A current VS Code release with Chat and the Custom Endpoint provider available for the VS Code walkthrough.
- Several gigabytes of free disk space and RAM. The Qwen 3 model download is about 2.5 GB.

## Start the local stack

From this repository in PowerShell:

```powershell
.\scripts\start-demo.ps1
```

The script generates local random credentials in `.env` (ignored by Git), starts PostgreSQL, Ollama, and LiteLLM, downloads the Qwen 3 model on first run, creates an 8K-context model alias, then checks that LiteLLM exposes it.

Services:

- LiteLLM API: `http://127.0.0.1:4000`
- LiteLLM Admin UI: `http://127.0.0.1:4000/ui`
- Ollama API: `http://127.0.0.1:11434`

The LiteLLM master key is stored in the ignored `.env` file. This is an admin credential; do not paste it into Copilot, VS Code, a ticket, or a commit.

## Create an individual user key

Each participant should use a separate virtual key, not the LiteLLM master key:

```powershell
.\scripts\new-user-key.ps1 -Alias alice
```

The command prints the new key once. Keep it private. It is restricted to the `qwen3:4b-8k` model. Create a separate key for each user so LiteLLM can distinguish and revoke keys independently.

Set the returned key in the current PowerShell process (replace the example value):

```powershell
$env:LITELLM_USER_KEY = "sk-<your-individual-key>"
```

This environment variable is process-local. Do not place a real key in this repository or save it in a shared shell profile.

## GitHub Copilot CLI

Launch Copilot with the individual key:

```powershell
.\scripts\run-copilot-cli.ps1
```

You can pass normal Copilot CLI arguments, for example:

```powershell
.\scripts\run-copilot-cli.ps1 --prompt "Explain this sample project"
```

The launcher sets and then restores the `COPILOT_PROVIDER_*` variables for the Copilot process. The important settings are:

```text
COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:4000/v1
COPILOT_PROVIDER_TYPE=openai
COPILOT_PROVIDER_API_KEY=<individual LiteLLM key>
COPILOT_MODEL=qwen3:4b-8k
```

The launcher limits the available Copilot tool surface to `view` to keep this small local-model demo focused. Remove `--available-tools view` in `scripts/run-copilot-cli.ps1` if you explicitly want to test additional tools and your model can handle their context.

## VS Code Chat

The VS Code path is separate from CLI environment-variable configuration. VS Code uses its **Custom Endpoint** BYOK provider:

1. Start the local stack and generate an individual LiteLLM virtual key as above.
2. Open this folder in VS Code (`code .` from the repository directory).
3. In VS Code, open the Chat model picker and choose **Manage Language Models** (or run **Chat: Manage Language Models** from the Command Palette).
4. Select **Add Models → Custom Endpoint**.
5. Enter a group name such as `LiteLLM local`, paste the *individual virtual key* (not the master key), and choose **Chat Completions**.
6. When VS Code opens `chatLanguageModels.json`, use the example in [`vscode/chatLanguageModels.json`](vscode/chatLanguageModels.json). If you are setting it up directly, keep the API key as an input variable; do not replace it with a committed plaintext key.
7. Save the configuration, reopen the model picker, and select **Qwen 3 4B via LiteLLM**. Restart VS Code if the model does not appear.
8. Send a short prompt. Confirm a request appears in LiteLLM's logs:

   ```powershell
   docker compose logs -f litellm
   ```

For the `chatLanguageModels.json` example, `${input:litellmApiKey}` allows VS Code to request/store the key through its input mechanism. The endpoint URL intentionally includes the complete `/v1/chat/completions` API path.

VS Code BYOK covers Chat/model interactions; it does not replace Copilot-backed inline code completions, semantic search, or embedding-dependent features. Using a BYOK model in Copilot harness/Agents sessions may require enabling the experimental `chat.agentHost.byokModels.enabled` setting.

## Stop the stack

```powershell
.\scripts\stop-demo.ps1
```

This stops containers but retains model weights, PostgreSQL data, and local credentials. To remove those local demo data volumes later, first stop the demo, then run:

```powershell
docker compose down --volumes
```

That command permanently deletes the demo's stored keys/database and downloaded Ollama models in its Docker volume.

## Troubleshooting

- **Docker daemon unavailable:** start Docker Desktop, then retry `.\scripts\start-demo.ps1`.
- **Model is not listed by LiteLLM:** inspect `docker compose logs litellm` and verify `docker compose exec ollama ollama list`.
- **401 from LiteLLM:** use the per-user key printed by `new-user-key.ps1`; do not use an expired/revoked key or the master key in client configuration.
- **VS Code model absent:** confirm the API type is Chat Completions, the URL ends in `/v1/chat/completions`, and restart VS Code.
- **Agent option unavailable in VS Code:** confirm the model supports tool calling; BYOK in Copilot harness sessions is experimental and may be policy- or version-dependent.
- **Slow response:** this demo runs a quantized 4B model on local CPU by default; inference can be much slower than a hosted model.

## Security notes

- All published demo values are local examples, not production credentials.
- The services bind to `127.0.0.1`; do not change the binding or expose the fixed demo setup to a network.
- `.env` contains the LiteLLM master key, salt, and database password and is ignored by Git.
- Never commit generated individual keys or real provider credentials.
- This sample is not hardened for production. Review authentication, TLS, secret management, database backups, access controls, and current LiteLLM deployment guidance before any shared or remote deployment.

## References

- [GitHub Copilot CLI: BYOK models](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models)
- [VS Code: AI language models and BYOK](https://code.visualstudio.com/docs/agent-customization/language-models)
- [LiteLLM: Docker quick start](https://docs.litellm.ai/docs/proxy/docker_quick_start)
- [LiteLLM: virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [Ollama: OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
