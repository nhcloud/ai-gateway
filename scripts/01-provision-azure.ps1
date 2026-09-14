<#
.SYNOPSIS
    Provisions the Azure resources the demo fronts: an Azure AI Foundry resource
    (with two model deployments), Content Safety, Document Intelligence, and APIM.

.DESCRIPTION
    Safe to re-run: every step checks for an existing resource first.

    Models are deployed into an Azure AI Foundry resource - `--kind AIServices` -
    rather than a standalone Azure OpenAI account. Foundry is the current shape for
    this: one resource, many model providers, and the same /openai/v1 surface the app
    already speaks. Deployment works identically either way.

    APIM on the Developer SKU takes 30-45 minutes to come up. The script kicks it off
    with --no-wait and moves on; 02-configure-apim.ps1 waits for it. Start this early.

.PARAMETER Prefix
    Short, globally distinctive name stem. Becomes <prefix>-foundry, <prefix>-apim, etc.

.PARAMETER SkipApim
    Provision only the AI services - useful if you already have an APIM instance, or
    if you only want to demo the direct route and the AI Gateway tier.

.EXAMPLE
    .\01-provision-azure.ps1 -Prefix nashuaug-demo -Location eastus -PublisherEmail you@contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublisherEmail,
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'eastus2',
    [string]$PublisherName = 'AI Gateway Demo',
    [string]$ChatModel = 'gpt-5.6-terra',
    [string]$EmbeddingModel = 'text-embedding-3-small',
    [int]$ChatCapacity = 30,
    [int]$EmbeddingCapacity = 30,
    [ValidateSet('Developer', 'Basic', 'Standard', 'Premium', 'BasicV2', 'StandardV2')]
    [string]$ApimSku = 'Developer',
    [switch]$SkipApim
)

. "$PSScriptRoot\00-common.ps1"

$account = Assert-AzureCli
$names = New-DemoNames -Prefix $Prefix -Location $Location -ResourceGroup $ResourceGroup

# ── resource group ────────────────────────────────────────────────────
# `az group create` looks idempotent but is not: on a group that already exists in
# another region it fails, because a resource group's location cannot be changed.
# So look first, and take an existing group as it is.
Write-Step "Resource group $($names.ResourceGroup)"
$group = Invoke-Az @('group', 'show', '--name', $names.ResourceGroup) -AllowFailure

if ($group) {
    Write-Ok "Already exists in $($group.location) - using it, nothing to create."

    if ($group.location -ne $Location) {
        if ($PSBoundParameters.ContainsKey('Location')) {
            # An explicit -Location wins: Azure is happy to put resources in a region
            # other than their group's, so this is a choice, not a mistake.
            Write-Warn "Group is in $($group.location) but -Location says $Location."
            Write-Warn "The new resources will go to $Location."
        }
        else {
            # No -Location was asked for, so follow the group rather than the default.
            $Location = $group.location
            $names.Location = $Location
            Write-Note "No -Location given; using $Location to match the group."
        }
    }
}
else {
    Invoke-Az @('group', 'create', '--name', $names.ResourceGroup, '--location', $Location) | Out-Null
    Write-Ok "Created in $Location."
}

# ── cognitive services accounts ───────────────────────────────────────
# Set-StrictMode -Version Latest turns a missing property into a terminating error,
# not $null, so reach for nested properties defensively.
function Get-CognitiveEndpoint {
    param($Account, [switch]$PreferOpenAi)

    if (-not $Account) { return '' }
    $properties = $Account.PSObject.Properties['properties']
    if (-not $properties -or -not $properties.Value) { return '' }
    $props = $properties.Value

    if ($PreferOpenAi) {
        # A Foundry resource advertises several endpoints; the app wants the one that
        # serves /openai/v1. Fall through to the general endpoint if it is not listed.
        $map = $props.PSObject.Properties['endpoints']
        if ($map -and $map.Value) {
            $openAi = $map.Value.PSObject.Properties |
                Where-Object { $_.Name -match 'OpenAI' -and $_.Value } |
                Select-Object -First 1
            if ($openAi) { return [string]$openAi.Value }
        }
    }

    $endpoint = $props.PSObject.Properties['endpoint']
    if (-not $endpoint) { return '' }
    return [string]$endpoint.Value
}

function New-CognitiveAccount {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Sku = 'S0'
    )

    $existing = Invoke-Az @('cognitiveservices', 'account', 'show',
        '--name', $Name, '-g', $names.ResourceGroup) -AllowFailure

    if ($existing) {
        Write-Ok "$Name already exists."
        return $existing
    }

    $created = Invoke-Az @('cognitiveservices', 'account', 'create',
        '--name', $Name, '-g', $names.ResourceGroup, '--location', $Location,
        '--kind', $Kind, '--sku', $Sku,
        # A custom subdomain is required for Azure OpenAI and harmless elsewhere.
        '--custom-domain', $Name,
        '--yes')

    Write-Ok "$Name created ($Kind)."

    # `create` already returns the account, so there is usually nothing to ask for.
    # Only re-read when the endpoint has not caught up yet.
    if (Get-CognitiveEndpoint $created) { return $created }
    Invoke-Az @('cognitiveservices', 'account', 'show', '--name', $Name, '-g', $names.ResourceGroup)
}

Write-Step "Azure AI Foundry: $($names.FoundryName)"
$foundry = New-CognitiveAccount -Name $names.FoundryName -Kind 'AIServices'

