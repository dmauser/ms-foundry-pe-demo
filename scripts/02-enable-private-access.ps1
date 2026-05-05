###############################################################################
# Phase 2: Enable Private Access for Azure AI Services
# Thin wrapper: Bicep handles private endpoint, DNS zone, and public access toggle.
###############################################################################

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# --- Azure Authentication Check ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "🔐 Verifying Azure authentication..."
$AccountJson = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Not logged in to Azure CLI. Run: az login" -ForegroundColor Red
    exit 1
}
$AccountInfo = $AccountJson | ConvertFrom-Json
Write-Host "  ✓ Logged in as : $($AccountInfo.user.name)"
Write-Host "  📋 Subscription : $($AccountInfo.name)"
Write-Host "  🆔 Subscription ID: $($AccountInfo.id)"
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host "⏳ Proceeding in 5 seconds... Press Ctrl+C to abort." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# --- Load suffix ---
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix"
if (-not (Test-Path $SuffixFile)) {
    Write-Host "❌ No .deploy-suffix file found. Run Phase 1 first." -ForegroundColor Red
    exit 1
}
$Suffix = (Get-Content $SuffixFile -Raw).Trim()
Write-Host "Using deployment suffix: $Suffix"

$ResourceGroup = "rg-foundry-demo-$Suffix"
$Location = "centralus"

# --- Deploy Bicep (private endpoint infra) ---
Write-Host "`n▶ Deploying private access infrastructure via Bicep..."
$BicepFile = Join-Path $RepoRoot "infra\02-private-access.bicep"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $BicepFile `
    --parameters suffix=$Suffix location=$Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }

# --- Disable public network access ---
Write-Host "`n▶ Disabling public network access on AI Services..."
$AiServicesName = "foundry-demo-ai-$Suffix"
$AiResourceId = (az cognitiveservices account show --name $AiServicesName --resource-group $ResourceGroup --query id -o tsv)
az resource update --ids $AiResourceId --set properties.publicNetworkAccess=Disabled --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to disable public access" }

# --- Done ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Phase 2 complete! Private access enabled."
Write-Host "  AI Services now only accessible via private endpoint."
Write-Host "  DNS zone: privatelink.cognitiveservices.azure.com"
Write-Host "════════════════════════════════════════════════════════════════"
