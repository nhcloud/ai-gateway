<#
.SYNOPSIS
    Proves the gateway works on its own, before any application is wired to it.

.DESCRIPTION
    A 200 completion confirms four things at once: the subscription key is valid, the
    model name resolves, no policy blocked the call, and the backend credential works.

    The script also reproduces, on purpose, the two failures from the troubleshooting
    slide, so the status-code-to-stage mapping can be demonstrated live:
      * an undefined path            -> 404 at the gateway, before any policy runs
      * the key under the wrong header -> 401, because APIM never saw an api-key

    Equivalent curl for the happy path:
      curl -X POST "https://<host>.azure-api.net/aoai/openai/v1/chat/completions" \
        -H "api-key: <SUBSCRIPTION-KEY>" -H "Content-Type: application/json" \
        -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

.EXAMPLE
    .\04-test-gateway.ps1
    .\04-test-gateway.ps1 -SkipDocumentIntelligence
#>
[CmdletBinding()]
param(
    [string]$EnvFile,
    [switch]$SkipDocumentIntelligence,
    [switch]$SkipNegativeTests
)

. "$PSScriptRoot\00-common.ps1"

# ── config from .env (no Azure sign-in needed for this script) ─────────
if (-not $EnvFile) { $EnvFile = Join-Path (Get-RepoRoot) '.env' }
if (-not (Test-Path $EnvFile)) { throw "No .env at $EnvFile. Run 03-set-local-env.ps1 first." }

$cfg = @{}
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $key, $value = $line -split '=', 2
    $cfg[$key.Trim()] = $value.Trim()
}

function Get-Cfg { param([string]$Key) if ($cfg.ContainsKey($Key)) { $cfg[$Key] } else { '' } }

