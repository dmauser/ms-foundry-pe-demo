###############################################################################
# Phase 1: Deploy Azure AI Foundry Demo with Public Access
# Thin wrapper: Bicep handles all Azure resources. This script only handles
# suffix generation, resource group creation, Bicep deployment, and app deploy.
###############################################################################

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# --- Suffix (generate once, reuse) ---
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix"
if (Test-Path $SuffixFile) {
    $Suffix = (Get-Content $SuffixFile -Raw).Trim()
} else {
    $Chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $Suffix = -join (1..5 | ForEach-Object { $Chars[(Get-Random -Maximum $Chars.Length)] })
    $Suffix | Out-File -FilePath $SuffixFile -NoNewline -Encoding utf8
}
Write-Host "Using deployment suffix: $Suffix"

$ResourceGroup = "rg-foundry-demo-$Suffix"
$Location = "centralus"
$WebAppName = "foundry-demo-app-$Suffix"

# --- Step 1: Create Resource Group ---
Write-Host "`n▶ Creating resource group: $ResourceGroup"
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group" }

# --- Step 2: Deploy Bicep (all infra) ---
Write-Host "`n▶ Deploying infrastructure via Bicep..."
$BicepFile = Join-Path $RepoRoot "infra\01-public-access.bicep"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $BicepFile `
    --parameters suffix=$Suffix location=$Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }
Write-Host "  ✓ Infrastructure deployed successfully"

# --- Step 3: Build .NET app ---
Write-Host "`n▶ Building .NET application..."
$SrcDir = Join-Path $RepoRoot "src"
$PublishDir = Join-Path $SrcDir "publish"
dotnet publish $SrcDir -c Release -o $PublishDir --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# --- Step 4: Zip deploy ---
Write-Host "`n▶ Deploying application to $WebAppName..."
$ZipFile = Join-Path $SrcDir "app.zip"
if (Test-Path $ZipFile) { Remove-Item $ZipFile -Force }
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipFile -Force
az webapp deploy --resource-group $ResourceGroup --name $WebAppName --src-path $ZipFile --type zip --output none
if ($LASTEXITCODE -ne 0) { throw "App deployment failed" }

# --- Done ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Phase 1 complete! Public access deployment finished."
Write-Host "  App URL: https://$WebAppName.azurewebsites.net"
Write-Host "  Suffix:  $Suffix"
Write-Host "════════════════════════════════════════════════════════════════"
