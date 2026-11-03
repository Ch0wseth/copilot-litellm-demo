$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envFile = Join-Path $repoRoot '.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    throw 'Missing .env. Start the repository demo first with .\scripts\start-demo.ps1.'
}

$masterKeyLine = [System.IO.File]::ReadLines($envFile) |
    Where-Object { $_ -match '^LITELLM_MASTER_KEY=' } |
    Select-Object -First 1
if (-not $masterKeyLine) {
    throw 'LITELLM_MASTER_KEY was not found in .env.'
}

$masterKey = $masterKeyLine.Substring('LITELLM_MASTER_KEY='.Length)
if ([string]::IsNullOrWhiteSpace($masterKey)) {
    throw 'LITELLM_MASTER_KEY in .env is empty.'
}

$env:LITELLM_MASTER_KEY = $masterKey
$env:LITELLM_BASE_URL = 'http://127.0.0.1:4000'
$env:LITELLM_POC_MODEL = 'qwen3:4b-8k'
$env:LITELLM_POC_BROKER_PORT = '43128'
$env:LITELLM_POC_TOKEN_FILE = Join-Path $env:LOCALAPPDATA 'CopilotLiteLLMPoc\broker-token'

try {
    node (Join-Path $PSScriptRoot '..\broker\server.mjs')
    if ($LASTEXITCODE -ne 0) {
        throw "The local key broker exited with code $LASTEXITCODE."
    }
} finally {
    Remove-Item Env:\LITELLM_MASTER_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\LITELLM_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\LITELLM_POC_MODEL -ErrorAction SilentlyContinue
    Remove-Item Env:\LITELLM_POC_BROKER_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:\LITELLM_POC_TOKEN_FILE -ErrorAction SilentlyContinue
    Remove-Variable masterKey -ErrorAction SilentlyContinue
}
