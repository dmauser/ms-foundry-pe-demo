#!/usr/bin/env bash
###############################################################################
# Scenario 2 — Step B: Enforce the Network Security Perimeter on the Foundry.
# Creates the NSP + profile + identity-based (Subscriptions) inbound rule and
# associates the existing Foundry in Enforced mode. After this:
#   - NSP App Service (managed identity) -> ALLOWED
#   - Laptop (user az login token)       -> BLOCKED
# The Foundry endpoint stays public in DNS; the boundary is at the identity layer.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load suffix ---
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"
if [[ ! -f "$SUFFIX_FILE" ]]; then
    echo "❌ No .deploy-suffix file found. Run Scenario 1 (01) and Scenario 2 Step A (03) first."
    exit 1
fi
SUFFIX=$(cat "$SUFFIX_FILE")
echo "Using deployment suffix: $SUFFIX"

RESOURCE_GROUP="rg-foundry-demo-$SUFFIX"
LOCATION="centralus"

# --- Prerequisite: register NSP preview feature flags -------------------------
# Network Security Perimeter support for Azure OpenAI / Cognitive Services is in
# public preview and requires TWO subscription feature flags to be registered,
# otherwise the perimeter association provisions at the control plane but the
# data plane does NOT enforce it (user tokens keep getting HTTP 200 instead of
# 403). Ref: https://learn.microsoft.com/azure/ai-services/openai/how-to/network-security-perimeter
echo -e "\n▶ Ensuring NSP preview feature flags are registered..."
register_feature() {
    local ns="$1" name="$2"
    local state
    state=$(az feature show --namespace "$ns" --name "$name" --query "properties.state" -o tsv 2>/dev/null || true)
    if [[ "$state" != "Registered" ]]; then
        echo "  Registering $ns/$name (was: ${state:-unknown})..."
        az feature registration create --namespace "$ns" --name "$name" --output none 2>/dev/null || true
    else
        echo "  $ns/$name: already Registered"
    fi
}
wait_feature() {
    local ns="$1" name="$2" state deadline
    deadline=$(( $(date +%s) + 900 ))   # 15 minutes
    while true; do
        state=$(az feature show --namespace "$ns" --name "$name" --query "properties.state" -o tsv 2>/dev/null || true)
        [[ "$state" == "Registered" ]] && break
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "❌ Feature $ns/$name did not reach Registered in time (state: ${state:-unknown})." >&2
            exit 1
        fi
        echo "  Waiting for $name to register (state: ${state:-unknown})..."
        sleep 20
    done
}
register_feature "Microsoft.CognitiveServices" "OpenAI.NspPreview"
register_feature "Microsoft.Network" "AllowNSPInPublicPreview"
wait_feature "Microsoft.CognitiveServices" "OpenAI.NspPreview"
wait_feature "Microsoft.Network" "AllowNSPInPublicPreview"
# Re-register the providers so the newly-registered features propagate.
az provider register --namespace Microsoft.CognitiveServices --output none 2>/dev/null || true
az provider register --namespace Microsoft.Network --output none 2>/dev/null || true
echo "  ✓ NSP preview features registered."

# --- Deploy Bicep (NSP + profile + inbound rule + association) ---
echo -e "\n▶ Deploying Network Security Perimeter via Bicep..."
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/04-nsp-enforce.bicep" \
    --parameters suffix="$SUFFIX" location="$LOCATION" \
    --output none

# --- Done ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Scenario 2 Step B complete! Foundry is now behind the NSP (Enforced)."
echo "  Allowed:  App Service managed identity (subscription inbound rule)"
echo "  Blocked:  Laptop / user tokens (not a managed identity)"
echo "  Endpoint DNS stays public — access is gated at the IDENTITY layer."
echo "  Note: data-plane enforcement can take a few minutes to propagate;"
echo "        if the laptop deny test still returns 200, wait ~3 min and retry."
echo "════════════════════════════════════════════════════════════════"
