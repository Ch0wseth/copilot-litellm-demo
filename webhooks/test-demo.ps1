#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4
<#
.SYNOPSIS
Send synthetic signed requests to the running local webhook receiver.
.DESCRIPTION
Checks valid signature, tamper rejection and duplicate suppression. Does not
contact GitHub or prove a delivery from a real GitHub webhook.
#>
[CmdletBinding()]
param([ValidateRange(1024, 65535)][int]$Port = 8787)

$ErrorActionPreference = 'Stop'
$baseUrl = "http://127.0.0.1:$Port"
$secretFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path -LiteralPath $secretFile)) { throw 'Run start-receiver.ps1 in another terminal first.' }
$line = Get-Content -LiteralPath $secretFile | Where-Object { $_ -match '^WEBHOOK_SECRET=' }
if (@($line).Count -ne 1 -or $line -notmatch '^WEBHOOK_SECRET=([a-fA-F0-9]{64})$') { throw 'Invalid local webhook secret file.' }
$secret = [Text.Encoding]::ASCII.GetBytes($Matches[1])
$health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 5 -MaximumRedirection 0
if ($health.status -ne 'ok') { throw 'Receiver is not healthy.' }

$delivery = [Guid]::NewGuid().ToString()
$body = [Text.Encoding]::UTF8.GetBytes('{"action":"completed","demo":"synthetic_local_test"}')
$signature = 'sha256=' + [Convert]::ToHexString(
    [Security.Cryptography.HMACSHA256]::HashData($secret, $body)
).ToLowerInvariant()
$headers = @{
    'X-Hub-Signature-256' = $signature
    'X-GitHub-Event' = 'workflow_run'
    'X-GitHub-Delivery' = $delivery
}
$response = Invoke-WebRequest -Uri "$baseUrl/webhook" -Method POST -Headers $headers `
    -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec 10 -MaximumRedirection 0
if ([int]$response.StatusCode -ne 202 -or ($response.Content | ConvertFrom-Json).status -ne 'accepted') {
    throw "Signed request was not accepted (HTTP $($response.StatusCode))."
}
Write-Host 'PASS: synthetic signed event accepted (HTTP 202).'

$response = Invoke-WebRequest -Uri "$baseUrl/webhook" -Method POST -Headers $headers `
    -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec 10 -MaximumRedirection 0
if ([int]$response.StatusCode -ne 200 -or ($response.Content | ConvertFrom-Json).status -ne 'duplicate') {
    throw 'Redelivery was not recognized as a duplicate.'
}
Write-Host 'PASS: duplicate acknowledged without a second event.'

$headers['X-GitHub-Delivery'] = [Guid]::NewGuid().ToString()
$tampered = [Text.Encoding]::UTF8.GetBytes('{"action":"tampered"}')
$response = Invoke-WebRequest -Uri "$baseUrl/webhook" -Method POST -Headers $headers `
    -ContentType 'application/json' -Body $tampered -SkipHttpErrorCheck -TimeoutSec 10 -MaximumRedirection 0
if ([int]$response.StatusCode -ne 401) { throw 'Tampered body was not rejected with HTTP 401.' }
$deliveries = Invoke-RestMethod -Uri "$baseUrl/deliveries" -TimeoutSec 5 -MaximumRedirection 0
$matching = @($deliveries | Where-Object { $_.delivery_id -eq $delivery })
if ($matching.Count -ne 1 -or -not $matching[0].signature_verified -or
    $deliveries.delivery_id -contains $headers['X-GitHub-Delivery']) {
    throw 'Receiver retained a duplicate or a rejected event, or omitted signature evidence.'
}
Write-Host 'PASS: tampered body rejected (HTTP 401), not stored.'
Write-Host "Local checks complete. Dashboard: $baseUrl ; real GitHub delivery remains a separate test."
