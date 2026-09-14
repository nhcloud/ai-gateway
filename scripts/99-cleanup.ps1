<#
.SYNOPSIS
    Deletes everything 01-provision-azure.ps1 created.

.DESCRIPTION
    Removes the whole resource group, then the local state file and .env. Cognitive
    Services accounts are soft-deleted by default, which blocks re-creating an account
    with the same name; -Purge clears them properly.

.EXAMPLE
    .\99-cleanup.ps1 -Purge
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroup,
    [switch]$Purge,
    [switch]$KeepEnvFile
)

. "$PSScriptRoot\00-common.ps1"

Assert-AzureCli | Out-Null
$state = Get-DemoState
if ($ResourceGroup) { $state.ResourceGroup = $ResourceGroup }

Write-Step "About to delete resource group $($state.ResourceGroup)"
Write-Host "  $($state.FoundryName), $($state.ContentSafety), $($state.DocIntelName)$(if ($state.ApimName) { ", $($state.ApimName)" })"

if (-not $PSCmdlet.ShouldProcess($state.ResourceGroup, 'Delete resource group and all resources in it')) {
    Write-Note 'Cancelled.'
    return
}

# Soft-deleted Cognitive Services accounts keep their names reserved, so purge them
# before the group goes away and their location is harder to look up.
$accounts = @(
    @{ Name = $state.FoundryName }
    @{ Name = $state.ContentSafety }
    @{ Name = $state.DocIntelName }
)

Write-Step 'Deleting the resource group (this runs in the background)'
Invoke-Az @('group', 'delete', '--name', $state.ResourceGroup, '--yes', '--no-wait') | Out-Null
Write-Ok 'Deletion started.'

if ($Purge) {
    Write-Step 'Purging soft-deleted Cognitive Services accounts'
    Write-Note 'Waiting for the group delete to release the accounts first.'
    Invoke-Az @('group', 'wait', '--name', $state.ResourceGroup, '--deleted', '--timeout', '1800') -AllowFailure | Out-Null

    foreach ($account in $accounts) {
        $result = Invoke-Az @('cognitiveservices', 'account', 'purge',
            '--name', $account.Name, '-g', $state.ResourceGroup, '-l', $state.Location) -AllowFailure
        if ($null -ne $result -or $LASTEXITCODE -eq 0) {
            Write-Ok "Purged $($account.Name)."
        }
        else {
            Write-Warn "Could not purge $($account.Name) - it may already be gone."
        }
    }
}
else {
    Write-Note 'Accounts remain soft-deleted. Re-run with -Purge to free the names.'
}

# ── local files ───────────────────────────────────────────────────────
Write-Step 'Local files'
$statePath = Join-Path $PSScriptRoot '.deploy.json'
if (Test-Path $statePath) {
    Remove-Item $statePath
    Write-Ok 'Removed scripts\.deploy.json'
}

if (-not $KeepEnvFile) {
    $envPath = Join-Path (Get-RepoRoot) '.env'
    if (Test-Path $envPath) {
        Remove-Item $envPath
        Write-Ok 'Removed .env (it held secrets)'
    }
}

Write-Step 'Done'
