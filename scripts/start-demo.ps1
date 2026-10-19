$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
$composeFile = Join-Path $root "docker-compose.yml"

function New-RandomHex([int]$Length = 32) {
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $envFile)) {
    $masterKey = "sk-" + (New-RandomHex)
    $saltKey = New-RandomHex
    $postgresPassword = New-RandomHex
    @(
        "LITELLM_MASTER_KEY=$masterKey"
        "LITELLM_SALT_KEY=$saltKey"
        "POSTGRES_PASSWORD=$postgresPassword"
        "DATABASE_URL=postgresql://litellm:$postgresPassword@postgres:5432/litellm"
    ) | Set-Content -LiteralPath $envFile -Encoding ascii
    Write-Host "Generated local-only credentials in .env (ignored by Git)."
}

Push-Location $root
try {
    docker compose --env-file $envFile -f $composeFile up -d postgres ollama
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed to start PostgreSQL or Ollama." }

    docker compose --env-file $envFile -f $composeFile exec -T ollama ollama pull qwen3:4b
    if ($LASTEXITCODE -ne 0) { throw "Could not download the Qwen 3 model." }

    docker compose --env-file $envFile -f $composeFile exec -T ollama ollama create qwen3:4b-8k -f /tmp/qwen3-Modelfile
    if ($LASTEXITCODE -ne 0) { throw "Could not create the 8k-context Qwen 3 model." }

    docker compose --env-file $envFile -f $composeFile up -d --force-recreate litellm
    if ($LASTEXITCODE -ne 0) { throw "Could not start LiteLLM." }

    $masterKey = (Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' } | Select-Object -First 1) -replace '^LITELLM_MASTER_KEY=', ''
    $headers = @{ Authorization = "Bearer $masterKey" }
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $models = Invoke-RestMethod -Uri "http://127.0.0.1:4000/v1/models" -Headers $headers -TimeoutSec 5
            if ($models.data.id -contains "qwen3:4b-8k") {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }

    if (-not $ready) { throw "LiteLLM did not become ready with qwen3:4b-8k. Inspect: docker compose logs litellm" }
    Write-Host "Demo ready: LiteLLM http://127.0.0.1:4000; Ollama http://127.0.0.1:11434"
    Write-Host "Generate an individual LiteLLM key with: .\scripts\new-user-key.ps1"
} finally {
    Pop-Location
}
