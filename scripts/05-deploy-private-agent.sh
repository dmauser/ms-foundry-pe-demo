#!/usr/bin/env bash
###############################################################################
# Scenario 3 — Deploy the Private Foundry Agent (Standard Agent Setup + VNet
# injection) with its VNet-integrated test WebApp.
#
# Self-contained: own resource group, own suffix, region westus3 (Standard Agent
# Setup + gpt-5-mini supported). Does NOT touch Scenario 1/2 infra.
#
# Flow: register RPs -> create RG -> deploy Bicep (VNet + Storage/Cosmos/Search
# private + Foundry account/project network-injected + capability host + WebApp)
# -> build & zip-deploy the app -> best-effort seed (upload manuals -> vector
# store -> create agent) from inside the VNet via the WebApp's public front door.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Suffix (RG name only; all Azure resource names derive from the RG id) ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix-agent"
if [[ -f "$SUFFIX_FILE" ]]; then
    SUFFIX=$(cat "$SUFFIX_FILE")
else
    SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 5)
    printf '%s' "$SUFFIX" > "$SUFFIX_FILE"
fi
echo "Using deployment suffix: $SUFFIX"

LOCATION="westus3"
RESOURCE_GROUP="rg-foundry-agent-$SUFFIX"
BICEP_FILE="$REPO_ROOT/infra/05-private-agent/main.bicep"
DEPLOYMENT_NAME="scenario3-agent-$SUFFIX"

# --- Step 1: Register resource providers (idempotent) ---
echo -e "\n▶ Registering resource providers..."
for p in Microsoft.App Microsoft.CognitiveServices Microsoft.Search \
         Microsoft.Storage Microsoft.DocumentDB Microsoft.Web \
         Microsoft.Network Microsoft.OperationalInsights Microsoft.Insights; do
    az provider register --namespace "$p" --output none 2>/dev/null || true
done
echo "  ✓ Providers registered (registration continues in the background)"

# --- Step 2: Create Resource Group ---
echo -e "\n▶ Creating resource group: $RESOURCE_GROUP ($LOCATION)"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# --- Step 3: Deploy Bicep (all infra) ---
echo -e "\n▶ Deploying infrastructure via Bicep (this takes ~10-15 min)..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --template-file "$BICEP_FILE" \
    --parameters location="$LOCATION" \
    --output none
echo "  ✓ Infrastructure deployed successfully"

# --- Step 4: Read deployment outputs (names derive from the RG id) ---
OUTPUTS=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query properties.outputs -o json)
WEB_APP_NAME=$(echo "$OUTPUTS" | jq -r '.webAppName.value')
WEB_APP_URL=$(echo "$OUTPUTS" | jq -r '.webAppUrl.value')
PROJECT_ENDPOINT=$(echo "$OUTPUTS" | jq -r '.projectEndpoint.value')
if [[ -z "$WEB_APP_NAME" || "$WEB_APP_NAME" == "null" ]]; then
    echo "❌ Deployment did not return a webAppName (deployTestWebApp=false?)" >&2
    exit 1
fi
echo "  ✓ Test WebApp: $WEB_APP_NAME"

# --- Step 5: Build .NET app ---
echo -e "\n▶ Building .NET application..."
SRC_DIR="$REPO_ROOT/src"
PUBLISH_DIR="$REPO_ROOT/.publish"
rm -rf "$PUBLISH_DIR"
dotnet publish "$SRC_DIR" -c Release -o "$PUBLISH_DIR" --nologo -v quiet

# --- Step 6: Zip deploy ---
echo -e "\n▶ Deploying application to $WEB_APP_NAME..."
ZIP_FILE="$REPO_ROOT/.publish.zip"
rm -f "$ZIP_FILE"
(cd "$PUBLISH_DIR" && zip -qr "$ZIP_FILE" .)
az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --src-path "$ZIP_FILE" --type zip --output none

# --- Cleanup build artifacts ---
rm -rf "$PUBLISH_DIR" "$ZIP_FILE"

# --- Step 7: Best-effort seed (upload manuals -> vector store -> create agent) ---
# Runs inside the VNet via the WebApp's public front door. RBAC/app warm-up can
# lag, so retry a few times; if it doesn't take, click "Seed" in the UI.
echo -e "\n▶ Seeding the agent (best effort; RBAC propagation can take a few minutes)..."
SEEDED=false
for i in 1 2 3 4 5; do
    sleep 20
    RESP=$(curl -s -m 120 -X POST "$WEB_APP_URL/api/seed" || true)
    if echo "$RESP" | grep -q '"seeded":true'; then
        SEEDED=true
        echo "  ✓ Agent seeded"
        break
    fi
    echo "  … attempt $i did not complete yet"
done
if [[ "$SEEDED" != "true" ]]; then
    echo "  ⚠ Auto-seed did not complete — open the app and click '🌱 Seed manuals & create agent'."
fi

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Scenario 3 complete! Private Foundry Agent + VNet injection deployed."
echo "  App URL:          $WEB_APP_URL"
echo "  Project endpoint: $PROJECT_ENDPOINT"
echo "  Suffix:           $SUFFIX"
echo "  Try asking:       'Why is my washer showing error E4?'"
echo "  Tear down with:   scripts/99-teardown.sh  (choose the agent RG)"
echo "════════════════════════════════════════════════════════════════"
