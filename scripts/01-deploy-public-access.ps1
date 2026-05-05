###############################################################################
# Phase 1: Deploy Azure AI Foundry Demo with Public Access
#
# This script documents the deployment of the Azure AI Foundry demo
# in its "BEFORE" state (public access enabled).
#
# Prerequisites:
#   - Azure CLI installed (az command available)
#   - Logged in to Azure (az login)
#   - .NET SDK installed (for dotnet publish)
#   - Appropriate Azure permissions (Contributor role or equivalent)
#
# Usage:
#   pwsh scripts/01-deploy-public-access.ps1
#
###############################################################################

$ErrorActionPreference = "Stop"

# ============================================================================
# Helper functions
# ============================================================================

function Log-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════════"
    Write-Host "▶ $Message"
    Write-Host "════════════════════════════════════════════════════════════════"
}

function Log-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message"
}

function Log-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message"
}

function Log-Warning {
    param([string]$Message)
    Write-Host "  ⚠ $Message"
}

function Log-Error {
    param([string]$Message)
    Write-Host "  ❌ $Message" -ForegroundColor Red
}

function Assert-AzSuccess {
    param([string]$StepDescription)
    if ($LASTEXITCODE -ne 0) {
        Log-Error "$StepDescription failed (exit code: $LASTEXITCODE). Stopping."
        exit 1
    }
}

# ============================================================================
# RANDOM SUFFIX - Ensures globally unique resource names so multiple users
# can deploy this demo without naming conflicts. Generated once and reused
# across all resources in this deployment.
# ============================================================================

$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix"
if (Test-Path $SuffixFile) {
    $Suffix = (Get-Content $SuffixFile -Raw).Trim()
} else {
    $Chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $Suffix = -join (1..5 | ForEach-Object { $Chars[(Get-Random -Maximum $Chars.Length)] })
    $Suffix | Out-File -FilePath $SuffixFile -NoNewline -Encoding utf8
}
Write-Host "Using deployment suffix: $Suffix"

# ============================================================================
# VARIABLES - Customize these for your environment
# ============================================================================

$ResourceGroup = "rg-foundry-demo-$Suffix"
$Location = "centralus"

# Azure AI Foundry (AIServices)
$FoundryName = "foundry-demo-ai-$Suffix"
$FoundrySku = "S0"

# App Service
$AppServiceName = "foundry-demo-app-$Suffix"
$AppServicePlan = "foundry-demo-plan-$Suffix"
$AppServiceSku = "B1"

# Network
$VnetName = "foundry-demo-vnet-$Suffix"
$VnetCidr = "10.0.0.0/16"
$AppServiceSubnet = "app-service-subnet"
$AppServiceSubnetCidr = "10.0.1.0/24"
$FoundrySubnet = "foundry-subnet"
$FoundrySubnetCidr = "10.0.2.0/24"

# Managed Identity
$IdentityName = "foundry-demo-identity-$Suffix"

# Model deployment
$ModelName = "gpt-4o-mini"
$ModelVersion = "2"

# Application - resolve src/ relative to the script location
$AppDir = Join-Path (Split-Path $PSScriptRoot -Parent) "src"
$BuildDir = "bin/Release/net8.0/publish"

# ============================================================================
# STEP 1: Create Resource Group
# ============================================================================

Log-Step "Step 1: Create Resource Group"

$RgExists = az group exists --name $ResourceGroup
if ($RgExists -eq "true") {
    Log-Warning "Resource group '$ResourceGroup' already exists. Skipping creation."
} else {
    Log-Info "Creating resource group in $Location..."
    az group create `
        --name $ResourceGroup `
        --location $Location
    Assert-AzSuccess "Resource group creation"
    Log-Success "Resource group created"
}

# ============================================================================
# STEP 2: Create Azure AI Foundry Resource (AIServices)
# ============================================================================

Log-Step "Step 2: Create Azure AI Foundry Resource (AIServices)"

