#!/usr/bin/env bash
###############################################################################
# Phase 2: Enable Private Access for Azure AI Services
# Thin wrapper: Bicep handles private endpoint, DNS zone, and public access toggle.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load suffix ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"
if [[ ! -f "$SUFFIX_FILE" ]]; then
    echo "❌ No .deploy-suffix file found. Run Phase 1 first."
    exit 1
fi
SUFFIX=$(cat "$SUFFIX_FILE")
echo "Using deployment suffix: $SUFFIX"

RESOURCE_GROUP="rg-foundry-demo-$SUFFIX"
LOCATION="centralus"

# --- Deploy Bicep (private endpoint infra) ---
echo -e "\n▶ Deploying private access infrastructure via Bicep..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/02-private-access.bicep" \
    --parameters suffix="$SUFFIX" location="$LOCATION" \
    --output none

# --- Disable public network access ---
echo -e "\n▶ Disabling public network access on AI Services..."
AI_SERVICES_NAME="foundry-demo-ai-$SUFFIX"
AI_RESOURCE_ID=$(az cognitiveservices account show --name "$AI_SERVICES_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az resource update --ids "$AI_RESOURCE_ID" --set properties.publicNetworkAccess=Disabled --output none

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Phase 2 complete! Private access enabled."
echo "  AI Services now only accessible via private endpoint."
echo "  DNS zone: privatelink.cognitiveservices.azure.com"
echo "════════════════════════════════════════════════════════════════"
