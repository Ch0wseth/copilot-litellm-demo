#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

function Invoke-DemoGitHubApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitHubHostname,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body
    )

    if ($GitHubHostname -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$') {
        throw 'Use a GitHub hostname, without scheme, port or path.'
    }
    if ($env:GH_DEBUG) {
        throw 'Unset GH_DEBUG before this demo to avoid logging credentials or payloads.'
    }
    $arguments = @(
        'api', '--hostname', $GitHubHostname, '--method', $Method,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint
    )
    if ($null -ne $Body) {
        $arguments += @('--input', '-')
        $output = $Body | ConvertTo-Json -Depth 8 -Compress | & gh @arguments
    } else {
        $output = & gh @arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API $Method failed (exit $LASTEXITCODE). Check the host, endpoint permissions, SSO and token type."
    }
    $json = $output -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        ConvertFrom-Json -InputObject $json -Depth 30 -NoEnumerate
    }
}
