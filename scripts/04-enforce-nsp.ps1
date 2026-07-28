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
Write-Host "════════════════════════════════════════════════════════════════"
