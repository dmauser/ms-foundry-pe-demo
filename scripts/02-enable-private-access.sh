#!/bin/bash

###############################################################################
# Phase 2: Convert Azure AI Foundry Demo to Private Endpoint Access
#
# This script converts the demo from public access to private endpoint access.
# It enables Azure AI Foundry to be accessed ONLY from the App Service via
# a private endpoint, while disabling public internet access.
#
# Prerequisites:
#   - Phase 1 deployment already completed (scripts/01-deploy-public-access.sh)
#   - Azure CLI installed (az command available)
#   - Logged in to Azure (az login)
#   - Appropriate Azure permissions (Network Contributor, Cognitive Services Contributor)
#
# Architecture:
#   App Service (VNet Integration) ──▶ Private Endpoint ──▶ Azure AI Foundry
#   └─ Private Subnet                                       (Private Access ONLY)
#
# Usage:
#   bash scripts/02-enable-private-access.sh
#
###############################################################################

set -e  # Exit on error

# ============================================================================
# VARIABLES - Must match Phase 1 deployment
# ============================================================================

RESOURCE_GROUP="rg-foundry-demo"
LOCATION="centralus"

# Azure AI Foundry
FOUNDRY_NAME="foundry-demo-ai"

# App Service
APP_SERVICE_NAME="foundry-demo-app"

# Network
VNET_NAME="foundry-demo-vnet"
APP_SERVICE_SUBNET="app-service-subnet"
FOUNDRY_SUBNET="foundry-subnet"

# Private Endpoint
PRIVATE_ENDPOINT_NAME="foundry-demo-pe"
PRIVATE_ENDPOINT_CONNECTION="foundry-demo-connection"

# Private DNS
PRIVATE_DNS_ZONE="privatelink.cognitiveservices.azure.com"
PRIVATE_DNS_LINK="foundry-demo-dns-link"

# ============================================================================
# Helper functions
# ============================================================================

log_step() {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "▶ $1"
    echo "════════════════════════════════════════════════════════════════"
}

log_info() {
    echo "  ℹ $1"
}

log_success() {
    echo "  ✓ $1"
}

log_warning() {
    echo "  ⚠ $1"
}

log_error() {
    echo "  ✗ $1"
}

# ============================================================================
# STEP 1: Enable App Service VNet Integration
# ============================================================================

log_step "Step 1: Enable App Service VNet Integration"

log_info "Adding VNet integration to App Service (subnet: $APP_SERVICE_SUBNET)..."
az webapp vnet-integration add \
    --name "$APP_SERVICE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --vnet "$VNET_NAME" \
    --subnet "$APP_SERVICE_SUBNET" \
    2>/dev/null || log_warning "VNet integration may already be enabled"

log_success "App Service VNet Integration enabled"

# ============================================================================
# STEP 2: Disable Private Endpoint Network Policies on Foundry Subnet
# ============================================================================

log_step "Step 2: Disable Private Endpoint Network Policies"

log_info "Updating subnet policies on $FOUNDRY_SUBNET..."
az network vnet subnet update \
    --name "$FOUNDRY_SUBNET" \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --disable-private-endpoint-network-policies true

log_success "Private endpoint network policies disabled on $FOUNDRY_SUBNET"

# ============================================================================
# STEP 3: Create Private Endpoint
# ============================================================================

log_step "Step 3: Create Private Endpoint for Foundry Resource"

