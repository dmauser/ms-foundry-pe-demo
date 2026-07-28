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
echo "════════════════════════════════════════════════════════════════"
