#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Run the LiteLLM Copilot demo with local OpenTelemetry export.
.DESCRIPTION
    Scope OTel environment overrides to the child CLI invocation, disable content
    capture, and restore the caller environment even if the CLI fails.
.PARAMETER RunId
    Optional correlation identifier attached to traces as demo.run_id.
.PARAMETER CopilotArgs
    Arguments passed through to the existing LiteLLM CLI launcher.
.EXAMPLE
    .\observability\run-copilot-cli.ps1 --no-custom-instructions --disable-builtin-mcps
.NOTES
    Requires the LiteLLM stack and LITELLM_USER_KEY. Does not edit global settings.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [guid]$RunId = [guid]::NewGuid(),

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CopilotArgs
)

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $previous = @{}
    $configured = @{
        COPILOT_OTEL_ENABLED = 'true'
        COPILOT_OTEL_EXPORTER_TYPE = 'otlp-http'
        OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:4318'
        OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
        OTEL_SERVICE_NAME = 'copilot-cli-demo'
        OTEL_RESOURCE_ATTRIBUTES = "deployment.environment=demo,deployment.environment.name=demo,demo.run_id=$RunId"
        OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = 'false'
        COPILOT_OTEL_CAPTURE_CONTENT = 'false'
    }
    $inherited = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(OTEL_|COPILOT_OTEL_)' })
    foreach ($entry in $inherited) {
        $previous[$entry.Name] = $entry.Value
    }

    try {
        foreach ($entry in $inherited) {
            [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
        }
        foreach ($name in $configured.Keys) {
            [Environment]::SetEnvironmentVariable($name, $configured[$name], 'Process')
        }
        Write-Host "Local telemetry run: $RunId (content capture disabled)."
        & (Join-Path $PSScriptRoot '..\scripts\run-copilot-cli.ps1') @CopilotArgs
    } finally {
        foreach ($name in $configured.Keys) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}
#endregion Main Execution
