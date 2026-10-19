#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4
<#
.SYNOPSIS
Run a bounded, read-only GitHub administrative API demonstration.
.DESCRIPTION
Uses the current gh credential or its host-specific token environment variable.
Never changes accounts, permissions or seats, or prints the raw admin response.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('RepositoryAccess', 'OrganizationSeats', 'EnterpriseSeats', 'EnterpriseAudit')]
    [string]$Operation,
    [Parameter(Mandatory)][string]$Target,
    [string]$GitHubHostname = 'github.com',
    [switch]$PromptToken
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\github-api.ps1')
if ($Operation -eq 'RepositoryAccess') {
    if ($Target -notmatch '^[a-zA-Z0-9-]+/[a-zA-Z0-9_.-]+$') { throw 'Repository target must be OWNER/REPO.' }
    $endpoint = "repos/$Target"
} else {
    if ($Target -notmatch '^[a-zA-Z0-9-]+$') { throw 'Target must be an organization or enterprise slug.' }
    if ($Operation -eq 'OrganizationSeats') {
        $endpoint = "orgs/$Target/copilot/billing/seats?per_page=1"
    } elseif ($Operation -eq 'EnterpriseSeats') {
        $endpoint = "enterprises/$Target/copilot/billing/seats?per_page=1"
    } else {
        $endpoint = "enterprises/$Target/audit-log?per_page=1&include=web"
    }
}
$tokenVariable = if ($GitHubHostname -eq 'github.com' -or $GitHubHostname -like '*.ghe.com') { 'GH_TOKEN' } else { 'GH_ENTERPRISE_TOKEN' }
$previousToken = [Environment]::GetEnvironmentVariable($tokenVariable, 'Process')
try {
    if ($PromptToken) {
        $token = Read-Host 'PAT or installation token (not an app JWT)' -MaskInput
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token is required.' }
        Set-Item -LiteralPath "Env:$tokenVariable" -Value $token
        Remove-Variable token
    }
    $result = Invoke-DemoGitHubApi -GitHubHostname $GitHubHostname -Endpoint $endpoint
    if ($null -eq $result) { throw 'Unexpected empty response from the read-only endpoint.' }
    switch ($Operation) {
        'RepositoryAccess' {
            if (-not $result.full_name) { throw 'Response does not contain repository metadata.' }
            [pscustomobject]@{
                operation = $Operation; target = $Target; hostname = $GitHubHostname
                repository = $result.full_name; private = $result.private
                admin = $result.permissions.admin
                note = 'Repository access only; this does not prove organization or enterprise admin access.'
            }
        }
        { $_ -in @('OrganizationSeats', 'EnterpriseSeats') } {
            if ($result.total_seats -isnot [long] -and $result.total_seats -isnot [int]) {
                throw 'Response does not contain an integer total_seats. Not reporting a zero fallback.'
            }
            if ($result.total_seats -lt 0) { throw 'Response contains an invalid seat count.' }
            [pscustomobject]@{
                operation = $Operation; target = $Target; hostname = $GitHubHostname
                total_seats = $result.total_seats
            }
        }
        'EnterpriseAudit' {
            if ($result -isnot [array]) { throw 'Expected an audit event array.' }
            [pscustomobject]@{
                operation = $Operation; target = $Target; hostname = $GitHubHostname
                returned_events = $result.Count
                note = 'At most one event requested; no event body or personal data is displayed.'
            }
        }
    }
} finally {
    if ($PromptToken) {
        if ($null -eq $previousToken) {
            Remove-Item -LiteralPath "Env:$tokenVariable" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$tokenVariable" -Value $previousToken
        }
    }
}
