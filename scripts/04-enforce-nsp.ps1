###############################################################################
# Scenario 2 — Step B: Enforce the Network Security Perimeter on the Foundry.
# Creates the NSP + profile + identity-based (Subscriptions) inbound rule and
# associates the existing Foundry in Enforced mode. After this:
#   - NSP App Service (managed identity) -> ALLOWED
#   - Laptop (user az login token)       -> BLOCKED
# The Foundry endpoint stays public in DNS; the boundary is at the identity layer.
###############################################################################

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# --- Load suffix ---
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix"
if (-not (Test-Path $SuffixFile)) {
    Write-Host "❌ No .deploy-suffix file found. Run Scenario 1 (01) and Scenario 2 Step A (03) first." -ForegroundColor Red
    exit 1
}
$Suffix = (Get-Content $SuffixFile -Raw).Trim()
Write-Host "Using deployment suffix: $Suffix"

$ResourceGroup = "rg-foundry-demo-$Suffix"
$Location = "centralus"

# --- Prerequisite: register NSP preview feature flags -------------------------
# Network Security Perimeter support for Azure OpenAI / Cognitive Services is in
# public preview and requires TWO subscription feature flags to be registered,
# otherwise the perimeter association provisions at the control plane but the
# data plane does NOT enforce it (user tokens keep getting HTTP 200 instead of
# 403). Ref: https://learn.microsoft.com/azure/ai-services/openai/how-to/network-security-perimeter
$Features = @(
    @{ Namespace = "Microsoft.CognitiveServices"; Name = "OpenAI.NspPreview" },
    @{ Namespace = "Microsoft.Network";          Name = "AllowNSPInPublicPreview" }
)
Write-Host "`n▶ Ensuring NSP preview feature flags are registered..."
foreach ($f in $Features) {
    $state = az feature show --namespace $f.Namespace --name $f.Name --query "properties.state" -o tsv 2>$null
    if ($state -ne "Registered") {
        Write-Host "  Registering $($f.Namespace)/$($f.Name) (was: $state)..."
        az feature registration create --namespace $f.Namespace --name $f.Name --output none 2>$null
    } else {
        Write-Host "  $($f.Namespace)/$($f.Name): already Registered"
    }
}
# Poll until both report Registered (registration is usually fast but not instant).
$deadline = (Get-Date).AddMinutes(15)
foreach ($f in $Features) {
    do {
        $state = az feature show --namespace $f.Namespace --name $f.Name --query "properties.state" -o tsv 2>$null
        if ($state -ne "Registered") {
            if ((Get-Date) -gt $deadline) { throw "Feature $($f.Namespace)/$($f.Name) did not reach Registered in time (state: $state)." }
            Write-Host "  Waiting for $($f.Name) to register (state: $state)..."
            Start-Sleep -Seconds 20
        }
    } while ($state -ne "Registered")
}
# Re-register the providers so the newly-registered features propagate.
az provider register --namespace Microsoft.CognitiveServices --output none 2>$null
az provider register --namespace Microsoft.Network --output none 2>$null
Write-Host "  ✓ NSP preview features registered."

# --- Deploy Bicep (NSP + profile + inbound rule + association) ---
Write-Host "`n▶ Deploying Network Security Perimeter via Bicep..."
$BicepFile = Join-Path $RepoRoot "infra\04-nsp-enforce.bicep"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $BicepFile `
    --parameters suffix=$Suffix location=$Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }

# --- Done ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Scenario 2 Step B complete! Foundry is now behind the NSP (Enforced)."
Write-Host "  Allowed:  App Service managed identity (subscription inbound rule)"
Write-Host "  Blocked:  Laptop / user tokens (not a managed identity)"
Write-Host "  Endpoint DNS stays public — access is gated at the IDENTITY layer."
Write-Host "  Note: data-plane enforcement can take a few minutes to propagate;"
Write-Host "        if the laptop deny test still returns 200, wait ~3 min and retry."
Write-Host "════════════════════════════════════════════════════════════════"
