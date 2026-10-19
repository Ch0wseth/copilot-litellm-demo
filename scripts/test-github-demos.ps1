#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4
<#
.SYNOPSIS
Offline contract tests for the GitHub demo scripts. No real gh calls are made.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$mock = @{
    Calls = [Collections.Generic.List[object]]::new()
    Responses = [Collections.Generic.Queue[string]]::new()
    Response = '{}'; ExitCode = 0; Body = ''
}

function Assert-Demo {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-DemoThrows {
    param([scriptblock]$Operation, [string]$Message)
    $threw = $false
    try { & $Operation | Out-Null } catch { $threw = $true }
    Assert-Demo $threw $Message
}
function gh {
    $mock.Calls.Add(@($args))
    $mock.Body = $input -join "`n"
    $global:LASTEXITCODE = $mock.ExitCode
    if ($mock.Responses.Count) { $mock.Responses.Dequeue() } else { $mock.Response }
}

$adminScript = Join-Path $root 'admin-api\test-access.ps1'
$hookScript = Join-Path $root 'webhooks\manage-hook.ps1'
$previousDebug = $env:GH_DEBUG
try {
    $env:GH_DEBUG = ''
    $mock.Response = '{"total_seats":12,"seats":[{"assignee":{"login":"not-for-output"}}]}'
    $result = & $adminScript -Operation OrganizationSeats -Target test-org
    Assert-Demo ($result.total_seats -eq 12) 'Seat count was not extracted.'
    Assert-Demo (($result | ConvertTo-Json) -notmatch 'not-for-output') 'Personal seat data leaked.'
    Assert-Demo ($mock.Calls[-1] -contains 'orgs/test-org/copilot/billing/seats?per_page=1') 'Wrong organization route.'
    Assert-Demo ($mock.Calls[-1] -contains 'GET') 'Administrative call must be read-only.'

    & $adminScript -Operation EnterpriseSeats -Target test-enterprise | Out-Null
    Assert-Demo ($mock.Calls[-1] -contains 'enterprises/test-enterprise/copilot/billing/seats?per_page=1') 'Wrong enterprise route.'
    $mock.Response = '[]'
    $result = & $adminScript -Operation EnterpriseAudit -Target test-enterprise
    Assert-Demo ($result.returned_events -eq 0) 'Empty audit list mishandled.'
    $mock.Response = '[{"actor":"not-for-output"}]'
    $result = & $adminScript -Operation EnterpriseAudit -Target test-enterprise
    Assert-Demo ($result.returned_events -eq 1) 'Single event array mishandled.'
    Assert-Demo (($result | ConvertTo-Json) -notmatch 'not-for-output') 'Audit data leaked.'

    $mock.Response = '{}'
    Assert-DemoThrows { & $adminScript -Operation OrganizationSeats -Target test-org } 'Missing seat count must fail.'
    $mock.ExitCode = 1
    Assert-DemoThrows { & $adminScript -Operation OrganizationSeats -Target test-org } 'API errors must fail.'
    $mock.ExitCode = 0
    $mock.Calls.Clear()
    & $hookScript -Scope Repository -Target test-owner/test-repo -Action Create -PayloadUrl https://receiver.example/webhook -WhatIf
    & $hookScript -Scope Organization -Target test-org -Action Delete -HookId 42 -WhatIf
    Assert-Demo ($mock.Calls.Count -eq 0) 'WhatIf made a real API call.'
    Assert-DemoThrows { & $hookScript -Scope CloudEnterprise -Target test-enterprise -Action Create } 'Cloud must not use the GHES API.'
    Assert-DemoThrows { & $hookScript -Scope ServerEnterprise -Target test-enterprise -Action List } 'GHES cannot target github.com.'
    Assert-DemoThrows { & $hookScript -Scope Repository -Target test-owner/test-repo -Action Delete } 'Delete needs an explicit ID.'
    Assert-DemoThrows { & $hookScript -Scope Repository -Target test-owner/test-repo -Action Create -PayloadUrl http://receiver.example/webhook } 'HTTP URL must be rejected.'

    $mock.Response = '[{"id":42,"active":true,"events":["repository"],"config":{"secret":"not-for-output"}}]'
    $result = @(& $hookScript -Scope Organization -Target test-org)
    Assert-Demo ($result.Count -eq 1 -and $result[0].id -eq 42) 'Hook list not flattened correctly.'
    Assert-Demo (($result | ConvertTo-Json) -notmatch 'not-for-output') 'Hook secret leaked.'
    $mock.Responses.Enqueue((@(1..100 | ForEach-Object { @{ id = $_ } }) | ConvertTo-Json -Compress))
    $mock.Responses.Enqueue('[{"id":101}]')
    $result = @(& $hookScript -Scope Organization -Target test-org)
    Assert-Demo ($result.Count -eq 101) 'Hook list pagination lost results.'
    Assert-Demo ($mock.Calls[-1] -contains 'orgs/test-org/hooks?per_page=100&page=2') 'Wrong pagination route.'
    $mock.Response = '[{"id":1,"event":"ping","status_code":202,"redelivery":false}]'
    $result = @(& $hookScript -Scope Repository -Target test-owner/test-repo -Action Deliveries -HookId 42)
    Assert-Demo ($result[0].status_code -eq 202) 'Delivery projection failed.'
    $mock.Response = ''
    & $hookScript -Scope Repository -Target test-owner/test-repo -Action Ping -HookId 42 -Confirm:$false
    Assert-Demo ($mock.Calls[-1] -contains 'repos/test-owner/test-repo/hooks/42/pings') 'Wrong ping route.'
    & $hookScript -Scope ServerEnterprise -GitHubHostname ghes.example -Target test-enterprise -Action Delete -HookId 42 -Confirm:$false
    Assert-Demo ($mock.Calls[-1] -contains 'admin/hooks/42') 'Wrong GHES route.'

    function Test-Path {
        param([string]$LiteralPath)
        if ($LiteralPath -like '*webhooks\.env') { return $true }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-Content {
        param([string]$LiteralPath)
        if ($LiteralPath -like '*webhooks\.env') { return 'WEBHOOK_SECRET=' + ('a' * 64) }
        Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath
    }
    $mock.Response = '{"id":42,"active":true,"events":["repository"]}'
    $result = & $hookScript -Scope Repository -Target test-owner/test-repo -Action Create `
        -PayloadUrl https://receiver.example/webhook -Confirm:$false
    $sent = $mock.Body | ConvertFrom-Json
    Assert-Demo ($result.id -eq 42) 'Created hook ID not returned.'
    Assert-Demo ($sent.config.secret -eq ('a' * 64)) 'Secret not passed via stdin JSON.'
    Assert-Demo ($sent.config.insecure_ssl -eq '0') 'TLS verification must remain enabled.'
    Assert-Demo (($mock.Calls[-1] -join ' ') -notmatch ('a' * 64)) 'Secret leaked into command arguments.'

    function Read-Host { 'offline-test-token' }
    $previousToken = $env:GH_TOKEN
    $mock.ExitCode = 1
    Assert-DemoThrows { & $adminScript -Operation OrganizationSeats -Target test-org -PromptToken } 'Prompted-token error must fail.'
    Assert-Demo ($env:GH_TOKEN -eq $previousToken) 'Prompted token was not restored after failure.'
    $previousEnterpriseToken = $env:GH_ENTERPRISE_TOKEN
    Assert-DemoThrows { & $adminScript -Operation RepositoryAccess -Target test-owner/test-repo -GitHubHostname ghes.example -PromptToken } 'Prompted GHES error must fail.'
    Assert-Demo ($env:GH_ENTERPRISE_TOKEN -eq $previousEnterpriseToken) 'GHES token was not restored after failure.'
    $mock.ExitCode = 0
    $env:GH_DEBUG = 'api'
    Assert-DemoThrows { & $adminScript -Operation RepositoryAccess -Target test-owner/test-repo } 'Debug mode must be rejected.'
    Write-Host 'PASS: offline API routing, privacy, failure and WhatIf checks.'
} finally {
    if ($null -eq $previousDebug) {
        Remove-Item Env:GH_DEBUG -ErrorAction SilentlyContinue
    } else {
        $env:GH_DEBUG = $previousDebug
    }
}