Write-Step "Content Safety: $($names.ContentSafety)"
$safety = New-CognitiveAccount -Name $names.ContentSafety -Kind 'ContentSafety'

Write-Step "Document Intelligence: $($names.DocIntelName)"
$docintel = New-CognitiveAccount -Name $names.DocIntelName -Kind 'FormRecognizer'

# ── model deployments ─────────────────────────────────────────────────
function New-ModelDeployment {
    param(
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][int]$Capacity
    )

    $existing = Invoke-Az @('cognitiveservices', 'account', 'deployment', 'show',
        '--name', $names.FoundryName, '-g', $names.ResourceGroup,
        '--deployment-name', $DeploymentName) -AllowFailure

    if ($existing) {
        Write-Ok "Deployment '$DeploymentName' already exists."
        return
    }

    # Available model versions differ by region, so ask rather than hard-code.
    $available = Invoke-Az @('cognitiveservices', 'model', 'list',
        '-l', $Location, '--query',
        "[?model.name=='$ModelName'].{version:model.version,sku:model.skus[0].name}",
        '-o', 'json') -AllowFailure

    if (-not $available) {
        Write-Warn "Model '$ModelName' is not offered in $Location. Deploy it by hand, or pick another region."
        return
    }

    $version = ($available | Select-Object -Last 1).version
    $skuName = ($available | Select-Object -Last 1).sku
    if (-not $skuName) { $skuName = 'Standard' }

    Invoke-Az @('cognitiveservices', 'account', 'deployment', 'create',
        '--name', $names.FoundryName, '-g', $names.ResourceGroup,
        '--deployment-name', $DeploymentName,
        '--model-name', $ModelName, '--model-version', $version, '--model-format', 'OpenAI',
        '--sku-name', $skuName, '--sku-capacity', $Capacity) | Out-Null

    Write-Ok "Deployed $ModelName v$version as '$DeploymentName' ($skuName, $Capacity K TPM)."
}

Write-Step "Model deployments"
New-ModelDeployment -DeploymentName $ChatModel -ModelName $ChatModel -Capacity $ChatCapacity
New-ModelDeployment -DeploymentName $EmbeddingModel -ModelName $EmbeddingModel -Capacity $EmbeddingCapacity

# ── APIM ──────────────────────────────────────────────────────────────
$apimCreated = $false
if (-not $SkipApim) {
    Write-Step "API Management: $($names.ApimName)"
    $existing = Invoke-Az @('apim', 'show', '--name', $names.ApimName, '-g', $names.ResourceGroup) -AllowFailure

    if ($existing) {
        Write-Ok "$($names.ApimName) already exists (state: $($existing.provisioningState))."
    }
    else {
        Invoke-Az @('apim', 'create',
            '--name', $names.ApimName, '-g', $names.ResourceGroup, '--location', $Location,
            '--publisher-email', $PublisherEmail, '--publisher-name', $PublisherName,
            '--sku-name', $ApimSku, '--no-wait') | Out-Null

        $apimCreated = $true
        Write-Ok "Creation started."
        Write-Warn "The $ApimSku SKU takes 30-45 minutes to activate. 02-configure-apim.ps1 will wait for it."
    }
}
else {
    Write-Note "Skipping APIM (-SkipApim)."
}

# ── state ─────────────────────────────────────────────────────────────
$endpoints = @{
    $names.FoundryName   = Get-CognitiveEndpoint $foundry -PreferOpenAi
    $names.ContentSafety = Get-CognitiveEndpoint $safety
    $names.DocIntelName  = Get-CognitiveEndpoint $docintel
}
foreach ($entry in $endpoints.GetEnumerator()) {
    if (-not $entry.Value) {
        throw "No endpoint came back for $($entry.Key). Check it in the portal, then re-run."
    }
}

$state = [pscustomobject]@{
    SubscriptionId   = $account.id
    Prefix           = $names.Prefix
    Location         = $Location
    ResourceGroup    = $names.ResourceGroup
    FoundryName      = $names.FoundryName
    FoundryEndpoint  = $endpoints[$names.FoundryName].TrimEnd('/')
    ContentSafety    = $names.ContentSafety
    SafetyEndpoint   = $endpoints[$names.ContentSafety].TrimEnd('/')
    DocIntelName     = $names.DocIntelName
    DocIntelEndpoint = $endpoints[$names.DocIntelName].TrimEnd('/')
    ApimName         = if ($SkipApim) { '' } else { $names.ApimName }
    AoaiApiPath      = $names.AoaiApiPath
    SafetyApiPath    = $names.SafetyApiPath
    DocIntelApiPath  = $names.DocIntelApiPath
    SubscriptionName = $names.SubscriptionName
    ChatModel        = $ChatModel
    EmbeddingModel   = $EmbeddingModel
    ApimPending      = $apimCreated
}

Save-DemoState -State $state

Write-Step 'Done'
Write-Host "  Azure AI Foundry     $($state.FoundryEndpoint)"
Write-Host "  Content Safety       $($state.SafetyEndpoint)"
Write-Host "  Document Intelligence $($state.DocIntelEndpoint)"
if (-not $SkipApim) {
    $apimNote = if ($apimCreated) { 'provisioning, 30-45 min' } else { 'already provisioned' }
    Write-Host "  APIM                 $($state.ApimName) ($apimNote)"
}
Write-Host ''
Write-Host "  Next: .\02-configure-apim.ps1" -ForegroundColor Cyan
