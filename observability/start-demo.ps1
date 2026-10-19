#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Start the local Grafana OpenTelemetry demo.
.DESCRIPTION
    Generate an ignored admin password, start the isolated Compose project and
    wait for Grafana, its provisioned dashboard and the container health check.
.EXAMPLE
    .\observability\start-demo.ps1
.NOTES
    Docker Desktop must be running. Only loopback ports are published.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $envFile = Join-Path $PSScriptRoot '.env'
    $composeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $envFile)) {
        $password = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        "GRAFANA_ADMIN_PASSWORD=$password" | Set-Content -LiteralPath $envFile -Encoding ascii
        Remove-Variable password
        Write-Host 'Generated local Grafana admin credentials in ignored observability\.env.'
    }

    docker compose --env-file $envFile -f $composeFile up -d --force-recreate --wait --wait-timeout 180
    if ($LASTEXITCODE -ne 0) {
        throw 'Grafana stack failed to become healthy. Inspect: docker compose -f observability\docker-compose.yml logs --tail 60'
    }

    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/api/health' -TimeoutSec 15
    if ($health.database -ne 'ok') {
        throw 'Grafana database is not healthy.'
    }
    $dashboard = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/api/dashboards/uid/copilot-otel-demo' -TimeoutSec 15
    if ($dashboard.dashboard.uid -ne 'copilot-otel-demo') {
        throw 'The Copilot dashboard was not provisioned.'
    }
    Write-Host 'Ready: http://127.0.0.1:3000/d/copilot-otel-demo'
    Write-Host 'OTLP/HTTP: http://127.0.0.1:4318 ; OTLP/gRPC: http://127.0.0.1:4317'
}
#endregion Main Execution
