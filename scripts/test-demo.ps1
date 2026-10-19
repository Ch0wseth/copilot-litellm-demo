#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Test the local LiteLLM API and optionally Copilot CLI.
.DESCRIPTION
    Verify model discovery, rejection of an invalid key, inference and streaming
    with the individual key in LITELLM_USER_KEY. Never print credentials.
.PARAMETER IncludeCopilot
    Also run a non-interactive Copilot CLI request through the existing launcher.
.EXAMPLE
    .\scripts\test-demo.ps1 -IncludeCopilot
.NOTES
    Start the stack and set LITELLM_USER_KEY before running this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$IncludeCopilot
)

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($env:LITELLM_USER_KEY)) {
        throw 'Set LITELLM_USER_KEY using .\scripts\new-user-key.ps1 first.'
    }

    $baseUrl = 'http://127.0.0.1:4000/v1'
    $headers = @{ Authorization = "Bearer $env:LITELLM_USER_KEY" }
    $model = 'qwen3:4b-8k'
    $marker = 'LITELLM_API_OK'

    $models = Invoke-RestMethod -Uri "$baseUrl/models" -Headers $headers -TimeoutSec 30
    if ($models.data.id -notcontains $model) {
        throw "The individual key cannot discover $model."
    }
    Write-Host 'PASS: individual key can discover the demo model.'

    $invalidKey = 'invalid-' + [Guid]::NewGuid().ToString('N')
    $denied = Invoke-WebRequest -Uri "$baseUrl/models" `
        -Headers @{ Authorization = "Bearer $invalidKey" } `
        -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$denied.StatusCode -ne 401) {
        throw "Invalid-key test expected HTTP 401, received $($denied.StatusCode)."
    }
    Write-Host 'PASS: invalid key is rejected with HTTP 401.'

    $request = @{
        model = $model
        messages = @(
            @{ role = 'user'; content = "/no_think Reply with exactly $marker and nothing else." }
        )
        temperature = 0
        max_tokens = 512
        stream = $false
    }
    $reply = Invoke-RestMethod -Method Post -Uri "$baseUrl/chat/completions" `
        -Headers $headers -ContentType 'application/json' `
        -Body ($request | ConvertTo-Json -Depth 6) -TimeoutSec 300
    if ($reply.choices[0].finish_reason -eq 'length') {
        throw 'Inference exhausted its output budget before completing the response.'
    }
    if ([string]::IsNullOrWhiteSpace($reply.choices[0].message.content) -or
        $reply.choices[0].message.content.Trim() -ne $marker) {
        throw 'Inference returned unexpected content instead of the requested marker.'
    }
    Write-Host "PASS: local inference returned $marker."

    $request.stream = $true
    $stream = Invoke-WebRequest -Method Post -Uri "$baseUrl/chat/completions" `
        -Headers $headers -ContentType 'application/json' `
        -Body ($request | ConvertTo-Json -Depth 6) -TimeoutSec 300
    $content = [System.Text.StringBuilder]::new()
    foreach ($line in ($stream.Content -split '\r?\n')) {
        if ($line.StartsWith('data: ') -and $line -ne 'data: [DONE]') {
            $chunk = $line.Substring(6) | ConvertFrom-Json
            if ($chunk.error) {
                throw 'The streaming endpoint returned an error event.'
            }
            foreach ($choice in $chunk.choices) {
                [void]$content.Append($choice.delta.content)
            }
        }
    }
    if ($stream.Content -notmatch '(?m)^data: \[DONE\]\s*$' -or $content.ToString().Trim() -ne $marker) {
        throw 'Streaming did not finish successfully with the requested marker.'
    }
    Write-Host 'PASS: Chat Completions streaming returned the marker and [DONE].'

    if ($IncludeCopilot) {
        $output = & (Join-Path $PSScriptRoot 'run-copilot-cli.ps1') `
            --no-custom-instructions --disable-builtin-mcps --stream off --silent `
            --prompt '/no_think Reply with exactly COPILOT_VIA_LITELLM_OK and nothing else. Do not use tools.'
        if (($output -join "`n").Trim() -ne 'COPILOT_VIA_LITELLM_OK') {
            throw 'Copilot CLI did not return the requested marker.'
        }
        Write-Host 'PASS: Copilot CLI returned COPILOT_VIA_LITELLM_OK.'
    }

    Write-Host 'All requested smoke tests passed. VS Code UI validation is a separate manual step.'
}
#endregion Main Execution
