#!/bin/bash

###############################################################################
# Phase 1: Deploy Azure AI Foundry Demo with Public Access
# 
# This script documents the deployment of the Azure AI Foundry demo
# in its "BEFORE" state (public access enabled).
#
# Prerequisites:
#   - Azure CLI installed (az command available)
#   - Logged in to Azure (az login)
#   - .NET SDK installed (for dotnet publish)
#   - Appropriate Azure permissions (Contributor role or equivalent)
#
# Usage:
#   bash scripts/01-deploy-public-access.sh
#
###############################################################################

set -e  # Exit on error

# ============================================================================
# RANDOM SUFFIX - Ensures globally unique resource names so multiple users
# can deploy this demo without naming conflicts. Generated once and reused
# across all resources in this deployment.
# ============================================================================

SUFFIX_FILE="$(dirname "$0")/.deploy-suffix"
if [ -f "$SUFFIX_FILE" ]; then
    SUFFIX=$(cat "$SUFFIX_FILE")
else
    SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5)
    echo "$SUFFIX" > "$SUFFIX_FILE"
fi
echo "Using deployment suffix: $SUFFIX"

# ============================================================================
# VARIABLES - Customize these for your environment
# ============================================================================

RESOURCE_GROUP="rg-foundry-demo-${SUFFIX}"
LOCATION="centralus"

# Azure AI Foundry (AIServices)
FOUNDRY_NAME="foundry-demo-ai-${SUFFIX}"
FOUNDRY_SKU="S0"

# App Service
APP_SERVICE_NAME="foundry-demo-app-${SUFFIX}"
APP_SERVICE_PLAN="foundry-demo-plan-${SUFFIX}"
APP_SERVICE_SKU="B1"

# Network
VNET_NAME="foundry-demo-vnet-${SUFFIX}"
VNET_CIDR="10.0.0.0/16"
APP_SERVICE_SUBNET="app-service-subnet"
APP_SERVICE_SUBNET_CIDR="10.0.1.0/24"
FOUNDRY_SUBNET="foundry-subnet"
FOUNDRY_SUBNET_CIDR="10.0.2.0/24"

# Managed Identity
IDENTITY_NAME="foundry-demo-identity-${SUFFIX}"

# Model deployment
MODEL_NAME="gpt-4o-mini"
MODEL_VERSION="2"

# Application
APP_DIR="."  # Root directory of .NET application
BUILD_DIR="bin/Release/net8.0/publish"

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

# ============================================================================
# STEP 1: Create Resource Group
# ============================================================================

log_step "Step 1: Create Resource Group"

if az group exists --name "$RESOURCE_GROUP" | grep -q true; then
    log_warning "Resource group '$RESOURCE_GROUP' already exists. Skipping creation."
else
    log_info "Creating resource group in $LOCATION..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION"
    log_success "Resource group created"
fi

# ============================================================================
# STEP 2: Create Azure AI Foundry Resource (AIServices)
# ============================================================================

log_step "Step 2: Create Azure AI Foundry Resource (AIServices)"

