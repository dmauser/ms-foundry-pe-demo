#!/usr/bin/env bash
###############################################################################
# Phase 1: Deploy Azure AI Foundry Demo with Public Access
# Thin wrapper: Bicep handles all Azure resources. This script only handles
# suffix generation, resource group creation, Bicep deployment, and app deploy.
#
# Shared baseline for Scenario 1 (Private Endpoint) and Scenario 3 (NSP). Pick
# which scenario's resource group to create with --scenario:
#   --scenario s1  -> rg-foundry-s1-pe-<suffix>   (suffix file .deploy-suffix-s1)  [default]
#   --scenario s3  -> rg-foundry-s3-nsp-<suffix>  (suffix file .deploy-suffix-s3)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Args ---
SCENARIO="s1"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIO="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Scenario -> RG prefix + suffix file ---
if [[ "$SCENARIO" == "s3" ]]; then
    RG_PREFIX="rg-foundry-s3-nsp-"
    SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix-s3"
elif [[ "$SCENARIO" == "s1" ]]; then
    RG_PREFIX="rg-foundry-s1-pe-"
    SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix-s1"
else
    echo "✗ Unknown --scenario '$SCENARIO' (expected 's1' or 's3')." >&2
    exit 1
fi

# --- Suffix (generate once, reuse) ---
if [[ -f "$SUFFIX_FILE" ]]; then
    SUFFIX=$(cat "$SUFFIX_FILE")
else
    SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 5)
    printf '%s' "$SUFFIX" > "$SUFFIX_FILE"
fi
echo "Using deployment suffix: $SUFFIX (scenario: $SCENARIO)"

RESOURCE_GROUP="$RG_PREFIX$SUFFIX"
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
PUBLISH_DIR="$REPO_ROOT/.publish"
rm -rf "$PUBLISH_DIR"
dotnet publish "$SRC_DIR" -c Release -o "$PUBLISH_DIR" --nologo -v quiet

# --- Step 4: Zip deploy ---
echo -e "\n▶ Deploying application to $WEB_APP_NAME..."
ZIP_FILE="$REPO_ROOT/.publish.zip"
rm -f "$ZIP_FILE"
(cd "$PUBLISH_DIR" && zip -qr "$ZIP_FILE" .)
az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --src-path "$ZIP_FILE" --type zip --output none

# --- Cleanup build artifacts ---
rm -rf "$PUBLISH_DIR" "$ZIP_FILE"

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Phase 1 complete! Public access deployment finished."
echo "  App URL: https://$WEB_APP_NAME.azurewebsites.net"
echo "  Suffix:  $SUFFIX"
echo "════════════════════════════════════════════════════════════════"
