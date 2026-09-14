<#
.SYNOPSIS
    Shared helpers for the AI Gateway demo scripts. Dot-source it; do not run it alone.

.DESCRIPTION
    Every 0N-*.ps1 script starts with:
        . "$PSScriptRoot\00-common.ps1"

    Resource names are derived from a single -Prefix and cached in scripts\.deploy.json,
    so the later scripts do not need the names passed again.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StatePath = Join-Path $PSScriptRoot '.deploy.json'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Note {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    ! $Message" -ForegroundColor Yellow
}

function Assert-AzureCli {
    <#  Confirms the Azure CLI is present and signed in.  #>
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI not found. Install it from https://aka.ms/installazurecli"
    }

    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not signed in. Run 'az login' (and 'az account set --subscription <id>') first."
    }

    Write-Note "Subscription: $($account.name)  ($($account.id))"
    return $account
}

function Invoke-Az {
    <#
    .SYNOPSIS
        Runs an az command, returning parsed JSON and failing loudly.
    .EXAMPLE
        Invoke-Az @('group','create','--name','rg-demo','--location','eastus')
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Raw
    )

    Write-Note "az $($Arguments -join ' ')"
    $output = & az @Arguments 2>&1
    $exit = $LASTEXITCODE

    if ($exit -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    if ($Raw) { return ($output -join [Environment]::NewLine) }

    $text = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try { return $text | ConvertFrom-Json } catch { return $text }
}

function New-DemoNames {
    <#  Derives every resource name from one prefix. APIM and Azure OpenAI names are
        globally unique, so keep the prefix distinctive.  #>
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Location,
        [string]$ResourceGroup
    )

    if ($Prefix -notmatch '^[a-z0-9][a-z0-9-]{2,20}$') {
        throw "Prefix must be 3-21 characters, lowercase letters, digits and hyphens: '$Prefix'"
    }

    [pscustomobject]@{
        Prefix          = $Prefix
        Location        = $Location
        ResourceGroup   = if ($ResourceGroup) { $ResourceGroup } else { "rg-$Prefix" }
        OpenAiName      = "$Prefix-aoai"
        ContentSafety   = "$Prefix-cs"
        DocIntelName    = "$Prefix-di"
        ApimName        = "$Prefix-apim"
        # API url suffixes inside APIM - these become part of the client base URL.
        AoaiApiPath     = 'aoai'
        SafetyApiPath   = 'contentsafety'
        DocIntelApiPath = 'docintel'
        SubscriptionName = "$Prefix-demo-app"
    }
}

function Save-DemoState {
    param([Parameter(Mandatory)][object]$State)
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath -Encoding utf8
    Write-Note "State saved to $script:StatePath"
}

function Get-DemoState {
    if (-not (Test-Path $script:StatePath)) {
        throw "No deployment state found at $script:StatePath. Run 01-provision-azure.ps1 first, or pass the parameters explicitly."
    }
    Get-Content $script:StatePath -Raw | ConvertFrom-Json
}

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}
