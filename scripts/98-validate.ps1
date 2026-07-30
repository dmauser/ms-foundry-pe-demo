###############################################################################
# 98-validate.ps1 — Read-only network validation for all three scenarios.
#
# Asserts the *intended* network posture (public access disabled, private
# endpoints approved, DNS zones linked, subnet delegations, NSP profile/rules)
# and prints a PASS / FAIL / SKIP table. Makes NO changes — safe on a live lab.
#
# Usage:
#   pwsh scripts/98-validate.ps1                  # every deployed scenario
#   pwsh scripts/98-validate.ps1 -Scenario 3      # only Scenario 3
#   pwsh scripts/98-validate.ps1 -Scenario 1 -Suffix abcde
#   pwsh scripts/98-validate.ps1 -Scenario 3 -ResourceGroup rg-foundry-agent-<suffix>
#
# Exit code is non-zero if any CRITICAL check FAILs. A scenario whose suffix
# file / resource group is absent is reported SKIP (not a failure).
###############################################################################

[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', 'all')]
    [string]$Scenario = 'all',
    [string]$Suffix,
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Continue'
$ScriptDir = $PSScriptRoot

# Resolve the real az CLI once. The helper below is named `Az`, and PowerShell
# resolves command names case-insensitively, so calling `az` inside it would
# recurse into the function. Bind to the actual executable to avoid that.
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
if (-not $script:AzExe) {
    Write-Host 'Azure CLI (az) not found on PATH. Install it and run: az login' -ForegroundColor Red
    exit 2
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:CriticalFail = $false

function Add-Result {
    param(
        [string]$Scenario,
        [string]$Check,
        [ValidateSet('PASS', 'FAIL', 'SKIP', 'WARN')][string]$Status,
        [string]$Detail = '',
        [switch]$Critical
    )
    $script:Results.Add([pscustomobject]@{
            Scenario = $Scenario; Check = $Check; Status = $Status; Detail = $Detail
        })
    if ($Status -eq 'FAIL' -and $Critical) { $script:CriticalFail = $true }
}

# Run an az query, return trimmed stdout ('' on any error). Read-only by contract.
# Plain (non-advanced) function so tokens like -o/-g are passed through to az via
# $args instead of being bound to PowerShell common parameters.
function Az {
    $out = & $script:AzExe @args 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($out | Out-String).Trim()
}

function Test-Rg {
    param([string]$Rg)
    return (Az group exists --name $Rg) -eq 'true'
}

function Read-Suffix {
    param([string]$FileName)
    $p = Join-Path $ScriptDir $FileName
    if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    return ''
}

# ---------------------------------------------------------------------------
# Scenario 1 — Private Endpoint + VNet Integration
# ---------------------------------------------------------------------------
function Validate-Scenario1 {
    $sfx = if ($Suffix) { $Suffix } else { Read-Suffix '.deploy-suffix' }
    $rg = if ($ResourceGroup) { $ResourceGroup } elseif ($sfx) { "rg-foundry-demo-$sfx" } else { '' }

    if (-not $rg -or -not (Test-Rg $rg)) {
        Add-Result 'S1' 'Deployment present' 'SKIP' 'no .deploy-suffix / resource group — not deployed'
        return
    }
    $ai = "foundry-demo-ai-$sfx"
    $app = "foundry-demo-app-$sfx"
    $vnet = "foundry-demo-vnet-$sfx"

    $pna = Az cognitiveservices account show -g $rg -n $ai --query properties.publicNetworkAccess -o tsv
    if ($pna -eq 'Disabled') { Add-Result 'S1' 'Foundry publicNetworkAccess' 'PASS' $pna }
    elseif ($pna) { Add-Result 'S1' 'Foundry publicNetworkAccess' 'FAIL' "$pna (expected Disabled)" -Critical }
    else { Add-Result 'S1' 'Foundry publicNetworkAccess' 'SKIP' "account $ai not found" }

    $peState = Az network private-endpoint list -g $rg --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv
    if ($peState -match 'Approved') { Add-Result 'S1' 'Private endpoint approved' 'PASS' 'Approved' }
    elseif ($peState) { Add-Result 'S1' 'Private endpoint approved' 'FAIL' $peState -Critical }
    else { Add-Result 'S1' 'Private endpoint approved' 'FAIL' 'no private endpoint found' -Critical }

    $zone = 'privatelink.cognitiveservices.azure.com'
    $link = Az network private-dns link vnet list -g $rg -z $zone --query "[].virtualNetwork.id" -o tsv
    if ($link -match [regex]::Escape($vnet)) { Add-Result 'S1' 'Private DNS zone linked to VNet' 'PASS' $zone }
    elseif ($link) { Add-Result 'S1' 'Private DNS zone linked to VNet' 'WARN' "linked to a different vnet" }
    else { Add-Result 'S1' 'Private DNS zone linked to VNet' 'SKIP' "$zone not found" }

    $arec = Az network private-dns record-set a list -g $rg -z $zone --query "[].aRecords[].ipv4Address" -o tsv
    if ($arec -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { Add-Result 'S1' 'DNS A-record is private' 'PASS' ($arec -split '\r?\n')[0] }
    elseif ($arec) { Add-Result 'S1' 'DNS A-record is private' 'WARN' $arec }
    else { Add-Result 'S1' 'DNS A-record is private' 'SKIP' 'no A record yet' }

    $subnetId = Az webapp show -g $rg -n $app --query virtualNetworkSubnetId -o tsv
    if ($subnetId) { Add-Result 'S1' 'App Service VNet integration' 'PASS' (($subnetId -split '/')[-1]) }
    else { Add-Result 'S1' 'App Service VNet integration' 'FAIL' 'not integrated' -Critical }

    $routeAll = Az webapp config show -g $rg -n $app --query vnetRouteAllEnabled -o tsv
    if ($routeAll -eq 'true') { Add-Result 'S1' 'Route-all outbound enabled' 'PASS' 'true' }
    elseif ($routeAll) { Add-Result 'S1' 'Route-all outbound enabled' 'WARN' $routeAll }
    else { Add-Result 'S1' 'Route-all outbound enabled' 'SKIP' 'app not found' }
}

# ---------------------------------------------------------------------------
# Scenario 2 — Network Security Perimeter + Managed Identity
# ---------------------------------------------------------------------------
function Validate-Scenario2 {
    $sfx = if ($Suffix) { $Suffix } else { Read-Suffix '.deploy-suffix' }
    $rg = if ($ResourceGroup) { $ResourceGroup } elseif ($sfx) { "rg-foundry-demo-$sfx" } else { '' }

    if (-not $rg -or -not (Test-Rg $rg)) {
        Add-Result 'S2' 'Deployment present' 'SKIP' 'no .deploy-suffix / resource group — not deployed'
        return
    }
    $ai = "foundry-demo-ai-$sfx"
    $nspApp = "foundry-demo-nsp-app-$sfx"
    $nsp = "foundry-demo-nsp-$sfx"
    $law = "foundry-demo-law-$sfx"

    $pna = Az cognitiveservices account show -g $rg -n $ai --query properties.publicNetworkAccess -o tsv
    if ($pna -eq 'Disabled') { Add-Result 'S2' 'Foundry publicNetworkAccess' 'PASS' $pna }
    elseif ($pna) { Add-Result 'S2' 'Foundry publicNetworkAccess' 'FAIL' "$pna (expected Disabled)" -Critical }
    else { Add-Result 'S2' 'Foundry publicNetworkAccess' 'SKIP' "account $ai not found — NSP scenario may not be applied" }

    $nspNames = Az network perimeter list -g $rg --query "[].name" -o tsv
    if ($nspNames -match [regex]::Escape($nsp)) {
        Add-Result 'S2' 'Network Security Perimeter exists' 'PASS' $nsp

        $mode = Az network perimeter association list --perimeter-name $nsp -g $rg --query "[].properties.accessMode" -o tsv
        if ($mode -match 'Enforced') { Add-Result 'S2' 'NSP access mode' 'PASS' 'Enforced' }
        elseif ($mode -match 'Learning') { Add-Result 'S2' 'NSP access mode' 'WARN' 'Learning (not yet enforcing)' }
        elseif ($mode) { Add-Result 'S2' 'NSP access mode' 'WARN' $mode }
        else { Add-Result 'S2' 'NSP association' 'FAIL' 'no association found' -Critical }

        $rules = Az network perimeter profile access-rule list --perimeter-name $nsp -g $rg --profile-name 'foundry-demo-nsp-profile' --query "[].name" -o tsv
        if ($rules) { Add-Result 'S2' 'NSP inbound access rule(s)' 'PASS' (($rules -split '\r?\n').Count.ToString() + ' rule(s)') }
        else { Add-Result 'S2' 'NSP inbound access rule(s)' 'WARN' 'no rules returned' }
    }
    elseif ($nspNames -eq '' ) {
        # Could be a missing az extension vs a genuinely-absent NSP.
        $ext = Az extension show -n nsp --query name -o tsv
        if (-not $ext) { Add-Result 'S2' 'Network Security Perimeter exists' 'SKIP' "az 'nsp' extension not installed (az extension add -n nsp) or NSP not deployed" }
        else { Add-Result 'S2' 'Network Security Perimeter exists' 'FAIL' "NSP $nsp not found" -Critical }
    }
    else { Add-Result 'S2' 'Network Security Perimeter exists' 'FAIL' "NSP $nsp not found" -Critical }

    $subnetId = Az webapp show -g $rg -n $nspApp --query virtualNetworkSubnetId -o tsv
    if (-not $subnetId) {
        $exists = Az webapp show -g $rg -n $nspApp --query name -o tsv
        if ($exists) { Add-Result 'S2' 'NSP app has NO VNet integration' 'PASS' 'identity-only path (correct)' }
        else { Add-Result 'S2' 'NSP app has NO VNet integration' 'SKIP' "$nspApp not found" }
    }
    else { Add-Result 'S2' 'NSP app has NO VNet integration' 'FAIL' "unexpectedly integrated: $subnetId" }

    $lawId = Az monitor log-analytics workspace show -g $rg -n $law --query id -o tsv
    if ($lawId) {
        Add-Result 'S2' 'Log Analytics workspace' 'PASS' $law
        $nspId = Az network perimeter show -g $rg -n $nsp --query id -o tsv
        if ($nspId) {
            $diag = Az monitor diagnostic-settings list --resource $nspId --query "[?name=='nsp-access-logs'] | length(@)" -o tsv
            if ($diag -eq '1') { Add-Result 'S2' 'Diagnostic setting nsp-access-logs' 'PASS' 'NSPAccessLogs wired' }
            else { Add-Result 'S2' 'Diagnostic setting nsp-access-logs' 'WARN' 'not found on NSP' }
        }
    }
    else { Add-Result 'S2' 'Log Analytics workspace' 'SKIP' "$law not found" }
}

# ---------------------------------------------------------------------------
# Scenario 3 — Private Agent + VNet Injection (discover resources by listing)
# ---------------------------------------------------------------------------
function Validate-Scenario3 {
    $sfx = if ($Suffix) { $Suffix } else { Read-Suffix '.deploy-suffix-agent' }
    $rg = if ($ResourceGroup) { $ResourceGroup } elseif ($sfx) { "rg-foundry-agent-$sfx" } else { '' }

    if (-not $rg -or -not (Test-Rg $rg)) {
        Add-Result 'S3' 'Deployment present' 'SKIP' 'no .deploy-suffix-agent / resource group — not deployed'
        return
    }

    $stgPna = Az storage account list -g $rg --query "[].publicNetworkAccess" -o tsv
    if ($stgPna -and ($stgPna -notmatch 'Enabled')) { Add-Result 'S3' 'Storage publicNetworkAccess' 'PASS' 'Disabled' }
    elseif ($stgPna) { Add-Result 'S3' 'Storage publicNetworkAccess' 'FAIL' $stgPna -Critical }
    else { Add-Result 'S3' 'Storage publicNetworkAccess' 'SKIP' 'no storage account found' }

    $cosPna = Az cosmosdb list -g $rg --query "[].publicNetworkAccess" -o tsv
    if ($cosPna -and ($cosPna -notmatch 'Enabled')) { Add-Result 'S3' 'Cosmos DB publicNetworkAccess' 'PASS' 'Disabled' }
    elseif ($cosPna) { Add-Result 'S3' 'Cosmos DB publicNetworkAccess' 'FAIL' $cosPna -Critical }
    else { Add-Result 'S3' 'Cosmos DB publicNetworkAccess' 'SKIP' 'no Cosmos account found' }

    $srchPna = Az search service list -g $rg --query "[].publicNetworkAccess" -o tsv
    if ($srchPna -and ($srchPna -match 'disabled')) { Add-Result 'S3' 'AI Search publicNetworkAccess' 'PASS' 'disabled' }
    elseif ($srchPna) { Add-Result 'S3' 'AI Search publicNetworkAccess' 'FAIL' $srchPna -Critical }
    else { Add-Result 'S3' 'AI Search publicNetworkAccess' 'SKIP' 'no Search service found' }

    $aiPna = Az cognitiveservices account list -g $rg --query "[].properties.publicNetworkAccess" -o tsv
    if ($aiPna -and ($aiPna -notmatch 'Enabled')) { Add-Result 'S3' 'Foundry publicNetworkAccess' 'PASS' 'Disabled' }
    elseif ($aiPna) { Add-Result 'S3' 'Foundry publicNetworkAccess' 'FAIL' $aiPna -Critical }
    else { Add-Result 'S3' 'Foundry publicNetworkAccess' 'SKIP' 'no Foundry account found' }

    $peStates = Az network private-endpoint list -g $rg --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv
    if ($peStates) {
        $states = $peStates -split '\r?\n'
        $bad = $states | Where-Object { $_ -notmatch 'Approved' }
        if (-not $bad) { Add-Result 'S3' 'Private endpoints approved' 'PASS' "$($states.Count) endpoint(s) Approved" }
        else { Add-Result 'S3' 'Private endpoints approved' 'FAIL' ($bad -join ', ') -Critical }
    }
    else { Add-Result 'S3' 'Private endpoints approved' 'FAIL' 'no private endpoints found' -Critical }

    $expectedZones = @(
        'privatelink.services.ai.azure.com', 'privatelink.openai.azure.com',
        'privatelink.cognitiveservices.azure.com', 'privatelink.search.windows.net',
        'privatelink.blob.core.windows.net', 'privatelink.documents.azure.com'
    )
    $zones = (Az network private-dns zone list -g $rg --query "[].name" -o tsv) -split '\r?\n'
    $missing = $expectedZones | Where-Object { $zones -notcontains $_ }
    if (-not $missing) { Add-Result 'S3' 'Six private DNS zones present' 'PASS' '6/6 core zones' }
    elseif ($zones -and $zones[0]) { Add-Result 'S3' 'Six private DNS zones present' 'FAIL' "missing: $($missing -join ', ')" -Critical }
    else { Add-Result 'S3' 'Six private DNS zones present' 'SKIP' 'no private DNS zones found' }

    $vnetName = Az network vnet list -g $rg --query "[0].name" -o tsv
    if ($vnetName) {
        $vnetId = Az network vnet show -g $rg -n $vnetName --query id -o tsv
        $linkedAll = $true
        foreach ($z in @('privatelink.blob.core.windows.net', 'privatelink.search.windows.net', 'privatelink.documents.azure.com')) {
            if ($zones -contains $z) {
                $l = Az network private-dns link vnet list -g $rg -z $z --query "[].virtualNetwork.id" -o tsv
                if ($l -notmatch [regex]::Escape($vnetName)) { $linkedAll = $false }
            }
        }
        if ($linkedAll) { Add-Result 'S3' 'DNS zones VNet-linked' 'PASS' "linked to $vnetName" }
        else { Add-Result 'S3' 'DNS zones VNet-linked' 'FAIL' 'one or more zones not linked to the agent VNet' -Critical }

        $agentDeleg = Az network vnet subnet show -g $rg --vnet-name $vnetName -n agent-subnet --query "delegations[].serviceName" -o tsv
        if ($agentDeleg -match 'Microsoft.App/environments') { Add-Result 'S3' 'agent-subnet delegation' 'PASS' 'Microsoft.App/environments' }
        elseif ($agentDeleg) { Add-Result 'S3' 'agent-subnet delegation' 'WARN' $agentDeleg }
        else { Add-Result 'S3' 'agent-subnet delegation' 'SKIP' 'agent-subnet not found' }

        $appDeleg = Az network vnet subnet show -g $rg --vnet-name $vnetName -n app-subnet --query "delegations[].serviceName" -o tsv
        if ($appDeleg -match 'Microsoft.Web/serverFarms') { Add-Result 'S3' 'app-subnet delegation' 'PASS' 'Microsoft.Web/serverFarms' }
        elseif ($appDeleg) { Add-Result 'S3' 'app-subnet delegation' 'WARN' $appDeleg }
        else { Add-Result 'S3' 'app-subnet delegation' 'SKIP' 'app-subnet not found' }
    }
    else { Add-Result 'S3' 'VNet present' 'FAIL' 'no VNet found in RG' -Critical }

    $webApp = Az webapp list -g $rg --query "[0].name" -o tsv
    if ($webApp) {
        $subnetId = Az webapp show -g $rg -n $webApp --query virtualNetworkSubnetId -o tsv
        if ($subnetId -match '/subnets/app-subnet') { Add-Result 'S3' 'Test WebApp VNet-integrated' 'PASS' 'app-subnet' }
        elseif ($subnetId) { Add-Result 'S3' 'Test WebApp VNet-integrated' 'WARN' (($subnetId -split '/')[-1]) }
        else { Add-Result 'S3' 'Test WebApp VNet-integrated' 'FAIL' 'not integrated' -Critical }
    }
    else { Add-Result 'S3' 'Test WebApp VNet-integrated' 'SKIP' 'no WebApp found' }
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Foundry Network Security — Validation ===' -ForegroundColor Cyan

$acct = Az account show --query name -o tsv
if (-not $acct) {
    Write-Host 'Not logged in to Azure. Run: az login' -ForegroundColor Red
    exit 2
}
Write-Host "Subscription: $acct" -ForegroundColor DarkGray

if ($Scenario -eq '1' -or $Scenario -eq 'all') { Validate-Scenario1 }
if ($Scenario -eq '2' -or $Scenario -eq 'all') { Validate-Scenario2 }
if ($Scenario -eq '3' -or $Scenario -eq 'all') { Validate-Scenario3 }

Write-Host ''
$fmt = "{0,-4} {1,-38} {2,-6} {3}"
Write-Host ($fmt -f 'Scn', 'Check', 'Status', 'Detail') -ForegroundColor White
Write-Host ('-' * 90) -ForegroundColor DarkGray
foreach ($r in $script:Results) {
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'DarkGray' }
    }
    Write-Host ($fmt -f $r.Scenario, $r.Check, $r.Status, $r.Detail) -ForegroundColor $color
}

$pass = ($script:Results | Where-Object Status -eq 'PASS').Count
$fail = ($script:Results | Where-Object Status -eq 'FAIL').Count
$warn = ($script:Results | Where-Object Status -eq 'WARN').Count
$skip = ($script:Results | Where-Object Status -eq 'SKIP').Count
Write-Host ''
Write-Host "Summary: $pass PASS, $fail FAIL, $warn WARN, $skip SKIP" -ForegroundColor White

if ($script:CriticalFail) {
    Write-Host 'CRITICAL network check failed — see FAIL rows above.' -ForegroundColor Red
    exit 1
}
exit 0
