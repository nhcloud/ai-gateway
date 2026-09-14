<#
.SYNOPSIS
    Wires the three AI services behind APIM: named values, backends, APIs, operations,
    policies and one subscription key for the demo app.

.DESCRIPTION
    Creates, in the APIM instance from 01-provision-azure.ps1:

      named values   aoai-key, contentsafety-key, docintel-key (secret), docintel-host
      backend        content-safety-backend  (only used by the llm-content-safety policy)
      API  aoai          -> Azure OpenAI,  operations for chat/completions and embeddings
      API  contentsafety -> Content Safety, wildcard
      API  docintel      -> Document Intelligence, wildcard + Operation-Location rewrite
      subscription   one key, scoped to all APIs - the only secret the app ever holds

    The subscription key header is named api-key, matching what the portal's Azure AI
    Foundry import produces, because that naming is the single most common cause of a
    401 in this pattern.

    Everything is done with `az rest` against the ARM API rather than `az apim ...`
    convenience commands, so the exact shape of each object is visible and the script
    does not drift between CLI versions.

.PARAMETER EnableContentSafetyPolicy
    Applies the variant Azure OpenAI policy that moderates prompts at the gateway with
    llm-content-safety. The demo app also screens client-side so it can show severities;
    turning this on means two checks, so pick one for production.

.EXAMPLE
    .\02-configure-apim.ps1
    .\02-configure-apim.ps1 -EnableContentSafetyPolicy -TokensPerMinute 2000
#>
[CmdletBinding()]
param(
    [string]$ApimName,
    [string]$ResourceGroup,
    [int]$TokensPerMinute = 10000,
    [switch]$EnableContentSafetyPolicy,
    [string]$ApiVersion = '2024-05-01',
    [int]$ApimWaitMinutes = 60
)

. "$PSScriptRoot\00-common.ps1"

Assert-AzureCli | Out-Null
$state = Get-DemoState

if ($ApimName) { $state.ApimName = $ApimName }
if ($ResourceGroup) { $state.ResourceGroup = $ResourceGroup }
if (-not $state.ApimName) { throw "No APIM instance recorded. Re-run 01-provision-azure.ps1 without -SkipApim." }

$base = "https://management.azure.com/subscriptions/$($state.SubscriptionId)" +
        "/resourceGroups/$($state.ResourceGroup)/providers/Microsoft.ApiManagement/service/$($state.ApimName)"

function Invoke-ArmPut {
    <#  PUTs a JSON body to an ARM path relative to the APIM service.  #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Body,
        [string]$Version = $ApiVersion
    )

    $file = New-TemporaryFile
    try {
        $Body | ConvertTo-Json -Depth 12 | Set-Content -Path $file -Encoding utf8
        Invoke-Az @('rest', '--method', 'put',
            '--url', "$base$Path`?api-version=$Version",
            '--headers', 'Content-Type=application/json',
            '--body', "@$file") | Out-Null
    }
    finally {
        Remove-Item $file -ErrorAction SilentlyContinue
    }
}

# ── wait for APIM ─────────────────────────────────────────────────────
Write-Step "Waiting for $($state.ApimName) to finish provisioning"
$deadline = (Get-Date).AddMinutes($ApimWaitMinutes)
while ($true) {
    $apim = Invoke-Az @('apim', 'show', '--name', $state.ApimName, '-g', $state.ResourceGroup) -AllowFailure
    if ($apim -and $apim.provisioningState -eq 'Succeeded') {
        Write-Ok "Ready at $($apim.gatewayUrl)"
        break
    }
    if ((Get-Date) -gt $deadline) {
        throw "APIM was still '$(if ($apim) { $apim.provisioningState } else { 'missing' })' after $ApimWaitMinutes minutes."
    }
    Write-Note "State: $(if ($apim) { $apim.provisioningState } else { 'creating' }) - checking again in 60s"
    Start-Sleep -Seconds 60
}
$gatewayUrl = $apim.gatewayUrl.TrimEnd('/')

# ── keys from the AI resources ────────────────────────────────────────
Write-Step 'Reading resource keys'
function Get-ResourceKey {
    param([Parameter(Mandatory)][string]$Name)
    (Invoke-Az @('cognitiveservices', 'account', 'keys', 'list',
        '--name', $Name, '-g', $state.ResourceGroup)).key1
}

