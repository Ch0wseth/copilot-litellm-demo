#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Stop only the local OpenTelemetry demo.
.DESCRIPTION
    Preserve telemetry volumes and leave the separate LiteLLM stack running.
.EXAMPLE
    .\observability\stop-demo.ps1
.NOTES
    Does not remove containers, volumes or credentials.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    docker compose --env-file (Join-Path $PSScriptRoot '.env') `
        -f (Join-Path $PSScriptRoot 'docker-compose.yml') stop
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to stop the OpenTelemetry demo.'
    }
}
#endregion Main Execution
