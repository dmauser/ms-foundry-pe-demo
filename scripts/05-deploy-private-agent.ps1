###############################################################################
# Scenario 3 — Deploy the Private Foundry Agent (Standard Agent Setup + VNet
# injection) with its VNet-integrated test WebApp.
#
# Self-contained: own resource group, own suffix, region westus3 (Standard Agent
# Setup + gpt-5-mini supported). Does NOT touch Scenario 1/2 infra.
#
# Flow: register RPs -> create RG -> deploy Bicep (VNet + Storage/Cosmos/Search
# private + Foundry account/project network-injected + capability host + WebApp)
# -> build & zip-deploy the app -> best-effort seed (upload manuals -> search
# store -> create agent) from inside the VNet via the WebApp's public front door.
###############################################################################

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent

# --- Suffix (RG name only; all Azure resource names derive from the RG id) ---
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix-agent"
if (Test-Path $SuffixFile) {
    $Suffix = (Get-Content $SuffixFile -Raw).Trim()
} else {
    $Chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $Suffix = -join (1..5 | ForEach-Object { $Chars[(Get-Random -Maximum $Chars.Length)] })
    $Suffix | Out-File -FilePath $SuffixFile -NoNewline -Encoding utf8
}
Write-Host "Using deployment suffix: $Suffix"

$Location = "westus3"
$ResourceGroup = "rg-foundry-agent-$Suffix"
$BicepFile = Join-Path $RepoRoot "infra\05-private-agent\main.bicep"

# --- Step 1: Register resource providers (idempotent) ---
Write-Host "`n▶ Registering resource providers..."
$Providers = @(
    "Microsoft.App", "Microsoft.CognitiveServices", "Microsoft.Search",
    "Microsoft.Storage", "Microsoft.DocumentDB", "Microsoft.Web",
    "Microsoft.Network", "Microsoft.OperationalInsights", "Microsoft.Insights"
)
foreach ($p in $Providers) { az provider register --namespace $p --output none 2>$null }
Write-Host "  ✓ Providers registered (registration continues in the background)"

# --- Step 2: Create Resource Group ---
Write-Host "`n▶ Creating resource group: $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group" }

# --- Step 3: Deploy Bicep (all infra) ---
Write-Host "`n▶ Deploying infrastructure via Bicep (this takes ~10-15 min)..."
$DeploymentName = "scenario3-agent-$Suffix"
az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file $BicepFile `
    --parameters location=$Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }
Write-Host "  ✓ Infrastructure deployed successfully"

# --- Step 4: Read deployment outputs (names derive from the RG id) ---
$Outputs = az deployment group show --resource-group $ResourceGroup --name $DeploymentName --query properties.outputs -o json | ConvertFrom-Json
$WebAppName = $Outputs.webAppName.value
$WebAppUrl = $Outputs.webAppUrl.value
$ProjectEndpoint = $Outputs.projectEndpoint.value
if ([string]::IsNullOrWhiteSpace($WebAppName)) { throw "Deployment did not return a webAppName (deployTestWebApp=false?)" }
Write-Host "  ✓ Test WebApp: $WebAppName"

# --- Step 5: Build .NET app ---
Write-Host "`n▶ Building .NET application..."
$SrcDir = Join-Path $RepoRoot "src"
$PublishDir = Join-Path $RepoRoot ".publish"
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
dotnet publish $SrcDir -c Release -o $PublishDir --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# --- Step 6: Zip deploy ---
Write-Host "`n▶ Deploying application to $WebAppName..."
$ZipFile = Join-Path $RepoRoot ".publish.zip"
if (Test-Path $ZipFile) { Remove-Item $ZipFile -Force }
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipFile -Force
az webapp deploy --resource-group $ResourceGroup --name $WebAppName --src-path $ZipFile --type zip --output none
if ($LASTEXITCODE -ne 0) { throw "App deployment failed" }

# --- Cleanup build artifacts ---
Remove-Item $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue

# --- Step 7: Best-effort seed (upload manuals -> search index -> create agent) ---
# Runs inside the VNet via the WebApp's public front door. RBAC/app warm-up can
# lag, so retry a few times; if it doesn't take, click "Seed" in the UI.
Write-Host "`n▶ Seeding the agent (best effort; RBAC propagation can take a few minutes)..."
$Seeded = $false
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Seconds 20
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$WebAppUrl/api/seed" -TimeoutSec 120 -ErrorAction Stop
        if ($resp.seeded) { $Seeded = $true; Write-Host "  ✓ Agent seeded (agentId=$($resp.agentId))"; break }
        if ($resp.error) { Write-Host "  … attempt ${i}: $($resp.error)" -ForegroundColor DarkYellow }
    } catch {
        Write-Host "  … attempt ${i}: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}
if (-not $Seeded) { Write-Host "  ⚠ Auto-seed did not complete — open the app and click '🌱 Seed manuals & create agent'." -ForegroundColor Yellow }

# --- Done ---
Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Scenario 3 complete! Private Foundry Agent + VNet injection deployed."
Write-Host "  App URL:          $WebAppUrl"
Write-Host "  Project endpoint: $ProjectEndpoint"
Write-Host "  Suffix:           $Suffix"
Write-Host "  Try asking:       'Why is my washer showing error E4?'"
Write-Host "  Tear down with:   scripts/99-teardown.ps1  (choose the agent RG)"
Write-Host "════════════════════════════════════════════════════════════════"