$aoaiKey = Get-ResourceKey -Name $state.OpenAiName
$safetyKey = Get-ResourceKey -Name $state.ContentSafety
$docIntelKey = Get-ResourceKey -Name $state.DocIntelName
Write-Ok 'Collected. These stay inside the gateway from here on.'

# ── named values ──────────────────────────────────────────────────────
Write-Step 'Named values'
function Set-NamedValue {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Value,
        [switch]$Secret
    )
    Invoke-ArmPut -Path "/namedValues/$Id" -Body @{
        properties = @{
            displayName = $Id
            value       = $Value
            secret      = [bool]$Secret
        }
    }
    Write-Ok "$Id$(if ($Secret) { ' (secret)' })"
}

# In production, back these with Key Vault instead so rotation is automatic:
#   properties.keyVault = @{ secretIdentifier = 'https://<vault>.vault.azure.net/secrets/aoai-key' }
Set-NamedValue -Id 'aoai-key' -Value $aoaiKey -Secret
Set-NamedValue -Id 'contentsafety-key' -Value $safetyKey -Secret
Set-NamedValue -Id 'docintel-key' -Value $docIntelKey -Secret
Set-NamedValue -Id 'docintel-host' -Value ([Uri]$state.DocIntelEndpoint).Host

# ── backend for the llm-content-safety policy ─────────────────────────
Write-Step 'Content Safety backend'
Invoke-ArmPut -Path '/backends/content-safety-backend' -Body @{
    properties = @{
        description = 'Azure AI Content Safety, used by the llm-content-safety policy'
        url         = $state.SafetyEndpoint
        protocol    = 'http'
        credentials = @{
            header = @{ 'Ocp-Apim-Subscription-Key' = @('{{contentsafety-key}}') }
        }
    }
}
Write-Ok 'content-safety-backend'

# ── APIs ──────────────────────────────────────────────────────────────
function Set-Api {
    param(
        [Parameter(Mandatory)][string]$ApiId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ServiceUrl,
        [string]$Description = ''
    )
    Invoke-ArmPut -Path "/apis/$ApiId" -Body @{
        properties = @{
            displayName          = $DisplayName
            description          = $Description
            path                 = $Path
            serviceUrl           = $ServiceUrl
            protocols            = @('https')
            subscriptionRequired = $true
            # The Foundry import names this api-key rather than the default
            # Ocp-Apim-Subscription-Key. Match it, and tell your clients.
            subscriptionKeyParameterNames = @{ header = 'api-key'; query = 'api-key' }
        }
    }
    Write-Ok "$DisplayName  ->  $gatewayUrl/$Path"
}

function Set-Operation {
    param(
        [Parameter(Mandatory)][string]$ApiId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$UrlTemplate
    )
    Invoke-ArmPut -Path "/apis/$ApiId/operations/$OperationId" -Body @{
        properties = @{
            displayName = $DisplayName
            method      = $Method
            urlTemplate = $UrlTemplate
            # The path segment lives here OR in the backend URL - never both, or the
            # backend sees .../chat/completions/chat/completions.
            templateParameters = @()
        }
    }
    Write-Note "$Method $UrlTemplate"
}

