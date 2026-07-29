#!/usr/bin/env bash
###############################################################################
# Teardown: Delete the Azure AI Foundry Demo lab
# Deletes the entire resource group (rg-foundry-demo-<suffix>), which cascades
# every resource created by phases 1-4 (Foundry, VNet, App Service plan, both
# web apps, the Network Security Perimeter, and Log Analytics).
#
# Usage:
#   ./99-teardown.sh                       # use saved suffix, prompt to confirm
#   ./99-teardown.sh --suffix abc12        # override the suffix
#   ./99-teardown.sh --subscription <id>   # target a specific subscription
#   ./99-teardown.sh --yes                 # skip the confirmation prompt
#   ./99-teardown.sh --no-wait             # return immediately (async delete)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"

SUFFIX=""
SUBSCRIPTION=""
ASSUME_YES="false"
NO_WAIT="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suffix)       SUFFIX="$2"; shift 2 ;;
        --subscription) SUBSCRIPTION="$2"; shift 2 ;;
        --yes|-y)       ASSUME_YES="true"; shift ;;
        --no-wait)      NO_WAIT="true"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Resolve suffix ---
if [[ -z "$SUFFIX" ]]; then
    if [[ -f "$SUFFIX_FILE" ]]; then
        SUFFIX=$(cat "$SUFFIX_FILE")
    else
        echo "✗ No suffix found. Pass --suffix <value> (scripts/.deploy-suffix is missing)." >&2
        exit 1
    fi
fi

RESOURCE_GROUP="rg-foundry-demo-$SUFFIX"

# --- Optional subscription target ---
if [[ -n "$SUBSCRIPTION" ]]; then
    az account set --subscription "$SUBSCRIPTION"
fi
CURRENT_SUB=$(az account show --query name -o tsv)

# --- Verify the resource group exists ---
if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
    echo "Resource group '$RESOURCE_GROUP' does not exist in subscription '$CURRENT_SUB'. Nothing to do."
    exit 0
fi

echo -e "\n▶ Resources to be deleted in '$RESOURCE_GROUP' (subscription: $CURRENT_SUB):"
az resource list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,type:type}" -o table

# --- Confirm ---
if [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    read -r -p "This will PERMANENTLY delete resource group '$RESOURCE_GROUP'. Type the suffix ('$SUFFIX') to confirm: " REPLY
    if [[ "$REPLY" != "$SUFFIX" ]]; then
        echo "Confirmation did not match. Aborting."
        exit 1
    fi
fi

# --- Delete ---
echo -e "\n▶ Deleting resource group: $RESOURCE_GROUP"
if [[ "$NO_WAIT" == "true" ]]; then
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    echo "  ✓ Deletion started (running asynchronously)."
else
    az group delete --name "$RESOURCE_GROUP" --yes
    echo "  ✓ Resource group deleted."
fi

# --- Clear saved suffix so the next deploy generates a fresh one ---
if [[ -f "$SUFFIX_FILE" && "$SUFFIX" == "$(cat "$SUFFIX_FILE")" ]]; then
    rm -f "$SUFFIX_FILE"
    echo "  ✓ Cleared scripts/.deploy-suffix"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Teardown complete for suffix: $SUFFIX"
echo "════════════════════════════════════════════════════════════════"
