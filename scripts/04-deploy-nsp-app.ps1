###############################################################################
# Scenario 3 — Step A: Deploy the second (NSP) App Service.
# Reuses the Scenario 1 Foundry + App Service Plan (same suffix). Deploys a new
# App Service WITHOUT VNet integration, then builds & zip-deploys the app.
# The Foundry stays public here, so both laptop and app can call it.
###############################################################################

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# --- Load suffix (from Scenario 1) ---
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix-s3"
if (-not (Test-Path $SuffixFile)) {
    Write-Host "❌ No .deploy-suffix-s3 file found. Run the Scenario 3 baseline first (01-deploy-public-access.ps1 -Scenario s3)." -ForegroundColor Red
    exit 1
}
$Suffix = (Get-Content $SuffixFile -Raw).Trim()
Write-Host "Using deployment suffix: $Suffix"

$ResourceGroup = "rg-foundry-s3-nsp-$Suffix"
$Location = "centralus"
$AiServicesName = "foundry-demo-ai-$Suffix"
$NspWebAppName = "foundry-demo-nsp-app-$Suffix"

# --- Ensure Foundry public access is enabled (baseline for Step A) ---
Write-Host "`n▶ Ensuring Foundry public network access is enabled..."
$AiResourceId = (az cognitiveservices account show --name $AiServicesName --resource-group $ResourceGroup --query id -o tsv)
az resource update --ids $AiResourceId --set properties.publicNetworkAccess=Enabled --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to enable public access" }

# --- Grant the interactive deployer data-plane access (so the laptop before/after
#     test is meaningful). NSP gates on identity, but the data plane still enforces
#     RBAC first: without this role a laptop token returns a misleading 401
#     "lacks the required data action" (RBAC) instead of the NSP identity denial. ---
Write-Host "`n▶ Granting the current user 'Cognitive Services OpenAI User' on the Foundry (for laptop testing)..."
$DeployerObjectId = (az ad signed-in-user show --query id -o tsv 2>$null)
if ([string]::IsNullOrWhiteSpace($DeployerObjectId)) {
    Write-Host "  ⚠ Could not resolve the signed-in user (service principal?). Skipping — grant the role manually to run the laptop deny test." -ForegroundColor Yellow
} else {
    az role assignment create --assignee-object-id $DeployerObjectId --assignee-principal-type User `
        --role "Cognitive Services OpenAI User" --scope $AiResourceId --output none 2>$null
    Write-Host "  ✓ Role granted (data-plane RBAC can take a few minutes to take effect)."
}

# --- Deploy Bicep (second App Service + RBAC) ---
Write-Host "`n▶ Deploying NSP App Service via Bicep..."
$BicepFile = Join-Path $RepoRoot "infra\04-nsp-app-service.bicep"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $BicepFile `
    --parameters suffix=$Suffix location=$Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }
Write-Host "  ✓ Infrastructure deployed successfully"

# --- Build .NET app ---
Write-Host "`n▶ Building .NET application..."
$SrcDir = Join-Path $RepoRoot "src"
$PublishDir = Join-Path $RepoRoot ".publish"
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
dotnet publish $SrcDir -c Release -o $PublishDir --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# --- Zip deploy ---
Write-Host "`n▶ Deploying application to $NspWebAppName..."
$ZipFile = Join-Path $RepoRoot ".publish.zip"
if (Test-Path $ZipFile) { Remove-Item $ZipFile -Force }
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipFile -Force
az webapp deploy --resource-group $ResourceGroup --name $NspWebAppName --src-path $ZipFile --type zip --output none
if ($LASTEXITCODE -ne 0) { throw "App deployment failed" }

# --- Cleanup build artifacts ---
Remove-Item $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue

# --- Done ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Scenario 3 Step A complete! NSP App Service deployed (public Foundry)."
Write-Host "  App URL: https://$NspWebAppName.azurewebsites.net"
Write-Host "  Next:    scripts/05-enforce-nsp.ps1  (lock Foundry behind the perimeter)"
Write-Host "════════════════════════════════════════════════════════════════"
