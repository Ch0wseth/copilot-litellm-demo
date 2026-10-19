#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4
<#
.SYNOPSIS
Explicitly list, create, ping, inspect or delete a demo webhook.
.DESCRIPTION
Uses the current gh credential without switching accounts. Mutations support
WhatIf and confirmation. Cloud enterprise hooks must be configured in the UI.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Repository', 'Organization', 'ServerEnterprise', 'CloudEnterprise')]
    [string]$Scope,
    [Parameter(Mandatory)][string]$Target,
    [ValidateSet('List', 'Create', 'Ping', 'Deliveries', 'Delete', 'OpenSettings')]
    [string]$Action = 'List',
    [string]$GitHubHostname = 'github.com',
    [ValidateRange(1, [long]::MaxValue)][long]$HookId,
    [uri]$PayloadUrl,
    [ValidateSet('repository', 'workflow_run', 'organization', 'team', 'membership', 'push', 'issues', 'pull_request')]
    [string[]]$Events = @('repository')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\github-api.ps1')
if ($GitHubHostname -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$') {
    throw 'Use a hostname without scheme, port or path.'
}
if ($Scope -eq 'Repository') {
    if ($Target -notmatch '^[a-zA-Z0-9-]+/[a-zA-Z0-9_.-]+$') { throw 'Repository target must be OWNER/REPO.' }
    $base = "repos/$Target/hooks"
    $settings = "https://$GitHubHostname/$Target/settings/hooks"
} else {
    if ($Target -notmatch '^[a-zA-Z0-9-]+$') { throw 'Target must be an organization or enterprise slug.' }
    $base = "orgs/$Target/hooks"
    $settings = "https://$GitHubHostname/organizations/$Target/settings/hooks"
}
if ($Scope -eq 'CloudEnterprise') {
    if ($GitHubHostname -ne 'github.com' -and $GitHubHostname -notlike '*.ghe.com') {
        throw 'CloudEnterprise requires github.com or your enterprise GHE.com hostname.'
    }
    $settings = "https://$GitHubHostname/enterprises/$Target/settings/hooks"
    if ($Action -ne 'OpenSettings') {
        throw "Cloud global hooks use the UI: run -Action OpenSettings. $settings"
    }
}
if ($Scope -eq 'ServerEnterprise') {
    if ($GitHubHostname -eq 'github.com' -or $GitHubHostname -like '*.ghe.com') {
        throw 'ServerEnterprise requires your explicit GHES hostname, not GitHub Cloud.'
    }
    $base = 'admin/hooks'
    $settings = "https://$GitHubHostname/enterprises/$Target/settings/hooks"
    if ($Action -eq 'Deliveries') { throw 'Inspect GHES global deliveries in the UI with -Action OpenSettings.' }
}
if ($Action -eq 'OpenSettings') {
    Write-Host $settings
    if ($PSCmdlet.ShouldProcess($settings, 'Open webhook settings in browser')) { Start-Process $settings }
    return
}
if ($Action -in @('Ping', 'Deliveries', 'Delete') -and -not $PSBoundParameters.ContainsKey('HookId')) {
    throw '-HookId is required for this action. Use List to find the exact hook.'
}
switch ($Action) {
    'List' {
        $page = 1
        do {
            $hooks = @(Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint "${base}?per_page=100&page=$page")
            # The API helper preserves top-level arrays; flatten only this list.
            $hooks = @($hooks | ForEach-Object { $_ })
            foreach ($hook in $hooks) {
                [pscustomobject]@{ id = $hook.id; active = $hook.active; events = $hook.events }
            }
            $page++
        } while ($hooks.Count -eq 100)
    }
    'Create' {
        if (-not $PayloadUrl -or -not $PayloadUrl.IsAbsoluteUri -or
            $PayloadUrl.Scheme -ne 'https' -or $PayloadUrl.UserInfo -or $PayloadUrl.Fragment) {
            throw '-PayloadUrl must be an absolute approved HTTPS receiver URL without credentials or fragment.'
        }
        if ($Events.Count -eq 0) { throw 'Select at least one event.' }
        if ($PSCmdlet.ShouldProcess("$GitHubHostname/$Target", "Create $Scope webhook for $($Events -join ', ')")) {
            $secretFile = Join-Path $PSScriptRoot '.env'
            if (-not (Test-Path -LiteralPath $secretFile)) { throw 'Run start-receiver.ps1 first to generate webhooks\.env.' }
            $line = Get-Content -LiteralPath $secretFile | Where-Object { $_ -match '^WEBHOOK_SECRET=' }
            if (@($line).Count -ne 1 -or $line -notmatch '^WEBHOOK_SECRET=([a-fA-F0-9]{64})$') { throw 'Invalid local webhook secret file.' }
            $body = @{
                name = 'web'; active = $true; events = $Events
                config = @{ url = $PayloadUrl.AbsoluteUri; content_type = 'json'; secret = $Matches[1]; insecure_ssl = '0' }
            }
            $hook = Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint $base -Method POST -Body $body
            if (-not $hook.id) { throw 'GitHub did not return a created hook ID. Inspect the target before retrying.' }
            [pscustomobject]@{ id = $hook.id; active = $hook.active; events = $hook.events }
        }
    }
    'Ping' {
        if ($PSCmdlet.ShouldProcess("$GitHubHostname/$base/$HookId", 'Send webhook ping')) {
            Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint "$base/$HookId/pings" -Method POST | Out-Null
            Write-Host "Ping requested for hook $HookId. Check deliveries for the actual HTTP result."
        }
    }
    'Deliveries' {
        $deliveries = Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint "$base/$HookId/deliveries?per_page=10"
        $deliveries | ForEach-Object {
            [pscustomobject]@{ id = $_.id; event = $_.event; status_code = $_.status_code; redelivery = $_.redelivery }
        }
    }
    'Delete' {
        if ($PSCmdlet.ShouldProcess("$GitHubHostname/$base/$HookId", 'Delete this exact webhook')) {
            Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint "$base/$HookId" -Method DELETE | Out-Null
            Write-Host "Deleted hook $HookId."
        }
    }
}
