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

# ── read native output as UTF-8 ────────────────────────────────────
# PowerShell decodes what a native command writes using [Console]::OutputEncoding,
# which on Windows PowerShell is the OEM code page. The Azure CLI emits UTF-8, so
# any non-ASCII in a resource name or an error message comes back as mojibake unless
# this is stated. Cosmetic, but it makes failures legible.
#
# This does NOT govern how az itself encodes its output, and it is not the fix for
# the 'charmap' codec can't encode character crash. az.cmd runs
#     python.exe -IBm azure.cli
# and -I is isolated mode, which implies -E: every PYTHON* environment variable is
# discarded before the CLI starts, PYTHONIOENCODING included. Setting it here would
# look like a fix and do nothing. When az has to print a body Azure sent with a BOM,
# the answer is --output-file at the call site - see Invoke-ArmPut in 02.
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
}
catch {
    # A redirected or non-interactive host may refuse; nothing here depends on it.
    Write-Verbose "Could not set the console to UTF-8: $($_.Exception.Message)"
}

$script:StatePath = Join-Path $PSScriptRoot '.deploy.json'

function Set-Utf8NoBom {
    <#
    .SYNOPSIS
        Writes text as UTF-8 with no byte-order mark.

    .DESCRIPTION
        Windows PowerShell 5.1 writes a BOM for `-Encoding utf8`; PowerShell 7 does not.
        Anything that reads the file with a plain UTF-8 decoder then chokes on it, and
        the failure is nowhere near the cause. The Azure CLI, for one:

          az rest --body @file
          -> Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)

        So never leave the encoding to the host: write the bytes explicitly.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

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

    # Through Invoke-Az, so the stderr handling below applies here too.
    $account = Invoke-Az @('account', 'show') -AllowFailure
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

    # $ErrorActionPreference must drop to Continue around the call. In Windows
    # PowerShell, a native command that writes ANYTHING to stderr raises a terminating
    # NativeCommandError while the preference is Stop - even when it exited 0. The CLI
    # writes warnings to stderr routinely, so with Stop in force an "already exists"
    # check blows up instead of returning, and nothing gets skipped. The exit code is
    # the only thing worth trusting here.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

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
        # An Azure AI Foundry resource (kind AIServices), which is what hosts
        # model deployments now - a standalone kind=OpenAI account is the old shape.
        FoundryName     = "$Prefix-foundry"
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
    Set-Utf8NoBom -Path $script:StatePath -Content ($State | ConvertTo-Json -Depth 6)
    Write-Note "State saved to $script:StatePath"
}

function Get-DemoState {
    if (-not (Test-Path $script:StatePath)) {
        throw "No deployment state found at $script:StatePath. Run 01-provision-azure.ps1 first, or pass the parameters explicitly."
    }
    Get-Content $script:StatePath -Raw | ConvertFrom-Json
}

function Get-EnvFilePath {
    <#
    .SYNOPSIS
        The single answer to "where is the .env".

    .DESCRIPTION
        03-set-local-env.ps1 writes python\.env, because that is the file the Python
        app actually reads - it takes its own folder ahead of any repo-root file. The
        location lives here rather than in each script so that a change to it cannot
        leave one script writing where another is still looking, which is exactly what
        happened when 04 kept reading the repo root after 03 had moved on.

    .PARAMETER Existing
        Returns the first file that exists, including the retired repo-root location,
        so a .env from an older run is still found instead of reported missing.
        Returns an empty string when there is none. Without it, returns where a new
        file should be written.
    #>
    param([switch]$Existing)

    $repo = Get-RepoRoot
    $stackLocal = Join-Path $repo 'python' | Join-Path -ChildPath '.env'
    if (-not $Existing) { return $stackLocal }

    foreach ($candidate in @($stackLocal, (Join-Path $repo '.env'))) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return ''
}

function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}
