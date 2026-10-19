#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Verify real Copilot CLI traces and metrics in Grafana's backends.
.DESCRIPTION
    Run a short local-model prompt, find this exact run in Tempo, inspect its
    GenAI spans, and require populated Prometheus dashboard queries.
.PARAMETER TimeoutSeconds
    Maximum time to wait for telemetry ingestion after the CLI has exited.
.EXAMPLE
    .\observability\test-demo.ps1
.NOTES
    Requires both demo stacks and an individual LITELLM_USER_KEY.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $baseUrl = 'http://127.0.0.1:3000'
    $runId = [guid]::NewGuid()
    $start = [DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds()
    $health = Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 15
    if ($health.database -ne 'ok') {
        throw 'Grafana is not ready. Run .\observability\start-demo.ps1 first.'
    }
    $dashboard = Invoke-RestMethod -Uri "$baseUrl/api/dashboards/uid/copilot-otel-demo" -TimeoutSec 15
    $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'grafana\copilot-dashboard.json') -Raw | ConvertFrom-Json
    foreach ($panel in $expected.panels | Where-Object { $_.type -eq 'stat' }) {
        $actual = @($dashboard.dashboard.panels | Where-Object { $_.id -eq $panel.id })
        if ($actual.Count -ne 1 -or $actual[0].targets[0].expr -ne $panel.targets[0].expr) {
            throw 'Grafana is serving an outdated dashboard. Run .\observability\start-demo.ps1 again.'
        }
    }

    $output = & (Join-Path $PSScriptRoot 'run-copilot-cli.ps1') -RunId $runId `
        --no-custom-instructions --disable-builtin-mcps --stream off --silent `
        --prompt '/no_think Reply with exactly COPILOT_OTEL_OK and nothing else. Do not use tools.'
    if (($output -join "`n").Trim() -ne 'COPILOT_OTEL_OK') {
        throw 'Copilot did not complete the real model request with the expected marker.'
    }
    Write-Host 'PASS: real Copilot CLI inference returned COPILOT_OTEL_OK.'

    $query = [Uri]::EscapeDataString("{ resource.service.name = `"copilot-cli-demo`" && resource.demo.run_id = `"$runId`" }")
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $traceId = $null
    do {
        $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $search = Invoke-RestMethod -Uri "$baseUrl/api/datasources/proxy/uid/tempo/api/search?q=$query&start=$start&end=$end" -TimeoutSec 15
        if (@($search.traces).Count -gt 0) {
            $traceId = $search.traces[0].traceID
            break
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $traceId) {
        throw "No Tempo trace for this run ($runId) arrived within $TimeoutSeconds seconds."
    }

    $trace = Invoke-RestMethod -Uri "$baseUrl/api/datasources/proxy/uid/tempo/api/traces/$traceId" `
        -Headers @{ Accept = 'application/json' } -TimeoutSec 15
    $operations = @()
    foreach ($batch in @($trace.batches) + @($trace.resourceSpans)) {
        foreach ($scope in @($batch.scopeSpans) + @($batch.instrumentationLibrarySpans)) {
            foreach ($span in $scope.spans) {
                $attributes = @($span.attributes) + @($span.events | ForEach-Object { $_.attributes })
                foreach ($attribute in $attributes) {
                    if ($attribute.key -eq 'gen_ai.operation.name') {
                        $operations += $attribute.value.stringValue
                    }
                    if ($attribute.key -match '^gen_ai\.(input\.messages|output\.messages|system_instructions|tool\.definitions|tool\.call\.(arguments|result))$') {
                        throw 'Unexpected captured content found in a trace attribute.'
                    }
                }
            }
        }
    }
    if ($operations -notcontains 'chat' -or $operations -notcontains 'invoke_agent') {
        throw 'Tempo trace is missing chat or invoke_agent GenAI spans.'
    }
    Write-Host "PASS: Tempo contains this run's invoke_agent and chat spans. Trace ID: $traceId"

    $freshQuery = [Uri]::EscapeDataString("timestamp(gen_ai_client_inference_usage_input_tokens_total{service_name=`"copilot-cli-demo`",gen_ai_operation_name=`"chat`"}) >= $start")
    do {
        $fresh = Invoke-RestMethod -Uri "$baseUrl/api/datasources/proxy/uid/prometheus/api/v1/query?query=$freshQuery" -TimeoutSec 15
        if ($fresh.status -ne 'success') {
            throw 'Prometheus failed to evaluate the metric freshness query.'
        }
        if (@($fresh.data.result).Count -gt 0) {
            break
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (@($fresh.data.result).Count -eq 0) {
        throw 'No input-token metric newer than this CLI invocation arrived.'
    }
    Write-Host 'PASS: Prometheus received a fresh CLI input-token sample.'

    $dashboard = Invoke-RestMethod -Uri "$baseUrl/api/dashboards/uid/copilot-otel-demo" -TimeoutSec 15
    foreach ($panel in $dashboard.dashboard.panels | Where-Object { $_.type -eq 'stat' }) {
        $expression = [Uri]::EscapeDataString($panel.targets[0].expr.Replace('$__range', '30m'))
        $found = $false
        do {
            $metrics = Invoke-RestMethod -Uri "$baseUrl/api/datasources/proxy/uid/prometheus/api/v1/query?query=$expression" -TimeoutSec 15
            if ($metrics.status -ne 'success') {
                throw "Prometheus query failed for panel: $($panel.title)"
            }
            if (@($metrics.data.result).Count -gt 0) {
                $value = [double]::Parse($metrics.data.result[0].value[1], [Globalization.CultureInfo]::InvariantCulture)
                if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value) -and $value -gt 0) {
                    $found = $true
                    break
                }
            }
            Start-Sleep -Seconds 2
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if (-not $found) {
            throw "Dashboard panel did not return a positive metric: $($panel.title)"
        }
        Write-Host "PASS: $($panel.title) = $value"
    }
    Write-Host 'Verified: real CLI traces and metrics. VS Code UI and Loki events are separate manual checks.'
}
#endregion Main Execution
