param(
    [string]$Alias = $env:USERNAME
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Local credentials are missing. Start the demo first with .\scripts\start-demo.ps1"
}

$masterKey = (Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' } | Select-Object -First 1) -replace '^LITELLM_MASTER_KEY=', ''
$headers = @{ Authorization = "Bearer $masterKey" }
$body = @{
    models = @("qwen3:4b-8k")
    key_alias = "copilot-demo-$Alias"
    metadata = @{ demo_user = $Alias }
} | ConvertTo-Json -Depth 5

$result = Invoke-RestMethod -Method Post `
    -Uri "http://127.0.0.1:4000/key/generate" `
    -Headers $headers `
    -ContentType "application/json" `
    -Body $body

Write-Host "Individual LiteLLM key for '$Alias' (copy it now; do not commit it):"
Write-Output $result.key