if az cognitiveservices account show --name "$FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "Foundry resource '$FOUNDRY_NAME' already exists. Skipping creation."
    FOUNDRY_ID=$(az cognitiveservices account show --name "$FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
else
    log_info "Creating Azure AI Foundry resource..."
    az cognitiveservices account create \
        --name "$FOUNDRY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --kind AIServices \
        --sku "$FOUNDRY_SKU" \
        --location "$LOCATION" \
        --custom-domain "$FOUNDRY_NAME"
    
    FOUNDRY_ID=$(az cognitiveservices account show --name "$FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    log_success "Foundry resource created: $FOUNDRY_ID"
fi

# ============================================================================
# STEP 3: Deploy Model to Foundry Resource
# ============================================================================

log_step "Step 3: Deploy Model (gpt-4o-mini, GlobalStandard)"

log_info "Deploying $MODEL_NAME model..."
az cognitiveservices account deployment create \
    --name "$FOUNDRY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$MODEL_NAME" \
    --model-name "$MODEL_NAME" \
    --model-version "$MODEL_VERSION" \
    --sku-name "GlobalStandard" \
    --sku-capacity 1 \
    2>/dev/null || log_warning "Model deployment already exists or creation skipped"

log_success "Model deployment configured"

# ============================================================================
# STEP 4: Create Virtual Network and Subnets
# ============================================================================

log_step "Step 4: Create Virtual Network and Subnets"

if az network vnet show --name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "VNet '$VNET_NAME' already exists. Skipping creation."
else
    log_info "Creating VNet $VNET_NAME ($VNET_CIDR)..."
    az network vnet create \
        --name "$VNET_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --address-prefix "$VNET_CIDR"
    log_success "VNet created"
fi

# Create App Service subnet
if az network vnet subnet show --name "$APP_SERVICE_SUBNET" --vnet-name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "Subnet '$APP_SERVICE_SUBNET' already exists. Skipping creation."
else
    log_info "Creating subnet $APP_SERVICE_SUBNET ($APP_SERVICE_SUBNET_CIDR)..."
    az network vnet subnet create \
        --name "$APP_SERVICE_SUBNET" \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --address-prefix "$APP_SERVICE_SUBNET_CIDR"
    log_success "App Service subnet created"
fi

# Create Foundry subnet
if az network vnet subnet show --name "$FOUNDRY_SUBNET" --vnet-name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "Subnet '$FOUNDRY_SUBNET' already exists. Skipping creation."
else
    log_info "Creating subnet $FOUNDRY_SUBNET ($FOUNDRY_SUBNET_CIDR)..."
    az network vnet subnet create \
        --name "$FOUNDRY_SUBNET" \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --address-prefix "$FOUNDRY_SUBNET_CIDR"
    log_success "Foundry subnet created"
fi

# ============================================================================
# STEP 5: Create App Service Plan and Web App
# ============================================================================

log_step "Step 5: Create App Service Plan and Web App"

if az appservice plan show --name "$APP_SERVICE_PLAN" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "App Service Plan '$APP_SERVICE_PLAN' already exists. Skipping creation."
else
    log_info "Creating App Service Plan (B1 Linux)..."
    az appservice plan create \
        --name "$APP_SERVICE_PLAN" \
        --resource-group "$RESOURCE_GROUP" \
        --sku B1 \
        --is-linux
    log_success "App Service Plan created"
fi

if az webapp show --name "$APP_SERVICE_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    log_warning "Web App '$APP_SERVICE_NAME' already exists. Skipping creation."
else
    log_info "Creating Web App..."
    az webapp create \
        --name "$APP_SERVICE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --plan "$APP_SERVICE_PLAN" \
        --runtime "DOTNET|8.0"
    log_success "Web App created"
fi

# ============================================================================
# STEP 6: Create Managed Identity and Assign RBAC Role
# ============================================================================

log_step "Step 6: Create Managed Identity and Assign RBAC Role"

log_info "Enabling Managed Identity on App Service..."
az webapp identity assign \
    --name "$APP_SERVICE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --identities [system]

PRINCIPAL_ID=$(az webapp identity show \
    --name "$APP_SERVICE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv)

log_info "Assigning RBAC role (Cognitive Services User)..."
az role assignment create \
    --role "Cognitive Services User" \
    --assignee "$PRINCIPAL_ID" \
    --scope "$FOUNDRY_ID" \
    2>/dev/null || log_warning "Role assignment already exists or skipped"

log_success "Managed Identity configured with RBAC"

# ============================================================================
# STEP 7: Configure App Settings
# ============================================================================

log_step "Step 7: Configure App Settings"

FOUNDRY_ENDPOINT=$(az cognitiveservices account show \
    --name "$FOUNDRY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.endpoint -o tsv)

log_info "Setting app configuration..."
az webapp config appsettings set \
    --name "$APP_SERVICE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings \
        AzureAiFoundry__Endpoint="$FOUNDRY_ENDPOINT" \
        AzureAiFoundry__DeploymentName="$MODEL_NAME" \
        AzureAiFoundry__UseSystemAssignedIdentity="true"

log_success "App settings configured"

# ============================================================================
# STEP 8: Build and Deploy Application
# ============================================================================

log_step "Step 8: Build and Deploy Application"

log_info "Building .NET application (Release)..."
if [ -d "$APP_DIR" ]; then
    cd "$APP_DIR"
    dotnet publish -c Release -o "$BUILD_DIR" --no-restore
    log_success "Build completed"
    
    log_info "Creating deployment package..."
    PACKAGE_FILE="foundry-demo-app.zip"
    cd "$BUILD_DIR"
    zip -r "../../../../$PACKAGE_FILE" . -q
    cd "../../../../"
    log_success "Package created: $PACKAGE_FILE"
    
    log_info "Deploying to App Service..."
    az webapp deployment source config-zip \
        --name "$APP_SERVICE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --src "$PACKAGE_FILE"
    log_success "Application deployed"
    
    rm -f "$PACKAGE_FILE"
else
    log_warning "Application directory not found at $APP_DIR. Skipping deployment."
fi

# ============================================================================
# VALIDATION & VERIFICATION
# ============================================================================

log_step "✓ Phase 1 Deployment Complete (Public Access)"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "VALIDATION COMMANDS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Verify Foundry resource endpoint:"
echo "   az cognitiveservices account show --name $FOUNDRY_NAME --resource-group $RESOURCE_GROUP --query properties.endpoint"
echo ""
echo "2. Verify App Service is accessible:"
echo "   curl https://${APP_SERVICE_NAME}.azurewebsites.net/"
echo ""
echo "3. Test the diagnostics endpoint (verify Managed Identity works):"
echo "   curl https://${APP_SERVICE_NAME}.azurewebsites.net/api/diagnostics"
echo ""
echo "4. Test the AI API endpoint (simple prompt):"
echo "   curl \"https://${APP_SERVICE_NAME}.azurewebsites.net/api/ask?prompt=Hello%20Azure%20AI%20Foundry\""
echo ""
echo "5. Verify public network access is enabled on Foundry:"
echo "   az cognitiveservices account show --name $FOUNDRY_NAME --resource-group $RESOURCE_GROUP --query properties.publicNetworkAccess"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ All Phase 1 resources deployed successfully!"
echo "✓ Next step: Run scripts/02-enable-private-access.sh to convert to private endpoints"
echo "════════════════════════════════════════════════════════════════"