function Set-ApiPolicy {
    param(
        [Parameter(Mandatory)][string]$ApiId,
        [Parameter(Mandatory)][string]$PolicyFile
    )
    $xml = Get-Content -Path (Join-Path $PSScriptRoot "policies\$PolicyFile") -Raw
    $xml = $xml -replace 'tokens-per-minute="10000"', "tokens-per-minute=`"$TokensPerMinute`""

    Invoke-ArmPut -Path "/apis/$ApiId/policies/policy" -Body @{
        properties = @{ format = 'rawxml'; value = $xml }
    }
    Write-Ok "Policy applied: $PolicyFile"
}

Write-Step 'API: Azure OpenAI'
Set-Api -ApiId 'aoai' -DisplayName 'Azure OpenAI' -Path $state.AoaiApiPath `
    -ServiceUrl $state.OpenAiEndpoint `
    -Description 'Chat completions and embeddings, fronted by the gateway.'

# APIM routes only to defined operations - an undefined path 404s at the gateway
# before any policy runs. The two the demo calls are declared explicitly; the
# wildcards cover everything else on the v1 surface.
Set-Operation -ApiId 'aoai' -OperationId 'chat-completions' -DisplayName 'Chat completions' `
    -Method 'POST' -UrlTemplate '/openai/v1/chat/completions'
Set-Operation -ApiId 'aoai' -OperationId 'embeddings' -DisplayName 'Embeddings' `
    -Method 'POST' -UrlTemplate '/openai/v1/embeddings'
Set-Operation -ApiId 'aoai' -OperationId 'catch-all-post' -DisplayName 'Any POST' `
    -Method 'POST' -UrlTemplate '/*'
Set-Operation -ApiId 'aoai' -OperationId 'catch-all-get' -DisplayName 'Any GET' `
    -Method 'GET' -UrlTemplate '/*'

Set-ApiPolicy -ApiId 'aoai' -PolicyFile $(
    if ($EnableContentSafetyPolicy) { 'aoai-api-content-safety.xml' } else { 'aoai-api.xml' })

Write-Step 'API: Content Safety'
Set-Api -ApiId 'contentsafety' -DisplayName 'Content Safety' -Path $state.SafetyApiPath `
    -ServiceUrl $state.SafetyEndpoint `
    -Description 'Text and image moderation, fronted by the gateway.'
Set-Operation -ApiId 'contentsafety' -OperationId 'catch-all-post' -DisplayName 'Any POST' `
    -Method 'POST' -UrlTemplate '/*'
Set-ApiPolicy -ApiId 'contentsafety' -PolicyFile 'contentsafety-api.xml'

Write-Step 'API: Document Intelligence'
Set-Api -ApiId 'docintel' -DisplayName 'Document Intelligence' -Path $state.DocIntelApiPath `
    -ServiceUrl $state.DocIntelEndpoint `
    -Description 'Analyze and poll, with Operation-Location rewritten to the gateway.'
# A wildcard passes path and query through unchanged, so every model and route works.
Set-Operation -ApiId 'docintel' -OperationId 'catch-all-post' -DisplayName 'Any POST' `
    -Method 'POST' -UrlTemplate '/*'
Set-Operation -ApiId 'docintel' -OperationId 'catch-all-get' -DisplayName 'Any GET' `
    -Method 'GET' -UrlTemplate '/*'
Set-ApiPolicy -ApiId 'docintel' -PolicyFile 'docintel-api.xml'

# ── subscription ──────────────────────────────────────────────────────
Write-Step 'Subscription key for the demo app'
$subscriptionId = 'demo-app'
Invoke-ArmPut -Path "/subscriptions/$subscriptionId" -Body @{
    properties = @{
        # Scoped to all APIs, so one key reaches models, safety and documents.
        # Issue one subscription per app per environment; revoke it without touching
        # a single provider credential.
        scope       = "$base/apis"
        displayName = $state.SubscriptionName
        state       = 'active'
    }
}

$secrets = Invoke-Az @('rest', '--method', 'post',
    '--url', "$base/subscriptions/$subscriptionId/listSecrets?api-version=$ApiVersion")
$subscriptionKey = $secrets.primaryKey
Write-Ok "Issued."

# ── state ─────────────────────────────────────────────────────────────
$state | Add-Member -NotePropertyName GatewayUrl -NotePropertyValue $gatewayUrl -Force
$state | Add-Member -NotePropertyName SubscriptionKey -NotePropertyValue $subscriptionKey -Force
$state | Add-Member -NotePropertyName ApimPending -NotePropertyValue $false -Force
Save-DemoState -State $state

Write-Step 'Done'
Write-Host "  Models      $gatewayUrl/$($state.AoaiApiPath)/openai/v1"
Write-Host "  Safety      $gatewayUrl/$($state.SafetyApiPath)"
Write-Host "  Documents   $gatewayUrl/$($state.DocIntelApiPath)"
Write-Host "  Auth header api-key: $($subscriptionKey.Substring(0,6))..."
Write-Host ''
Write-Host "  Next: .\03-set-local-env.ps1" -ForegroundColor Cyan