$FoundryExists = az cognitiveservices account show --name $FoundryName --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($FoundryExists) {
    Log-Warning "Foundry resource '$FoundryName' already exists. Skipping creation."
    $FoundryId = az cognitiveservices account show --name $FoundryName --resource-group $ResourceGroup --query id -o tsv
} else {
    Log-Info "Creating Azure AI Foundry resource..."
    az cognitiveservices account create `
        --name $FoundryName `
        --resource-group $ResourceGroup `
        --kind AIServices `
        --sku $FoundrySku `
        --location $Location `
        --custom-domain $FoundryName
    Assert-AzSuccess "AI Foundry resource creation"

    $FoundryId = az cognitiveservices account show --name $FoundryName --resource-group $ResourceGroup --query id -o tsv
    Log-Success "Foundry resource created: $FoundryId"
}

# ============================================================================
# STEP 3: Deploy Model to Foundry Resource
# ============================================================================

Log-Step "Step 3: Deploy Model (gpt-4o-mini, GlobalStandard)"

Log-Info "Deploying $ModelName model..."
az cognitiveservices account deployment create `
    --name $FoundryName `
    --resource-group $ResourceGroup `
    --deployment-name $ModelName `
    --model-name $ModelName `
    --model-version $ModelVersion `
    --sku-name "GlobalStandard" `
    --sku-capacity 1 `
    -ErrorAction SilentlyContinue 2>$null
if ($LASTEXITCODE -ne 0) {
    Log-Warning "Model deployment already exists or creation skipped"
}

Log-Success "Model deployment configured"

# ============================================================================
# STEP 4: Create Virtual Network and Subnets
# ============================================================================

Log-Step "Step 4: Create Virtual Network and Subnets"

