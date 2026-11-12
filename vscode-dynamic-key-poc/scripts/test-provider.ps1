#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envFile = Join-Path $root '.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    throw 'Start the local stack with .\scripts\start-demo.ps1 before this integration test.'
}
if (Get-NetTCPConnection -LocalPort 43128 -State Listen -ErrorAction SilentlyContinue) {
    throw 'Port 43128 is occupied. Stop only your POC broker before running this isolated test.'
}
$codeCommand = Get-Command code -ErrorAction Stop
$codeExe = Join-Path (Split-Path -Parent (Split-Path -Parent $codeCommand.Source)) 'Code.exe'
if (-not (Test-Path -LiteralPath $codeExe)) {
    throw 'This integration test requires the Windows VS Code desktop installation.'
}
$nodeExe = (Get-Command node -ErrorAction Stop).Source
$masterKeyLine = [IO.File]::ReadLines($envFile) |
    Where-Object { $_ -match '^LITELLM_MASTER_KEY=' } | Select-Object -First 1
if (-not $masterKeyLine) { throw 'LITELLM_MASTER_KEY is missing from .env.' }

$workDirectory = Join-Path ([IO.Path]::GetTempPath()) "litellm-provider-test-$([guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $workDirectory)
$names = @(
    'LITELLM_MASTER_KEY', 'LITELLM_BASE_URL', 'LITELLM_POC_MODEL',
    'LITELLM_POC_BROKER_PORT', 'LITELLM_POC_TOKEN_FILE', 'LITELLM_POC_TEST_RESULT'
)
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$brokerProcess = $null
$codeProcess = $null
$brokerToken = $null
$individualKey = $null
$passed = $false
try {
    $env:LITELLM_MASTER_KEY = $masterKeyLine.Substring('LITELLM_MASTER_KEY='.Length)
    $env:LITELLM_BASE_URL = 'http://127.0.0.1:4000'
    $env:LITELLM_POC_MODEL = 'qwen3:4b-8k'
    $env:LITELLM_POC_BROKER_PORT = '43128'
    $env:LITELLM_POC_TOKEN_FILE = Join-Path $workDirectory 'broker-token'
    $env:LITELLM_POC_TEST_RESULT = Join-Path $workDirectory 'result.json'
    $brokerScript = Join-Path $PSScriptRoot '..\broker\server.mjs'
    $brokerProcess = Start-Process -FilePath $nodeExe -ArgumentList "`"$brokerScript`"" -PassThru `
        -RedirectStandardOutput (Join-Path $workDirectory 'broker.log') `
        -RedirectStandardError (Join-Path $workDirectory 'broker-errors.log')
    Remove-Item Env:\LITELLM_MASTER_KEY
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $env:LITELLM_POC_TOKEN_FILE)) {
        if ($brokerProcess.HasExited) { throw 'The test broker failed to start. Inspect broker-errors.log.' }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Timed out waiting for the test broker.' }
        Start-Sleep -Milliseconds 200
    }
    $brokerToken = [IO.File]::ReadAllText($env:LITELLM_POC_TOKEN_FILE).Trim()
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:43128/healthz' -TimeoutSec 5
    if ($health.status -ne 'ok') { throw 'The test broker is not healthy.' }
    $denied = Invoke-WebRequest -Method Post -Uri 'http://127.0.0.1:43128/v1/key' `
        -SkipHttpErrorCheck -TimeoutSec 5
    if ([int]$denied.StatusCode -ne 401) { throw 'The broker accepted an unauthenticated key request.' }
    Write-Host 'PASS: the real broker rejects requests without its token.'

    $extensionPath = Join-Path $PSScriptRoot '..\extension'
    $testsPath = Join-Path $PSScriptRoot '..\tests\vscode.test.cjs'
    $arguments = @(
        '--new-window', '--disable-extensions', '--skip-welcome', '--skip-release-notes',
        '--user-data-dir', "`"$(Join-Path $workDirectory 'profile')`"",
        '--extensions-dir', "`"$(Join-Path $workDirectory 'extensions')`"",
        '--extensionDevelopmentPath', "`"$extensionPath`"",
        '--extensionTestsPath', "`"$testsPath`""
    )
    $codeProcess = Start-Process -FilePath $codeExe -ArgumentList $arguments -PassThru `
        -RedirectStandardOutput (Join-Path $workDirectory 'vscode.log') `
        -RedirectStandardError (Join-Path $workDirectory 'vscode-errors.log')
    if (-not $codeProcess.WaitForExit(360000)) { throw 'The VS Code provider test exceeded six minutes.' }
    if ($codeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $env:LITELLM_POC_TEST_RESULT)) {
        throw 'The VS Code provider test failed. Inspect vscode.log and vscode-errors.log.'
    }
    $result = Get-Content -LiteralPath $env:LITELLM_POC_TEST_RESULT -Raw | ConvertFrom-Json
    if (-not $result.modelDiscovered -or $result.completedRequests -ne 2) {
        throw 'The VS Code test did not complete both real model requests.'
    }
    Write-Host 'PASS: the real VS Code provider completed two model requests through the broker.'

    $key = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:43128/v1/key' `
        -Headers @{ Authorization = "Bearer $brokerToken" } -TimeoutSec 30
    $individualKey = $key.apiKey
    $headers = @{ Authorization = "Bearer $individualKey" }
    $models = Invoke-RestMethod -Uri 'http://127.0.0.1:4000/v1/models' -Headers $headers -TimeoutSec 15
    if ($models.data.id -notcontains 'qwen3:4b-8k') { throw 'The issued key cannot access the demo model.' }
    Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:43128/v1/shutdown' `
        -Headers @{ Authorization = "Bearer $brokerToken" } -TimeoutSec 5 | Out-Null
    if (-not $brokerProcess.WaitForExit(40000)) { throw 'The broker did not shut down in time.' }
    if ($brokerProcess.ExitCode -ne 0) { throw 'The broker reported a shutdown failure.' }
    $revoked = $false
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    do {
        $response = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/v1/models' `
            -Headers $headers -SkipHttpErrorCheck -TimeoutSec 5
        if ([int]$response.StatusCode -eq 401) { $revoked = $true; break }
        if ([int]$response.StatusCode -ne 200) { throw "Unexpected revocation-check HTTP status: $($response.StatusCode)." }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $revoked) { throw 'LiteLLM still accepts the individual key after broker shutdown.' }
    if (Test-Path -LiteralPath $env:LITELLM_POC_TOKEN_FILE) { throw 'The broker left its token file after shutdown.' }
    Write-Host 'PASS: LiteLLM rejects the revoked key with HTTP 401 and the broker token is removed.'
    Write-Host 'Provider integration passed. This does not test the standard Chat UI or GitHub sign-in.'
    $passed = $true
} finally {
    if ($codeProcess -and -not $codeProcess.HasExited) { Stop-Process -Id $codeProcess.Id }
    if ($brokerProcess -and -not $brokerProcess.HasExited) {
        if ($brokerToken) {
            try {
                Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:43128/v1/shutdown' `
                    -Headers @{ Authorization = "Bearer $brokerToken" } -TimeoutSec 5 | Out-Null
                if (-not $brokerProcess.WaitForExit(40000)) { Stop-Process -Id $brokerProcess.Id }
            } catch {
                Write-Warning 'Graceful test-broker shutdown failed; its temporary key may remain valid until expiry.'
                if (-not $brokerProcess.HasExited) { Stop-Process -Id $brokerProcess.Id }
            }
        } else {
            Stop-Process -Id $brokerProcess.Id
        }
    }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    Remove-Variable masterKeyLine, brokerToken, individualKey, key, headers -ErrorAction SilentlyContinue
    if ($passed) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    } else {
        Write-Warning "Test diagnostics retained at $workDirectory. Do not share token files or raw logs."
    }
}
