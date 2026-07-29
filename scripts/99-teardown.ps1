###############################################################################
# Teardown: Delete the Azure AI Foundry Demo lab
# Deletes the entire resource group (rg-foundry-demo-<suffix>), which cascades
# every resource created by phases 1-4 (Foundry, VNet, App Service plan, both
# web apps, the Network Security Perimeter, and Log Analytics).
#
# Usage:
#   ./99-teardown.ps1                        # use saved suffix, prompt to confirm
#   ./99-teardown.ps1 -Suffix abc12          # override the suffix
#   ./99-teardown.ps1 -Subscription <id>     # target a specific subscription
#   ./99-teardown.ps1 -Yes                   # skip the confirmation prompt
#   ./99-teardown.ps1 -NoWait                # return immediately (async delete)
###############################################################################
param(
    [string]$Suffix,
    [string]$Subscription,
    [switch]$Yes,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"
$SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix"

# --- Resolve suffix ---
if (-not $Suffix) {
    if (Test-Path $SuffixFile) {
        $Suffix = (Get-Content $SuffixFile -Raw).Trim()
    } else {
        throw "No suffix found. Pass -Suffix <value> (scripts/.deploy-suffix is missing)."
    }
}

$ResourceGroup = "rg-foundry-demo-$Suffix"

# --- Optional subscription target ---
if ($Subscription) {
    az account set --subscription $Subscription
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription" }
}
$CurrentSub = az account show --query name -o tsv

# --- Verify the resource group exists ---
if ((az group exists --name $ResourceGroup) -ne "true") {
    Write-Host "Resource group '$ResourceGroup' does not exist in subscription '$CurrentSub'. Nothing to do."
    exit 0
}

Write-Host "`n▶ Resources to be deleted in '$ResourceGroup' (subscription: $CurrentSub):"
az resource list --resource-group $ResourceGroup --query "[].{name:name,type:type}" -o table

# --- Confirm ---
if (-not $Yes) {
    Write-Host ""
    $Reply = Read-Host "This will PERMANENTLY delete resource group '$ResourceGroup'. Type the suffix ('$Suffix') to confirm"
    if ($Reply -ne $Suffix) {
        Write-Host "Confirmation did not match. Aborting."
        exit 1
    }
}

# --- Delete ---
Write-Host "`n▶ Deleting resource group: $ResourceGroup"
if ($NoWait) {
    az group delete --name $ResourceGroup --yes --no-wait
    if ($LASTEXITCODE -ne 0) { throw "Failed to start resource group deletion" }
    Write-Host "  ✓ Deletion started (running asynchronously)."
} else {
    az group delete --name $ResourceGroup --yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete resource group" }
    Write-Host "  ✓ Resource group deleted."
}

# --- Clear saved suffix so the next deploy generates a fresh one ---
if ((Test-Path $SuffixFile) -and ((Get-Content $SuffixFile -Raw).Trim() -eq $Suffix)) {
    Remove-Item $SuffixFile -Force
    Write-Host "  ✓ Cleared scripts/.deploy-suffix"
}

Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Teardown complete for suffix: $Suffix"
Write-Host "════════════════════════════════════════════════════════════════"
