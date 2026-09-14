<#
.SYNOPSIS
    Copies the shared front end from python\static to the Razor app, and checks they match.

.DESCRIPTION
    app.js and app.css are byte-identical in both implementations - that is the point:
    one page, one JSON contract, two back ends. python\static is the source of truth.
    Pages\Index.cshtml is the same markup as index.html with a two-line Razor header.

    Run it after editing anything in python\static, or with -Check in CI.

.EXAMPLE
    .\sync-frontend.ps1
    .\sync-frontend.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

. "$PSScriptRoot\00-common.ps1"

$root = Get-RepoRoot
$source = Join-Path $root 'python\static'
$wwwroot = Join-Path $root 'dotnet\AiGatewayDemo\wwwroot'
$razorPage = Join-Path $root 'dotnet\AiGatewayDemo\Pages\Index.cshtml'
$razorHeader = @('@page', '@{ Layout = null; }')

$drift = @()

function Test-Same {
    param([string]$Label, [string[]]$Expected, [string]$Path)

    if (-not (Test-Path $Path)) { return "$Label is missing" }
    $actual = Get-Content $Path
    if (Compare-Object $Expected $actual -SyncWindow 0) { return "$Label differs" }
    return $null
}

# ── app.js / app.css ──────────────────────────────────────────────────
foreach ($name in @('app.js', 'app.css')) {
    $from = Join-Path $source $name
    $to = Join-Path $wwwroot $name
    $issue = Test-Same -Label $name -Expected (Get-Content $from) -Path $to

    if (-not $issue) {
        Write-Ok "$name in sync"
        continue
    }

    if ($Check) { $drift += $issue; Write-Warn $issue }
    else {
        Copy-Item $from $to -Force
        Write-Ok "$name copied"
    }
}

# ── index.html -> Index.cshtml ────────────────────────────────────────
$expected = $razorHeader + (Get-Content (Join-Path $source 'index.html'))
$issue = Test-Same -Label 'Index.cshtml' -Expected $expected -Path $razorPage

if (-not $issue) {
    Write-Ok 'Index.cshtml in sync'
}
elseif ($Check) {
    $drift += $issue
    Write-Warn $issue
}
else {
    $expected | Set-Content -Path $razorPage -Encoding utf8
    Write-Ok 'Index.cshtml regenerated'
}

if ($Check -and $drift) {
    Write-Host ''
    Write-Host 'Front end has drifted. Run .\sync-frontend.ps1 without -Check.' -ForegroundColor Red
    exit 1
}
