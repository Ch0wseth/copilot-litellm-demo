param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CopilotArgs
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Local credentials are missing. Start the demo first with .\scripts\start-demo.ps1"
}

if (-not $env:LITELLM_USER_KEY) {
    throw "Set LITELLM_USER_KEY to your individual key from .\scripts\new-user-key.ps1"
}

$oldValues = @{}
$names = @(
    "COPILOT_PROVIDER_BASE_URL",
    "COPILOT_PROVIDER_TYPE",
    "COPILOT_PROVIDER_API_KEY",
    "COPILOT_MODEL",
    "COPILOT_PROVIDER_MODEL_ID",
    "COPILOT_PROVIDER_WIRE_MODEL",
    "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
    "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
)
foreach ($name in $names) {
    $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$env:COPILOT_PROVIDER_BASE_URL = "http://127.0.0.1:4000/v1"
$env:COPILOT_PROVIDER_TYPE = "openai"
$env:COPILOT_PROVIDER_API_KEY = $env:LITELLM_USER_KEY
$env:COPILOT_MODEL = "qwen3:4b-8k"
$env:COPILOT_PROVIDER_MODEL_ID = "gpt-4.1"
$env:COPILOT_PROVIDER_WIRE_MODEL = "qwen3:4b-8k"
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "7680"
$env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "512"

Push-Location $root
$copilotExitCode = 0
try {
    & copilot --context long_context --available-tools view @CopilotArgs
    $copilotExitCode = $LASTEXITCODE
} finally {
    Pop-Location
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $oldValues[$name], "Process")
    }
}

if ($copilotExitCode -ne 0) {
    throw "Copilot exited with code $copilotExitCode."
}
