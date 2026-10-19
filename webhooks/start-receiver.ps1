#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4
<#
.SYNOPSIS
Start the loopback-only signed webhook receiver in the foreground.
#>
[CmdletBinding()]
param([ValidateRange(1024, 65535)][int]$Port = 8787)

$ErrorActionPreference = 'Stop'
$secretFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path -LiteralPath $secretFile)) {
    $secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    "WEBHOOK_SECRET=$secret" | Set-Content -LiteralPath $secretFile -Encoding ascii
    Remove-Variable secret
    Write-Host 'Generated a local secret in ignored webhooks\.env. Do not share this file.'
}
$line = Get-Content -LiteralPath $secretFile | Where-Object { $_ -match '^WEBHOOK_SECRET=' }
if (@($line).Count -ne 1 -or $line -notmatch '^WEBHOOK_SECRET=([a-fA-F0-9]{64})$') {
    throw 'Invalid webhooks\.env: expected one generated WEBHOOK_SECRET entry.'
}
$previousSecret = $env:WEBHOOK_SECRET
try {
    $env:WEBHOOK_SECRET = $Matches[1]
    Write-Host "Receiver: http://127.0.0.1:$Port ; GitHub destination: HTTPS_URL/webhook"
    Write-Host 'Local receiver only. No tunnel or GitHub hook is created. Stop with Ctrl+C.'
    python (Join-Path $PSScriptRoot 'receiver.py') --port $Port
    if ($LASTEXITCODE -ne 0) { throw "Webhook receiver exited with code $LASTEXITCODE." }
} finally {
    if ($null -eq $previousSecret) {
        Remove-Item Env:WEBHOOK_SECRET -ErrorAction SilentlyContinue
    } else {
        $env:WEBHOOK_SECRET = $previousSecret
    }
}
