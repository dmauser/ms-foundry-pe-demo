#!/usr/bin/env bash
###############################################################################
# Phase 1: Deploy Azure AI Foundry Demo with Public Access
# Thin wrapper: Bicep handles all Azure resources. This script only handles
# suffix generation, resource group creation, Bicep deployment, and app deploy.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Suffix (generate once, reuse) ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"
if [[ -f "$SUFFIX_FILE" ]]; then
    SUFFIX=$(cat "$SUFFIX_FILE")
else
    SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 5)
    printf '%s' "$SUFFIX" > "$SUFFIX_FILE"
fi
echo "Using deployment suffix: $SUFFIX"

RESOURCE_GROUP="rg-foundry-demo-$SUFFIX"
LOCATION="centralus"
WEB_APP_NAME="foundry-demo-app-$SUFFIX"

# --- Step 1: Create Resource Group ---
echo -e "\n▶ Creating resource group: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# --- Step 2: Deploy Bicep (all infra) ---
echo -e "\n▶ Deploying infrastructure via Bicep..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/01-public-access.bicep" \
    --parameters suffix="$SUFFIX" location="$LOCATION" \
    --output none
echo "  ✓ Infrastructure deployed successfully"

# --- Step 3: Build .NET app ---
echo -e "\n▶ Building .NET application..."
SRC_DIR="$REPO_ROOT/src"
PUBLISH_DIR="$SRC_DIR/publish"
dotnet publish "$SRC_DIR" -c Release -o "$PUBLISH_DIR" --nologo -v quiet

# --- Step 4: Zip deploy ---
echo -e "\n▶ Deploying application to $WEB_APP_NAME..."
ZIP_FILE="$SRC_DIR/app.zip"
rm -f "$ZIP_FILE"
(cd "$PUBLISH_DIR" && zip -qr "$ZIP_FILE" .)
az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --src-path "$ZIP_FILE" --type zip --output none

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Phase 1 complete! Public access deployment finished."
echo "  App URL: https://$WEB_APP_NAME.azurewebsites.net"
echo "  Suffix:  $SUFFIX"
echo "════════════════════════════════════════════════════════════════"
