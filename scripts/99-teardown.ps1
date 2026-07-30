###############################################################################
# Teardown: Delete an Azure AI Foundry Demo lab
# Deletes the entire resource group (cascading every resource in it), then
# PURGES any soft-deleted Foundry (Cognitive Services) accounts so they don't
# linger (soft-deleted accounts still count against quota and block same-name
# redeploys).
#
# Scenarios (with legacy aliases accepted):
#   s1  (alias pe)     -> rg-foundry-s1-pe-<suffix>     (Scenario 1, suffix file .deploy-suffix-s1)
#   s2  (alias agent)  -> rg-foundry-s2-agent-<suffix>  (Scenario 2, suffix file .deploy-suffix-s2)
#   s3  (alias nsp)    -> rg-foundry-s3-nsp-<suffix>    (Scenario 3, suffix file .deploy-suffix-s3)
#
# Usage:
#   ./99-teardown.ps1                        # Scenario 1 lab, saved suffix, prompt to confirm
#   ./99-teardown.ps1 -Scenario s2           # Scenario 2 lab
#   ./99-teardown.ps1 -Suffix abc12          # override the suffix
#   ./99-teardown.ps1 -Subscription <id>     # target a specific subscription
#   ./99-teardown.ps1 -Yes                   # skip the confirmation prompt
#   ./99-teardown.ps1 -NoWait                # return immediately (async delete)
###############################################################################
param(
    [ValidateSet("s1", "s2", "s3", "pe", "agent", "nsp")]
    [string]$Scenario = "s1",
    [string]$Suffix,
    [string]$Subscription,
    [switch]$Yes,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"

# --- Normalize legacy aliases (pe->s1, agent->s2, nsp->s3) ---
switch ($Scenario) {
    "pe"    { $Scenario = "s1" }
    "agent" { $Scenario = "s2" }
    "nsp"   { $Scenario = "s3" }
}

# --- Scenario -> RG prefix + suffix file ---
switch ($Scenario) {
    "s2" {
        $RgPrefix = "rg-foundry-s2-agent-"
        $SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix-s2"
    }
    "s3" {
        $RgPrefix = "rg-foundry-s3-nsp-"
        $SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix-s3"
    }
    default {
        $RgPrefix = "rg-foundry-s1-pe-"
        $SuffixFile = Join-Path $PSScriptRoot ".deploy-suffix-s1"
    }
}

# --- Resolve suffix ---
if (-not $Suffix) {
    if (Test-Path $SuffixFile) {
        $Suffix = (Get-Content $SuffixFile -Raw).Trim()
    } else {
        throw "No suffix found. Pass -Suffix <value> ($SuffixFile is missing)."
    }
}

$ResourceGroup = "$RgPrefix$Suffix"

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

# --- Capture Foundry (Cognitive Services) accounts so we can purge them after RG delete ---
$FoundryAccounts = az resource list --resource-group $ResourceGroup `
    --resource-type "Microsoft.CognitiveServices/accounts" `
    --query "[].{name:name,location:location}" -o json | ConvertFrom-Json

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
    if ($FoundryAccounts) {
        Write-Host "  ⚠ Soft-deleted Foundry accounts were NOT purged (async delete). Re-run without -NoWait or purge manually with 'az cognitiveservices account purge'." -ForegroundColor Yellow
    }
} else {
    az group delete --name $ResourceGroup --yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete resource group" }
    Write-Host "  ✓ Resource group deleted."

    # --- Purge soft-deleted Foundry accounts (otherwise they linger + block redeploy) ---
    foreach ($acct in $FoundryAccounts) {
        Write-Host "`n▶ Purging soft-deleted Foundry account: $($acct.name) ($($acct.location))"
        az cognitiveservices account purge --name $acct.name --resource-group $ResourceGroup --location $acct.location --output none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Purged $($acct.name)" }
        else { Write-Host "  ⚠ Could not purge $($acct.name) (may already be gone)." -ForegroundColor Yellow }
    }
}

# --- Clear saved suffix so the next deploy generates a fresh one ---
if ((Test-Path $SuffixFile) -and ((Get-Content $SuffixFile -Raw).Trim() -eq $Suffix)) {
    Remove-Item $SuffixFile -Force
    Write-Host "  ✓ Cleared $SuffixFile"
}

Write-Host "`n════════════════════════════════════════════════════════════════"
Write-Host "✓ Teardown complete for suffix: $Suffix (scenario: $Scenario)"
Write-Host "════════════════════════════════════════════════════════════════"