if az network private-endpoint show --name "$PRIVATE_ENDPOINT_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "Private endpoint '$PRIVATE_ENDPOINT_NAME' already exists. Skipping creation."
else
    log_info "Retrieving Foundry resource ID..."
    FOUNDRY_ID=$(az cognitiveservices account show \
        --name "$FOUNDRY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query id -o tsv)
    
    log_info "Creating private endpoint..."
    az network private-endpoint create \
        --name "$PRIVATE_ENDPOINT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --subnet "$FOUNDRY_SUBNET" \
        --private-connection-resource-id "$FOUNDRY_ID" \
        --group-id account \
        --connection-name "$PRIVATE_ENDPOINT_CONNECTION"
    
    log_success "Private endpoint created"
fi

# ============================================================================
# STEP 4: Create Private DNS Zone
# ============================================================================

log_step "Step 4: Create Private DNS Zone"

if az network private-dns zone show --resource-group "$RESOURCE_GROUP" --name "$PRIVATE_DNS_ZONE" &>/dev/null; then
    log_warning "Private DNS zone '$PRIVATE_DNS_ZONE' already exists. Skipping creation."
else
    log_info "Creating private DNS zone..."
    az network private-dns zone create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$PRIVATE_DNS_ZONE"
    
    log_success "Private DNS zone created"
fi

# ============================================================================
# STEP 5: Link Private DNS Zone to VNet
# ============================================================================

log_step "Step 5: Link Private DNS Zone to VNet"

if az network private-dns link vnet show \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "$PRIVATE_DNS_ZONE" \
    --name "$PRIVATE_DNS_LINK" &>/dev/null; then
    log_warning "DNS link '$PRIVATE_DNS_LINK' already exists. Skipping creation."
else
    log_info "Linking DNS zone to VNet..."
    az network private-dns link vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --zone-name "$PRIVATE_DNS_ZONE" \
        --name "$PRIVATE_DNS_LINK" \
        --virtual-network "$VNET_NAME" \
        --registration-enabled false
    
    log_success "DNS zone linked to VNet"
fi

# ============================================================================
# STEP 6: Create DNS Zone Group for Private Endpoint
# ============================================================================

log_step "Step 6: Create DNS Zone Group for Private Endpoint"

if az network private-endpoint dns-zone-group show \
    --resource-group "$RESOURCE_GROUP" \
    --endpoint-name "$PRIVATE_ENDPOINT_NAME" \
    --name "default" &>/dev/null; then
    log_warning "DNS zone group already exists. Skipping creation."
else
    log_info "Creating DNS zone group..."
    az network private-endpoint dns-zone-group create \
        --resource-group "$RESOURCE_GROUP" \
        --endpoint-name "$PRIVATE_ENDPOINT_NAME" \
        --name "default" \
        --private-dns-zone "$PRIVATE_DNS_ZONE" \
        --zone-name "cognitiveservices"
    
    log_success "DNS zone group created (A record will be auto-registered)"
fi

# ============================================================================
# STEP 7: Disable Public Network Access on Foundry Resource
# ============================================================================

log_step "Step 7: Disable Public Network Access"

log_info "Updating Foundry resource to block public access..."
az cognitiveservices account update \
    --name "$FOUNDRY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --public-network-access Disabled

log_success "Public network access DISABLED on Foundry resource"

# ============================================================================
# VALIDATION & VERIFICATION
# ============================================================================

log_step "✓ Phase 2 Deployment Complete (Private Endpoint Access)"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "VALIDATION COMMANDS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Verify private endpoint creation:"
echo "   az network private-endpoint show --name $PRIVATE_ENDPOINT_NAME --resource-group $RESOURCE_GROUP"
echo ""
echo "2. Verify private DNS zone group (A record should be registered):"
echo "   az network private-endpoint dns-zone-group show --resource-group $RESOURCE_GROUP --endpoint-name $PRIVATE_ENDPOINT_NAME --name default"
echo ""
echo "3. Verify public network access is DISABLED on Foundry:"
echo "   az cognitiveservices account show --name $FOUNDRY_NAME --resource-group $RESOURCE_GROUP --query properties.publicNetworkAccess"
echo ""
echo "4. Test diagnostics from App Service (should work - private access via VNet):"
echo "   curl https://${APP_SERVICE_NAME}.azurewebsites.net/api/diagnostics"
echo "   Expected: Status 🟢 (private IP), access through Private Endpoint"
echo ""
echo "5. Test AI API from App Service (should work - private access):"
echo "   curl \"https://${APP_SERVICE_NAME}.azurewebsites.net/api/ask?prompt=Hello%20Private%20Endpoint\""
echo "   Expected: AI response via private connection"
echo ""
echo "6. Verify local access is BLOCKED (from your laptop/local environment):"
echo "   curl \"https://foundry-demo-ai.cognitiveservices.azure.com/openai/models\" -H \"api-key: <key>\""
echo "   Expected: 403 Forbidden (public access blocked)"
echo ""
echo "7. Check DNS resolution from VNet (via App Service or VM in VNet):"
echo "   nslookup foundry-demo-ai.cognitiveservices.azure.com"
echo "   Expected: Points to private IP in VNet (10.0.x.x range)"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Private endpoint access successfully enabled!"
echo "✓ Foundry resource now accessible ONLY from App Service via VNet"
echo "✓ Public internet access is BLOCKED"
echo "════════════════════════════════════════════════════════════════"