$script:Passed = 0
$script:Failed = 0

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        $detail = & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green -NoNewline
        Write-Host $(if ($detail) { "  $detail" } else { '' }) -ForegroundColor DarkGray
    }
    catch {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Invoke-Gateway {
    <#  Returns the raw response so status codes can be asserted, errors included.  #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'POST',
        [hashtable]$Headers = @{},
        [string]$Body
    )
    $params = @{
        Uri                = $Uri
        Method             = $Method
        Headers            = $Headers
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    if ($Body) {
        $params.Body = $Body
        $params.ContentType = 'application/json'
    }
    Invoke-WebRequest @params
}

# ── chat completion ─────────────────────────────────────────
# One connection. Whether AI_ENDPOINT is the provider, a classic APIM instance or
# the AI Gateway tier, the request below is byte for byte the same.
$aiEndpoint = Get-Cfg 'AI_ENDPOINT'
$aiKey = Get-Cfg 'AI_KEY'
$aiHeader = $(if (Get-Cfg 'AI_KEY_HEADER') { Get-Cfg 'AI_KEY_HEADER' } else { 'api-key' })
$aiModel = $(if (Get-Cfg 'AI_CHAT_MODEL') { Get-Cfg 'AI_CHAT_MODEL' } else { 'gpt-4o' })

if (-not $aiEndpoint -or -not $aiKey) {
    throw "AI_ENDPOINT and AI_KEY must both be set in $EnvFile. Run 03-set-local-env.ps1."
}

$chatBase = if ($aiEndpoint -match '/openai/v1/?$') {
    $aiEndpoint.TrimEnd('/')
} else {
    "$($aiEndpoint.TrimEnd('/'))/openai/v1"
}

# Same derivation the apps use, so the script reports the same thing the page does.
$mode =
    if ($aiEndpoint -match '^https?://[^/]*\.azure-api\.net') {
        $path = ([Uri]$aiEndpoint).AbsolutePath.Trim('/') -split '/'
        if ($path.Count -ge 2 -and $path[1] -eq 'models') { 'aigateway' } else { 'apim' }
    }
    elseif ($aiEndpoint -match '\.(openai\.azure\.com|cognitiveservices\.azure\.com|services\.ai\.azure\.com)') { 'direct' }
    else { 'custom' }

Write-Step "Chat completions  (derived mode: $mode)"
Write-Note "$chatBase/chat/completions"

Test-Case 'Model responds with 200' {
    $body = @{
        model    = $aiModel
        messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' })
        max_tokens = 16
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-Gateway -Uri "$chatBase/chat/completions" `
        -Headers @{ $aiHeader = $aiKey; 'x-correlation-id' = "smoke-$(Get-Random)" } -Body $body

    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode): $($response.Content)"
    }

    $json = $response.Content | ConvertFrom-Json
    $reply = $json.choices[0].message.content
    $tokens = $json.usage.total_tokens
    $remaining = $response.Headers['x-ratelimit-remaining-tokens']
    "$tokens tokens; reply '$($reply.Trim())'" + $(if ($remaining) { "; budget left $remaining" } else { '' })
}

Test-Case 'Embeddings respond with 200' {
    $body = @{
        model = $(if (Get-Cfg 'AI_EMBEDDING_MODEL') { Get-Cfg 'AI_EMBEDDING_MODEL' } else { 'text-embedding-3-small' })
        input = @('gateway smoke test')
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-Gateway -Uri "$chatBase/embeddings" `
        -Headers @{ $aiHeader = $aiKey } -Body $body

    if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode): $($response.Content)" }
    $vector = ($response.Content | ConvertFrom-Json).data[0].embedding
    "$($vector.Count) dimensions"
}

# ── content safety ────────────────────────────────────────────────────
Write-Step 'Content Safety guardrail'
# The endpoint may be the resource or the gateway's path for it; the key header
# follows from which one it is, exactly as the apps infer it.
$safetyBase = Get-Cfg 'CONTENT_SAFETY_ENDPOINT'
$safetyKey = Get-Cfg 'CONTENT_SAFETY_KEY'
$safetyHeader = if (Get-Cfg 'CONTENT_SAFETY_KEY_HEADER') { Get-Cfg 'CONTENT_SAFETY_KEY_HEADER' }
                elseif ($safetyBase -like '*.azure-api.net*') { $aiHeader }
                else { 'Ocp-Apim-Subscription-Key' }

if ($safetyBase -and $safetyKey) {
    Test-Case 'text:analyze returns four category severities' {
        $body = @{ text = 'Good morning, how do I reset my password?'
                   categories = @('Hate', 'SelfHarm', 'Sexual', 'Violence')
                   outputType = 'FourSeverityLevels' } | ConvertTo-Json -Compress

        $response = Invoke-Gateway -Uri "$($safetyBase.TrimEnd('/'))/contentsafety/text:analyze?api-version=2024-09-01" `
            -Headers @{ $safetyHeader = $safetyKey } -Body $body

        if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode): $($response.Content)" }
        $analysis = ($response.Content | ConvertFrom-Json).categoriesAnalysis
        if ($analysis.Count -lt 4) { throw "Expected 4 categories, got $($analysis.Count)" }
        "max severity $(($analysis.severity | Measure-Object -Maximum).Maximum) on benign text"
    }
}
else {
    Write-Host '  SKIP  Content Safety not configured' -ForegroundColor DarkGray
}

# ── document intelligence ─────────────────────────────────────────────
Write-Step 'Document Intelligence'
$diBase = Get-Cfg 'DOC_INTEL_ENDPOINT'
$diKey = Get-Cfg 'DOC_INTEL_KEY'
$diHeader = if (Get-Cfg 'DOC_INTEL_KEY_HEADER') { Get-Cfg 'DOC_INTEL_KEY_HEADER' }
            elseif ($diBase -like '*.azure-api.net*') { $aiHeader }
            else { 'Ocp-Apim-Subscription-Key' }

if (-not $SkipDocumentIntelligence -and $diBase -and $diKey) {
    Test-Case '202 + Operation-Location pointing at the gateway' {
        # A real one-page PDF would be better; a public sample keeps the script small.
        $body = @{ urlSource = 'https://raw.githubusercontent.com/Azure-Samples/cognitive-services-REST-api-samples/master/curl/form-recognizer/sample-layout.pdf' } |
            ConvertTo-Json -Compress

        $uri = "$($diBase.TrimEnd('/'))/documentintelligence/documentModels/prebuilt-layout:analyze" +
               '?api-version=2024-11-30&outputContentFormat=markdown'
        $response = Invoke-Gateway -Uri $uri -Headers @{ $diHeader = $diKey } -Body $body

        if ($response.StatusCode -ne 202) { throw "Expected 202, got $($response.StatusCode): $($response.Content)" }

        $location = $response.Headers['Operation-Location']
        if (-not $location) { throw 'No Operation-Location header returned.' }

        $pollHost = ([Uri]($location -join '')).Host
        $expected = ([Uri]$diBase).Host

        if ($pollHost -ne $expected) {
            throw "Operation-Location points at $pollHost, not $expected. " +
                  'The outbound rewrite policy is missing, so a client following it would get a 401.'
        }
        "polling stays on $pollHost"
    }
}
else {
    Write-Host '  SKIP  Document Intelligence' -ForegroundColor DarkGray
}

# ── the two classic failures, on purpose ──────────────────────────────
if (-not $SkipNegativeTests -and $chatBase -like '*.azure-api.net*') {
    Write-Step 'Reproducing the two classic failures'

    Test-Case '404 - a path with no matching operation' {
        $response = Invoke-Gateway -Uri "$chatBase/chat/completions/not-an-operation" `
            -Headers @{ $aiHeader = $aiKey } -Body '{}'
        if ($response.StatusCode -ne 404) { throw "Expected 404, got $($response.StatusCode)" }
        'path problem, not policy - matching happens before any policy runs'
    }

    Test-Case '401 - the key sent under the wrong header' {
        # What every SDK does by default: Authorization: Bearer <key>.
        $response = Invoke-Gateway -Uri "$chatBase/chat/completions" `
            -Headers @{ 'Authorization' = "Bearer $aiKey" } `
            -Body '{"model":"x","messages":[{"role":"user","content":"hi"}]}'
        if ($response.StatusCode -ne 401) { throw "Expected 401, got $($response.StatusCode)" }
        "APIM never saw a key in '$aiHeader'"
    }
}
elseif (-not $SkipNegativeTests) {
    Write-Note 'Skipping the 404/401 demonstrations - they need a gateway endpoint.'
}

# ── summary ───────────────────────────────────────────────────────────
Write-Step 'Summary'
Write-Host "  $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
Write-Host ''
Write-Host '  Status code -> stage:' -ForegroundColor Cyan
Write-Host '    401 / 403  the gateway - bad subscription key, or the backend credential'
Write-Host '    404        a path problem - undefined operation or wrong suffix'
Write-Host '    429        a policy - a token or rate limit was hit'
Write-Host '    400        content safety, a malformed body, or the provider'
Write-Host '    5xx        often the provider or the deployment - confirm with the APIM trace'

if ($script:Failed) { exit 1 }
