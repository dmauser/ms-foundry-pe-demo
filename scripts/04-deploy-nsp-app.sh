#!/usr/bin/env bash
###############################################################################
# Scenario 3 — Step A: Deploy the second (NSP) App Service.
# Reuses the Scenario 1 Foundry + App Service Plan (same suffix). Deploys a new
# App Service WITHOUT VNet integration, then builds & zip-deploys the app.
# The Foundry stays public here, so both laptop and app can call it.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load suffix (from Scenario 1) ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix-s3"
if [[ ! -f "$SUFFIX_FILE" ]]; then
    echo "❌ No .deploy-suffix-s3 file found. Run the Scenario 3 baseline first (01-deploy-public-access.sh --scenario s3)."
    exit 1
fi
SUFFIX=$(cat "$SUFFIX_FILE")
echo "Using deployment suffix: $SUFFIX"

RESOURCE_GROUP="rg-foundry-s3-nsp-$SUFFIX"
LOCATION="centralus"
AI_SERVICES_NAME="foundry-demo-ai-$SUFFIX"
NSP_WEB_APP_NAME="foundry-demo-nsp-app-$SUFFIX"

# --- Ensure Foundry public access is enabled (baseline for Step A) ---
echo -e "\n▶ Ensuring Foundry public network access is enabled..."
AI_RESOURCE_ID=$(az cognitiveservices account show --name "$AI_SERVICES_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az resource update --ids "$AI_RESOURCE_ID" --set properties.publicNetworkAccess=Enabled --output none

# --- Grant the interactive deployer data-plane access (for the laptop before/after
#     test). Without the "Cognitive Services OpenAI User" role, a laptop token gets a
#     misleading 401 "lacks the required data action" (RBAC) instead of the NSP denial. ---
echo -e "\n▶ Granting the current user 'Cognitive Services OpenAI User' on the Foundry (for laptop testing)..."
DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "${DEPLOYER_OBJECT_ID:-}" ]]; then
    echo "  ⚠ Could not resolve the signed-in user (service principal?). Skipping — grant the role manually to run the laptop deny test."
else
    az role assignment create --assignee-object-id "$DEPLOYER_OBJECT_ID" --assignee-principal-type User \
        --role "Cognitive Services OpenAI User" --scope "$AI_RESOURCE_ID" --output none 2>/dev/null || true
    echo "  ✓ Role granted (data-plane RBAC can take a few minutes to take effect)."
fi

# --- Deploy Bicep (second App Service + RBAC) ---
echo -e "\n▶ Deploying NSP App Service via Bicep..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/04-nsp-app-service.bicep" \
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
echo "✓ Scenario 3 Step A complete! NSP App Service deployed (public Foundry)."
echo "  App URL: https://$NSP_WEB_APP_NAME.azurewebsites.net"
echo "  Next:    scripts/05-enforce-nsp.sh  (lock Foundry behind the perimeter)"
echo "════════════════════════════════════════════════════════════════"
