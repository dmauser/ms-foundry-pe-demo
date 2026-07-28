#!/usr/bin/env bash
###############################################################################
# Scenario 2 — Step A: Deploy the second (NSP) App Service.
# Reuses the Scenario 1 Foundry + App Service Plan (same suffix). Deploys a new
# App Service WITHOUT VNet integration, then builds & zip-deploys the app.
# The Foundry stays public here, so both laptop and app can call it.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load suffix (from Scenario 1) ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"
if [[ ! -f "$SUFFIX_FILE" ]]; then
    echo "❌ No .deploy-suffix file found. Run Scenario 1 (01-deploy-public-access.sh) first."
    exit 1
fi
SUFFIX=$(cat "$SUFFIX_FILE")
echo "Using deployment suffix: $SUFFIX"

RESOURCE_GROUP="rg-foundry-demo-$SUFFIX"
LOCATION="centralus"
AI_SERVICES_NAME="foundry-demo-ai-$SUFFIX"
NSP_WEB_APP_NAME="foundry-demo-nsp-app-$SUFFIX"

# --- Ensure Foundry public access is enabled (baseline for Step A) ---
echo -e "\n▶ Ensuring Foundry public network access is enabled..."
AI_RESOURCE_ID=$(az cognitiveservices account show --name "$AI_SERVICES_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az resource update --ids "$AI_RESOURCE_ID" --set properties.publicNetworkAccess=Enabled --output none

# --- Deploy Bicep (second App Service + RBAC) ---
echo -e "\n▶ Deploying NSP App Service via Bicep..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/03-nsp-app-service.bicep" \
    --parameters suffix="$SUFFIX" location="$LOCATION" \
    --output none
echo "  ✓ Infrastructure deployed successfully"

# --- Build .NET app ---
echo -e "\n▶ Building .NET application..."
SRC_DIR="$REPO_ROOT/src"
PUBLISH_DIR="$REPO_ROOT/.publish"
rm -rf "$PUBLISH_DIR"
dotnet publish "$SRC_DIR" -c Release -o "$PUBLISH_DIR" --nologo -v quiet

# --- Zip deploy ---
echo -e "\n▶ Deploying application to $NSP_WEB_APP_NAME..."
ZIP_FILE="$REPO_ROOT/.publish.zip"
rm -f "$ZIP_FILE"
(cd "$PUBLISH_DIR" && zip -qr "$ZIP_FILE" .)
az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$NSP_WEB_APP_NAME" --src-path "$ZIP_FILE" --type zip --output none

# --- Cleanup build artifacts ---
rm -rf "$PUBLISH_DIR" "$ZIP_FILE"

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Scenario 2 Step A complete! NSP App Service deployed (public Foundry)."
echo "  App URL: https://$NSP_WEB_APP_NAME.azurewebsites.net"
echo "  Next:    scripts/04-enforce-nsp.sh  (lock Foundry behind the perimeter)"
echo "════════════════════════════════════════════════════════════════"