$VnetExists = az network vnet show --name $VnetName --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($VnetExists) {
    Log-Warning "VNet '$VnetName' already exists. Skipping creation."
} else {
    Log-Info "Creating VNet $VnetName ($VnetCidr)..."
    az network vnet create `
        --name $VnetName `
        --resource-group $ResourceGroup `
        --address-prefix $VnetCidr
    Assert-AzSuccess "VNet creation"
    Log-Success "VNet created"
}

# Create App Service subnet
$SubnetExists = az network vnet subnet show --name $AppServiceSubnet --vnet-name $VnetName --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($SubnetExists) {
    Log-Warning "Subnet '$AppServiceSubnet' already exists. Skipping creation."
} else {
    Log-Info "Creating subnet $AppServiceSubnet ($AppServiceSubnetCidr)..."
    az network vnet subnet create `
        --name $AppServiceSubnet `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --address-prefix $AppServiceSubnetCidr
    Assert-AzSuccess "App Service subnet creation"
    Log-Success "App Service subnet created"
}

# Create Foundry subnet
$SubnetExists = az network vnet subnet show --name $FoundrySubnet --vnet-name $VnetName --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($SubnetExists) {
    Log-Warning "Subnet '$FoundrySubnet' already exists. Skipping creation."
} else {
    Log-Info "Creating subnet $FoundrySubnet ($FoundrySubnetCidr)..."
    az network vnet subnet create `
        --name $FoundrySubnet `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --address-prefix $FoundrySubnetCidr
    Assert-AzSuccess "Foundry subnet creation"
    Log-Success "Foundry subnet created"
}

# ============================================================================
# STEP 5: Create App Service Plan and Web App
# ============================================================================

Log-Step "Step 5: Create App Service Plan and Web App"

$PlanExists = az appservice plan show --name $AppServicePlan --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($PlanExists) {
    Log-Warning "App Service Plan '$AppServicePlan' already exists. Skipping creation."
} else {
    Log-Info "Creating App Service Plan (B1 Linux)..."
    az appservice plan create `
        --name $AppServicePlan `
        --resource-group $ResourceGroup `
        --sku B1 `
        --is-linux
    Assert-AzSuccess "App Service Plan creation"
    Log-Success "App Service Plan created"
}

$AppExists = az webapp show --name $AppServiceName --resource-group $ResourceGroup -ErrorAction SilentlyContinue 2>$null
if ($AppExists) {
    Log-Warning "Web App '$AppServiceName' already exists. Skipping creation."
} else {
    Log-Info "Creating Web App..."
    az webapp create `
        --name $AppServiceName `
        --resource-group $ResourceGroup `
        --plan $AppServicePlan `
        --runtime "DOTNET|8.0"
    Assert-AzSuccess "Web App creation"
    Log-Success "Web App created"
}

# ============================================================================
# STEP 6: Create Managed Identity and Assign RBAC Role
# ============================================================================

Log-Step "Step 6: Create Managed Identity and Assign RBAC Role"

Log-Info "Enabling Managed Identity on App Service..."
az webapp identity assign `
    --name $AppServiceName `
    --resource-group $ResourceGroup `
    --identities [system]
Assert-AzSuccess "Managed Identity assignment"

$PrincipalId = az webapp identity show `
    --name $AppServiceName `
    --resource-group $ResourceGroup `
    --query principalId -o tsv

Log-Info "Assigning RBAC role (Cognitive Services User)..."
az role assignment create `
    --role "Cognitive Services User" `
    --assignee $PrincipalId `
    --scope $FoundryId `
    -ErrorAction SilentlyContinue 2>$null
if ($LASTEXITCODE -ne 0) {
    Log-Warning "Role assignment already exists or skipped"
}

Log-Success "Managed Identity configured with RBAC"

# ============================================================================
# STEP 7: Configure App Settings
# ============================================================================

Log-Step "Step 7: Configure App Settings"

$FoundryEndpoint = az cognitiveservices account show `
    --name $FoundryName `
    --resource-group $ResourceGroup `
    --query properties.endpoint -o tsv

Log-Info "Setting app configuration..."
az webapp config appsettings set `
    --name $AppServiceName `
    --resource-group $ResourceGroup `
    --settings `
        "AzureAiFoundry__Endpoint=$FoundryEndpoint" `
        "AzureAiFoundry__DeploymentName=$ModelName" `
        "AzureAiFoundry__UseSystemAssignedIdentity=true"
Assert-AzSuccess "App settings configuration"

Log-Success "App settings configured"

# ============================================================================
# STEP 8: Build and Deploy Application
# ============================================================================

Log-Step "Step 8: Build and Deploy Application"

Log-Info "Building .NET application (Release)..."
if (Test-Path $AppDir) {
    Push-Location $AppDir
    dotnet publish -c Release -o $BuildDir
    Assert-AzSuccess "dotnet publish"
    Log-Success "Build completed"

    Log-Info "Creating deployment package..."
    $PackageFile = Join-Path $PSScriptRoot "foundry-demo-app.zip"
    $PublishPath = Resolve-Path $BuildDir
    if (Test-Path $PackageFile) { Remove-Item $PackageFile -Force }
    Compress-Archive -Path (Join-Path $PublishPath "*") -DestinationPath $PackageFile -Force
    Pop-Location
    Log-Success "Package created: $PackageFile"

    Log-Info "Deploying to App Service..."
    az webapp deployment source config-zip `
        --name $AppServiceName `
        --resource-group $ResourceGroup `
        --src $PackageFile
    Assert-AzSuccess "App deployment"
    Log-Success "Application deployed"

    Remove-Item -Path $PackageFile -Force -ErrorAction SilentlyContinue
} else {
    Log-Warning "Application directory not found at $AppDir. Skipping deployment."
}

# ============================================================================
# VALIDATION & VERIFICATION
# ============================================================================

Log-Step "✓ Phase 1 Deployment Complete (Public Access)"

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host "VALIDATION COMMANDS"
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host ""
Write-Host "1. Verify Foundry resource endpoint:"
Write-Host "   az cognitiveservices account show --name $FoundryName --resource-group $ResourceGroup --query properties.endpoint"
Write-Host ""
Write-Host "2. Verify App Service is accessible:"
Write-Host "   curl https://${AppServiceName}.azurewebsites.net/"
Write-Host ""
Write-Host "3. Test the diagnostics endpoint (verify Managed Identity works):"
Write-Host "   curl https://${AppServiceName}.azurewebsites.net/api/diagnostics"
Write-Host ""
Write-Host "4. Test the AI API endpoint (simple prompt):"
Write-Host "   curl `"https://${AppServiceName}.azurewebsites.net/api/ask?prompt=Hello%20Azure%20AI%20Foundry`""
Write-Host ""
Write-Host "5. Verify public network access is enabled on Foundry:"
Write-Host "   az cognitiveservices account show --name $FoundryName --resource-group $ResourceGroup --query properties.publicNetworkAccess"
