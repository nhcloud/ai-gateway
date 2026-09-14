<#
.SYNOPSIS
    Provisions the Azure resources the demo fronts: Azure OpenAI (with two model
    deployments), Content Safety, Document Intelligence, and an APIM instance.

.DESCRIPTION
    Safe to re-run: every step checks for an existing resource first.

    APIM on the Developer SKU takes 30-45 minutes to come up. The script kicks it off
    with --no-wait and moves on; 02-configure-apim.ps1 waits for it. Start this early.

.PARAMETER Prefix
    Short, globally distinctive name stem. Becomes <prefix>-aoai, <prefix>-apim, etc.

.PARAMETER SkipApim
    Provision only the AI services - useful if you already have an APIM instance, or
    if you only want to demo the direct route and the AI Gateway tier.

.EXAMPLE
    .\01-provision-azure.ps1 -Prefix nashuaug-demo -Location eastus -PublisherEmail you@contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [string]$Location = 'eastus',
    [string]$ResourceGroup,
    [Parameter(Mandatory)][string]$PublisherEmail,
    [string]$PublisherName = 'AI Gateway Demo',
    [string]$ChatModel = 'gpt-4o',
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
Write-Step "Resource group $($names.ResourceGroup)"
Invoke-Az @('group', 'create', '--name', $names.ResourceGroup, '--location', $Location) | Out-Null
Write-Ok "Ready."

# ── cognitive services accounts ───────────────────────────────────────
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

    Invoke-Az @('cognitiveservices', 'account', 'create',
        '--name', $Name, '-g', $names.ResourceGroup, '--location', $Location,
        '--kind', $Kind, '--sku', $Sku,
        # A custom subdomain is required for Azure OpenAI and harmless elsewhere.
        '--custom-domain', $Name,
        '--yes') | Out-Null

    Write-Ok "$Name created ($Kind)."
    Invoke-Az @('cognitiveservices', 'account', 'show', '--name', $Name, '-g', $names.ResourceGroup)
}

Write-Step "Azure OpenAI: $($names.OpenAiName)"
$openai = New-CognitiveAccount -Name $names.OpenAiName -Kind 'OpenAI'

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
        '--name', $names.OpenAiName, '-g', $names.ResourceGroup,
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
        '--name', $names.OpenAiName, '-g', $names.ResourceGroup,
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
$state = [pscustomobject]@{
    SubscriptionId   = $account.id
    Prefix           = $names.Prefix
    Location         = $Location
    ResourceGroup    = $names.ResourceGroup
    OpenAiName       = $names.OpenAiName
    OpenAiEndpoint   = $openai.properties.endpoint.TrimEnd('/')
    ContentSafety    = $names.ContentSafety
    SafetyEndpoint   = $safety.properties.endpoint.TrimEnd('/')
    DocIntelName     = $names.DocIntelName
    DocIntelEndpoint = $docintel.properties.endpoint.TrimEnd('/')
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
Write-Host "  Azure OpenAI         $($state.OpenAiEndpoint)"
Write-Host "  Content Safety       $($state.SafetyEndpoint)"
Write-Host "  Document Intelligence $($state.DocIntelEndpoint)"
if (-not $SkipApim) { Write-Host "  APIM                 $($state.ApimName) (provisioning)" }
Write-Host ''
Write-Host "  Next: .\02-configure-apim.ps1" -ForegroundColor Cyan
